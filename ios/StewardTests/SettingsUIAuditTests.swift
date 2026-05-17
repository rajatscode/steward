//
//  SettingsUIAuditTests.swift
//  StewardTests
//
//  v1.1 patch (settings-audit): user-driven Settings UI mutations must emit
//  `settings_change` events with `{field, prior, new}` payload so the audit
//  log can show what the user changed and when. Covers:
//
//   1. mercy mode engage from UI -> settings_change w/ field=mercy_mode_until
//   2. quiet hours edit from UI -> settings_change w/ structured prior+new
//   3. AuditLogView renders settings events (no Undo button)
//   4. No-op edit (Save tapped without changing the value) -> NO event row
//   5. Agent-driven mercy_mode.engage tool still writes its own event;
//      no `settings_change` row is duplicated by the user-UI path
//

import XCTest
import GRDB
@testable import Steward

final class SettingsUIAuditTests: XCTestCase {

    // MARK: - Test harness

    private func makeProvider() async throws -> DatabaseProvider {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-settings-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("steward.sqlite")
        let provider = DatabaseProvider(location: .file(dbURL))
        _ = try await provider.database()
        return provider
    }

    private func loadSettingsChangeEvents(provider: DatabaseProvider) async throws -> [Row] {
        let db = try await provider.database()
        return try await db.read { dbase in
            try Row.fetchAll(
                dbase,
                sql: """
                    SELECT event_id, actor, kind, source, payload_json, reasoning
                    FROM events
                    WHERE kind = 'settings_change'
                    ORDER BY created_at ASC
                """
            )
        }
    }

