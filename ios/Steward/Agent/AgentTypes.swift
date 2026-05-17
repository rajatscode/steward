//
//  AgentTypes.swift
//  Steward
//
//  Shared value types for the agent loop. These are deliberately small and
//  free of FoundationModels dependencies so other pods (C, D) can pull
//  them in without breaking the gating contract from addendum §4 #20.
//

import Foundation

// MARK: - Identifiers
//
// `TurnID` and `ActionID` are declared in `Actions/TurnAction.swift`
// (strongly-typed structs). An earlier `init(raw:)` and
// `.raw` API is preserved as an alias on the canonical structs so
// existing AgentLoop call sites stay working.

// MARK: - Roles

/// Who is running the LLM call. Enum, not string — §4 #9 forbids string-keyed
/// kind dispatch. Coordinator and DomainAgent each construct the right
/// AgentRole; PromptAssembler switches on this.
enum AgentRole: Sendable, Equatable, Hashable {
    case coordinator
    case domain(String) // domain identifier ("health", "money", ...)
}

/// `ActorRef` is declared in `Actions/TurnAction.swift` (the canonical
/// definition). `ActorRef.dbValue` returns the same string vocabulary
/// that the earlier `dbActor` did.

// MARK: - Runtime context

/// Everything PromptAssembler needs to assemble a system prompt for a turn.
/// Sub-pods fill the fields they care about; missing fields render to empty
/// segments (PromptAssembler skips them rather than emitting "(none)").
struct RuntimeContext: Sendable, Equatable {
    var now: Date
    var localTimezone: TimeZone
    var conversationState: ConversationState
    var emptyStateBranch: EmptyStateBranch?
    var mercyMode: MercyMode
    var pauseUntil: Date?
    var activeDomains: [DomainSummary]
    var openCommitments: [CommitmentSummary]
    var recentEventsSummary: String?
    var memoryHitsSummary: String?
    var todayCalendarSummary: String?
    /// The user-visible message currently being processed. NEVER trimmed.
    var userMessage: String
    /// Optional prior-turn compaction; injected when running multi-turn.
    var priorTurnSummary: String?

    init(
        now: Date,
        localTimezone: TimeZone,
        conversationState: ConversationState,
        emptyStateBranch: EmptyStateBranch?,
        mercyMode: MercyMode,
        pauseUntil: Date?,
        activeDomains: [DomainSummary],
        openCommitments: [CommitmentSummary],
        recentEventsSummary: String?,
        memoryHitsSummary: String?,
        todayCalendarSummary: String?,
        userMessage: String,
        priorTurnSummary: String?
    ) {
        self.now = now
        self.localTimezone = localTimezone
        self.conversationState = conversationState
        self.emptyStateBranch = emptyStateBranch
        self.mercyMode = mercyMode
        self.pauseUntil = pauseUntil
        self.activeDomains = activeDomains
        self.openCommitments = openCommitments
        self.recentEventsSummary = recentEventsSummary
        self.memoryHitsSummary = memoryHitsSummary
        self.todayCalendarSummary = todayCalendarSummary
        self.userMessage = userMessage
        self.priorTurnSummary = priorTurnSummary
    }
}

enum MercyMode: Sendable, Equatable, Hashable {
    case off
    case on(until: Date?)
}

struct DomainSummary: Sendable, Equatable, Hashable, Codable {
    let domain: String
    let displayName: String
    init(domain: String, displayName: String) {
        self.domain = domain
        self.displayName = displayName
    }
}

struct CommitmentSummary: Sendable, Equatable, Hashable, Codable {
    let title: String
    let dueAt: Date?
    let domain: String?
    init(title: String, dueAt: Date?, domain: String?) {
        self.title = title
        self.dueAt = dueAt
        self.domain = domain
    }
}

// MARK: - Turn outcome

/// What AgentLoop returns to the caller after one user message.
struct CoordinatorResponse: Sendable, Equatable {
    let turnID: TurnID
    let text: String
    let backendKind: LLMBackendKind
    let toolInvocations: [LLMToolInvocation]
    let handoffsConsumed: Int
    let budgetExhausted: Bool

    init(
        turnID: TurnID,
        text: String,
        backendKind: LLMBackendKind,
        toolInvocations: [LLMToolInvocation],
        handoffsConsumed: Int,
        budgetExhausted: Bool
    ) {
        self.turnID = turnID
        self.text = text
        self.backendKind = backendKind
        self.toolInvocations = toolInvocations
        self.handoffsConsumed = handoffsConsumed
        self.budgetExhausted = budgetExhausted
    }
}
