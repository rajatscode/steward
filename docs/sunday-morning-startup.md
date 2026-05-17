# v0.1.0-alpha startup

Audience: Rajat. Read this first thing — before opening the project. **This is a v0.1.0-alpha build: code is written but not yet end-to-end-validated on device. Treat every "PASS" below as "expected to pass" until you confirm it on hardware.**

## 1. State of the build

All six tracks merged to `main`. Build green on simulator. Foundation Models is gated behind a protocol (`LLMSession` / `LLMResolver`) so the app runs today against a deterministic mock — every mock reply gets a `STUB` chip stamped on it in the UI so you always know whether you're talking to the real model. Once Xcode 26 beta is installed and the iOS deployment target is bumped to 26.0, `LLMResolver` picks up `FoundationModelsSession` automatically. No code changes needed; the only two files that import `FoundationModels` are `ios/Steward/Agent/LLMResolver.swift` and `ios/Steward/Agent/FoundationModelsSession.swift`, both gated on `#if canImport(FoundationModels)`.

## 2. Install Xcode 26 beta (~30–45 min, mostly download)

1. https://developer.apple.com → sign in → **Downloads** → **Xcode 26 beta** → grab the `.xip` (~12–15 GB).
2. Expand it into `/Applications`:
   ```
   xip --expand ~/Downloads/Xcode_26_beta.xip -o /Applications/
   ```
3. Point the command-line tools at the beta:
   ```
   sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
   ```
4. Verify:
   ```
   xcrun --sdk iphoneos --show-sdk-version
   ```
   Should print `26.x`. If it prints `18.x`, `xcode-select` didn't take — rerun step 3.

## 3. Fetch the WhisperKit model (~5–10 min, one-time)

Voice capture ships with the model bundled inside the app — no lazy runtime download. Run this once before your first device build:

```
cd /Users/rmehndir/dev/rajat/steward
scripts/fetch-whisperkit-model.sh
```

This pulls `openai_whisper-large-v3-turbo` (~1.6 GB) into `ios/Steward/Resources/WhisperKitModels/` via `git-lfs`. If `git-lfs` isn't installed: `brew install git-lfs && git lfs install`. If you want a smaller dev model: `scripts/fetch-whisperkit-model.sh openai_whisper-base`. The script is idempotent — re-running with the model already present is a no-op.

If you skip this step, the app still builds and runs; the voice (mic) button just won't appear in the Chat input. Everything else works.

## 4. Open the project + bump deployment target (~2 min)

1. ```
   open /Users/rmehndir/dev/rajat/steward/ios/Steward.xcodeproj
   ```
2. Project navigator → **Steward** target → **General** → **Minimum Deployments** → **iOS**: change `18.4` → `26.0`.
3. Build: **⌘B**. Should compile clean.
4. If it doesn't: screenshot the error, paste in chat, don't fight it.

## 5. Deploy to phone (~5 min)

