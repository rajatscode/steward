# API Verification — iOS 26 / May 2026

Researcher: research. For team-lead. Cross-checks spec.md §4 (Tech stack), §7 (Agent loop), §10 (Notifications), §11 (EventKit), §14 (Voice), §17 (Onboarding).

Sources are cited inline. Where a claim is inference from public docs rather than directly quoted, it's flagged "(inferred)".

---

## 1. Apple Foundation Models framework

### Confirmed surface (iOS 26+, macOS 26+, iPadOS 26+)

- The framework is `FoundationModels`, exposing the on-device ~3B-parameter language model that powers Apple Intelligence. Free of per-token cost, runs offline, private. Apple explicitly positions it as **not a general-knowledge chatbot** — it's tuned for language understanding, structured output, summarization, extraction, and tool calling. ([Apple newsroom](https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/), [Apple docs: Foundation Models](https://developer.apple.com/documentation/FoundationModels), [Apple research](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates))
- Core class: **`LanguageModelSession`** — represents a "single context" / conversation transcript. Methods: `respond(to:)` and `streamResponse(to:)`. Constructed with a system prompt and an optional `tools: [any Tool]` array. ([createwithswift overview](https://www.createwithswift.com/exploring-the-foundation-models-framework/), [appcoda tool-calling](https://www.appcoda.com/tool-calling/))
- Availability gate: **`SystemLanguageModel.default.isAvailable`** for a binary check, or switch on `SystemLanguageModel.default.availability` to discriminate `.available`, `.unavailable(.appleIntelligenceNotEnabled)`, `.unavailable(.deviceNotEligible)`, `.unavailable(.modelNotReady)`. ([Apple docs: SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [dev.to fallback patterns](https://dev.to/arshtechpro/how-to-fall-back-gracefully-when-apple-intelligence-isnt-available-48j))

### Structured generation: `@Generable` and `@Guide`

- `@Generable` is a macro you attach to a Swift `struct` or `enum`. The session returns a typed value of that struct, parsed from the model output. `@Guide` macros decorate individual properties to constrain ranges, enums (`anyOf:`), array counts (`count:`), or to give natural-language hints. ([Apple docs: Foundation Models](https://developer.apple.com/documentation/FoundationModels), [createwithswift](https://www.createwithswift.com/exploring-the-foundation-models-framework/))
- This is the recommended pattern for Steward's tool-arg parsing and for any "extract structured event from freeform user text" path. **Spec §8 should use `@Generable` types for tool argument structs and the parsed-event return shape — not hand-roll JSON parsing.**

### Tool calling and the multi-hop loop

- Tools conform to a Swift `Tool` protocol. Each tool has `name`, `description`, an `Arguments` type (often `@Generable`), and a `call(arguments:)` async function. Passed in via `LanguageModelSession(tools: [...])`. ([Apple docs: Expanding generation with tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling), [Medium: Salvaterra on tool calling](https://medium.com/@luizfernandosalvaterra/teaching-llms-to-act-mastering-tool-calling-in-foundationmodels-9bf319c081b2))
- **The framework automatically handles the tool-result → model loop, including parallel and serial tool calls within a single `respond(to:)` call.** You do not write your own `while hops < MAX_HOPS` loop for individual tool calls within one turn. ([WWDC25 Session 286](https://developer.apple.com/videos/play/wwdc2025/286/), [appcoda tool-calling](https://www.appcoda.com/tool-calling/))
- **Implication for spec.md §7 (Agent architecture):** the hand-coded `while hops < MAX_HOPS` loop in the spec is unnecessary for *single-agent* tool calls — the framework does it. But the **`agent.handoff` cross-agent loop is still ours to write**, because spinning up a sub-`LanguageModelSession` with a different system prompt and tool subset is not something the framework abstracts. Keep the hop cap *for handoffs*, drop it for within-session tool calls.
- No public documentation on a hard per-call tool-hop ceiling. Treat infinite loops as a theoretical risk for handoffs only; framework-managed within-session loops have not been reported as runaway.

### Behavior when unavailable

- `SystemLanguageModel` returns `.unavailable(...)` in three distinct cases (device ineligible, Apple Intelligence not enabled, model still downloading). The model download requires Apple Intelligence to be activated by the user; ~7 GB of free storage is required, and the download is opaque. ([Apple Support: Apple Intelligence requirements](https://support.apple.com/en-us/121115), [Tom's Guide on iOS 26 AI gating](https://www.tomsguide.com/phones/iphones/many-ios-26-features-cant-be-used-without-apple-intelligence-what-you-need-to-know))
- Hardware floor: **A17 Pro or newer** — i.e., iPhone 15 **Pro/Pro Max** and all iPhone 16/17 models. iPhone 15 non-Pro is *excluded* even on iOS 26. ([techpp supported devices](https://techpp.com/2026/04/01/apple-intelligence-supported-devices/))
- **Landmine for Implementers:** Rajat's device is iPhone 15 Pro+ per spec, so this works for v1. But onboarding (spec §17 step 1) must handle `.modelNotReady` — if Apple Intelligence was just turned on, the model can take many minutes to download. Show a "Steward is finishing setup" state, poll `isAvailable`, do not try to call `respond(to:)` against an unready model.

### Recommendations for spec.md

1. Drop the within-session `MAX_HOPS = 6` loop; keep it only for `agent.handoff` cross-agent transitions.
2. Use `@Generable` for every tool's `Arguments` struct *and* for the coordinator's "parse this freeform text into a structured event" return type — this is what the framework is best at.
3. Onboarding needs an explicit "model not yet ready" branch, not just an "unavailable" branch.

---

## 2. WhisperKit (May 2026)

### Confirmed surface

- Argmax's WhisperKit (Swift package, repo recently renamed to `argmax-oss-swift` but still imported as `WhisperKit`) is the de facto on-device Whisper for Apple Silicon as of 2026. ([WhisperKit repo](https://github.com/argmaxinc/WhisperKit), [Argmax blog](https://www.argmaxinc.com/blog/whisperkit), [Forasoft 2026 playbook](https://www.forasoft.com/blog/article/speech-recognition-with-neural-networks-on-ios-1621), [WhisperKit paper, arXiv 2507.10860](https://arxiv.org/html/2507.10860v1))
- Recommended model for iPhone 15 Pro+: **`large-v3-turbo`**. Disk footprint ~1.6 GB. On iPhone 15 Pro, ~10 min of audio transcribes in ~82 s (5–6× real time). Streaming first-word latency <200 ms. ([Argmax blog](https://www.argmaxinc.com/blog/whisperkit), [Forasoft](https://www.forasoft.com/blog/article/speech-recognition-with-neural-networks-on-ios-1621))
- API shape: `let pipe = try await WhisperKit(model: "large-v3-turbo"); let results = try await pipe.transcribe(audioPath: …)` for batch, with a streaming `transcribe` variant that yields token-by-token. Xcode 16+ required for SPM integration. ([WhisperKit repo](https://github.com/argmaxinc/WhisperKit), [Transloadit guide](https://transloadit.com/devtips/transcribe-audio-on-ios-macos-whisperkit/))

### Microphone permission flow

- WhisperKit doesn't capture audio for you — you wire up `AVAudioEngine` (or AVAudioRecorder) and feed it the buffers. ([Medium: real-time STT with Whisper](https://medium.com/@jonataneduard/building-a-real-time-on-device-speech-to-text-in-swiftui-with-whisper-core-ml-ios-17-b1d468e44f4d))
- **Info.plist requires `NSMicrophoneUsageDescription` — the app will crash at first mic access without it.** Then call `AVAudioApplication.requestRecordPermission` (the modern replacement for the deprecated `AVAudioSession.sharedInstance().requestRecordPermission`). Permission is granted asynchronously. ([Apple docs: NSMicrophoneUsageDescription](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSMicrophoneUsageDescription), [Medium: media-capture authorization](https://medium.com/@nayananp/requesting-authorization-for-media-capture-and-audio-on-ios-b7b62c7f9ba7))
- For Steward's hold-to-talk UX: prompt for mic permission on **first tap of the voice button**, not at app launch. iOS will only ask once; a denial requires a Settings-app trip to undo, so timing matters.

### Landmines

- **App size:** 1.6 GB model is a real cost. WhisperKit supports bundling smaller variants (e.g., `small.en` at ~250 MB) or downloading on first run from HuggingFace. For overnight build, **bundle** to keep first-launch friction minimal; ship a Settings toggle to fall back to a smaller variant later if size becomes an issue.
- **First-load cold start:** Loading `large-v3-turbo` into the Neural Engine takes several seconds on first use. Initialize WhisperKit eagerly in a background task at app launch (gated on mic permission already granted) so the first hold-to-talk feels instant.
- **Audio session conflicts:** if the user is playing music or on a call, naive AVAudioSession configuration can stop their audio. Use `.playAndRecord` category with `.mixWithOthers` option *only* if you want non-disruptive capture; otherwise `.record` and accept the music pause.

### Recommendation for spec.md §14

Spec is correct that WhisperKit large-v3-turbo is plug-and-play. Add explicit notes: bundle the model in v1 (don't depend on first-launch download), initialize eagerly post-permission-grant, and gate the first-mic-prompt to actual voice-button tap.

---

## 3. GRDB.swift + FTS5 + on-device vector search

### Confirmed surface (current as of Feb 2026)

- GRDB.swift remains the canonical Swift SQLite toolkit; FTS5 is supported via the `FTS5` virtual-table DSL, with `Database.create(virtualTable:…, using: FTS5())` and BM25-ranked queries via `MATCH`/`RANK`. ([Swift Package Index GRDB docs](https://swiftpackageindex.com/groue/GRDB.swift/master/documentation/grdb/fts5), [GRDB GitHub](https://github.com/groue/GRDB.swift))
- Spec §5's FTS5 mirror tables (`events_fts`, `memory_fts`) with `content='events'/'memory_items'` plus sync triggers are the textbook GRDB pattern — verified correct.

### Vector storage as BLOB

- **GRDB has no first-class vector support.** The dominant pattern for Steward's scale (single user, tens of thousands of memory rows at most) is: store the normalized `float32` vector as a `BLOB` column on `memory_items`, do brute-force cosine in Swift after candidate prefiltering via FTS5. This is what spec §4 already calls for and it is the right call. ([Hybrid Search FTS5+vector+RRF article](https://ceaksan.com/en/hybrid-search-fts5-vector-rrf), [ZeroClaws hybrid memory write-up](https://zeroclaws.io/blog/zeroclaw-sqlite-fts5-vector-hybrid-memory-explained/), [dev.to: SQLite+FTS5 for agent memory](https://dev.to/fex_beck_27bfd4dccd05f062/why-sqlitefts5-beats-vector-dbs-for-ai-agent-memory-4inj))
- BLOB encoding: serialize `[Float]` as raw bytes (`Data(bytes: vec, count: vec.count * MemoryLayout<Float>.size)`); deserialize symmetrically. **Normalize at write time** so cosine collapses to a dot product at read time — verified standard. ([BGE model card normalization example](https://huggingface.co/BAAI/bge-small-en-v1.5))

### Vector search performance

- Brute-force cosine over a few thousand 512-dim `float32` vectors in Swift is sub-millisecond on iPhone 15 Pro using `Accelerate.vDSP.dotProduct`. No need for `sqlite-vec`, ObjectBox, or any ANN library at Steward's scale. (inferred from vector math + Accelerate norms; consistent with the hybrid-search articles above)
- For hybrid retrieval, the FTS5 prefilter narrows candidate IDs to ~40, then load those rows and compute cosine vs query vector in Swift. This is exactly the pseudo-code in spec §9 — verified sound.

### Landmines

- **GRDB transactions around event log + FTS5 + instrument state must be atomic.** A failed write that updates `events` but not the FTS index, or updates `instruments.state_json` but not the event log, breaks the "events are history, instruments are state" invariant. Wrap each tool execution in a single `db.write { … }` block.
- **Schema migrations:** add a `migrator.eraseDatabaseOnSchemaChange = false` and version every migration. GRDB's `DatabaseMigrator` is the right tool. (Apply standard GRDB hygiene; not novel.)
- **Embedding dimension drift:** if you ever swap NLEmbedding for BGE later, existing 512-dim vectors must be regenerated. Store `embedding_dim` on each row (spec §5 already does this — keep it).

### Recommendation for spec.md

Spec §4 says "Brute-force cosine over normalized vectors in SQLite BLOB column" — verified correct. No changes needed. Make sure the implementer uses `vDSP` for the dot product (not a hand-written for-loop) and that all writes are inside `db.write` blocks.

---

## 4. EventKit on iOS 26 — Calendar and Reminders permissions

### Confirmed surface (changes since iOS 17, stable through iOS 26)

iOS 17 split Calendar permissions into **write-only** and **full access**, and added a separate Reminders full-access scope. These are the current methods as of iOS 26 (no further breaking changes have been reported for iOS 26): ([Apple TN3153](https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos), [Apple docs: Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store))

| API | Purpose | Info.plist key |
|---|---|---|
| `EKEventStore.requestFullAccessToEvents()` (async) | Read + write Calendar events | `NSCalendarsFullAccessUsageDescription` |
| `EKEventStore.requestWriteOnlyAccessToEvents()` (async) | Write Calendar events only; cannot read existing events, cannot list calendars, cannot create calendars | `NSCalendarsWriteOnlyAccessUsageDescription` |
| `EKEventStore.requestFullAccessToReminders()` (async) | Read + write Reminders | `NSRemindersFullAccessUsageDescription` |

- Status enum: `EKAuthorizationStatus` now has `.notDetermined`, `.restricted`, `.denied`, `.writeOnly`, `.fullAccess`. `.authorized` is deprecated. Check via `EKEventStore.authorizationStatus(for: .event)` and `for: .reminder`. ([Apple docs: requestFullAccessToReminders](https://developer.apple.com/documentation/eventkit/ekeventstore/4162273-requestfullaccesstoreminderswith), [Apple docs: requestWriteOnlyAccessToEvents](https://developer.apple.com/documentation/eventkit/ekeventstore/requestwriteonlyaccesstoevents(completion:)?language=objc))

### Choreography for Steward

Spec §11 wants both calendar read and calendar write (read to surface "what's on today", write to create agent-scheduled blocks). That requires **`requestFullAccessToEvents`**, not write-only. Similarly, spec §8's `reminder.list` tool needs **`requestFullAccessToReminders`**.

- Request both in onboarding (spec §17 step 3): two separate prompts back-to-back is fine. iOS shows each prompt with its own usage description string.
- **Reminders has no write-only mode** as of iOS 26 — you either get full access or nothing. (verified from Apple docs surface; no write-only Reminders API exists)
- The "Steward" Calendar/list creation (spec §11) requires *full* access; write-only cannot list or create calendars.

### Info.plist required (all three)

```
NSCalendarsFullAccessUsageDescription
NSRemindersFullAccessUsageDescription
```

(Don't include the write-only key — requesting both write-only and full access from the same app may confuse the user about which the app actually needs.)

### Landmines

- **`.authorized` is deprecated** — do not switch on it; you'll silently fall through. Use `.fullAccess` and `.writeOnly`.
- **No iOS 26 breaking changes reported** for EventKit beyond the iOS 17 split. (inferred from the absence of TN updates for iOS 26 in the public docs as of May 2026; verify in beta release notes before WWDC)
- **Reminders permission is separate from Calendar permission** — granting one doesn't grant the other. Two prompts.

### Recommendation for spec.md §11 / §17

Spec is broadly correct but should make explicit: full access for both events and reminders, two separate prompts, two Info.plist keys, and `.fullAccess` (not `.authorized`) in switch statements.

---

## 5. NLEmbedding (NaturalLanguage framework)

### Confirmed surface

- `NLEmbedding.sentenceEmbedding(for: .english)` returns a sentence-level encoder. **Output dimension: 512 (Double[]).** Available since iOS 14. ([Apple docs: NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding), [Apple docs: sentenceEmbedding(for:)](https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:)), [callstack on-device embeddings](https://www.callstack.com/blog/on-device-ai-introducing-apple-embeddings-in-react-native))
- API: `embedding.vector(for: "some sentence")` returns `[Double]?`. Returns `nil` if the language doesn't support sentence embeddings or the input is empty.

### Suitability for Steward

- **Good enough for v1, with caveats.** Sentence embeddings exist and are 512-dim. Apple ships an updated revision per OS version; query the current revision via `NLEmbedding.currentSentenceEmbeddingRevision(for: .english)`. ([Apple docs: currentSentenceEmbeddingRevision](https://developer.apple.com/documentation/naturallanguage/nlembedding/currentsentenceembeddingrevision(for:)))
- Quality is below 2024-era open models (BGE-small-en-v1.5, MiniLM-L6-v2). Apple doesn't publish MTEB-style benchmarks; the consensus from public write-ups is "decent for clustering and rough semantic recall, weaker than BGE for nuanced retrieval." ([dasroot embedding comparison](https://dasroot.net/posts/2026/03/python-embedding-generation-sentence-transformers-bge/), [BentoML 2026 embedding survey](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models))
- **For Steward's hybrid retrieval, FTS5 carries most of the lexical recall load. NLEmbedding only needs to catch semantic-but-different-words cases ("I'm feeling burnt out" ≈ "exhausted from work").** That bar is meetable.

### Landmines

- **Old word-level NLEmbedding gotchas don't apply to sentence embeddings.** The "must lowercase / no Chinese / no Russian" issues are word-embedding-specific. Sentence embeddings are produced by a different (transformer-based) revision. (inferred from Apple docs structure; verify with `supportedSentenceEmbeddingRevisions(for:)` per language)
- **Language detection first.** `NLEmbedding.sentenceEmbedding(for: .english)` won't embed Chinese sentences well. For Rajat (English-primary), this is fine, but if user-entered text occasionally contains non-English content, embed via the detected language or skip embedding for short uncertain strings.
- **Cast to `[Float]` immediately.** Apple returns `[Double]`; you want `Float` for compact BLOB storage. Normalize after the cast.
- **Revision pinning:** if iOS ships a new sentence-embedding revision in a point release, vectors generated with the old revision are not comparable. Store the `revision` integer alongside `embedding_dim` in `memory_items`, and trigger re-embedding when the current revision changes. This is a real ongoing maintenance cost — flag for v1.1.

### Recommendation for spec.md §4 / §5

NLEmbedding is the right v1 choice. Add a `embedding_revision INTEGER NOT NULL` column to `memory_items` alongside `embedding_dim`. Plan an eventual BGE-small-en-v1.5 (384-dim) upgrade for v1.2 if retrieval quality is the bottleneck — the schema is already shape-agnostic.

---

## 6. BGTaskScheduler reliability + "recurring nudge that recomputes state at delivery"

### Reliability reality (2026)

- **No guaranteed minimum interval.** `BGAppRefreshTaskRequest.earliestBeginDate` is a *floor*, not a schedule. iOS may run your task seconds after that floor, hours later, or never that day. ([Apple docs: BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler), [Apple Developer Forums on background tasks](https://developer.apple.com/forums/thread/131205), [Apple Developer Forums on periodic background](https://developer.apple.com/forums/thread/724506))
- Execution time: ~30 s for `BGAppRefreshTask`, longer for `BGProcessingTask` (often gated on external power for "long" work). ([Medium: background tasks 2026 guide](https://medium.com/@dhruvmanavadaria/mastering-background-tasks-in-ios-bgtaskscheduler-silent-push-and-background-fetch-with-6b5c502d7448))
- Gating factors: low battery (<20%), Low Power Mode, no recent app usage (iOS learns "when this user opens the app" and runs refresh near those times), background app refresh disabled globally. Freshly installed apps have **no usage history → significant delay before any background task fires.** ([dev.to background processing 2026](https://dev.to/samantha-dev/react-native-background-task-processing-methods-2026-1aic))
- **No iOS 26 changes** to this reliability story have been reported. Treat BGTasks as "best effort, opportunistic." ([Apple docs: BackgroundTasks](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler))

### Pattern for "recurring nudge that recomputes state at delivery"

The honest answer: **you can't do real "compute fresh content at notification delivery" with local notifications on iOS, period.**

- `UNNotificationServiceExtension` only modifies *remote* (push) notifications, not local ones. ([Apple docs: UNNotificationServiceExtension](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension))
- `UNCalendarNotificationTrigger(repeats: true)` fires with whatever content you set when you scheduled it. No callback at delivery.

**Recommended pattern (the working compromise):**

1. **Pre-schedule generic, evergreen notification content** with `UNCalendarNotificationTrigger`. The notification body says something safe like *"Quick wind-down check — tap to see today's pick."*
2. The notification's `userInfo` (≈ spec's `action_context_json`) marks the intent (e.g. `{kind: "wind_down", domain: "health"}`).
3. **On tap**, the app opens, the coordinator/domain agent runs *now* with fresh state, and renders the contextual response in the app. This is what the user actually reads.
4. **In parallel**, use `BGAppRefreshTask` to: (a) cancel pending notifications whose preconditions have changed (e.g., user already logged sleep, so cancel wind-down nudge); (b) replace generic content with more specific content via `UNUserNotificationCenter.removePendingNotificationRequests` + re-add. Treat the BGTask as a *nice-to-have* polish, never as the source of truth for what the notification will say.
5. After the app handles a notification tap, **schedule the next occurrence with refreshed copy** while the app is foregrounded — this guarantees the *next* nudge has reasonably fresh content even if no BGTask fires in between.

This pattern is consistent with spec.md §10 ("Pre-schedule everything we know" + "Tap-to-act"). Verified sound; the spec's framing is already right.

### Landmines

- **Don't promise users "Steward will think about your state at 10pm and send a contextual nudge."** It can't. The nudge is pre-baked; the contextual thinking happens on tap or during foregrounded scheduling.
- **First-run dead period:** for the first few days after install, BGTasks may not fire at all. Have the app schedule the *next 7 days* of recurring notifications during the active foreground session, so users don't see a silent app while iOS is still learning.
- **`BGProcessingTaskRequest.requiresExternalPower = true`** for heavy work (memory decay recomputation, embedding regeneration) — this almost guarantees overnight execution but means it won't run if the user doesn't charge. Memory decay is fine to skip a day; embedding regeneration is rare. Accept the tradeoff.
- **Notification cap enforcement must happen in Swift at schedule time** (as spec §10 already says), not at delivery — because there is no delivery-time hook for local notifications. The spec's deterministic cap check before `UNNotificationRequest` registration is the right design.

### Recommendation for spec.md §10

Spec is correct in framing. Add to §10 explicitly:
- Local notification content is frozen at schedule time; only the *tap handler* gets fresh state.
- The recurring nudge pattern is: pre-schedule generic copy → user taps → app generates contextual response live → reschedule next occurrence with fresh copy.
- Schedule the next 7+ days of notifications during *every* foreground session, so first-week BGTask-dead-period doesn't leave the app silent.

---

## Cross-cutting summary for team-lead

See SendMessage for the ~200-word brief.
