//
//  AgentLoop.swift
//  Steward — Track B
//
//  One actor owns one user-session's turn loop. Per addendum §1.1 + §1.10:
//
//   - Foundation Models auto-loops internal tool calls. We never manually
//     loop them (§4 hard reject #7). The coordinator's session calls
//     `respond(to:)` once per user message and the framework runs as many
//     tool calls as the model wants before returning.
//
//   - The ONE exception is `agent.handoff`. It's hand-rolled as an
//     `LLMTool` whose `invoke()` consumes a `TurnBudget` hop, spawns a
//     domain agent's session, and returns the domain reply to the
//     coordinator's session as the tool result. The framework then
//     continues the coordinator's reply with that result available. This
//     is what makes the 8-hop cap mean "max 8 cross-agent handoffs per
//     coordinator turn".
//
//   - The empty-state branch is decided deterministically BEFORE the LLM
//     call (`EmptyStateRouter`). `ConversationState` is threaded across
//     turns by this actor; the assembler emits it into the runtime context
//     segment so `MockLLMSession` can disambiguate canned turns.
//

import Foundation

// MARK: - Shared budget

/// Wraps the mutable `TurnBudget` so the agent.handoff tool (which runs
/// inside the LLM's tool-call auto-loop) and the AgentLoop (which spawns
/// it) can share a single counter without races.
public actor SharedBudget {
    public private(set) var budget: TurnBudget

    public init(budget: TurnBudget) {
        self.budget = budget
    }

    public func consumeHandoff() throws {
        try budget.consumeHandoff()
    }

    public func snapshot() -> TurnBudget { budget }
    public var handoffsRemaining: Int { budget.handoffsRemaining }
    public var handoffsConsumed: Int {
        TurnBudget.defaultHandoffs - budget.handoffsRemaining
    }
}

// MARK: - Domain resolution

/// Looks up an active `DomainAgent` by domain identifier. Track C / Pod E
/// own the canonical `domains` table reader; for v0.9 the AgentLoop ships
/// with a closure-based resolver so tests can inject fixtures and the real
/// app wires in a DB-backed implementation.
public protocol DomainAgentResolver: Sendable {
    func resolve(domain: String) async -> DomainAgent?
    func listActive() async -> [DomainSummary]
}

public struct FixtureDomainAgentResolver: DomainAgentResolver {
    private let byID: [String: DomainAgent]
    public init(domains: [DomainAgent]) {
        self.byID = Dictionary(
            uniqueKeysWithValues: domains.map { ($0.domain, $0) }
        )
    }
    public func resolve(domain: String) async -> DomainAgent? { byID[domain] }
    public func listActive() async -> [DomainSummary] {
        byID.values.map { DomainSummary(domain: $0.domain, displayName: $0.displayName) }
    }
}

// MARK: - Agent loop

