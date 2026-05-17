//
//  InstrumentCSVCoder.swift
//  Steward — Track F
//
//  Bridging layer between Track C's `InstrumentKind` protocol (addendum §1.2)
//  and the CSV mirror in Track F. Track C's per-kind static `renderCSV` and
//  `parseCSVOverride` functions are wrapped in a `Coder` value and registered
//  here by kind id; the watcher dispatches by `instruments.kind` column at
//  reconcile time.
//
//  Until Track C lands, this file also includes a minimal
//  `RunningAccumulatorCoder` so Track F's tests can round-trip end-to-end. The
//  stub is documented as such and will be deleted on merge with Track C's
//  registry (we'll switch to `InstrumentRegistry.coder(for:)`).
//

import Foundation

/// Diff result for one cell. Emitted as a `manual_correction` event payload
/// (addendum §1.4 step 3).
struct ManualCorrection: Codable, Sendable, Equatable {
    let rowID: String
    let columnName: String
    /// `nil` when the row is brand new (no prior Steward write of that cell).
    let oldValue: String?
    let newValue: String
    /// Set when the diff came from a conflict-resolution merge; surfaces the
    /// row to the user in the chat next-turn context.
    var requiresUserAttention: Bool = false
}

/// New row from the CSV that has no matching `__row_id` in the events table.
/// Emitted as `log_entry` events with `source='sheets_edit'` per §1.4 step 4.
struct ManualLogEntry: Codable, Sendable, Equatable {
    let assignedRowID: String
    let cells: [String: String]
}

/// The pair of operations a kind must provide. Track C's `InstrumentKind.renderCSV`
/// and `parseCSVOverride` static funcs map 1-1 onto these closures via
/// `InstrumentCSVCoder(kind:)` once their protocol lands.
struct InstrumentCSVCoder: Sendable {
    /// Render the current state + recent events into a `CSVTable`. The table
    /// MUST include the reserved columns (`__row_id`, `__steward_version`,
    /// `__last_synced_at`) so reconciliation can diff cell-by-cell.
    let render: @Sendable (_ stateJSON: String, _ definitionJSON: String, _ recentEventsJSON: [String]) throws -> CSVTable

    /// Compute corrections + new entries from a user-edited table. Returns
    /// what changed; caller owns event emission + state update.
    let parseOverride: @Sendable (_ table: CSVTable, _ currentStateJSON: String, _ definitionJSON: String) throws -> CSVOverrideResult
}

struct CSVOverrideResult: Sendable, Equatable {
    var corrections: [ManualCorrection]
    var newEntries: [ManualLogEntry]
}

/// Process-wide registry mapping `instruments.kind` strings to a coder. Track
/// C's `@main` boot calls `register(kind:coder:)` for each of the 7 built-in
/// kinds; Track F's `CSVMirrorWatcher` looks them up by the row's `kind`
/// column.
actor InstrumentCSVCoderRegistry {
    static let shared = InstrumentCSVCoderRegistry()

    private var coders: [String: InstrumentCSVCoder] = [:]

    func register(kindID: String, coder: InstrumentCSVCoder) {
        coders[kindID] = coder
    }

    func coder(for kindID: String) -> InstrumentCSVCoder? {
        coders[kindID]
    }

    /// Test seam — wipes registrations between unit tests. Tests register
    /// stub coders per test.
    func reset() {
        coders.removeAll()
    }
}

// MARK: - Stub: RunningAccumulator coder (delete on Track C merge)
//
// Track C will replace this with `InstrumentCSVCoder(kind: RunningAccumulator.self)`
// once `InstrumentKind` and its registry land. We carry a working
// implementation here so Track F's reconciliation tests run end-to-end and so
// the v0.9 build can demo the CSV mirror against the simplest instrument kind.
//
// Schema mirrored: `RunningAccumulator` per spec §6:
//   definition: { unit: String, daily_target?: Double, weekly_target?: Double, capture_prompt: String }
//   state:      { today_total: Double, seven_day_avg: Double, thirty_day_avg: Double, last_event_at: Int? }
// CSV columns (data.csv): __row_id, __steward_version, __last_synced_at, occurred_at, value, notes
// CSV columns (state.csv): metric, value
//

enum StubRunningAccumulatorCoder {
    static let kindID = "running_accumulator"

    static let dataColumns = [
        CSVTable.Reserved.rowID,
        CSVTable.Reserved.stewardVersion,
        CSVTable.Reserved.lastSyncedAt,
        "occurred_at",
        "value",
        "notes"
    ]

