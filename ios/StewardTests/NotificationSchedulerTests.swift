//
//  NotificationSchedulerTests.swift
//  StewardTests
//
//  Track D test surface: cap, gap, quiet-hours, mercy, pause, mode template
//  substitution. Uses an in-memory fake UN center + a settings stub so the
//  test doesn't touch the real notification center.
//
//  Researcher landmine §3: cap math runs INSIDE the scheduler actor. Tests
//  drive the actor through its public API only.
//

import XCTest
import UserNotifications
@testable import Steward

// MARK: - In-memory fakes

/// In-memory implementation of UserNotificationCenterProtocol.
final class FakeUNCenter: UserNotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest) async throws {
        lock.lock(); defer { lock.unlock() }
        pending.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }
        return pending
    }
}

/// Settings stub — exposes one mutable value for tests.
final class FakeSettingsProvider: SettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: Settings

    init(snapshot: Settings) { self.snapshot = snapshot }

    func setSnapshot(_ s: Settings) {
        lock.lock(); defer { lock.unlock() }
        snapshot = s
    }

    func load() async throws -> Settings {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}

final class FixedClock: ClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ d: Date) { current = d }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Test helpers

private func defaultSettings() -> Settings {
    Settings(
        quietHours: Settings.QuietHours(start: "22:00", end: "05:00"),
        morningBriefTime: "07:00",
        maxProactiveNotificationsPerDay: 3,
        minNotificationGapMinutes: 90,
        mercyModeUntil: nil,
        pauseUntil: nil,
        csvMirrorEnabled: true,
        icloudDriveFolder: "Steward",
        voiceCaptureEnabled: true,
        defaultAgentTemperature: 0.7
    )
}

private func makeRequest(
    kind: NotificationKind = .instrumentNudge,
    at fireAt: Date,
    domain: String? = "health"
) -> NotificationRequest {
    NotificationRequest(
        kind: kind,
        domain: domain,
        instrumentID: nil,
        fireAt: fireAt,
        templateContext: TemplateContext(domainDisplayName: domain, instrumentName: "sleep"),
        actionContextJSON: nil,
        priority: 10
    )
}

/// Build a scheduler wired to in-memory fakes. Anchors NYC noon on 2026-05-17.
private func makeScheduler(
    settings: Settings = defaultSettings(),
    clockAt: Date? = nil
) -> (scheduler: NotificationScheduler, center: FakeUNCenter, clock: FixedClock, settings: FakeSettingsProvider) {
    let center = FakeUNCenter()
    let provider = FakeSettingsProvider(snapshot: settings)

    let tz = TimeZone(identifier: "America/New_York")!
    var noonComps = DateComponents()
    noonComps.year = 2026; noonComps.month = 5; noonComps.day = 17; noonComps.hour = 12; noonComps.minute = 0
    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
    let noon = clockAt ?? cal.date(from: noonComps)!

    let clock = FixedClock(noon)
    let scheduler = NotificationScheduler(
        center: center,
        settings: provider,
        clock: clock,
        timeZone: { tz }
    )
    return (scheduler, center, clock, provider)
}

// MARK: - Tests

final class NotificationSchedulerTests: XCTestCase {

    func testScheduleSucceedsWhenUnderCap() async {
        let (sched, center, clock, _) = makeScheduler()
        let outcome = await sched.schedule(
            makeRequest(at: clock.now().addingTimeInterval(60 * 60 * 2)),
            scope: .coordinator
        )
        guard case .scheduled = outcome else {
            return XCTFail("expected .scheduled, got \(outcome)")
        }
        let pending = await center.pendingNotificationRequests()
        XCTAssertEqual(pending.count, 1)
    }

    func testDailyMaxThreeBlocksFourth() async {
        // Cap = 3/day. Fire 5 requests on the same day spaced > 90 min apart.
        // Serial submission — cap math depends on call order.
        let (sched, _, clock, _) = makeScheduler()
        let base = clock.now()
        var outcomes: [ScheduleOutcome] = []
        for i in 0..<5 {
            let when = base.addingTimeInterval(TimeInterval((i + 1) * 60 * 100)) // 100 min apart
            outcomes.append(await sched.schedule(makeRequest(at: when), scope: .coordinator))
        }
        // First 3 land; 4th and 5th hit dailyMax.
        XCTAssertEqual(outcomes.count, 5)
        var scheduledCount = 0
        var dailyMaxCount = 0
        for o in outcomes {
            switch o {
            case .scheduled: scheduledCount += 1
            case .capExceeded(let reason, _):
                if case .dailyMax = reason { dailyMaxCount += 1 }
            default: break
            }
        }
        XCTAssertEqual(scheduledCount, 3)
        XCTAssertEqual(dailyMaxCount, 2)
    }