public actor AgentLoop {
    private let factory: any LLMSessionFactory
    private let registry: any ToolRegistry
    private let coordinator: CoordinatorAgent
    private let resolver: any DomainAgentResolver
    private let temperature: Double
    private let clock: @Sendable () -> Date
    private let timezone: TimeZone
    private let turnIDGen: @Sendable () -> String

    /// Conversation state threaded across turns. Tests can seed it via the
    /// `initialState` init arg.
    private var conversationState: ConversationState

    public init(
        factory: any LLMSessionFactory,
        registry: any ToolRegistry,
        coordinator: CoordinatorAgent = CoordinatorAgent(),
        resolver: any DomainAgentResolver,
        temperature: Double = 0.7,
        clock: @escaping @Sendable () -> Date = { Date() },
        timezone: TimeZone = .autoupdatingCurrent,
        turnIDGen: @escaping @Sendable () -> String = { UUID().uuidString },
        initialState: ConversationState = .awaitingFirstMessage
    ) {
        self.factory = factory
        self.registry = registry
        self.coordinator = coordinator
        self.resolver = resolver
        self.temperature = temperature
        self.clock = clock
        self.timezone = timezone
        self.turnIDGen = turnIDGen
        self.conversationState = initialState
    }

    /// Run one user turn through the coordinator. Throws on session-level
    /// failures; returns a typed `CoordinatorResponse` for all in-band
    /// outcomes (including handoff-budget exhaustion).
    public func run(userMessage: String) async throws -> CoordinatorResponse {
        let turnID = TurnID(raw: turnIDGen())
        let now = clock()
        let activeDomains = await resolver.listActive()

        // Pre-LLM deterministic routing — only relevant when no domains
        // exist yet (empty state). Once at least one domain exists, the
        // coordinator drops the scripted flow per UXR v2 §4.7.
        let branch: EmptyStateBranch?
        if activeDomains.isEmpty {
            branch = EmptyStateRouter.route(userMessage)
        } else {
            branch = nil
        }

        // Compute the new conversation state for THIS turn based on the
        // prior state + branch + user message shape.
        conversationState = nextConversationState(
            prior: conversationState,
            branch: branch,
            userMessage: userMessage,
            activeDomainsEmpty: activeDomains.isEmpty
        )

        let runtime = RuntimeContext(
            now: now,
            localTimezone: timezone,
            conversationState: conversationState,
            emptyStateBranch: branch,
            mercyMode: .off,         // Pod D wires the real read from SettingsStore
            pauseUntil: nil,
            activeDomains: activeDomains,
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: userMessage,
            priorTurnSummary: nil
        )

        let prompt = coordinator.systemPrompt(runtime: runtime)

        // Build the tool list given to the coordinator's LLM session:
        // every registered tool whose ID is in coordinator scope, PLUS
        // the hand-rolled agent.handoff wrapper.
        let sharedBudget = SharedBudget(
            budget: TurnBudget(
                handoffsRemaining: TurnBudget.defaultHandoffs,
                contextTokenCeiling: TurnBudget.coordinatorTokenCeiling,
                startedAt: now
            )
        )
        var coordinatorTools = await registry.tools(in: coordinator.scope.allowedTools)
        coordinatorTools.append(AgentHandoffTool(
            budget: sharedBudget,
            resolver: resolver,
            registry: registry,
            factory: factory,
            temperature: temperature,
            timezone: timezone,
            clock: clock
        ))

        let session = try await factory.makeSession(
            systemPrompt: prompt.text,
            tools: coordinatorTools,
            temperature: temperature
        )
        let response = try await session.respond(to: userMessage)

        let consumed = await sharedBudget.handoffsConsumed
        let exhausted = await sharedBudget.handoffsRemaining == 0
            && response.toolInvocations.contains(where: { $0.toolID == ToolID.agentHandoff.rawValue })

        return CoordinatorResponse(
            turnID: turnID,
            text: response.text,
            backendKind: response.backendKind,
            toolInvocations: response.toolInvocations,
            handoffsConsumed: consumed,
            budgetExhausted: exhausted
        )
    }

    // MARK: - State transitions

    /// Pure-function state transition. Exposed to tests via the `internal`
    /// import on the test target; the production path always goes through
    /// `run(userMessage:)`.
    func nextConversationState(
        prior: ConversationState,
        branch: EmptyStateBranch?,
        userMessage: String,
        activeDomainsEmpty: Bool
    ) -> ConversationState {
        guard activeDomainsEmpty else {
            return .inFreeChat
        }
        let lowered = userMessage.lowercased()
        // Honor explicit branch transitions first.
        if let branch {
            switch branch {
            case .branchACaptureFirst:
                // capture-first → after the LLM replies, we're waiting on
                // a yes/no to the retroactive offer.
                return .capturedAwaitingTrackOffer
            case .branchBSetupFirst:
                // setup-first → expecting the life-area answer next.
                return .awaitingLifeAreaAnswer
            case .branchCUnclear:
                return .unclearOnRamp
            }
        }
        // Confirmation flow transitions (no branch, mid-script).
        let isYes = ["yes", "yeah", "yep", "confirm", "sounds good", "do it", "ok"]
            .contains(where: { lowered.contains($0) })
        switch prior {
        case .awaitingLifeAreaAnswer:
            return .awaitingDomainConfirm
        case .awaitingDomainConfirm where isYes:
            return .awaitingInstrumentConfirm
        case .awaitingInstrumentConfirm where isYes:
            return .inFreeChat
        case .capturedAwaitingTrackOffer where isYes:
            return .inFreeChat
        case .capturedAwaitingTrackOffer,
             .awaitingDomainConfirm,
             .awaitingInstrumentConfirm,
             .unclearOnRamp,
             .awaitingFirstMessage,
             .proposingDomain,
             .proposingInstrument,
             .inFreeChat:
            return prior
        }
    }

    /// Tests + Track E's chat-replay path read the current state to render
    /// the right input prompt / chip set.
    public func currentConversationState() -> ConversationState {
        return conversationState
    }
}

