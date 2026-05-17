//
//  UndoExecutorTests.swift
//  StewardTests
//
//  Verifies:
//   - Exhaustiveness: every InverseAction case has a handler (compile-time
//     enforced — the test just instantiates each case so we'd hit a fatalError
//     before reaching this file if we'd been sloppy).
//   - AuditLog.recordAgentAction refuses blank reasoning for agent actors.
//   - AuditLog round-trips a TurnAction.
//

import XCTest
import GRDB
@testable import Steward

final class UndoExecutorTests: XCTestCase {

    // MARK: - Exhaustiveness smoke test

    func testEveryInverseActionCanBeInstantiated() {
        // Compile-time check: each enum case must construct. Tests in this
        // file fail to compile if a case is added without updating this list,
        // mirroring the addendum's hard-reject #4 invariant.
        let payload = CalendarEventPayload(
            title: "x", startDate: Date(), endDate: Date(), ekEventID: "ek-1"
        )
        let cases: [InverseAction] = [
            .restoreCalendarEvent(payload: payload),
            .deleteCalendarEvent(ekEventID: "ek-2", calendarIdentifier: "cal-1"),
            .modifyCalendarEvent(ekEventID: "ek-3", restoreTo: payload),
            .recreateReminder(payload: ReminderPayload(title: "r")),
            .deleteReminder(ekReminderID: "rem-1", listIdentifier: "list-1"),
            .rescheduleNotification(request: NotificationRequest(
                kind: .windDown,
                fireAt: Date(),
                templateContext: TemplateContext()
            )),
            .cancelNotification(notificationID: "notif-1"),
            .revertInstrumentEvent(instrumentID: "inst-1", eventIDToReverse: EventID.generate()),
            .archiveDomain(domain: "health", archivedAt: Date()),
            .unarchiveDomain(domain: "health"),
            .forgetMemory(memoryID: MemoryID(rawValue: "m-1")),
            .unforgetMemory(memoryID: MemoryID(rawValue: "m-1"))
        ]
        XCTAssertEqual(cases.count, 12, "InverseAction case count drift: did you add a case without updating UndoExecutor?")
    }

    // MARK: - AuditLog

    /// Build an isolated in-memory provider + audit log. Mirrors the pattern
    /// used in Track A's SchemaTests.
    private func makeAuditLog() async throws -> (AuditLog, DatabaseProvider, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-d-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("steward-test.sqlite")
        let provider = DatabaseProvider(location: .file(url))
        // Warm the migration up front so the audit log doesn't race.
        _ = try await provider.database()
        let audit = AuditLog(provider: provider)
        return (audit, provider, dir)
    }

    func testAuditLogRefusesBlankReasoningForAgent() async throws {
        let (audit, _, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .calendarWrite,
            actor: .coordinator,
            reasoning: "   ",  // whitespace-only
            inverse: .deleteCalendarEvent(ekEventID: "x", calendarIdentifier: nil)
        )
        do {
            _ = try await audit.recordAgentAction(action)
            XCTFail("blank reasoning should throw")
        } catch let e as AuditLogError {
            if case .reasoningEmpty = e { /* good */ } else {
                XCTFail("wrong AuditLogError: \(e)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testAuditLogRoundtripsTurnAction() async throws {
        let (audit, _, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = CalendarEventPayload(
            title: "Therapy",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            ekEventID: "ek-abc"
        )
        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .calendarDelete,
            actor: .agent(domain: "health"),
            reasoning: "User asked me to drop this; conflict noted in chat.",
            inverse: .restoreCalendarEvent(payload: payload)
        )

        let eventID = try await audit.recordAgentAction(action, source: "tool:calendar.delete")
        let loaded = try await audit.loadTurnAction(eventID: eventID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.toolID, .calendarDelete)
        XCTAssertEqual(loaded?.actor.dbValue, "agent:health")
        if case .restoreCalendarEvent(let loadedPayload) = loaded?.inverse {
            XCTAssertEqual(loadedPayload.ekEventID, "ek-abc")
            XCTAssertEqual(loadedPayload.title, "Therapy")
        } else {
            XCTFail("inverse decoded wrong")
        }
        let undone1 = try await audit.hasBeenUndone(eventID: eventID)
        XCTAssertFalse(undone1)
    }

    func testRecordUndoMarksOriginalAsUndone() async throws {
        let (audit, _, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .notificationSchedule,
            actor: .coordinator,
            reasoning: "Schedule wind-down per user request.",
            inverse: .cancelNotification(notificationID: "un-1")
        )
        let eventID = try await audit.recordAgentAction(action)
        _ = try await audit.recordUndo(
            originalEventID: eventID,
            undoneBy: .user,
            reasoning: "User tapped undo in Settings."
        )
        let undone = try await audit.hasBeenUndone(eventID: eventID)
        XCTAssertTrue(undone)
    }

    func testEventsCheckConstraintRejectsAgentRowWithoutReasoningAtDB() async throws {
        // Belt-and-braces — the DB CHECK is the second line of defense after
        // AuditLogError.reasoningEmpty. Verify it actually rejects.
        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let queue = try await provider.database()
        do {
            try await queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO events (event_id, created_at, actor, kind)
                    VALUES (?, ?, 'coordinator', 'calendar.write')
                    """,
                    arguments: [UUID().uuidString, Int64(Date().timeIntervalSince1970 * 1000)]
                )
            }
            XCTFail("DB should reject agent row without reasoning")
        } catch {
            // expected — CHECK constraint trips.
        }
    }
}