1. iPhone connected via cable, unlocked, developer mode on:
   **Settings → Privacy & Security → Developer Mode → On** (requires restart if you haven't done this before).
2. Xcode top bar → target picker → select your iPhone.
3. **⌘R**. First deploy is slow (a few minutes); subsequent runs are fast.
4. If Xcode prompts for signing:
   - **Project → Signing & Capabilities → Team** → pick your Apple Developer team.
   - Bundle ID stays `com.rajatscode.steward`. Don't change it.

## 6. First launch — what to expect

- Splash, then a Foundation Models availability check (a few seconds for cold init).
- One of three things happens at the top of the Chat tab:
  - **No banner.** `LLMResolver` resolved to `FoundationModelsSession`. You're talking to the real on-device model. Replies have no `STUB` chip.
  - **`STUB` chip on every reply, with a banner explaining why.** The resolver fell back to `MockLLMSession`. The banner uses a typed reason so you know exactly what's wrong:
    - *Apple Intelligence is off* → Settings → Apple Intelligence & Siri → turn on, then relaunch.
    - *Model is still preparing* → wait a few minutes after enabling Apple Intelligence; the model downloads in the background.
    - *Device not eligible* → wrong hardware (needs iPhone 15 Pro/Pro Max or iPhone 16+).
    - *SDK not compiled in* → you didn't bump the deployment target to 26.0; go back to step 4.
- Onboarding asks for, in order:
  - Notifications permission
  - EventKit permission (Calendar + Reminders)
  - iCloud Drive folder check (creates `Steward/` in your iCloud Drive root if iCloud Drive is enabled; falls back to local sandbox silently if not)
  - Morning brief time (default **07:00**)
  - Quiet hours (default **22:00–05:00**)
- App drops you into the **Chat** tab with the empty-state greeting per `design/coordinator-empty-state-v2.md` §1.1. Two chips below the input:
  - **Catch something** → focuses the input with placeholder `"What should I catch? (sleep, weight, a spend, a thing on your mind…)"`. Type a concrete event and send. The coordinator silently logs it, acknowledges, and (if the event has a recurring shape) offers a one-sentence "want me to keep tracking this?" follow-up. Per the v2 script that's **Branch A — capture-first**.
  - **Walk me through it** → fills the input with `walk me through it`. Send. The coordinator runs **Branch B — setup-first**: one open question, then proposes a team name, then a behavioral tone (Stay gentle / Push back a little / Push hard), then proposes exactly one starting instrument, then asks if you want a second, then proposes a morning-brief + wind-down cadence.
- Mic button appears next to the input only if the WhisperKit model was bundled (step 3). Hold to talk; release inserts the transcript into the input (no auto-send).

## 7. The 7 instrument kinds (spec §6)

The coordinator will propose these by plain name ("a 7-day rolling average for sleep"), not by kind. For your own reference when QAing:

- `running_accumulator` — daily totals with rolling 7d / 30d averages
- `bounded_budget` — daily/weekly/monthly budget with remaining
- `rolling_average` — windowed mean or EMA (sleep, weight, mood)
- `countdown_commitment` — "N things by end of period"
- `weekly_evidence_log` — qualitative weekly entries
- `checklist` — recurring items with per-item streak
- `bounded_window` — time-window adherence (sleep window compliance)

All seven implementations live in `ios/Steward/Instruments/Kinds/`. State recomputes deterministically in Swift on every event — the LLM never does instrument arithmetic.

## 8. The 14-item DoD checklist (spec.md §20)

Self-QA on first device launch. Check each as you confirm it. Anything unchecked goes back to the team. **None of these has been verified on device yet.**

- [ ] **1.** App launches on iPhone, Foundation Models confirmed available, Apple Intelligence active
- [ ] **2.** Chat tab opens, coordinator greets and runs the empty-state protocol (section 16)
- [ ] **3.** Spawn first domain via chat — coordinator proposes shape, user accepts/edits, `domain.create` writes row, the new domain agent responds in the same conversation
- [ ] **4.** Spawn first instruments during the same conversation via `instrument.create`; visible in Today tab immediately
- [ ] **5.** Log an event via chat ("slept 6 hours" or whatever fits the spawned domain) → coordinator hands off to the domain agent → relevant instrument updates → event appears in Today tab
- [ ] **6.** Read instrument state via chat ("how am I doing on X this week?") → domain agent reads instrument, reports accurately (no LLM math; values come from the deterministic state)
- [ ] **7.** Schedule a wind-down or check-in notification via chat ("nudge me at 10:30 to start winding down") → notification visible in Settings, fires at the scheduled time
- [ ] **8.** Morning brief notification fires at the configured time (default 7am if user kept default during onboarding); opens to a generated brief on tap
- [ ] **9.** Spawn a second domain via chat ("make me a Money agent for discretionary spend") → domain row written, agent responds in next turn
- [ ] **10.** Calendar read via chat ("what's on my calendar today") → EventKit read returns today's events
- [ ] **11.** Reminder create via chat ("remind me to call mom this weekend") → EventKit Reminder created, visible in iOS Reminders app
- [ ] **12.** Works offline — airplane mode, all of 1–11 still work except CSV mirror sync (which queues for when iCloud Drive sync next runs)
- [ ] **13.** Audit log in Settings shows recent agent actions with `reasoning` fields, each with a working undo button
- [ ] **14.** Notification cap is configurable — Settings exposes proactive-per-day cap, min gap, quiet hours; chat tool also lets user adjust ("up the cap to 5/day this week, I'm in a focus push")

## 9. If something is broken

- Regression suite: `qa/regression-checklist.md`.
- Every agent action is in **Settings → Recent agent actions** with the `reasoning` field and a working undo button. If an agent did something unexpected, that's where you find out why and reverse it.
- For anything weirder than a single failed action, reply in chat with the failing DoD item number and what you saw.

## 10. What's not in v0.1.0-alpha (per spec §21)

Deferred on purpose. Don't be surprised when these are missing:

- Apple HealthKit (top of the v1.1 list)
- Google Sheets mirror (in-app SwiftUI grids + iCloud Drive CSV mirror are the only spreadsheet surfaces)
- Google Calendar mirror (EventKit / iCloud Calendar is the transport; subscribe to your GCal in iOS Calendar settings if you need to see GCal events)
- Custom user-defined instrument kinds (the seven in §7 are what you get)
- Multi-device CloudKit sync (single-device only)
- Structured weekly review report (coordinator can do ad-hoc on request)
- Background cron via webhooks
- Written-formula support (interpretation B from the spreadsheets discussion)
- Plaid / bank sync
- Native Mac companion app
- Web search (returns offline-error in v1)
