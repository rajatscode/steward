# Steward — QA Regression Checklist

**Role:** QA Tester #1, persistent / cross-cutting. Re-run this checklist after every integration. Flag anything that *used to work but doesn't anymore* — regressions are the highest priority.

**Source of truth:** `/steward/spec.md` (§20 DoD, §6 instrument kinds, §16 empty-state protocol).

**How to use:** For each check, record `PASS`, `FAIL`, `BLOCKED`, or `N/A (not yet integrated)`. On `FAIL`, capture: what action, expected vs. actual, the relevant event/instrument/notification IDs if reachable, and which integration introduced the regression.

---

## A. Tuesday-morning Definition of Done (spec §20)

These 14 items are the contractual ship gate. Every integration must leave all previously-passing items still passing.

| # | Check | Notes |
|---|---|---|
| 1 | App launches on the user's iPhone; Foundation Models reports available; Apple Intelligence active | Cold launch from a killed state. Confirm iOS 26+ build. |
| 2 | Chat tab opens; coordinator greets and runs the empty-state protocol (§16) when `domains.count == 0` | Coordinator must NOT pre-propose Health or any specific domain (§16, "Why no Health pre-seed"). |
| 3 | Spawn first domain via chat — coordinator proposes shape, user accepts/edits, `domain.create` writes row, new domain agent responds in the same conversation | Verify `domains` row written; verify the next assistant turn comes from the new domain agent (handoff visible in UI per §18). |
| 4 | Spawn first instruments during the same conversation via `instrument.create`; visible in Today tab immediately | Confirm card appears without app restart; `instruments_domain` index used. |
| 5 | Log an event via chat → coordinator hands off to domain agent → relevant instrument updates → event appears in Today tab | Verify event row, instrument `state_json` recomputed, Today tab reflects delta. |
| 6 | Read instrument state via chat ("how am I doing on X this week?") → domain agent reads instrument, reports accurately (no LLM math; values come from deterministic state) | **Critical:** numbers in chat must equal numbers in instrument grid. If they diverge, fail immediately — that's the "math is correct" principle. |
| 7 | Schedule a wind-down or check-in notification via chat → notification visible in Settings, fires at the scheduled time | Verify `notifications` row, `un_request_id` registered with UNUserNotificationCenter, delivered. |
| 8 | Morning brief notification fires at configured time (default 7am if onboarding kept default); opens to a generated brief on tap | Use a date-faked simulator or wait through onboarding time. Tap action lands on Today brief view. |
| 9 | Spawn a second domain via chat ("make me a Money agent for discretionary spend") → domain row written, agent responds in next turn | Confirms multi-domain. |
| 10 | Calendar read via chat ("what's on my calendar today") → EventKit read returns today's events | Requires EventKit permission granted. |
| 11 | Reminder create via chat ("remind me to call mom this weekend") → EventKit Reminder created, visible in iOS Reminders app | Cross-check in Reminders.app on the device. |
| 12 | Works offline — airplane mode, all of 1–11 still work except Sheets/CSV sync (which queues for when network returns) | Toggle airplane mode mid-test and rerun chat-driven flows. Confirm sync queue rows enqueued but not failing. |
| 13 | Audit log in Settings shows recent agent actions with `reasoning` fields, each with a working undo button | Test undo for: calendar event create, reminder create, notification schedule, instrument apply_event (where reversible). |
| 14 | Notification cap is configurable — Settings exposes proactive-per-day cap, min gap, quiet hours; chat tool also lets user adjust ("up the cap to 5/day this week, I'm in a focus push") | Verify the change persists in `settings_json` and that the scheduler honors it on the next decision. |

---

## B. Empty-state protocol (spec §16)

| # | Check | Notes |
|---|---|---|
| B1 | Coordinator's first turn is a brief self-intro + ONE open question ("what's been decaying / hard to keep up with") | No moralization. No mention of "executive function." |
| B2 | Coordinator does NOT propose Health (or any specific domain) before the user names one | Watch for steering language. |
| B3 | Coordinator proposes `display_name` + `role_prompt` + default tool scope, and shows the proposed role prompt inline for user edit | User must be able to edit "never moralize" to "sometimes push me a little" and have it stick. |
| B4 | Coordinator suggests 1–3 instruments (not more), each with explicit `kind` + `definition`, asks "want this, or design it differently?" | Verify the kind matches the user's described need (e.g., budget → `bounded_budget`, not `running_accumulator`). |
| B5 | Coordinator asks about cadence + morning brief preference; schedules via `notification.schedule_recurring` | Confirms notifications row created with `kind='morning_brief'`. |
| B6 | User can short-circuit the protocol ("just spawn a Money agent with $300/wk and remind me Sunday") and coordinator complies without running the full script | Critical: protocol is guidance, not rigid UI. |

---

## C. Instrument kinds — round-trip per kind (spec §6)

For each instrument kind, on a fresh test domain: create → apply at least one event → read state → confirm Today-tab card matches → confirm CSV mirror updated (when online). Math is recomputed in Swift, never by the LLM.

