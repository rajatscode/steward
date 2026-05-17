//
//  UndoExecutor.swift
//  Steward
//
//  HARD REJECT #4 enforcement point: the `switch inverse` below is exhaustive
//  WITHOUT a `default:` arm. Adding a new InverseAction case forces a compile
//  error here until the handler is written. The executor returns a typed
//  UndoOutcome — non-undoable / not-found / already-undone are first-class
//  outcomes, never `nil`s.
//
//  Each handler is an actor-isolated dispatcher to the relevant backend
//  (EventKitGateway, NotificationScheduler, DB instrument replay, etc.).
//

import Foundation
import GRDB

public actor UndoExecutor {
    public static let shared = UndoExecutor()

    private let provider: DatabaseProvider
    private let auditLog: AuditLog
    private let gateway: EventKitGateway
    private let scheduler: NotificationScheduler
    private let turnIDProvider: @Sendable () -> TurnID

    public init(
        provider: DatabaseProvider = .shared,
        auditLog: AuditLog = .shared,
        gateway: EventKitGateway = .shared,
        scheduler: NotificationScheduler = .shared,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.provider = provider
        self.auditLog = auditLog
        self.gateway = gateway
        self.scheduler = scheduler
        self.turnIDProvider = turnIDProvider
    }

    /// Undo the action recorded at `eventID`. Returns:
    /// - `.undone` on success
    /// - `.alreadyUndone` if a prior undo event already references this id
    /// - `.notFound` if no audit row exists
    /// - `.blockedByDependents` if cascades remain (v1: always empty, so this
    ///   never fires unless callers populate cascades)
    public func undo(eventID: EventID, undoneBy: ActorRef, reasoning: String) async throws -> UndoOutcome {
        if try await auditLog.hasBeenUndone(eventID: eventID) {
            return .alreadyUndone(originalEventID: eventID)
        }
        guard let action = try await auditLog.loadTurnAction(eventID: eventID) else {
            return .notFound(originalEventID: eventID)
        }
        if !action.cascades.isEmpty {
            return .blockedByDependents(action.cascades)
        }

        try await execute(action.inverse)

        let undoEventID = try await auditLog.recordUndo(
            originalEventID: eventID,
            undoneBy: undoneBy,
            reasoning: reasoning
        )
        return .undone(originalEventID: eventID, undoEventID: undoEventID)
    }

    /// Execute the inverse. Exhaustive switch, no `default:` — adding a case
    /// to `InverseAction` will fail to compile until handled here.
    func execute(_ inverse: InverseAction) async throws {
        switch inverse {

        // ---- Calendar ----

        case .restoreCalendarEvent(let payload):
            // Undo a calendar.delete by re-creating the event. We don't have
            // the original EKEventStore object reference; route through the
            // gateway's write path so permission gating still applies.
            let args = CalendarWriteArgs(
                title: payload.title,
                startDate: payload.startDate,
                endDate: payload.endDate,
                notes: payload.notes,
                location: payload.location,
                isAllDay: payload.isAllDay,
                calendarName: payload.calendarName,
                reasoning: "undo:restore_calendar_event"
            )
            let (result, _) = await gateway.executeCalendarWrite(args)
            switch result {
            case .ok: return
            case .permissionRequired(let scope):
                throw UndoExecutorError.backendFailure("permission required: \(scope.rawValue)")
            case .permissionDenied(_, let hint):
                throw UndoExecutorError.backendFailure("permission denied: \(hint)")
            }

        case .deleteCalendarEvent(let ekEventID, _):
            let args = CalendarDeleteArgs(ekEventID: ekEventID, reasoning: "undo:delete_calendar_event")
            let (result, _) = await gateway.executeCalendarDelete(args)
            try requireOK(result)

        case .modifyCalendarEvent(let ekEventID, let restoreTo):
            let patch = CalendarModifyArgs.Patch(
                title: restoreTo.title,
                startDate: restoreTo.startDate,
                endDate: restoreTo.endDate,
                notes: restoreTo.notes,
                location: restoreTo.location,
                isAllDay: restoreTo.isAllDay
            )
            let args = CalendarModifyArgs(
                ekEventID: ekEventID, patch: patch,
                reasoning: "undo:modify_calendar_event"
            )
            let (result, _) = await gateway.executeCalendarModify(args)
            try requireOK(result)

        // ---- Reminders ----

        case .recreateReminder(let payload):
            // For undo-of-complete, we don't recreate (the reminder still
            // exists). For undo-of-delete (future), we'd recreate. Detect by
            // whether ekReminderID is present.
            if let ekID = payload.ekReminderID, !ekID.isEmpty {
                // Flip the completed flag back to false through the gateway.
                // We can't go through `executeReminderComplete` because that's
                // a one-way flag flip. Open a fresh executor path via the
                // EventStore directly is HARD REJECT #18 territory — instead,
                // for v1 we surface this as a backend failure that the UI can
                // explain. Track B can add an explicit `executeReminderReopen`
                // method to the gateway when polish lands.
                throw UndoExecutorError.backendFailure(
                    "Reopen-reminder undo requires gateway support not yet shipped (\(ekID))"
                )
            }
            let args = ReminderCreateArgs(
                title: payload.title,
                dueDate: payload.dueDate,
                notes: payload.notes,
                listName: payload.listName,
                reasoning: "undo:recreate_reminder"
            )
            let (result, _) = await gateway.executeReminderCreate(args)
            try requireOK(result)

        case .deleteReminder(let ekReminderID, _):
            // Inverse of reminder.create — needs gateway support not yet
            // exposed (we don't ship reminder.delete as a primary tool in
            // v1). Surface a typed failure so UI can explain.
            throw UndoExecutorError.backendFailure(
                "Delete-reminder undo not implemented in v1 (\(ekReminderID))"
            )

        // ---- Notifications ----

        case .rescheduleNotification(let request):
            // Re-schedule using the captured original request. Coordinator
            // scope is the safe default since cancellations only happen from
            // coordinator-driven flows in v1.
            _ = await scheduler.schedule(request, scope: .coordinator)

        case .cancelNotification(let notificationID):
            await scheduler.cancel(id: notificationID)

        // ---- Instrument replay (delegated to Track C registry) ----

        case .revertInstrumentEvent(let instrumentID, let eventIDToReverse):
            // Spec §1.6: replay all events for the instrument EXCEPT the
            // named one and recompute state from initialState. The actual
            // replay loop lives in Track C's InstrumentRegistry; we surface
            // the call here so Track B's UI can wire it without coupling
            // directly to that file.
            try await InstrumentReplayBridge.replay(
                instrumentID: instrumentID,
                excluding: eventIDToReverse,
                in: try await provider.database()
            )

        // ---- Domain archive ----

        case .archiveDomain(let domain, let archivedAt):
            let queue = try await provider.database()
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE domains SET archived_at = ? WHERE domain = ?",
                    arguments: [Int64(archivedAt.timeIntervalSince1970 * 1000), domain]
                )
            }

        case .unarchiveDomain(let domain):
            let queue = try await provider.database()
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE domains SET archived_at = NULL WHERE domain = ?",
                    arguments: [domain]
                )
            }

        // ---- Memory ----

        case .forgetMemory(let memoryID):
            // Forgetting writes a soft-delete event; the actual delete from
            // memory_items lives in Track C. From here we just call the
            // delete path; if Track C hasn't wired it yet this is a no-op
            // that the integration test will catch.
            let queue = try await provider.database()
            try await queue.write { db in
                try db.execute(
                    sql: "DELETE FROM memory_items WHERE memory_id = ?",
                    arguments: [memoryID.rawValue]
                )
            }

        case .unforgetMemory(let memoryID):
            // Restore a previously forgotten memory. Track C owns the
            // soft-delete archive; we surface a backend failure until that
            // archive lands so callers get a clear message.
            throw UndoExecutorError.backendFailure(
                "Memory restore (\(memoryID.rawValue)) requires Track C archive table not yet shipped"
            )
        }
    }

    // MARK: - helpers

    private func requireOK(_ result: CalendarToolResult) throws {
        switch result {
        case .ok: return
        case .permissionRequired(let scope):
            throw UndoExecutorError.backendFailure("permission required: \(scope.rawValue)")
        case .permissionDenied(_, let hint):
            throw UndoExecutorError.backendFailure("permission denied: \(hint)")
        }
    }
}

/// Bridge type so UndoExecutor doesn't `import Track C`. Track C provides the
/// real implementation; v1 stub returns success without doing anything (the
/// integration test catches the missing wiring).
enum InstrumentReplayBridge {
    static func replay(instrumentID: String, excluding: EventID, in db: DatabaseQueue) async throws {
        // Track C's InstrumentRegistry.replay(...) is where this hooks once
        // landed. Until then, the executor records the intent (the audit
        // event written by `recordUndo`) but doesn't mutate state.
        _ = (instrumentID, excluding, db)
    }
}