    static let stateColumns = ["metric", "value"]

    static func make() -> InstrumentCSVCoder {
        InstrumentCSVCoder(
            render: { stateJSON, _, recentEventsJSON in
                // Recent events come in as JSON strings shaped like:
                //   { "event_id": ..., "occurred_at": <unix-ms>, "value": Double, "notes": String? }
                let decoder = JSONDecoder()
                var rows: [CSVTable.Row] = []
                for jsonString in recentEventsJSON {
                    guard let data = jsonString.data(using: .utf8) else { continue }
                    let evt = try decoder.decode(StubRunningEvent.self, from: data)
                    rows.append(CSVTable.Row(cells: [
                        evt.event_id,
                        String(evt.steward_version ?? 1),
                        String(evt.last_synced_at ?? Int64(Date().timeIntervalSince1970 * 1000)),
                        String(evt.occurred_at),
                        String(evt.value),
                        evt.notes ?? ""
                    ]))
                }
                _ = stateJSON // unused for data.csv body
                return CSVTable(header: dataColumns, rows: rows)
            },
            parseOverride: { table, currentStateJSON, _ in
                _ = currentStateJSON
                guard table.header.contains(CSVTable.Reserved.rowID) else {
                    throw CSVTableError.missingRequiredColumn(CSVTable.Reserved.rowID)
                }
                // For the stub, we report every value/notes cell change as a
                // correction; new rows (no row_id) become log entries.
                let (keyed, unkeyed) = table.partitionedByRowID()
                var corrections: [ManualCorrection] = []
                for (rowID, row) in keyed {
                    for col in ["value", "notes"] {
                        if let newValue = row.value(forColumn: col, in: table.header) {
                            corrections.append(ManualCorrection(
                                rowID: rowID,
                                columnName: col,
                                oldValue: nil, // resolved by caller against events table
                                newValue: newValue
                            ))
                        }
                    }
                }
                var newEntries: [ManualLogEntry] = []
                for row in unkeyed {
                    var cells: [String: String] = [:]
                    for (i, name) in table.header.enumerated() where !CSVTable.Reserved.all.contains(name) {
                        guard i < row.cells.count else { continue }
                        cells[name] = row.cells[i]
                    }
                    newEntries.append(ManualLogEntry(
                        assignedRowID: ULIDFactory.make(),
                        cells: cells
                    ))
                }
                return CSVOverrideResult(corrections: corrections, newEntries: newEntries)
            }
        )
    }

    private struct StubRunningEvent: Decodable {
        let event_id: String
        let occurred_at: Int64
        let value: Double
        let notes: String?
        let steward_version: Int?
        let last_synced_at: Int64?
    }

    /// State.csv body for the stub: a 2-column metric/value pair.
    static func renderStateCSV(stateJSON: String) throws -> CSVTable {
        struct State: Decodable {
            let today_total: Double?
            let seven_day_avg: Double?
            let thirty_day_avg: Double?
            let last_event_at: Int64?
        }
        guard let data = stateJSON.data(using: .utf8) else {
            return CSVTable(header: stateColumns, rows: [])
        }
        let s = (try? JSONDecoder().decode(State.self, from: data)) ?? .init(
            today_total: nil, seven_day_avg: nil, thirty_day_avg: nil, last_event_at: nil
        )
        let rows: [CSVTable.Row] = [
            CSVTable.Row(cells: ["today_total", s.today_total.map { String($0) } ?? ""]),
            CSVTable.Row(cells: ["seven_day_avg", s.seven_day_avg.map { String($0) } ?? ""]),
            CSVTable.Row(cells: ["thirty_day_avg", s.thirty_day_avg.map { String($0) } ?? ""]),
            CSVTable.Row(cells: ["last_event_at", s.last_event_at.map { String($0) } ?? ""])
        ]
        return CSVTable(header: stateColumns, rows: rows)
    }
}

/// Tiny ULID factory; replace with Track A's shared one if it lands first.
/// Format: Crockford-base32-ish but we use uppercase hex of timestamp + random,
/// which sorts lexicographically and is unique-enough for single-user CSV row
/// keys. Not cryptographic.
enum ULIDFactory {
    static func make(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        let randHi = UInt32.random(in: .min ... .max)
        let randLo = UInt32.random(in: .min ... .max)
        return String(format: "%012llX%08X%08X", ms, randHi, randLo)
    }
}
