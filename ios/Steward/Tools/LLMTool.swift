//
//  LLMTool.swift
//  Steward
//
//  Track D placeholder for the LLMTool protocol surface defined in
//  implementation-addendum §1.10. Track B is the eventual owner; we define the
//  minimal symbol here so EventKit / Notification tools compile against a
//  stable interface and Track B can merge a richer factory side-by-side
//  without churn.
//
//  Tools register their JSON schema (string) for the FoundationModelsSession
//  bridge; MockLLMSession invokes by toolID pattern match (so an empty schema
//  string is fine for tools that only ever run under Mock for now).
//
//  HARD REJECT #20: `import FoundationModels` is FORBIDDEN in this file.
//  This protocol must be plain Foundation so the build stays green on Xcode
//  16.3 / iOS 18.4 SDK.
//

import Foundation

/// Protocol every tool conforms to. JSON in / JSON out.
///
/// Implementations are pure Swift actors / structs — they never see a
/// `LanguageModelSession`, never see permission UI state, and never compose
/// notification bodies. The session's tool dispatcher handles serialization.
public protocol LLMTool: Sendable {
    var id: String { get }
    var description: String { get }
    var jsonSchemaForArgs: String { get }
    func invoke(argsJSON: String) async throws -> String
}

/// Canonical tool identifiers used across tracks. Track B's `ToolGuard`
/// (addendum §1.8) validates by these string values; the enum keeps the names
/// out of stringly-typed code (hard reject #9 prevention).
public enum ToolID: String, Codable, CaseIterable, Sendable {
    // EventKit (Track D)
    case calendarRead       = "calendar.read"
    case calendarWrite      = "calendar.write"
    case calendarModify     = "calendar.modify"
    case calendarDelete     = "calendar.delete"
    case reminderCreate     = "reminder.create"
    case reminderComplete   = "reminder.complete"
    case reminderList       = "reminder.list"

    // Notifications (Track D)
    case notificationSchedule          = "notification.schedule"
    case notificationScheduleRecurring = "notification.schedule_recurring"
    case notificationCancel            = "notification.cancel"
    case notificationListUpcoming      = "notification.list_upcoming"

    // Track B / C tools (declared here for completeness; not implemented in D)
    case eventCapture        = "event.capture"
    case eventList           = "event.list"
    case instrumentCreate    = "instrument.create"
    case instrumentApplyEvent = "instrument.apply_event"
    case instrumentRead      = "instrument.read"
    case commitmentCreate    = "commitment.create"
    case memorySave          = "memory.save"
    case memorySearch        = "memory.search"
    case memoryForget        = "memory.forget"
    case domainCreate        = "domain.create"
    case mercyModeEngage     = "mercy_mode.engage"
    case pauseEngage         = "pause.engage"
    case quietHoursSet       = "quiet_hours.set"
}

/// Structured tool error surface. Foundation Models receives errors as part of
/// the tool result vocabulary — never as Swift `throw`s that bubble out of
/// `respond(to:)` (which would terminate the agent loop entirely).
public struct ToolError: Error, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case argumentsInvalid
        case permissionDenied
        case capExceeded
        case notFound
        case backendUnavailable
        case internalFailure
    }
    public let kind: Kind
    public let message: String
    public let hint: String?

    public init(kind: Kind, message: String, hint: String? = nil) {
        self.kind = kind
        self.message = message
        self.hint = hint
    }
}
