//
//  SheetDetailViewModel.swift
//  Steward
//
//  Loads one sheet (header + columns + rows) and exposes the rows as a
//  list of column-ordered values so SwiftUI can render the grid without
//  random dictionary lookups in the body.
//

import Foundation

@MainActor
final class SheetDetailViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    struct DisplayCell: Identifiable, Equatable {
        let id: String          // "<rowID>:<columnName>"
        let columnName: String
        let displayValue: String
    }

    struct DisplayRow: Identifiable, Equatable {
        let id: String          // rowID.rawValue
        let createdAt: Date
        let cells: [DisplayCell]
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var sheet: Sheet?
    @Published private(set) var columns: [SheetColumn] = []
    @Published private(set) var rows: [DisplayRow] = []

    let sheetID: SheetID
    private let provider: DatabaseProvider

    init(sheetID: SheetID, provider: DatabaseProvider = .shared) {
        self.sheetID = sheetID
        self.provider = provider
    }

    func load() async {
        state = .loading
        do {
            let db = try await provider.database()
            let sheetIDValue = self.sheetID
            let (loadedSheet, loadedColumns, loadedRows) =
                try await db.read { dbase -> (Sheet?, [SheetColumn], [SheetRow]) in
                let s = try WorkbookStore.loadSheet(sheetID: sheetIDValue, in: dbase)
                let c = try WorkbookStore.listColumns(sheetID: sheetIDValue, in: dbase)
                let r = try WorkbookStore.listRows(sheetID: sheetIDValue, in: dbase)
                return (s, c, r)
            }
            self.sheet = loadedSheet
            self.columns = loadedColumns
            self.rows = loadedRows.map { row in
                let cells = loadedColumns.map { column in
                    DisplayCell(
                        id: "\(row.rowID.rawValue):\(column.name)",
                        columnName: column.name,
                        displayValue: Self.formatCell(
                            row.cells[column.name] ?? .null,
                            kind: column.kind,
                            unit: column.unit
                        )
                    )
                }
                return DisplayRow(
                    id: row.rowID.rawValue,
                    createdAt: row.createdAt,
                    cells: cells
                )
            }
            self.state = .loaded
        } catch {
            self.state = .failed(message: String(describing: error))
        }
    }

    /// Render a cell value to a short display string. Currency renders as
    /// "$N.NN" assuming integer cents; duration renders as "Nh Mm" when
    /// numeric; everything else is a best-effort cast.
    /// `nonisolated` so tests can call without hopping to the main actor.
    nonisolated static func formatCell(_ value: CellValue, kind: SheetColumnKind, unit: String?) -> String {
        switch (kind, value) {
        case (_, .null):
            return ""
        case (.text, .string(let s)):
            return s
        case (.number, .number(let n)):
            if let unit { return "\(formatNumber(n)) \(unit)" }
            return formatNumber(n)
        case (.date, .string(let s)):
            return s
        case (.duration, .number(let n)):
            let totalMinutes = Int(n.rounded())
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours == 0 { return "\(minutes)m" }
            if minutes == 0 { return "\(hours)h" }
            return "\(hours)h \(minutes)m"
        case (.currency, .number(let cents)):
            let dollars = cents / 100
            return String(format: "$%.2f", dollars)
        case (.bool, .bool(let b)):
            return b ? "yes" : "no"
        default:
            // Defensive: catch-all so unexpected pairings render *something*
            // rather than disappear.
            switch value {
            case .null: return ""
            case .bool(let b): return b ? "yes" : "no"
            case .number(let n): return formatNumber(n)
            case .string(let s): return s
            }
        }
    }

    nonisolated private static func formatNumber(_ n: Double) -> String {
        if n.rounded() == n { return String(Int(n)) }
        return String(format: "%.2f", n)
    }
}