| # | Kind | Create | Event applies | State read matches grid | CSV mirror correct |
|---|---|---|---|---|---|
| C1 | `running_accumulator` (e.g., movement minutes daily target) | | | | |
| C2 | `bounded_budget` (e.g., $300/wk discretionary, with rollover variants) | | | | |
| C3 | `rolling_average` (e.g., 7-day weight trend; both `mean` and `ema`) | | | | |
| C4 | `countdown_commitment` (e.g., 3 pushbacks/week) | | | | |
| C5 | `weekly_evidence_log` (therapy homework) | | | | |
| C6 | `checklist` (morning routine; per-item streak) | | | | |
| C7 | `bounded_window` (sleep window adherence; compliance %) | | | | |

For each: also verify `manual_correction` event via inline grid edit produces the same downstream effect as a chat-logged event (§12).

---

## D. Agent loop and tooling (spec §7, §8)

| # | Check | Notes |
|---|---|---|
| D1 | Coordinator → domain handoff via `agent.handoff` works; transcript shows both turns; hop counter increments | |
| D2 | `MAX_HOPS = 6` is respected; on overrun, response is "I went around in circles. Saved what I had." and partial state is persisted | Force a loop with a deliberately ambiguous chain. |
| D3 | `agent.cross_consult` returns a domain-scoped answer without full handoff | |
| D4 | Domain agent tool scope is enforced — Money agent cannot write a `health`-domain commitment, etc. | Try to violate scope; expect a tool-router rejection logged as an event. |
| D5 | Every external mutation emits an event with `actor` + `reasoning` populated | Spot-check `events` table after a multi-tool turn. |
| D6 | Tool calls render in chat as collapsible "Steward did X" cards (§18) | UI surface. |
| D7 | "Hand-off in progress" indicator appears during domain agent turn | |

---

## E. Memory layer (spec §9)

| # | Check | Notes |
|---|---|---|
| E1 | Coordinator admits memories per heuristics: preferences/constraints/lessons saved; ephemeral states ("I'm hungry") NOT saved | |
| E2 | `memory.search` returns hybrid results (vectors + FTS5); ranking weights match §9 formula | Spot-check with a constraint vs. an observation; constraint should rank higher (type bonus). |
| E3 | Retrieval boost: an item used in an agent's context gets `+0.05` strength (capped 1.0) | Verify via `last_accessed_at` and `strength` after a relevant turn. |
| E4 | Nightly decay reduces strength per type modifier; soft-delete at `strength < 0.05` (archived, not lost) | Force-run decay job; check archived rows still readable. |
| E5 | `memory.forget` soft-deletes with an event row capturing the reason | |
| E6 | Constraint-type memory ("allergic to peanuts") never expires and surfaces in cross-domain context (e.g., Food/Health suggestion) | |

---

## F. Notifications and cron (spec §10)

| # | Check | Notes |
|---|---|---|
| F1 | Max 3 proactive notifications/day enforced deterministically before UN registration | Try to schedule a 4th; expect `cap_exceeded` result from scheduler. |
| F2 | Min 90-minute gap enforced; 4th-in-90min request returns `cap_exceeded` | |
| F3 | Quiet hours: only `morning_brief` survives; if morning brief overlaps quiet hours, it reschedules to wake hour (NOT silenced) | Edge: set quiet hours to swallow the morning brief time and confirm reschedule logic. |
| F4 | Mercy mode: cap drops to 1 (morning brief counts); body templates switch to soft copy | Engage via `mercy_mode.engage`; verify next scheduled notif uses soft template. |
| F5 | Pause mode: only calendar-driven hard reminders fire | |
| F6 | Auto-engage mercy after 3+ days of zero domain activity OR detected overwhelm | Simulate 3-day gap; coordinator should ask "want mercy for a few days?" |
| F7 | Recurring rule (`FREQ=DAILY;BYHOUR=7;BYMINUTE=0`) translates to `UNCalendarNotificationTrigger(repeats: true)` | |
| F8 | Tap on notification opens to action context; agent runs one-turn loop tailored to it | E.g., wind-down nudge tap → coordinator references "you scheduled this nudge; opened it X min later". |
| F9 | BGAppRefreshTask handler drains sync queue, recomputes upcoming notifs (cancel wind-down if user already logged sleep), refreshes memory decay | Best-effort; confirm idempotency. |

---

## G. EventKit (spec §11)

| # | Check | Notes |
|---|---|---|
| G1 | First run creates a "Steward" Calendar and a "Steward" Reminders list | |
| G2 | `calendar.write` lands in Steward calendar by default; writing to user's default calendar requires explicit user instruction | |
| G3 | `calendar.delete` is fully autonomous but logs an event with `reasoning` | |
| G4 | Subscribed Google Calendar (if user has one) is readable via EventKit `calendar.read` | Documented offline-graceful path. |
| G5 | Commitments with `ek_reminder_id` round-trip: complete in iOS Reminders → reflected in Steward `commitments.status` | NSFileCoordinator-equivalent via EKEventStore change notifications. |

