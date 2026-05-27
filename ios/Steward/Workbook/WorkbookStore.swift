//
//  WorkbookStore.swift
//  Steward
//
//  GRDB query layer for the workbook substrate. Pure data plumbing —
//  the SheetTools wrap these with audit-log + event emission. Kept
//  separate so unit tests can exercise the storage layer against a
//  fresh in-memory DB without standing up the full tool surface.
//

import Foundation
import GRDB

enum WorkbookStore {

    // MARK: - Sheets

    static func insertSheet(
        sheetID: SheetID,
        displayName: String,
        description: String?,
        createdAt: Date,
        in db: Database
    ) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SheetValidationError.emptyDisplayName }
        try db.execute(
            sql: """
                INSERT INTO sheets (sheet_id, display_name, description, created_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [
                sheetID.rawValue,
                trimmed,
                description,
                Int(createdAt.timeIntervalSince1970),
            ]
        )
    }

    static func loadSheet(sheetID: SheetID, in db: Database) throws -> Sheet? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM sheets WHERE sheet_id = ?",
            arguments: [sheetID.rawValue]
        )
        return row.map(decodeSheet)
    }

    static func listSheets(includeArchived: Bool, in db: Database) throws -> [Sheet] {
        let sql = includeArchived
            ? "SELECT * FROM sheets ORDER BY created_at ASC"
            : "SELECT * FROM sheets WHERE archived_at IS NULL ORDER BY created_at ASC"
        return try Row.fetchAll(db, sql: sql).map(decodeSheet)
    }

    static func archiveSheet(sheetID: SheetID, at: Date, in db: Database) throws {
        guard try loadSheet(sheetID: sheetID, in: db) != nil else {
            throw SheetValidationError.sheetNotFound(sheetID)
        }
        try db.execute(
            sql: "UPDATE sheets SET archived_at = ? WHERE sheet_id = ?",
            arguments: [Int(at.timeIntervalSince1970), sheetID.rawValue]
        )
    }

    // MARK: - Columns

    static func insertColumn(
        columnID: SheetColumnID,
        sheetID: SheetID,
        name: String,
        kind: SheetColumnKind,
        unit: String?,
        ordinal: Int,
        in db: Database
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SheetValidationError.emptyColumnName }
        guard try loadSheet(sheetID: sheetID, in: db) != nil else {
            throw SheetValidationError.sheetNotFound(sheetID)
        }
        do {
            try db.execute(
                sql: """
                    INSERT INTO sheet_columns
                      (column_id, sheet_id, name, kind, unit, ordinal)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    columnID.rawValue,
                    sheetID.rawValue,
                    trimmed,
                    kind.rawValue,
                    unit,
                    ordinal,
                ]
            )
        } catch let dbError as DatabaseError where dbError.resultCode == .SQLITE_CONSTRAINT {
            throw SheetValidationError.duplicateColumnName(sheetID: sheetID, name: trimmed)
        }
    }

    static func listColumns(sheetID: SheetID, in db: Database) throws -> [SheetColumn] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM sheet_columns
                WHERE sheet_id = ? AND archived_at IS NULL
                ORDER BY ordinal ASC
            """,
            arguments: [sheetID.rawValue]
        )
        return rows.compactMap(decodeColumn)
    }

    /// Returns the next ordinal to assign for a new column on this sheet.
    static func nextColumnOrdinal(sheetID: SheetID, in db: Database) throws -> Int {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COALESCE(MAX(ordinal), -1) AS max_ord
                FROM sheet_columns
                WHERE sheet_id = ?
            """,
            arguments: [sheetID.rawValue]
        )
        return (row?["max_ord"] as Int? ?? -1) + 1
    }

    // MARK: - Rows

    static func insertRow(
        rowID: SheetRowID,
        sheetID: SheetID,
        cells: [String: CellValue],
        createdAt: Date,
        in db: Database
    ) throws {
        let columns = try listColumns(sheetID: sheetID, in: db)
        guard !columns.isEmpty || cells.isEmpty else {
            // A sheet with no columns gets rows with no cells — fine.
            try writeRow(rowID: rowID, sheetID: sheetID, cells: [:], createdAt: createdAt, in: db)
            return
        }
        let normalized = try normalize(cells: cells, against: columns, sheetID: sheetID)
        try writeRow(rowID: rowID, sheetID: sheetID, cells: normalized, createdAt: createdAt, in: db)
    }

    static func updateCell(
        rowID: SheetRowID,
        columnName: String,
        value: CellValue,
        in db: Database
    ) throws {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT sheet_id, cells_json, archived_at FROM sheet_rows WHERE row_id = ?",
            arguments: [rowID.rawValue]
        )
        guard let row else { throw SheetValidationError.rowNotFound(rowID) }
        let sheetID = SheetID(rawValue: row["sheet_id"] as String)
        let columns = try listColumns(sheetID: sheetID, in: db)
        guard let column = columns.first(where: { $0.name == columnName }) else {
            throw SheetValidationError.columnNotFound(sheetID: sheetID, name: columnName)
        }
        let normalized = try column.kind.normalize(value)
        var cells = decodeCells(row["cells_json"] as String? ?? "{}")
        cells[columnName] = normalized
        try db.execute(
            sql: "UPDATE sheet_rows SET cells_json = ? WHERE row_id = ?",
            arguments: [encodeCells(cells), rowID.rawValue]
        )
    }

    static func listRows(sheetID: SheetID, in db: Database) throws -> [SheetRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM sheet_rows
                WHERE sheet_id = ? AND archived_at IS NULL
                ORDER BY created_at ASC
            """,
            arguments: [sheetID.rawValue]
        )
        return rows.compactMap(decodeRow)
    }

    // MARK: - Validation

    private static func normalize(
        cells: [String: CellValue],
        against columns: [SheetColumn],
        sheetID: SheetID
    ) throws -> [String: CellValue] {
        var byName: [String: SheetColumn] = [:]
        for column in columns { byName[column.name] = column }
        var out: [String: CellValue] = [:]
        for (name, value) in cells {
            guard let column = byName[name] else {
                throw SheetValidationError.columnNotFound(sheetID: sheetID, name: name)
            }
            out[name] = try column.kind.normalize(value)
        }
        return out
    }

    // MARK: - Encoding helpers

    private static func writeRow(
        rowID: SheetRowID,
        sheetID: SheetID,
        cells: [String: CellValue],
        createdAt: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sheet_rows (row_id, sheet_id, created_at, cells_json)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [
                rowID.rawValue,
                sheetID.rawValue,
                Int(createdAt.timeIntervalSince1970),
                encodeCells(cells),
            ]
        )
    }

    static func encodeCells(_ cells: [String: CellValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cells),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func decodeCells(_ json: String) -> [String: CellValue] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: CellValue].self, from: data) else {
            return [:]
        }
        return decoded
    }

    // MARK: - Row decoders

    private static func decodeSheet(_ row: Row) -> Sheet {
        Sheet(
            sheetID: SheetID(rawValue: row["sheet_id"] as String),
            displayName: row["display_name"] as String,
            description: row["description"] as String?,
            createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int)),
            archivedAt: (row["archived_at"] as Int?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func decodeColumn(_ row: Row) -> SheetColumn? {
        guard let kind = SheetColumnKind(rawValue: row["kind"] as String) else { return nil }
        return SheetColumn(
            columnID: SheetColumnID(rawValue: row["column_id"] as String),
            sheetID: SheetID(rawValue: row["sheet_id"] as String),
            name: row["name"] as String,
            kind: kind,
            unit: row["unit"] as String?,
            ordinal: row["ordinal"] as Int,
            archivedAt: (row["archived_at"] as Int?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func decodeRow(_ row: Row) -> SheetRow {
        SheetRow(
            rowID: SheetRowID(rawValue: row["row_id"] as String),
            sheetID: SheetID(rawValue: row["sheet_id"] as String),
            createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int)),
            archivedAt: (row["archived_at"] as Int?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            cells: decodeCells(row["cells_json"] as String? ?? "{}")
        )
    }
}
