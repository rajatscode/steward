# Sunday morning startup

Audience: Rajat. Read this first thing — before opening the project.

## 1. What happened overnight

The team built the app. The build machine didn't have Xcode 26 beta installed, so `FoundationModels` is currently stubbed behind a protocol — every agent call routes through a fake that returns canned responses. Once Xcode 26 beta is installed and the iOS deployment target is bumped, the real on-device LLM lights up automatically. No code changes needed beyond the deployment-target bump; the protocol's real implementation is already wired and gated on `#if canImport(FoundationModels)`.

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

## 3. Open the project + bump deployment target (~2 min)

1. ```
   open /Users/rmehndir/dev/rajat/steward/ios/Steward.xcodeproj
   ```
2. Project navigator → **Steward** target → **General** → **Minimum Deployments** → **iOS**: change `18.4` → `26.0`.
3. Build: **⌘B**. Should compile clean.
4. If it doesn't: screenshot the error, paste in chat, don't fight it.

## 4. Deploy to phone (~5 min)

1. iPhone connected via cable, unlocked, developer mode on:
   **Settings → Privacy & Security → Developer Mode → On** (requires restart if you haven't done this before).
2. Xcode top bar → target picker → select your iPhone.
3. **⌘R**. First deploy is slow (a few minutes); subsequent runs are fast.
4. If Xcode prompts for signing:
   - **Project → Signing & Capabilities → Team** → pick your Apple Developer team.
   - Bundle ID stays `com.rajatscode.steward`. Don't change it.

## 5. First launch — what to expect

- Splash screen, then a Foundation Models availability check. Expect a few seconds for cold init on first launch.
- Onboarding asks for, in order:
  - Notifications permission
  - iCloud Drive folder check (creates `Steward/` in your iCloud Drive root if iCloud Drive is enabled; falls back to local sandbox silently if not)
  - Morning brief time (default **07:00**)
  - Quiet hours (default **22:00–05:00**)
- App drops you into the **Chat** tab. Coordinator greets per `design/coordinator-empty-state-v2.md` §1.1 — read that file beforehand if you want to know the exact opening lines and the two suggestion chips.
- From there it's the empty-state protocol: **capture-first** (type something concrete) or **setup-first** (tap "walk me through it"). Your call. Either branch produces a working state in under five minutes.

## 6. The 14-item DoD checklist (spec.md §20)

Self-QA Sunday morning. Check each as you confirm it. Anything unchecked goes back to the team.

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
- [ ] **12.** Works offline — airplane mode, all of 1–11 still work except Sheets sync (which queues for when network returns)
- [ ] **13.** Audit log in Settings shows recent agent actions with `reasoning` fields, each with a working undo button
- [ ] **14.** Notification cap is configurable — Settings exposes proactive-per-day cap, min gap, quiet hours; chat tool also lets user adjust ("up the cap to 5/day this week, I'm in a focus push")

## 7. If something is broken

- Run qa-1's regression suite: `qa/regression-checklist.md`.
- Every agent action is in **Settings → Recent agent actions** with the `reasoning` field and a working undo button. If an agent did something unexpected, that's where you find out why and reverse it.
- For anything weirder than a single failed action, reply in chat with the failing DoD item number and what you saw.

## 8. What's not in v1 (per spec §21)

Deferred on purpose. Don't be surprised when these are missing:

- Google Calendar mirror (EventKit / iCloud Calendar is the transport; subscribe to your GCal in iOS Calendar settings if you need to see GCal events)
- Google Sheets mirror (in-app SwiftUI grids + iCloud Drive CSV mirror only)
- Apple HealthKit integration (top of the v1.1 list)
- Custom user-defined instrument kinds (the seven built-in kinds in spec §6 are what you get)
- Structured weekly review report (coordinator can do ad-hoc on request)
- Plaid / bank sync
- Native Mac companion app
- Web search (returns offline-error in v1)
