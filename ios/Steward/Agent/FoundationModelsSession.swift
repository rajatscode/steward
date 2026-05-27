//
//  FoundationModelsSession.swift
//  Steward
//
//  Real-LLM conformance to `LLMSession`. Entire file body wrapped in
//  `#if canImport(FoundationModels)` so the Xcode 16.3 build skips it
//  cleanly until the iOS 26 SDK is installed.
//
//  Hard rule (addendum §4 #20): `import FoundationModels` is allowed
//  ONLY in this file and `LLMResolver.swift`. Adding it anywhere else
//  recouples the architecture to a single provider and breaks the
//  16.3-toolchain build the user is on tonight.
//
//  The Foundation Models framework auto-loops tool calls inside
//  `respond(to:)` — we never manually loop (§4 #7).
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
struct FoundationModelsSessionFactory: LLMSessionFactory {
    let backendKind: LLMBackendKind = .foundationModels

    init() {}

    func makeSession(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws -> any LLMSession {
        return try await FoundationModelsSession(
            systemPrompt: systemPrompt,
            tools: tools,
            temperature: temperature
        )
    }
}

/// Out-of-band sink for `PermissionRequiredSignal` / `HealthPermissionRequiredSignal`
/// thrown inside a tool's `invoke(argsJSON:)`. The FoundationModels framework
/// owns the auto-loop and may swallow tool-call errors back into the model's
/// transcript. We can't rely on a `throw` from the adapter to propagate up
/// through `session.respond(to:)` cleanly. So the adapter writes the signal
/// here before re-throwing, and `FoundationModelsSession.respond` checks the
/// sink after the framework call returns — if a permission signal was
/// captured, it overrides the response and re-throws so the chat UI's host
/// catch arms fire (addendum §1.9 / HARD REJECT #19).
///
/// One sink per `FoundationModelsSession` instance (i.e. one per user turn).
/// First-wins: only the first signal in a turn is propagated, since the
/// inline-grant flow can only resolve one scope at a time anyway.
@available(iOS 26.0, *)
actor PermissionSignalSink {
    private var captured: Error?

    func record(_ error: Error) {
        if captured == nil { captured = error }
    }

    func consume() -> Error? {
        let result = captured
        captured = nil
        return result
    }
}

/// Bridges Steward's provider-agnostic `LLMTool` (JSON-string vocabulary)
/// to the FoundationModels framework's typed `Tool` conformance. The
/// framework parses + dispatches; we just hand it a wrapped invoke().
@available(iOS 26.0, *)
private struct FMToolAdapter: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let wrapped: any LLMTool
    let sink: PermissionSignalSink

    var name: String { wrapped.id }
    var description: String { wrapped.description }

    func call(arguments: GeneratedContent) async throws -> String {
        let argsJSON = arguments.jsonString
        do {
            return try await wrapped.invoke(argsJSON: argsJSON)
        } catch let signal as PermissionRequiredSignal {
            let enriched = PermissionRequiredSignal(
                scope: signal.scope,
                pendingToolID: signal.pendingToolID ?? wrapped.id,
                pendingArgsJSON: signal.pendingArgsJSON ?? argsJSON
            )
            await sink.record(enriched)
            throw enriched
        } catch let signal as HealthPermissionRequiredSignal {
            let enriched = HealthPermissionRequiredSignal(
                scope: signal.scope,
                pendingToolID: signal.pendingToolID ?? wrapped.id,
                pendingArgsJSON: signal.pendingArgsJSON ?? argsJSON
            )
            await sink.record(enriched)
            throw enriched
        }
    }
}

@available(iOS 26.0, *)
actor FoundationModelsSession: LLMSession {
    private var session: LanguageModelSession
    private let toolMap: [String: any LLMTool]
    private let backendKind: LLMBackendKind = .foundationModels
    private let permissionSink: PermissionSignalSink
    private let generationOptions: GenerationOptions

    init(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws {
        let sink = PermissionSignalSink()
        self.permissionSink = sink
        let adapters = tools.map { FMToolAdapter(wrapped: $0, sink: sink) }
        self.toolMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        self.generationOptions = GenerationOptions(temperature: temperature)

        // Construct a fresh per-turn session (addendum §3 FM bullet:
        // "Wrap each turn in a fresh LanguageModelSession to bound KV cache").
        // GenerationOptions moved from the session initializer to respond(to:)
        // in the iOS 26 release SDK.
        self.session = LanguageModelSession(
            tools: adapters,
            instructions: systemPrompt
        )
    }

    func respond(to userMessage: String) async throws -> LLMResponse {
        // Foundation Models auto-loops tool calls within this single call.
        // We never manually loop (§4 hard reject #7). On return, the
        // response carries the new transcript entries for this turn.
        //
        // A tool that throws `PermissionRequiredSignal` /
        // `HealthPermissionRequiredSignal` may have its error swallowed by
        // the framework auto-loop (the framework hands the error back to the
        // model so it can route around). We don't want that: addendum §1.9
        // says the UI host must catch the signal directly. The adapter wrote
        // the signal to `permissionSink` on its way through — consult the
        // sink BEFORE returning, even on the success path, and rethrow if
        // present. On the failure path, prefer the captured signal over the
        // framework's wrapped error (more actionable type for the UI catch
        // arms in `ChatViewModel.send`).
        do {
            let result = try await session.respond(to: userMessage, options: generationOptions)
            if let pending = await permissionSink.consume() {
                throw pending
            }
            let invocations = Self.extractInvocations(from: result.transcriptEntries)
            return LLMResponse(
                text: result.content,
                toolInvocations: invocations,
                backendKind: backendKind
            )
        } catch {
            if let pending = await permissionSink.consume() {
                throw pending
            }
            throw error
        }
    }

    /// Pair `ToolCall`s with their matching `ToolOutput`s by sequence position
    /// within a single response's transcript entries. The framework emits them
    /// interleaved (`toolCalls -> toolOutput -> toolCalls -> ...`); we flatten
    /// to a single list keyed by name so the audit log keeps argsJSON +
    /// resultJSON together.
    private static func extractInvocations(
        from entries: ArraySlice<Transcript.Entry>
    ) -> [LLMToolInvocation] {
        var pendingCalls: [(name: String, argsJSON: String)] = []
        var paired: [LLMToolInvocation] = []
        let now = Date()
        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls {
                    pendingCalls.append((call.toolName, call.arguments.jsonString))
                }
            case .toolOutput(let output):
                let idx = pendingCalls.firstIndex(where: { $0.name == output.toolName })
                let argsJSON = idx.map { pendingCalls.remove(at: $0).argsJSON } ?? ""
                paired.append(LLMToolInvocation(
                    toolID: output.toolName,
                    argsJSON: argsJSON,
                    resultJSON: Self.flatten(segments: output.segments),
                    executedAt: now
                ))
            case .instructions, .prompt, .response:
                continue
            }
        }
        return paired
    }

    private static func flatten(segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structured): return structured.content.jsonString
            }
        }.joined()
    }

    func reset() async {
        // Recreate the underlying session. The instructions and tools are
        // captured in this actor's init args via the adapters dictionary,
        // but we can't reconstruct without storing them. KV-cache bounding
        // is the goal — for v1 the agent loop creates a fresh
        // FoundationModelsSession per user turn anyway, so reset() is a
        // no-op here.
    }
}

#endif // canImport(FoundationModels)
