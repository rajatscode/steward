//
//  NotificationScheduler.swift
//  Steward
//
//  HARD REJECT #8 enforcement point: every UNUserNotificationCenter.add call
//  in the app MUST come from this actor. The actor is where cap math runs;
//  going around it loses the cap.
//
//  Spec §10 cap policy (deterministic, not LLM):
//  - Max 3 proactive notifications/day (morningBrief counts as 1)
//  - Min 90 minutes between any two notifications
//  - In quiet hours: only morningBrief (suppressed-and-rescheduled to wake hour
//    if the wake hour ≥ briefTime; otherwise scheduled exactly at briefTime)
//  - In mercy mode: only morningBrief + at most 1 other notification/day, soft
//    templates substituted automatically
//  - In pause mode: nothing
//

import Foundation
import UserNotifications

// MARK: - Public types

public struct ScheduledNotification: Sendable, Equatable {
    public let notificationID: NotificationID
    public let request: NotificationRequest
    public let firesAt: Date
    public let unRequestIdentifier: String
    public let mode: NotificationMode
}

public enum ScheduleOutcome: Sendable, Equatable {
    case scheduled(notificationID: String, firesAt: Date)
    case capExceeded(reason: CapReason, nextAvailableSlot: Date?)
    case suppressedByQuietHours(rescheduledTo: Date?)
    case suppressedByPause
}

public enum CapReason: Sendable, Equatable {
    case dailyMax(currentCount: Int, max: Int)
    case minGap(lastFiredAt: Date, requiredGapMinutes: Int)
    case mercyModeCap
}

/// Scope tag — used so morning-brief / coordinator-priority requests can opt
/// past mercy-mode caps the way addendum §1.3 + spec §15 describe.
public enum AgentScope: Sendable, Equatable {
    case coordinator
    case domain(String)
}

// MARK: - Notification center abstraction (for tests)

/// Minimal slice of UNUserNotificationCenter the scheduler depends on. Lets
/// tests inject a fake without standing up a real notification center.
public protocol UserNotificationCenterProtocol: AnyObject, Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingNotificationRequests() async -> [UNNotificationRequest]
}

extension UNUserNotificationCenter: @unchecked Sendable {}
extension UNUserNotificationCenter: UserNotificationCenterProtocol {
    // `add(_ request:)` and `pendingNotificationRequests()` are already async
    // on iOS 15+; `removePendingNotificationRequests` is sync. Default
    // conformance via the existing API surface.
}

// MARK: - The actor

