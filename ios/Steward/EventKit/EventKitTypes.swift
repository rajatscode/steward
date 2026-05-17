//
//  EventKitTypes.swift
//  Steward
//
//  Shared types for the EventKit tool surface (calendar.* and reminder.*).
//  Addendum §1.9 contract.
//

import Foundation
import EventKit

// MARK: - Permission scope (LLM/UI/Audit vocabulary)

public enum EKPermissionScope: String, Codable, Sendable, Equatable, CaseIterable {
    case calendarFullAccess
    case calendarWriteOnly
    case remindersFullAccess
    case remindersWriteOnly

    public var entityType: EKEntityType {
        switch self {
        case .calendarFullAccess, .calendarWriteOnly: return .event
        case .remindersFullAccess, .remindersWriteOnly: return .reminder
        }
    }
}

// MARK: - CalendarToolResult

/// Hybrid permission lifecycle result type (addendum §1.9). The LLM only sees
/// `.ok` and `.permissionDenied` (hard reject #19). `.permissionRequired` is
/// intercepted by the UI for the inline-grant flow.
public enum CalendarToolResult: Sendable {
    case ok(payloadJSON: String)
    case permissionRequired(scope: EKPermissionScope)
    case permissionDenied(scope: EKPermissionScope, hint: String)
}

extension CalendarToolResult {
    /// LLM-safe wire representation. `permissionRequired` is omitted so this
    /// surface cannot leak it back into the model.
    public func wireJSON() throws -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        switch self {
        case .ok(let payload):
            return payload
        case .permissionRequired:
            // Hard reject #19: never serialize this for the LLM.
            return nil
        case .permissionDenied(let scope, let hint):
            struct Body: Codable {
                let status: String
                let scope: String
                let hint: String
            }
            let data = try enc.encode(Body(status: "permission_denied",
                                            scope: scope.rawValue, hint: hint))
            return String(data: data, encoding: .utf8)
        }
    }

    public var isPermissionRequired: Bool {
        if case .permissionRequired = self { return true }
        return false
    }
}

// MARK: - Tool argument structs

public struct CalendarReadArgs: Codable, Sendable {
    public var start: Date
    public var end: Date
    public var calendarName: String?
    public var reasoning: String?    // optional for read (read isn't a mutation)
}

public struct CalendarWriteArgs: Codable, Sendable {
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var notes: String?
    public var location: String?
    public var isAllDay: Bool?
    public var calendarName: String?
    public var reasoning: String
}

public struct CalendarModifyArgs: Codable, Sendable {
    public struct Patch: Codable, Sendable {
        public var title: String?
        public var startDate: Date?
        public var endDate: Date?
        public var notes: String?
        public var location: String?
        public var isAllDay: Bool?
    }
    public var ekEventID: String
    public var patch: Patch
    public var reasoning: String
}

public struct CalendarDeleteArgs: Codable, Sendable {
    public var ekEventID: String
    public var reasoning: String
}

public struct ReminderCreateArgs: Codable, Sendable {
    public var title: String
    public var dueDate: Date?
    public var notes: String?
    public var listName: String?
    public var reasoning: String
}

public struct ReminderCompleteArgs: Codable, Sendable {
    public var ekReminderID: String
    public var reasoning: String
}

public struct ReminderListArgs: Codable, Sendable {
    public var listName: String?
    public var completed: Bool?
}

// MARK: - Tool error helpers

extension CalendarToolResult {
    static func denied(_ scope: EKPermissionScope) -> CalendarToolResult {
        let hint: String
        switch scope {
        case .calendarFullAccess, .calendarWriteOnly:
            hint = "Calendar access is off. Open Settings → Privacy → Calendars → Steward to grant access."
        case .remindersFullAccess, .remindersWriteOnly:
            hint = "Reminders access is off. Open Settings → Privacy → Reminders → Steward to grant access."
        }
        return .permissionDenied(scope: scope, hint: hint)
    }
}