    func testMinGap90MinutesBlocksTooClose() async {
        let (sched, _, clock, _) = makeScheduler()
        let base = clock.now()
        let first = await sched.schedule(
            makeRequest(at: base.addingTimeInterval(60 * 60 * 2)),
            scope: .coordinator
        )
        guard case .scheduled = first else { return XCTFail("first should schedule") }
        let second = await sched.schedule(
            makeRequest(at: base.addingTimeInterval(60 * 60 * 2 + 60 * 30)), // 30 min later
            scope: .coordinator
        )
        switch second {
        case .capExceeded(let reason, let nextSlot):
            if case .minGap(_, let gap) = reason {
                XCTAssertEqual(gap, 90)
                XCTAssertNotNil(nextSlot)
            } else {
                XCTFail("expected minGap reason, got \(reason)")
            }
        default:
            XCTFail("expected .capExceeded, got \(second)")
        }
    }

    func testQuietHoursSuppressesNonBrief() async {
        // 23:00 local — inside 22:00–05:00 quiet hours.
        let tz = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 17; comps.hour = 23; comps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let inQuiet = cal.date(from: comps)!

        var earlyClock = DateComponents()
        earlyClock.year = 2026; earlyClock.month = 5; earlyClock.day = 17; earlyClock.hour = 12
        let noon = cal.date(from: earlyClock)!

        let (sched, _, _, _) = makeScheduler(clockAt: noon)
        let outcome = await sched.schedule(
            makeRequest(kind: .instrumentNudge, at: inQuiet),
            scope: .coordinator
        )
        guard case .suppressedByQuietHours(let resched) = outcome else {
            return XCTFail("expected suppressedByQuietHours, got \(outcome)")
        }
        XCTAssertNotNil(resched)
    }

    func testQuietHoursAllowsMorningBrief() async {
        let tz = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 17; comps.hour = 4; comps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let inQuiet = cal.date(from: comps)!

        let (sched, _, _, _) = makeScheduler()
        // morningBrief during quiet hours should still schedule.
        let outcome = await sched.schedule(
            makeRequest(kind: .morningBrief, at: inQuiet),
            scope: .coordinator
        )
        guard case .scheduled = outcome else {
            return XCTFail("morning brief should schedule in quiet hours; got \(outcome)")
        }
    }

    func testMercyModeCapsToOneNonBrief() async {
        var s = defaultSettings()
        s.mercyModeUntil = Date(timeIntervalSinceNow: 24 * 60 * 60)
        let (sched, _, clock, _) = makeScheduler(settings: s)
        let base = clock.now()

        // Brief at 7am tomorrow — allowed.
        let briefOutcome = await sched.schedule(
            makeRequest(kind: .morningBrief, at: base.addingTimeInterval(60 * 60 * 5)),
            scope: .coordinator
        )
        guard case .scheduled = briefOutcome else { return XCTFail() }

        // One non-brief — allowed.
        let firstOutcome = await sched.schedule(
            makeRequest(kind: .instrumentNudge, at: base.addingTimeInterval(60 * 60 * 8)),
            scope: .coordinator
        )
        guard case .scheduled = firstOutcome else { return XCTFail() }

        // Second non-brief — blocked.
        let secondOutcome = await sched.schedule(
            makeRequest(kind: .windDown, at: base.addingTimeInterval(60 * 60 * 11)),
            scope: .coordinator
        )
        switch secondOutcome {
        case .capExceeded(let reason, _):
            if case .mercyModeCap = reason { /* good */ } else {
                XCTFail("expected mercyModeCap, got \(reason)")
            }
        default:
            XCTFail("expected mercy cap, got \(secondOutcome)")
        }
    }

    func testPauseModeSuppressesEverything() async {
        var s = defaultSettings()
        s.pauseUntil = Date(timeIntervalSinceNow: 24 * 60 * 60)
        let (sched, _, clock, _) = makeScheduler(settings: s)
        let outcome = await sched.schedule(
            makeRequest(kind: .morningBrief, at: clock.now().addingTimeInterval(60 * 60)),
            scope: .coordinator
        )
        XCTAssertEqual(outcome, .suppressedByPause)
    }

    func testTemplateRendererProducesModeSpecificCopy() {
        let context = TemplateContext(
            domainDisplayName: "Health",
            instrumentName: "sleep",
            briefTimeDisplay: "7am"
        )
        let normal = NotificationTemplate.render(kind: .windDown, mode: .normal, context: context)
        let mercy = NotificationTemplate.render(kind: .windDown, mode: .mercy, context: context)
        XCTAssertNotEqual(normal, mercy, "mercy mode must produce different copy than normal")
        XCTAssertTrue(mercy.body.contains("if it feels okay") || mercy.body.contains("Small win"))
    }
}