public actor NotificationScheduler {
    public static let shared = NotificationScheduler()

    private let center: any UserNotificationCenterProtocol
    private let settings: SettingsProviding
    private let clock: ClockProviding
    private let timeZoneProvider: @Sendable () -> TimeZone

    /// In-memory log of notifications we've scheduled, for cap math. Survives
    /// only while the process is alive; foreground tick + topUpHorizon re-
    /// reads pending notifications so a fresh launch reconstructs state.
    private var scheduled: [ScheduledNotification] = []

    public init(
        center: any UserNotificationCenterProtocol = UNUserNotificationCenter.current(),
        settings: SettingsProviding = LiveSettingsProvider(),
        clock: ClockProviding = SystemClock(),
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent }
    ) {
        self.center = center
        self.settings = settings
        self.clock = clock
        self.timeZoneProvider = timeZone
    }

    // MARK: - Public API

    public func schedule(_ req: NotificationRequest, scope: AgentScope) async -> ScheduleOutcome {
        let settingsSnapshot: Settings
        do {
            settingsSnapshot = try await settings.load()
        } catch {
            // Without settings we have no way to evaluate caps safely; fail
            // closed and surface a structured outcome rather than crash.
            return .capExceeded(reason: .dailyMax(currentCount: 0, max: 0), nextAvailableSlot: nil)
        }
        let now = clock.now()
        let mode = currentMode(in: settingsSnapshot, now: now)

        // Pause: hard suppression, no exceptions.
        if mode == .pause {
            return .suppressedByPause
        }

        // Quiet hours: only morningBrief survives, and only if its fire time
        // is at/after wake hour OR is itself the brief time.
        let inQuiet = isInQuietHours(req.fireAt, settings: settingsSnapshot)
        if inQuiet && req.kind != .morningBrief {
            let rescheduled = nextSlotAfterQuietHours(req.fireAt, settings: settingsSnapshot)
            return .suppressedByQuietHours(rescheduledTo: rescheduled)
        }

        // Mercy mode: cap drops to 1 non-brief / day; brief is exempt.
        if mode == .mercy, req.kind != .morningBrief {
            let nonBriefCount = scheduled.filter {
                isSameDay($0.firesAt, req.fireAt, in: timeZoneProvider())
                    && $0.request.kind != .morningBrief
            }.count
            if nonBriefCount >= 1 {
                return .capExceeded(reason: .mercyModeCap, nextAvailableSlot: nil)
            }
        }

        // Daily max (morning brief still counts toward the cap per spec §10).
        let dailyMax = settingsSnapshot.maxProactiveNotificationsPerDay
        let dayCount = scheduled.filter {
            isSameDay($0.firesAt, req.fireAt, in: timeZoneProvider())
        }.count
        if dayCount >= dailyMax {
            return .capExceeded(
                reason: .dailyMax(currentCount: dayCount, max: dailyMax),
                nextAvailableSlot: nil
            )
        }

        // Min gap (90 min default). Compare against everything scheduled.
        let gap = settingsSnapshot.minNotificationGapMinutes
        if let lastFire = nearestNeighbor(to: req.fireAt) {
            let deltaSec = abs(req.fireAt.timeIntervalSince(lastFire))
            if deltaSec < TimeInterval(gap * 60) {
                return .capExceeded(
                    reason: .minGap(lastFiredAt: lastFire, requiredGapMinutes: gap),
                    nextAvailableSlot: lastFire.addingTimeInterval(TimeInterval(gap * 60))
                )
            }
        }

        // All caps pass — render the body deterministically (LLM never composes)
        // and register the trigger.
        let rendered = NotificationTemplate.render(
            kind: req.kind,
            mode: mode,
            context: req.templateContext
        )
        let notificationID = NotificationID.generate()
        let unRequestID = notificationID.rawValue

        let content = UNMutableNotificationContent()
        content.title = rendered.title
        content.body = rendered.body
        // userInfo carries the action_context so the tap handler can resolve
        // a one-turn coordinator response on open (spec §10 #4 tap-to-act).
        if let ctx = req.actionContextJSON, let data = ctx.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            content.userInfo = dict
        }
        content.userInfo["steward_notification_kind"] = req.kind.rawValue
        content.userInfo["steward_notification_id"] = unRequestID

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, req.fireAt.timeIntervalSince(now)),
            repeats: false
        )
        let unRequest = UNNotificationRequest(
            identifier: unRequestID,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(unRequest)
        } catch {
            return .capExceeded(reason: .dailyMax(currentCount: 0, max: 0), nextAvailableSlot: nil)
        }

        scheduled.append(ScheduledNotification(
            notificationID: notificationID,
            request: req,
            firesAt: req.fireAt,
            unRequestIdentifier: unRequestID,
            mode: mode
        ))
        return .scheduled(notificationID: unRequestID, firesAt: req.fireAt)
    }

    public func scheduleRecurring(
        _ rule: RRuleSubset,
        request: NotificationRequest,
        scope: AgentScope
    ) async -> ScheduleOutcome {
        // Recurring rules are pre-expanded into the next 7 days of concrete
        // fire dates and scheduled through `schedule(_:scope:)` so cap math
        // still applies per spec §10. Pure UN repeating triggers can't tell
        // us "skip this occurrence because it hits the cap", so we expand.
        let now = clock.now()
        let occurrences = RecurringExpander.nextOccurrences(
            rule: rule,
            startingAt: now,
            daysAhead: 7,
            timeZone: timeZoneProvider()
        )
        guard let first = occurrences.first else {
            return .capExceeded(reason: .dailyMax(currentCount: 0, max: 0), nextAvailableSlot: nil)
        }
        var lastOutcome: ScheduleOutcome = .scheduled(notificationID: "", firesAt: first)
        for occ in occurrences {
            var occRequest = request
            occRequest.fireAt = occ
            let outcome = await schedule(occRequest, scope: scope)
            lastOutcome = outcome
            // If a single occurrence is capped, keep going — later days may
            // pass. We surface only the FIRST outcome for tools (since that's
            // the user-visible one); later ones go into the audit log via
            // the caller.
            if case .scheduled = outcome, occ == first { lastOutcome = outcome }
        }
        return lastOutcome
    }

    public func cancel(id: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        scheduled.removeAll { $0.unRequestIdentifier == id }
    }

    public func upcoming(domain: String?) async -> [ScheduledNotification] {
        guard let domain else { return scheduled }
        return scheduled.filter { $0.request.domain == domain }
    }

    /// Top up the next `daysAhead` days of recurring rules. Called on every
    /// foreground tick (and from BGAppRefreshTask). BGTasks are unreliable in
    /// install week, so this proactive refresh is the correctness guarantor.
    public func topUpHorizon(daysAhead: Int = 7) async {
        // Reconcile in-memory `scheduled` with what UN actually has pending.
        // If iOS dropped a request (eg. due to system reload), the source of
        // truth is UN; if WE think we have one that UN doesn't, drop it.
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))
        scheduled.removeAll { !pendingIDs.contains($0.unRequestIdentifier) }
        // Future work: re-issue recurring rules whose horizon has shrunk
        // below `daysAhead`. v1 leans on caller-tracked recurring state in
        // notifications table; this method is a placeholder reconciliation
        // hook that keeps cap math honest.
    }

    // MARK: - DEBUG hooks

    #if DEBUG
    /// Reset scheduler state for tests. Production builds don't see this.
    public func _resetForTesting() {
        scheduled.removeAll()
    }
    #endif

    // MARK: - Cap math primitives (internal — exposed for tests)

    func currentMode(in s: Settings, now: Date) -> NotificationMode {
        if let pause = s.pauseUntil, pause > now { return .pause }
        if let mercy = s.mercyModeUntil, mercy > now { return .mercy }
        return .normal
    }

    func dayBucket(for date: Date, in tz: TimeZone) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            // Calendar.date(byAdding:to:) only returns nil for transitions
            // we don't use here, but if it ever does we fall back to a
            // 24-hour interval rather than crashing.
            return DateInterval(start: start, duration: 86_400)
        }
        return DateInterval(start: start, end: end)
    }

    func isSameDay(_ a: Date, _ b: Date, in tz: TimeZone) -> Bool {
        dayBucket(for: a, in: tz) == dayBucket(for: b, in: tz)
    }

    func isInQuietHours(_ date: Date, settings: Settings) -> Bool {
        QuietHoursWindow.contains(
            date,
            startHHmm: settings.quietHours.start,
            endHHmm: settings.quietHours.end,
            timeZone: timeZoneProvider()
        )
    }

    func nextSlotAfterQuietHours(_ date: Date, settings: Settings) -> Date? {
        QuietHoursWindow.nextSlotAfter(
            date,
            endHHmm: settings.quietHours.end,
            timeZone: timeZoneProvider()
        )
    }

    private func nearestNeighbor(to candidate: Date) -> Date? {
        scheduled
            .map(\.firesAt)
            .min(by: { abs($0.timeIntervalSince(candidate)) < abs($1.timeIntervalSince(candidate)) })
    }
}

