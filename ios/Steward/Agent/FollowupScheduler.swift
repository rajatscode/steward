//
//  FollowupScheduler.swift
//  Steward — Track B
//
//  Implements the day-0 afternoon followup notification from
//  design/coordinator-empty-state-v2.md §6.
//
//  Rule (verbatim from §6.1):
//   - Schedule (now + 5h 30m), clamped to [13:00, 17:00] local.
//   - If outside that window, snap to the nearest edge.
//   - `kind: onboarding_followup`, scheduled_by: coordinator.
//   - Never repeats.
//   - If quiet hours overlap, suppress entirely (the scheduler enforces
//     this in §1.3; we pass the request through and rely on the actor).
//
//  Notification body copy is verbatim from §6.2 (three variants).
//  LLM-composed bodies = §4 hard reject #6 — these are fixed templates.
//

import Foundation

/// Outcome of a single onboarding-followup schedule attempt.
public enum FollowupSchedulingOutcome: Sendable, Equatable {
    case scheduled(notificationID: String, firesAt: Date)
    case skippedNoEngagement   // Branch C tail with neither domain nor event
    case suppressedByQuietHours
    case suppressedByPause
    case capExceeded
}

/// Snapshot of what happened in the empty-state script — picks which of
/// the three §6.2 templates fires.
public struct OnboardingOutcome: Sendable, Equatable {
    public let spawnedDomainDisplayName: String?
    public let capturedAtLeastOneEvent: Bool

    public init(spawnedDomainDisplayName: String?, capturedAtLeastOneEvent: Bool) {
        self.spawnedDomainDisplayName = spawnedDomainDisplayName
        self.capturedAtLeastOneEvent = capturedAtLeastOneEvent
    }
}

public actor FollowupScheduler {
    private let scheduler: NotificationScheduler
    private let clock: @Sendable () -> Date

    public init(
        scheduler: NotificationScheduler = .shared,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.clock = clock
    }

    /// Computes the fire time and schedules the followup. Pure-logic
    /// helpers below are exposed for unit tests.
    public func schedule(
        outcome: OnboardingOutcome,
        timezone: TimeZone = .autoupdatingCurrent
    ) async -> FollowupSchedulingOutcome {
        if outcome.spawnedDomainDisplayName == nil && !outcome.capturedAtLeastOneEvent {
            return .skippedNoEngagement
        }

        let now = clock()
        let fireAt = Self.computeFireTime(now: now, timezone: timezone)

        let (title, body) = Self.templateCopy(outcome: outcome)

        let request = NotificationRequest(
            kind: .onboardingFollowup,
            title: title,
            body: body,
            firesAt: fireAt,
            domain: nil,
            instrumentID: nil,
            actionContextJSON: #"{"open_tab":"chat","focus_input":true,"prime_mic":true}"#
        )

        let outcomeFromScheduler = await scheduler.schedule(request, scope: .coordinator)
        switch outcomeFromScheduler {
        case .scheduled(let id, let firesAt):
            return .scheduled(notificationID: id, firesAt: firesAt)
        case .suppressedByQuietHours:
            return .suppressedByQuietHours
        case .suppressedByPause:
            return .suppressedByPause
        case .capExceeded:
            return .capExceeded
        }
    }

    // MARK: - Pure helpers (unit-testable)

    /// (now + 5h30m), clamped to [13:00, 17:00] local. Outside that
    /// window → snap to nearest edge per §6.1.
    public static func computeFireTime(now: Date, timezone: TimeZone) -> Date {
        let candidate = now.addingTimeInterval(5 * 3600 + 30 * 60)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
        let hour = comps.hour ?? 12

        if hour >= 13 && hour < 17 {
            return candidate
        }

        var snap = comps
        if hour < 13 {
            snap.hour = 13
            snap.minute = 0
            snap.second = 0
        } else {
            // hour >= 17 → snap to 17:00 of the same day
            snap.hour = 17
            snap.minute = 0
            snap.second = 0
        }
        return cal.date(from: snap) ?? candidate
    }

    /// Verbatim copy from coordinator-empty-state-v2 §6.2.
    public static func templateCopy(outcome: OnboardingOutcome) -> (title: String, body: String) {
        if let name = outcome.spawnedDomainDisplayName {
            if outcome.capturedAtLeastOneEvent {
                return (
                    "Steward",
                    "How's \(name) feeling? Anything to log — or nothing's fine too."
                )
            } else {
                return (
                    "Steward",
                    "You set up the \(name) team this morning. Anything to log? Hold the mic and just talk."
                )
            }
        }
        // captured but no team
        return (
            "Steward",
            "Anything else to catch from today? Two seconds of voice works."
        )
    }
}
