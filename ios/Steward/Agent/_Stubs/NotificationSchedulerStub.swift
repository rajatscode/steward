//
//  NotificationSchedulerStub.swift
//  Steward — Track B  /  DELETE AT MERGE
//
//  ⚠️  Pod D owns the canonical `NotificationScheduler` per addendum §1.3.
//  This file lives under `Agent/_Stubs/` and MUST be deleted when Pod D's
//  real implementation lands. Surface MUST match §1.3 verbatim so the
//  call sites in `FollowupScheduler.swift` don't need to change at merge.
//
//  This stub does NOT touch UNUserNotificationCenter — that is hard reject
//  #8 territory (only Pod D's real scheduler is allowed to call
//  `UNUserNotificationCenter.add`). The stub just enqueues a row into the
//  `notifications` table inside a single `db.write { }` block so the
//  audit history exists when Pod D's scheduler comes online and drains
//  the table.
//

import Foundation
import GRDB

// MARK: - Public types from §1.3 (verbatim shape)

public enum NotificationKind: String, Sendable, Codable, CaseIterable {
    case morningBrief        = "morning_brief"
    case windDown            = "wind_down"
    case instrumentNudge     = "instrument_nudge"
    case commitmentDue       = "commitment_due"
    case recoveryNudge       = "recovery_nudge"
    case onboardingFollowup  = "onboarding_followup"  // UXR v2 §6
}

public enum NotificationMode: Sendable, Equatable {
    case normal
    case mercy
    case pause
}

public enum CapReason: Sendable, Codable, Equatable {
    case dailyMax(currentCount: Int, max: Int)
    case minGap(lastFiredAt: Date, requiredGapMinutes: Int)
    case mercyModeCap
}

public enum ScheduleOutcome: Sendable, Codable, Equatable {
    case scheduled(notificationID: String, firesAt: Date)
    case capExceeded(reason: CapReason, nextAvailableSlot: Date?)
    case suppressedByQuietHours(rescheduledTo: Date?)
    case suppressedByPause
}

public enum AgentScope: Sendable, Codable, Equatable {
    case coordinator
    case agentDomain(String)

    public var dbScheduledBy: String {
        switch self {
        case .coordinator:            return "coordinator"
        case .agentDomain(let d):     return "agent:\(d)"
        }
    }
}

public struct NotificationRequest: Sendable, Codable, Equatable {
    public let kind: NotificationKind
    public let title: String
    public let body: String
    public let firesAt: Date
    public let domain: String?
    public let instrumentID: String?
    public let actionContextJSON: String?

    public init(
        kind: NotificationKind,
        title: String,
        body: String,
        firesAt: Date,
        domain: String? = nil,
        instrumentID: String? = nil,
        actionContextJSON: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.firesAt = firesAt
        self.domain = domain
        self.instrumentID = instrumentID
        self.actionContextJSON = actionContextJSON
    }
}

// MARK: - The stub actor

/// Stub — same surface as Pod D's canonical, no UN registration.
///
/// Hard rule: this file MUST NOT call `UNUserNotificationCenter.add`. Pod
/// D's real implementation handles UN. The stub just writes the row so the
/// audit chain is intact when the real scheduler comes online and drains.
public actor NotificationScheduler {
    public static let shared = NotificationScheduler()

    private let provider: DatabaseProvider
    private let idGen: @Sendable () -> String

    // Internal init: parameter types (`DatabaseProvider`) are internal in
    // Track A's scaffold; `public` would warn. Same-target callers don't
    // need the broader visibility.
    init(
        provider: DatabaseProvider = .shared,
        idGen: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.provider = provider
        self.idGen = idGen
    }

    /// Per §1.3. The stub does not enforce cap math — it just writes the
    /// row and returns `.scheduled`. Pod D's canonical replaces this with
    /// real cap math + UN registration.
    @discardableResult
    public func schedule(
        _ req: NotificationRequest,
        scope: AgentScope
    ) async -> ScheduleOutcome {
        let id = idGen()
        do {
            let db = try await provider.database()
            try await db.write { dbase in
                try dbase.execute(
                    sql: """
                        INSERT INTO notifications (
                            notification_id, scheduled_for, domain, instrument_id,
                            kind, title, body, action_context_json, scheduled_by
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        id,
                        Int64(req.firesAt.timeIntervalSince1970 * 1000),
                        req.domain,
                        req.instrumentID,
                        req.kind.rawValue,
                        req.title,
                        req.body,
                        req.actionContextJSON,
                        scope.dbScheduledBy,
                    ]
                )
            }
            return .scheduled(notificationID: id, firesAt: req.firesAt)
        } catch {
            // No UN call. Surface "scheduled" with a synthetic ID; Pod D's
            // real implementation will replace this whole path. The audit
            // row failing to insert is a real problem — but we cannot
            // throw from a stub return type. Best we can do without
            // changing the §1.3 surface: emit a `.capExceeded` shape with
            // a sentinel so callers don't think it succeeded.
            return .capExceeded(
                reason: .dailyMax(currentCount: -1, max: -1),
                nextAvailableSlot: nil
            )
        }
    }
}