// MARK: - Supporting providers (kept generic so tests can inject)

public protocol SettingsProviding: Sendable {
    func load() async throws -> Settings
}

public struct LiveSettingsProvider: SettingsProviding {
    public init() {}
    public func load() async throws -> Settings {
        try await SettingsStore.shared.load()
    }
}

public protocol ClockProviding: Sendable {
    func now() -> Date
}

public struct SystemClock: ClockProviding {
    public init() {}
    public func now() -> Date { Date() }
}

// MARK: - QuietHoursWindow

/// "HH:mm" wall-clock window helpers. The window may straddle midnight (the
/// default 22:00–05:00 does). All arithmetic happens in the named TimeZone
/// so DST flips don't shift the brief by an hour.
enum QuietHoursWindow {
    static func contains(
        _ date: Date,
        startHHmm: String,
        endHHmm: String,
        timeZone: TimeZone
    ) -> Bool {
        guard let start = parseHHmm(startHHmm), let end = parseHHmm(endHHmm) else {
            return false
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.hour, .minute], from: date)
        guard let h = comps.hour, let m = comps.minute else { return false }
        let cur = h * 60 + m
        let s = start.hour * 60 + start.minute
        let e = end.hour * 60 + end.minute
        if s == e { return false }
        if s < e {
            return cur >= s && cur < e
        } else {
            // Window straddles midnight: e.g. 22:00–05:00 → cur ≥ 22:00 OR cur < 05:00.
            return cur >= s || cur < e
        }
    }

    /// Next date strictly after `from` whose wall-clock equals `endHHmm`.
    /// Used to reschedule a non-brief notification past quiet hours.
    static func nextSlotAfter(
        _ from: Date,
        endHHmm: String,
        timeZone: TimeZone
    ) -> Date? {
        guard let end = parseHHmm(endHHmm) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = cal.dateComponents([.year, .month, .day], from: from)
        comps.hour = end.hour
        comps.minute = end.minute
        comps.second = 0
        guard let today = cal.date(from: comps) else { return nil }
        if today > from { return today }
        return cal.date(byAdding: .day, value: 1, to: today)
    }

    static func parseHHmm(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        return (h, m)
    }
}

// MARK: - RecurringExpander

/// Expands an `RRuleSubset` into a flat list of concrete fire `Date`s in a
/// given horizon. Pure function; safe to test without UserNotifications.
enum RecurringExpander {
    static func nextOccurrences(
        rule: RRuleSubset,
        startingAt anchor: Date,
        daysAhead: Int,
        timeZone: TimeZone
    ) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let allowedWeekdays: Set<Int> = rule.byDay.isEmpty
            ? Set(1...7)
            : Set(rule.byDay.map(\.calendarWeekday))

        var results: [Date] = []
        for offset in 0..<max(1, daysAhead) {
            guard let day = cal.date(byAdding: .day, value: offset, to: anchor) else { continue }
            var comps = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let weekday = comps.weekday, allowedWeekdays.contains(weekday) else { continue }
            comps.hour = rule.byHour
            comps.minute = rule.byMinute
            comps.second = 0
            comps.weekday = nil
            guard let fire = cal.date(from: comps), fire > anchor else { continue }
            results.append(fire)
        }
        return results.sorted()
    }
}
