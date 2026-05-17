//
//  FollowupSchedulerTests.swift
//  StewardTests — Track B
//
//  Pure-helper coverage of the day-0 followup scheduler. Body copy,
//  fire-time window clamp, skip-no-engagement logic.
//

import XCTest
@testable import Steward

final class FollowupSchedulerTests: XCTestCase {

    private let nyc = TimeZone(identifier: "America/New_York")!

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyc
        return cal.date(from: comps)!
    }

    // MARK: - Fire-time window

    func test_fireTime_insideWindow_unchanged() {
        // 9am + 5h30m = 14:30, inside [13:00, 17:00]
        let now = date(2026, 5, 17, 9, 0)
        let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = nyc
        let comps = cal.dateComponents([.hour, .minute], from: fire)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
    }

    func test_fireTime_beforeWindow_snapsTo13() {
        // 6am + 5h30m = 11:30, before 13:00 → snap to 13:00
        let now = date(2026, 5, 17, 6, 0)
        let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = nyc
        let comps = cal.dateComponents([.hour, .minute], from: fire)
        XCTAssertEqual(comps.hour, 13)
        XCTAssertEqual(comps.minute, 0)
    }

    func test_fireTime_afterWindow_snapsTo17() {
        // 13:00 + 5h30m = 18:30, after 17:00 → snap to 17:00
        let now = date(2026, 5, 17, 13, 0)
        let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = nyc
        let comps = cal.dateComponents([.hour, .minute], from: fire)
        XCTAssertEqual(comps.hour, 17)
        XCTAssertEqual(comps.minute, 0)
    }

    // MARK: - Template copy (verbatim §6.2)

    func test_templateCopy_spawnedDomainOnly() {
        let outcome = OnboardingOutcome(
            spawnedDomainDisplayName: "Health",
            capturedAtLeastOneEvent: false
        )
        let (title, body) = FollowupScheduler.templateCopy(outcome: outcome)
        XCTAssertEqual(title, "Steward")
        XCTAssertTrue(body.contains("You set up the Health team this morning"))
        XCTAssertTrue(body.contains("Hold the mic"))
    }

    func test_templateCopy_capturedEventOnly() {
        let outcome = OnboardingOutcome(
            spawnedDomainDisplayName: nil,
            capturedAtLeastOneEvent: true
        )
        let (_, body) = FollowupScheduler.templateCopy(outcome: outcome)
        XCTAssertEqual(body, "Anything else to catch from today? Two seconds of voice works.")
    }

    func test_templateCopy_bothDomainAndEvent() {
        let outcome = OnboardingOutcome(
            spawnedDomainDisplayName: "Health",
            capturedAtLeastOneEvent: true
        )
        let (_, body) = FollowupScheduler.templateCopy(outcome: outcome)
        XCTAssertTrue(body.contains("How's Health feeling?"))
        XCTAssertTrue(body.contains("nothing's fine too"))
    }

    // MARK: - Banned patterns (UXR v2 §6.3)

    func test_templateCopy_neverUsesCommitmentShameLanguage() {
        let outcomes = [
            OnboardingOutcome(spawnedDomainDisplayName: "Health", capturedAtLeastOneEvent: false),
            OnboardingOutcome(spawnedDomainDisplayName: nil, capturedAtLeastOneEvent: true),
            OnboardingOutcome(spawnedDomainDisplayName: "Money", capturedAtLeastOneEvent: true),
        ]
        for outcome in outcomes {
            let (_, body) = FollowupScheduler.templateCopy(outcome: outcome)
            let lowered = body.lowercased()
            XCTAssertFalse(lowered.contains("you committed to"))
            XCTAssertFalse(lowered.contains("you said you would"))
            XCTAssertFalse(lowered.contains("don't forget"))
            XCTAssertFalse(lowered.contains("streak"))
        }
    }
}
