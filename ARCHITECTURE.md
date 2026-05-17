# Architecture

This document orients a future contributor (human or LLM) inside the Outkeep iOS codebase. It is the single onboarding read for anyone returning to the project after a gap. Spec details live in [`spec.md`](spec.md); this doc is the *map* — what each folder owns, which way dependencies flow, what is load-bearing, and where to look first.

Note on naming: the user-visible product name is **Outkeep**. The Swift module, Xcode project, and most internal types still say `Steward` (rename was deliberately scoped to user-visible strings only — see `Design/BrandStrings.swift`).

## Mental model

Outkeep is a **single-user, offline-first** iOS app. The runtime is a **coordinator agent** plus **per-domain sub-agents** sharing one Foundation Models inference path (with a deterministic `MockLLMSession` fallback). State has three non-overlapping layers:

1. **Events log** — append-only history of every user message, every external write, every state change. Single writer: `DB/EventLog`. Hard reject #10.
2. **Instruments** — typed state machines that act as the "spreadsheets" the user sees. Math runs in deterministic Swift updater functions (`Instruments/Kinds/*`), never via LLM-emitted arithmetic.
3. **Memory items** — distilled qualitative facts retrieved via a hybrid FTS5 + NLEmbedding cosine score. No event-log overlap; this layer is for *recall*, not *truth*.

External effects (calendar, reminders, notifications, CSV mirror) all go through actor-serialized gateways. The LLM proposes; the gateways execute and stamp inverse actions onto the audit log. Undo is a typed switch over those inverse actions.

The deployment target is iOS 18.4 (the project was sketched against iOS 26 but currently builds against the 18.4 SDK with sim-only Foundation Models gating).

## Module graph (under `ios/Steward/`)

| Folder | Owns |
| --- | --- |
| `Actions/` | `TurnAction` + `InverseAction` + `UndoExecutor`. The audit log row schema and the exhaustive-undo-switch invariant live here. |
| `Agent/` | The LLM agent surface: `AgentLoop`, `CoordinatorAgent`, `DomainAgent`, prompt assembly, role templates, conversation state, the `LLMSession` protocol, the Foundation Models adapter, the canned mock session, tool registry, error types. |
| `Background/` | `BGTaskCoordinator` — single registration site for `BGTaskScheduler`. Forwards foreground/background ticks to `NotificationScheduler` and `MemoryDecayJob`. |
| `CSVMirror/` | iCloud Drive CSV mirror: paths resolver, watcher, instrument↔CSV coder, availability classifier, the `csv_mirror.*` tools. |
| `DB/` | GRDB plumbing: `DatabaseProvider` (singleton open), `Migrations`, `EventLog` (single writer for `events`), `SettingsStore`, ID generation. |
| `Design/` | Brand surface: `BrandColors`, `BrandFonts`, `BrandStrings`. The only place product copy and visual tokens live. |
| `Domains/` | `DomainStore` + `DBDomainAgentResolver`. Domains are runtime config (rows in `domains`), not hard-coded code paths. |
| `EventKit/` | Calendar + Reminders gateway with deferred-permission lifecycle. `EventKitGateway` is the singleton actor; `CalendarTools.swift` exposes the `LLMTool` surface. |
| `HealthKit/` | HealthKit gateway with the same deferred-permission shape as EventKit. `HealthSampleKind` enum + tool wrappers. |
| `Instruments/` | `InstrumentKind` protocol, `InstrumentRegistry`, and the seven concrete kinds in `Kinds/`. All instrument arithmetic lives in these files. |
| `Memory/` | `MemoryItem`, `MemoryRetriever` (hybrid FTS5 + cosine), `MemoryAdmissionPolicy`, `MemoryDecayJob`, `Embedding` (NLEmbedding wrapper). |
| `Network/` | `NetworkObserver` — NWPathMonitor wrapper that nudges the sync queue when the path becomes satisfied. |
| `Notifications/` | The cap-math actor (`NotificationScheduler`), the `LLMTool` wrappers, the recurring rule store, the `RRuleSubset` parser, the `NotificationActionRouter` that handles tap-to-act. |
| `Resources/` | Bundled fonts (`Satoshi`) and `WhisperKit` model assets. |
| `Tools/` | `ToolCatalog` is the single entry point that enumerates the spec §8 tool surface. `Tools/Catalog/*.swift` is one file per tool family (events, instruments, commitments, memory, domains, agent, settings, health). |
| `Views/` | SwiftUI surface. `Chat/`, `Root/`, `Settings/`, `Today/`. View-models are MainActor `ObservableObject`s. |
| `Voice/` | `VoiceCaptureService` (WhisperKit), `VoiceCaptureAdapter`, the `VoiceCapture` protocol + adapter registry. |