    private func decodePayload(_ row: Row) throws -> [String: Any] {
        let json: String = try XCTUnwrap(row["payload_json"])
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 1. Mercy mode engage from UI

    func test_mercyModeEngage_fromUI_emitsSettingsChangeWithPriorAndNew() async throws {
        let provider = try await makeProvider()
        let store = SettingsStore(provider: provider)

        let target = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15-ish
        _ = try await store.update(audit: .mercyModeUntil) { s in
            s.mercyModeUntil = target
        }

        let rows = try await loadSettingsChangeEvents(provider: provider)
        XCTAssertEqual(rows.count, 1, "exactly one settings_change row expected")
        let row = rows[0]
        XCTAssertEqual(row["actor"] as String?, "user",
                       "settings UI mutations must record actor=user")
        XCTAssertEqual(row["source"] as String?, "ui",
                       "settings UI mutations must record source=ui")
        // CHECK constraint allows nil reasoning for actor='user'; we keep it
        // nil rather than inventing prose.
        XCTAssertNil(row["reasoning"] as String?,
                     "reasoning should be nil for user-actor settings changes")

        let payload = try decodePayload(row)
        XCTAssertEqual(payload["field"] as? String, "mercy_mode_until")
        XCTAssertTrue(payload["prior"] is NSNull,
                      "prior mercyModeUntil was nil so payload prior must be JSON null")
        let newISO = try XCTUnwrap(payload["new"] as? String,
                                   "new value must be ISO-8601 string")
        let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: newISO))
        XCTAssertEqual(parsed.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - 2. Quiet hours edit from UI

    func test_quietHoursEdit_fromUI_emitsStructuredPriorAndNew() async throws {
        let provider = try await makeProvider()
        let store = SettingsStore(provider: provider)

        _ = try await store.update(audit: .quietHours) { s in
            s.quietHours = .init(start: "23:00", end: "06:00")
        }

        let rows = try await loadSettingsChangeEvents(provider: provider)
        XCTAssertEqual(rows.count, 1)
        let payload = try decodePayload(rows[0])
        XCTAssertEqual(payload["field"] as? String, "quiet_hours")
        let prior = try XCTUnwrap(payload["prior"] as? [String: Any])
        XCTAssertEqual(prior["start"] as? String, "22:00")
        XCTAssertEqual(prior["end"] as? String, "05:00")
        let new = try XCTUnwrap(payload["new"] as? [String: Any])
        XCTAssertEqual(new["start"] as? String, "23:00")
        XCTAssertEqual(new["end"] as? String, "06:00")
    }

    // MARK: - 3. AuditLogView renders settings events (no undo)

    @MainActor
    func test_auditLogView_rendersSettingsEvents_withoutUndoButton() async throws {
        let provider = try await makeProvider()
        let store = SettingsStore(provider: provider)

        _ = try await store.update(audit: .maxProactiveNotificationsPerDay) { s in
            s.maxProactiveNotificationsPerDay = 5
        }

        let viewModel = AuditLogViewModel(provider: provider)
        await viewModel.load()

        XCTAssertEqual(viewModel.entries.count, 1,
                       "AuditLogView should surface the settings_change event")
        let entry = viewModel.entries[0]
        XCTAssertEqual(entry.kind, "settings_change")
        XCTAssertEqual(entry.actorLabel, "You",
                       "user-actor pretty label is 'You' per AuditLogViewModel.prettyActor")
        XCTAssertFalse(entry.isReversible,
                       "settings_change must NOT be reversible — no InverseAction pair")
        XCTAssertEqual(
            entry.summary,
            "Max nudges per day set to 5",
            "summary should humanise the settings_change payload"
        )
    }

    // MARK: - 4. No-op save -> no duplicate event

    func test_noOpUpdate_doesNotEmitDuplicateEvent() async throws {
        let provider = try await makeProvider()
        let store = SettingsStore(provider: provider)

        // Mutation closure that doesn't actually change the audited field —
        // mimics the user opening the cap stepper, not moving it, tapping Save.
        _ = try await store.update(audit: .maxProactiveNotificationsPerDay) { s in
            // Re-assign the same value. The settings row write still runs
            // (we don't deep-compare the whole struct), but the audited
            // field's value didn't change, so no event row may be emitted.
            s.maxProactiveNotificationsPerDay = s.maxProactiveNotificationsPerDay
        }

        let rows = try await loadSettingsChangeEvents(provider: provider)
        XCTAssertEqual(rows.count, 0,
                       "no-op cap edit must not emit a duplicate settings_change row")
    }

    // MARK: - 5. Agent-driven mercy_mode.engage still works and is not duplicated

    func test_agentDrivenMercyModeEngage_writesItsOwnEvent_andNoSettingsChange() async throws {
        let provider = try await makeProvider()
        let store = SettingsStore(provider: provider)
        let fixedNow = ISO8601DateFormatter().date(from: "2026-05-17T10:00:00Z")!

        let tool = MercyModeEngageTool(
            provider: provider,
            settings: store,
            now: { fixedNow }
        )
        let until = ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(3 * 86_400))
        let args = """
        {
          "until_when": "\(until)",
          "reason": "User asked to be soft on themselves this week.",
          "reasoning": "User mentioned a hard week ahead and asked for gentler nudges.",
          "actor": "coordinator"
        }
        """
        _ = try await tool.invoke(argsJSON: args)

        // Agent-emitted mercy_mode_engage event still lands.
        let db = try await provider.database()
        let agentRows = try await db.read { dbase in
            try Row.fetchAll(
                dbase,
                sql: "SELECT actor, kind, reasoning FROM events WHERE kind = 'mercy_mode_engage'"
            )
        }
        XCTAssertEqual(agentRows.count, 1,
                       "agent path must still write its own mercy_mode_engage event")
        XCTAssertEqual(agentRows[0]["actor"] as String?, "coordinator")
        XCTAssertNotNil(agentRows[0]["reasoning"] as String?,
                        "agent actor requires reasoning (events CHECK constraint)")

        // The user-UI `settings_change` row must NOT appear — the agent
        // tool calls `SettingsStore.update(_:)` (no audit overload), not
        // `update(audit:_:)`, so no settings_change event is emitted.
        let settingsChangeRows = try await loadSettingsChangeEvents(provider: provider)
        XCTAssertEqual(
            settingsChangeRows.count, 0,
            "agent-driven mercy_mode.engage must NOT also emit a user-side settings_change"
        )

        // And the underlying settings row reflects the new value.
        let s = try await store.load()
        XCTAssertNotNil(s.mercyModeUntil, "mercyModeUntil must be set after the tool runs")
    }
}