---

## H. CSV mirror (spec §12)

| # | Check | Notes |
|---|---|---|
| H1 | On first run with iCloud Drive enabled, `Steward/` folder created with `README.md` | |
| H2 | Every instrument update enqueues `csv_mirror` sync row; worker drains immediately | |
| H3 | File layout matches spec: `instruments/<domain>/<name>.csv`, `__state.csv`, `events/events_YYYY-MM.csv` | |
| H4 | User edit in Numbers → NSFileCoordinator picks up change → emits `manual_correction` event(s) → instrument state updates → in-app grid reflects | The reconciliation loop. |
| H5 | iCloud Drive disabled: app still works fully; CSV mirror falls back to app sandbox without error | |
| H6 | Conflict resolution: last-writer-wins per cell, with event-log audit trail intact | |

---

## I. Voice capture (spec §14)

| # | Check | Notes |
|---|---|---|
| I1 | Hold-to-talk in chat input transcribes via WhisperKit on-device; releases into input field for review | Offline. |
| I2 | Siri Shortcut "Hey Siri, log to Steward" captures voice → posts to Steward URL scheme → processed like typed input | |
| I3 | Voice capture toggle in Settings disables both surfaces | |

---

## J. Anti-moralization / shame audit (spec §2, §15)

Run a synthetic "bad week" transcript (3+ day gap, missed commitments) and grep coordinator + domain agent output for banned patterns:

| # | Banned pattern | Notes |
|---|---|---|
| J1 | "you should have…" / "you didn't…" | |
| J2 | "let's get back on track" framing | |
| J3 | Streak language ("you broke your streak") | |
| J4 | Unsolicited comparison to past performance ("you missed 4 days this week") | |
| J5 | Quantitative shame | |
| J6 | After 3+ day lapse: coordinator switches to recovery script — smallest possible re-entry action, no review of the gap unless user asks | |

This audit re-runs every integration because prompts and context assembly evolve.

---

## K. Offline behavior (spec §13)

Toggle airplane mode and verify the matrix:

| # | Operation | Expected offline behavior |
|---|---|---|
| K1 | Chat with coordinator | Works fully (Foundation Models on-device) |
| K2 | Log event / update instrument | Works fully (local SQLite) |
| K3 | Read instrument state | Works fully |
| K4 | Memory retrieval | Works fully (NLEmbedding on-device) |
| K5 | Schedule local notification | Works fully |
| K6 | Calendar read/write | Writes locally; reads from local cache; syncs when network returns |
| K7 | CSV mirror | File writes are local; iCloud Drive syncs transparently when online |
| K8 | Web search | Returns offline-error; agent falls back to "I don't know without lookup" — does NOT hallucinate |
| K9 | Offline badge appears in UI; does NOT block any user action | |

---

## L. Settings + safety (spec §15, §18)

| # | Check | Notes |
|---|---|---|
| L1 | Quiet hours editable from Settings; chat tool `quiet_hours.set` also works and updates Settings UI | |
| L2 | Morning brief time editable; change takes effect on next scheduling pass | |
| L3 | Mercy toggle works from both Settings and chat (`mercy_mode.engage`); duration honored | |
| L4 | Pause toggle works from both surfaces; duration honored | |
| L5 | Domains list: rename, edit role prompt, archive — each writes an event | |
| L6 | Recent agent actions audit view shows last 50 actions with reasoning + undo | |
| L7 | Event log export (JSON) from Settings produces a valid file | |
| L8 | Foundation Models version + app version visible in About | |

---

## M. Data integrity / append-only invariants (spec §5)

| # | Check | Notes |
|---|---|---|
| M1 | `events` table is append-only — no UPDATE/DELETE statements anywhere in agent or tool code | grep-level check on every integration. |
| M2 | FTS5 triggers keep `events_fts` and `memory_fts` in sync after inserts | Spot-check with new rows. |
| M3 | Every instrument state change is preceded by an emitted event with matching `instrument_id` | Cross-join sanity check. |
| M4 | Every `agent_action` event has non-null `reasoning` | |
| M5 | ULIDs are sortable + unique across event/memory/instrument/commitment/notification IDs | |
| M6 | Migrations are idempotent — re-running on a hydrated DB does not lose data | |

---

## N. Regression-watch (cross-cutting, evolves per integration)

Each new integration appends a row here capturing what changed and what we'll now keep watching.

| Date | Integration | New surface | What we'll regression-watch |
|---|---|---|---|
| 2026-05-16 | (initial checklist) | — | — |

---

## Pass/fail recording template

```
Integration: <branch / PR / hash>
Date/time: <UTC>
Result: PASS=<n> FAIL=<n> BLOCKED=<n> N/A=<n>
Failures:
  - [X.n] <one-line summary>
    expected: ...
    actual:   ...
    repro:    ...
    suspected cause: <which integration changed this surface>
Regressions vs. previous run:
  - [X.n] used to PASS, now FAIL — see above
```