## Dependency direction (one-way)

```
Views/  ──▶  Agent/ (AgentLoopHost) ──▶  Tools/ ──▶  DB/, EventKit/, HealthKit/, Notifications/, CSVMirror/, Memory/, Instruments/
                                                                       │
                                                                       ▼
                                                                     DB/  ◀── (everyone reads/writes through GRDB here)
```

- `Views/` may import from `Agent/`, `DB/`, `Notifications/`, `Voice/`, `EventKit/`, `Design/`, `Instruments/`. It should never reach into `Tools/` directly — the agent loop is the indirection.
- `Agent/` may import from `DB/`, `Tools/`, `Notifications/`, `EventKit/`, `HealthKit/`, `Instruments/`, `Memory/`, `Domains/`.
- `Tools/Catalog/*` may import from `DB/`, `EventKit/`, `HealthKit/`, `Instruments/`, `Memory/`, `Notifications/`, `Domains/`, `Actions/` (the audit log).
- `DB/`, `Actions/`, `Design/`, `Network/` have no upward dependencies (leaves).
- `Voice/`, `Background/` are leaves that the app bootstraps directly from `StewardApp.swift` / `TrackFBootstrap`.

## Load-bearing invariants

These are guarded for a reason. If you spot a real bug in one, **stop and call it out** — don't fix it as part of a routine refactor.