// MARK: - agent.handoff tool

/// The only hand-rolled tool. Consumes one `TurnBudget` hop, spawns a
/// domain agent session, returns the domain reply to the coordinator
/// session as JSON. Foundation Models then auto-continues with that
/// reply available.
public struct AgentHandoffTool: LLMTool {
    public let id: String = ToolID.agentHandoff.rawValue
    public let description: String = "Hand off to a domain agent. Counts one budget hop per call. Args: {domain: string, message: string}."
    public let jsonSchemaForArgs: String = """
        {
          "type": "object",
          "properties": {
            "domain": {"type": "string"},
            "message": {"type": "string"}
          },
          "required": ["domain", "message"]
        }
        """

    let budget: SharedBudget
    let resolver: any DomainAgentResolver
    let registry: any ToolRegistry
    let factory: any LLMSessionFactory
    let temperature: Double
    let timezone: TimeZone
    let clock: @Sendable () -> Date

    public func invoke(argsJSON: String) async throws -> String {
        // Parse args defensively — malformed JSON → structured error
        // back to the LLM (never throw fatal).
        let args: HandoffArgs
        do {
            let data = Data(argsJSON.utf8)
            args = try JSONDecoder().decode(HandoffArgs.self, from: data)
        } catch {
            return errorJSON(
                kind: "malformed_args",
                detail: String(describing: error)
            )
        }

        // Consume budget; on exhaustion, return structured error JSON.
        // The coordinator's LLM continues with that result available and
        // produces a final text without retrying handoff.
        do {
            try await budget.consumeHandoff()
        } catch {
            return errorJSON(
                kind: "handoff_budget_exhausted",
                detail: "8-hop per-turn cap reached"
            )
        }

        guard let domainAgent = await resolver.resolve(domain: args.domain) else {
            return errorJSON(
                kind: "domain_not_found",
                detail: args.domain
            )
        }

        // Build a domain runtime context for this hop. Carry only what
        // the domain needs; no transcript replay in v1.
        let activeDomains = await resolver.listActive()
        let runtime = RuntimeContext(
            now: clock(),
            localTimezone: timezone,
            conversationState: .inFreeChat,
            emptyStateBranch: nil,
            mercyMode: .off,
            pauseUntil: nil,
            activeDomains: activeDomains,
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: args.message,
            priorTurnSummary: "(handoff from coordinator)"
        )

        let prompt = domainAgent.systemPrompt(runtime: runtime)

        // Domain agent gets ITS scoped tool subset. agent.handoff is NOT
        // in domain scope, so domain agents cannot themselves hand off
        // (architecturally simpler — coordinator stays the orchestration
        // hub; domains never recurse into other domains).
        let domainTools = await registry.tools(in: domainAgent.scope.allowedTools)

        do {
            let session = try await factory.makeSession(
                systemPrompt: prompt.text,
                tools: domainTools,
                temperature: temperature
            )
            let reply = try await session.respond(to: args.message)
            let payload = HandoffResultPayload(
                domain: args.domain,
                text: reply.text,
                toolInvocationCount: reply.toolInvocations.count
            )
            let data = try JSONEncoder().encode(payload)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return errorJSON(
                kind: "domain_session_failed",
                detail: String(describing: error)
            )
        }
    }

    // MARK: - JSON helpers

    private struct HandoffArgs: Codable {
        let domain: String
        let message: String
    }

    private struct HandoffResultPayload: Codable {
        let domain: String
        let text: String
        let toolInvocationCount: Int
    }

    private func errorJSON(kind: String, detail: String) -> String {
        // Stable, compact, no random ordering — pure function of inputs.
        let escapedDetail = detail
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"error\":\"\(kind)\",\"detail\":\"\(escapedDetail)\"}"
    }
}