- **Instrument arithmetic is deterministic Swift.** Every instrument kind in `Instruments/Kinds/*` is a pure updater conforming to `InstrumentKind`. The LLM may *propose* events but must not emit math. (Spec §6 / Hard reject #9.)
- **`UndoExecutor.execute(_:)` is an exhaustive switch over `InverseAction` with no `default:` arm.** Adding a new `InverseAction` case must produce a compile error in `Actions/UndoExecutor.swift` until handled. (Hard reject #4 — see top-of-file comments in both `TurnAction.swift` and `UndoExecutor.swift`.)
- **Notification cap math lives in `NotificationScheduler`.** Max 3 proactive notifications/day, 90-min spacing, morning brief counts as one. The LLM never decides whether to schedule — it only proposes; the actor enforces. (Spec §10 / Hard reject #8.)
- **`<<INVARIANT>>`-bracketed clauses in `PromptAssembler` bookend the system prompt.** The opening invariant is at position `[2]` and the closing invariant is at `[6]`; nothing the LLM emits — including `role_prompt` — can override them. Anti-moralization, anti-streak-shame, and the daily-slogan ban live here. (Spec §7.)
- **`EventLog.append` is the single writer for the `events` table.** Hard reject #10. Agent actors must supply `reasoning` (hard reject #11); the SQL CHECK constraint backs this up but `EventLog` surfaces a typed error first.
- **EventKit + HealthKit permissions are deferred-first-use.** The gateways throw typed `PermissionRequiredSignal` / `HealthPermissionRequiredSignal` on `.notDetermined`; `ChatViewModel` intercepts and surfaces the inline-grant bubble. **Never call `requestAccess` outside the gateway** (hard reject #18 / #14).
- **`events.domain` does double duty.** For `chat_turn` rows it places the message on a thread; for state-change rows it scopes the change. The two readings are disambiguated by `events.kind`.
- **Anti-moralization & anti-streak language are prompt-level bans.** `PromptAssembler` forbids "streaks/resets/get back on track" framing. No motto/slogan in the morning brief footer. If you're adding new copy and you reach for that vocabulary, you're outside the design.
- **Tool dispatch is enum-keyed, not string-keyed.** Every dispatch site keys off `ToolID` (enum) so adding a tool is a compile-error forcing function. The exception is the LLM↔tool boundary, which is necessarily JSON.

## Where to look first for X

| If you want to change… | Start at |
| --- | --- |
| how the coordinator decides to call a tool | `Agent/AgentLoop.swift` + `Agent/PromptAssembler.swift` |
| the canned mock-session responses (offline tests, no-Apple-Intelligence devices) | `Agent/MockLLMSession.swift` |
| add a new instrument kind | `Instruments/InstrumentKind.swift` + add a file under `Instruments/Kinds/` and register in `InstrumentRegistry.bootstrapAll()` |
| add a new mutating tool | `Tools/Catalog/<Family>Tools.swift` + add the inverse to `Actions/TurnAction.swift` + handle it in `Actions/UndoExecutor.swift` |
| notification cap math (proactive limits, mercy mode, quiet hours) | `Notifications/NotificationScheduler.swift` |
| recurring-rule semantics (RRULE subset) | `Notifications/RRuleSubset.swift` + `Notifications/RecurringRuleStore.swift` |
| tap-to-act on a notification | `Notifications/NotificationActionRouter.swift` |
| EventKit permission UX | `EventKit/EventKitGateway.swift` + `Views/Chat/PermissionPromptBubble.swift` + `Views/Chat/ChatViewModel.swift` |
| HealthKit permission UX | `HealthKit/HealthKitGateway.swift` (same shape as EventKit) |
| memory retrieval scoring weights | `Memory/MemoryRetriever.swift` (see `(0.45·cos + 0.25·bm25 + 0.20·recency + 0.10·typeBonus) · effectiveStrength`) |
| memory admission / decay | `Memory/MemoryAdmissionPolicy.swift` + `Memory/MemoryDecayJob.swift` |
| CSV mirror file format | `CSVMirror/InstrumentCSVCoder.swift` + `CSVMirror/CSVTable.swift` |
| CSV mirror watch / reconcile | `CSVMirror/CSVMirrorWatcher.swift` |
| DB schema | `DB/Migrations.swift` (one giant migration set; add a new migration, never edit a shipped one) |
| settings (toggles, mercy mode, quiet hours, etc.) | `DB/SettingsStore.swift` (typed `Settings` struct + persistence) |
| chat view-model state machine | `Views/Chat/ChatViewModel.swift` |
| today view (instrument cards, upcoming list) | `Views/Today/TodayView.swift` + `Views/Today/TodayViewModel.swift` |
| settings sections | `Views/Settings/SettingsView.swift` (one file per section in the same folder) |
| brand strings / colors / fonts | `Design/BrandStrings.swift`, `Design/BrandColors.swift`, `Design/BrandFonts.swift` (`SatoshiWeight` enum) |
| how the app boots | `StewardApp.swift` (`AppBootstrap`, `TrackFBootstrap`) |
| voice capture (WhisperKit) | `Voice/VoiceCaptureService.swift` |

## Three-layer state, drawn out

| Layer | Table(s) | Mutated by | Read by |
| --- | --- | --- | --- |
| **History** | `events`, `events_fts` | `DB/EventLog.append` (single writer) | `Tools/Catalog/EventTools.swift`, `Views/Settings/AuditLogView.swift`, `Actions/AuditLog.swift` |
| **State machines** | `instruments` | `InstrumentTools.swift` via `InstrumentRegistry` | `Views/Today/*`, `Tools/Catalog/InstrumentTools.swift` |
| **Recall** | `memory_items`, `memory_fts` | `MemoryTools.swift` via `MemoryAdmissionPolicy` | `MemoryRetriever`, runtime context in `PromptAssembler` |

Cross-layer rules (Spec §5):
- Every `instrument` update writes a paired event with `kind = 'instrument_update'`. Spec §6.
- Every memory write writes a paired event with `kind = 'memory_write'` (or `memory_strengthen` / `memory_forget`). Provenance event-ids are stored on the memory row.
- Events never get updated or deleted. Undo is recorded as a *new* event referencing the original; `AuditLog.hasBeenUndone` checks for that link.

## The agent loop, briefly

1. User sends a chat message. `ChatViewModel.send(_:)` appends an optimistic bubble + thinking placeholder, then calls `AgentLoopHost.shared`'s pending turn.
2. `AgentLoop` builds the **runtime context** (current mercy/pause state, recent memory hits, conversation state, agent role, timezone, clock), assembles the prompt via `PromptAssembler`, and calls the coordinator's `LLMSession.respond(to:)`.
3. Foundation Models internally loops tool calls (it owns the tool-call ↔ result ↔ continued-reply chain). We never re-enter the loop manually — that's hard reject #7.
4. The **one exception** is `agent.handoff`. It's wired as a real `LLMTool` whose `invoke()` consumes a `TurnBudget` hop, spawns the domain agent's session, and returns the domain reply to the coordinator. This is the *only* way the 8-hop cap means "max 8 cross-agent handoffs per coordinator turn."
5. When the coordinator's reply returns, `ChatViewModel` drops the placeholder, appends the assistant bubble, and renders any tool-call cards. Failures drop the placeholder and append a `systemNote` with a retry hook.
6. Side effects (calendar writes, notification scheduling, memory writes) happen inside the tool `invoke()`s before the reply returns. Each emits an event with reasoning + inverse action.

## Backends and gating

- `Agent/LLMResolver` picks Foundation Models or Mock at runtime based on availability + the `mockLLMEnabled` setting toggle. `LLMBackendKind` is the public summary.
- `MockLLMSession` is a **pure dispatcher** keyed on a `conversation_state` token the assembler injects. Adding a canned turn is two changes: a new `ConversationState` case + a branch in `MockResponsePlan.plan`. No string-prefix fuzziness — exhaustive `switch` over `ConversationState`.

## Things that are deliberately a single file

These show up in the "files >400 lines" list. They are kept whole on purpose:

- `Agent/MockLLMSession.swift` — token-table dispatcher. Splitting would break the "one place to read the whole canned-turn surface" property.
- `Actions/UndoExecutor.swift` — exhaustive switch over `InverseAction`. The whole point is to read all cases together.
- `Actions/TurnAction.swift` — type bundle (identifier newtypes + payload structs + the `InverseAction` enum). The newtypes are clustered intentionally so a fresh reader sees the whole ID surface in one read.
- `Notifications/NotificationScheduler.swift` — cap math + the actor that runs it. Splitting the math from the actor would move the invariant out of the file that enforces it.
- `Tools/Catalog/*Tools.swift` — one file per tool family. Each contains 4–6 self-similar tool structs. These were split per-tool in earlier passes and put back together because the per-tool files all read identically and the family-level file is faster to skim.

If a file ends up over ~400 lines and *isn't* in this list, that's a hint it might be splittable. But there is no LOC budget — single-file clarity beats forced splits.

## Tests

Tests live in `ios/StewardTests/`. They all use `@testable import Steward`, so anything `internal` (i.e. no access modifier) is test-visible. `public` is never required for testability.

Coverage hotspots:
- Agent loop + handoff + budget: `AgentLoopTests.swift`, `MockLLMSessionTests.swift`, `TurnBudgetTests.swift`.
- Undo / inverse-action coverage: `UndoExecutorTests.swift`.
- Notification cap math: `NotificationSchedulerTests.swift`, `RecurringRuleStoreTests.swift`, `RRuleSubsetTests.swift`.
- Permission flows: `ChatViewModelPermissionFlowTests.swift`, `EventKitGatewayTests.swift`, `HealthKitGatewayTests.swift`.
- Instruments: `Instruments/InstrumentKindsTests.swift`.
- CSV mirror: `CSVMirrorTests.swift`, `CSVMirrorAvailabilityTests.swift`.

## Spec cross-references

| Concept | Spec section |
| --- | --- |
| Design principles (continuity, capture, no moralization, etc.) | §2 |
| Three-layer state model | §5 |
| Instrument kinds (the seven Pod C kinds) | §6 |
| Agent architecture (coordinator + domains + handoff) | §7 |
| Tool surface (catalog enumeration) | §8 |
| Memory architecture (hybrid retrieval, decay) | §9 |
| Notifications + recurring rules + cap math | §10 |
| EventKit + Reminders (deferred permissions) | §11 |
| CSV mirror | §12 |
| Offline / sync | §13 |
| Voice capture (WhisperKit) | §14 |
| Safety, mercy, audit | §15 |
| First-run experience | §16 |
| Onboarding | §17 |
| UI surface (three tabs) | §18 |
| v0.1.0-alpha DoD | §20 |
| Explicitly deferred | §21 |

## Pointers for future work

The v1.5 UI rework specs (`design/ui-rework-v1.5-*.md` if present, plus `spec/ui-rework-v1.5-arch-impact.md`) describe the next major rework. They were drafted before this refactor and reference the same module structure documented here. If you're picking up that work, the arch-impact doc is the place to start.

Anything not covered here is in `spec.md`.
