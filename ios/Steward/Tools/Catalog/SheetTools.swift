//
//  SheetTools.swift
//  Steward
//
//  The agent's sheet surface — seven tools the coordinator uses to
//  shape and maintain the workbook end-to-end:
//
//    sheet.create        — spawn a new sheet (name + initial columns)
//    sheet.list          — enumerate sheets in the workbook
//    sheet.read          — load columns + rows for one sheet
//    sheet.add_column    — extend a sheet's schema with a typed column
//    sheet.add_row       — log a record into a sheet
//    sheet.update_cell   — edit one cell on one row
//    sheet.archive       — hide a sheet (kept in DB for audit / undo)
//
//  Each mutating tool emits a paired audit event so undo and the audit
//  log work the same way they do for the rest of the tool surface.
//
//  Sheets are intentionally untyped at the storage layer (cells live as
//  JSON keyed by column name). Validation is column-kind-aware on write
//  via SheetColumnKind.normalize so the agent can't corrupt rows by
//  inserting a string into a number column.
//

import Foundation
import GRDB

// MARK: - sheet.create

struct SheetCreateColumnSpec: Codable, Equatable, Sendable {
    let name: String
    let kind: SheetColumnKind
    let unit: String?
}

struct SheetCreateArgs: Codable, Equatable, Sendable {
    let displayName: String
    let description: String?
    let columns: [SheetCreateColumnSpec]
    /// Required for audit log (hard reject #11).
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case description
        case columns
        case reasoning
        case actor
    }
}

struct SheetCreateResult: Codable, Equatable, Sendable {
    let sheetID: SheetID
    let columnIDs: [SheetColumnID]

    enum CodingKeys: String, CodingKey {
        case sheetID    = "sheet_id"
        case columnIDs  = "column_ids"
    }
}

struct SheetCreateTool: LLMTool {
    let id: String = ToolID.sheetCreate.rawValue
    let description: String = """
    Create a new sheet in the workbook with an initial column schema. \
    Use this when the user names a new area to track. Column kinds: \
    text | number | date | duration | currency | bool.
    """
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["display_name", "columns", "reasoning", "actor"],
      "properties": {
        "display_name": {"type": "string"},
        "description":  {"type": ["string", "null"]},
        "columns": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["name", "kind"],
            "properties": {
              "name": {"type": "string"},
              "kind": {"type": "string", "enum": ["text", "number", "date", "duration", "currency", "bool"]},
              "unit": {"type": ["string", "null"]}
            }
          }
        },
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(SheetCreateArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let sheetID = SheetID(rawValue: ULID.generate(now: timestamp))
        var columnIDs: [SheetColumnID] = []
        let db = try await provider.database()
        try await db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID,
                displayName: args.displayName,
                description: args.description,
                createdAt: timestamp,
                in: dbase
            )
            for (i, spec) in args.columns.enumerated() {
                let columnID = SheetColumnID(rawValue: ULID.generate(now: timestamp))
                try WorkbookStore.insertColumn(
                    columnID: columnID,
                    sheetID: sheetID,
                    name: spec.name,
                    kind: spec.kind,
                    unit: spec.unit,
                    ordinal: i,
                    in: dbase
                )
                columnIDs.append(columnID)
            }
            struct Payload: Encodable {
                let sheetID: String
                let displayName: String
                let columns: [SheetCreateColumnSpec]
            }
            try EventLog.append(
                actor: actor,
                kind: "sheet_create",
                payload: Payload(
                    sheetID: sheetID.rawValue,
                    displayName: args.displayName,
                    columns: args.columns
                ),
                text: args.displayName,
                domain: nil,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(SheetCreateResult(sheetID: sheetID, columnIDs: columnIDs))
    }
}

// MARK: - sheet.list

struct SheetListArgs: Codable, Equatable, Sendable {
    let includeArchived: Bool?
    enum CodingKeys: String, CodingKey { case includeArchived = "include_archived" }
}

struct SheetListItem: Codable, Equatable, Sendable {
    let sheetID: SheetID
    let displayName: String
    let description: String?
    let createdAt: Date
    let archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sheetID = "sheet_id"
        case displayName = "display_name"
        case description
        case createdAt = "created_at"
        case archivedAt = "archived_at"
    }
}

struct SheetListResult: Codable, Equatable, Sendable {
    let sheets: [SheetListItem]
}

struct SheetListTool: LLMTool {
    let id: String = ToolID.sheetList.rawValue
    let description: String = "List sheets in the workbook. Pass include_archived=true to see archived sheets."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "properties": {
        "include_archived": {"type": ["boolean", "null"]}
      }
    }
    """

    let provider: DatabaseProvider
    init(provider: DatabaseProvider = .shared) { self.provider = provider }

    func invoke(argsJSON: String) async throws -> String {
        let args = (try? ToolJSON.decode(SheetListArgs.self, from: argsJSON))
            ?? SheetListArgs(includeArchived: nil)
        let db = try await provider.database()
        let sheets = try await db.read { dbase in
            try WorkbookStore.listSheets(includeArchived: args.includeArchived ?? false, in: dbase)
        }
        let items = sheets.map {
            SheetListItem(
                sheetID: $0.sheetID,
                displayName: $0.displayName,
                description: $0.description,
                createdAt: $0.createdAt,
                archivedAt: $0.archivedAt
            )
        }
        return try ToolJSON.encode(SheetListResult(sheets: items))
    }
}

// MARK: - sheet.read

struct SheetReadArgs: Codable, Equatable, Sendable {
    let sheetID: SheetID
    enum CodingKeys: String, CodingKey { case sheetID = "sheet_id" }
}

struct SheetReadColumn: Codable, Equatable, Sendable {
    let columnID: SheetColumnID
    let name: String
    let kind: SheetColumnKind
    let unit: String?
    let ordinal: Int

    enum CodingKeys: String, CodingKey {
        case columnID = "column_id"
        case name, kind, unit, ordinal
    }
}

struct SheetReadRow: Codable, Equatable, Sendable {
    let rowID: SheetRowID
    let createdAt: Date
    let cells: [String: CellValue]

    enum CodingKeys: String, CodingKey {
        case rowID = "row_id"
        case createdAt = "created_at"
        case cells
    }
}

struct SheetReadResult: Codable, Equatable, Sendable {
    let sheet: SheetListItem
    let columns: [SheetReadColumn]
    let rows: [SheetReadRow]
}

struct SheetReadTool: LLMTool {
    let id: String = ToolID.sheetRead.rawValue
    let description: String = "Read all columns and active rows for a sheet by sheet_id."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["sheet_id"],
      "properties": { "sheet_id": {"type": "string"} }
    }
    """

    let provider: DatabaseProvider
    init(provider: DatabaseProvider = .shared) { self.provider = provider }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(SheetReadArgs.self, from: argsJSON)
        let db = try await provider.database()
        let (maybeSheet, columns, rows): (Sheet?, [SheetColumn], [SheetRow]) = try await db.read { dbase in
            let sheet = try WorkbookStore.loadSheet(sheetID: args.sheetID, in: dbase)
            let columns = try WorkbookStore.listColumns(sheetID: args.sheetID, in: dbase)
            let rows = try WorkbookStore.listRows(sheetID: args.sheetID, in: dbase)
            return (sheet, columns, rows)
        }
        guard let sheet = maybeSheet else {
            throw SheetValidationError.sheetNotFound(args.sheetID)
        }
        return try ToolJSON.encode(SheetReadResult(
            sheet: SheetListItem(
                sheetID: sheet.sheetID,
                displayName: sheet.displayName,
                description: sheet.description,
                createdAt: sheet.createdAt,
                archivedAt: sheet.archivedAt
            ),
            columns: columns.map {
                SheetReadColumn(
                    columnID: $0.columnID,
                    name: $0.name,
                    kind: $0.kind,
                    unit: $0.unit,
                    ordinal: $0.ordinal
                )
            },
            rows: rows.map {
                SheetReadRow(rowID: $0.rowID, createdAt: $0.createdAt, cells: $0.cells)
            }
        ))
    }
}

// MARK: - sheet.add_column

struct SheetAddColumnArgs: Codable, Equatable, Sendable {
    let sheetID: SheetID
    let name: String
    let kind: SheetColumnKind
    let unit: String?
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case sheetID = "sheet_id"
        case name, kind, unit, reasoning, actor
    }
}

struct SheetAddColumnResult: Codable, Equatable, Sendable {
    let columnID: SheetColumnID
    enum CodingKeys: String, CodingKey { case columnID = "column_id" }
}

struct SheetAddColumnTool: LLMTool {
    let id: String = ToolID.sheetAddColumn.rawValue
    let description: String = "Extend a sheet's schema with a new column."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["sheet_id", "name", "kind", "reasoning", "actor"],
      "properties": {
        "sheet_id": {"type": "string"},
        "name":     {"type": "string"},
        "kind":     {"type": "string", "enum": ["text", "number", "date", "duration", "currency", "bool"]},
        "unit":     {"type": ["string", "null"]},
        "reasoning":{"type": "string"},
        "actor":    {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(SheetAddColumnArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let columnID = SheetColumnID(rawValue: ULID.generate(now: timestamp))
        let db = try await provider.database()
        try await db.write { dbase in
            let ordinal = try WorkbookStore.nextColumnOrdinal(sheetID: args.sheetID, in: dbase)
            try WorkbookStore.insertColumn(
                columnID: columnID,
                sheetID: args.sheetID,
                name: args.name,
                kind: args.kind,
                unit: args.unit,
                ordinal: ordinal,
                in: dbase
            )
            struct Payload: Encodable {
                let sheetID: String
                let columnID: String
                let name: String
                let kind: String
                let unit: String?
            }
            try EventLog.append(
                actor: actor,
                kind: "sheet_add_column",
                payload: Payload(
                    sheetID: args.sheetID.rawValue,
                    columnID: columnID.rawValue,
                    name: args.name,
                    kind: args.kind.rawValue,
                    unit: args.unit
                ),
                text: args.name,
                domain: nil,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(SheetAddColumnResult(columnID: columnID))
    }
}

// MARK: - sheet.add_row

struct SheetAddRowArgs: Codable, Equatable, Sendable {
    let sheetID: SheetID
    let cells: [String: CellValue]
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case sheetID = "sheet_id"
        case cells, reasoning, actor
    }
}

struct SheetAddRowResult: Codable, Equatable, Sendable {
    let rowID: SheetRowID
    enum CodingKeys: String, CodingKey { case rowID = "row_id" }
}

struct SheetAddRowTool: LLMTool {
    let id: String = ToolID.sheetAddRow.rawValue
    let description: String = "Add a row to a sheet. Cells is a {column_name: value} object; values must match column kinds."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["sheet_id", "cells", "reasoning", "actor"],
      "properties": {
        "sheet_id": {"type": "string"},
        "cells":    {"type": "object"},
        "reasoning":{"type": "string"},
        "actor":    {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(SheetAddRowArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let rowID = SheetRowID(rawValue: ULID.generate(now: timestamp))
        let db = try await provider.database()
        try await db.write { dbase in
            try WorkbookStore.insertRow(
                rowID: rowID,
                sheetID: args.sheetID,
                cells: args.cells,
                createdAt: timestamp,
                in: dbase
            )
            struct Payload: Encodable {
                let sheetID: String
                let rowID: String
                let cellsJSON: String
            }
            try EventLog.append(
                actor: actor,
                kind: "sheet_add_row",
                payload: Payload(
                    sheetID: args.sheetID.rawValue,
                    rowID: rowID.rawValue,
                    cellsJSON: WorkbookStore.encodeCells(args.cells)
                ),
                text: nil,
                domain: nil,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(SheetAddRowResult(rowID: rowID))
    }
}

// MARK: - sheet.update_cell

struct SheetUpdateCellArgs: Codable, Equatable, Sendable {
    let rowID: SheetRowID
    let columnName: String
    let value: CellValue
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case rowID = "row_id"
        case columnName = "column_name"
        case value, reasoning, actor
    }
}

struct SheetUpdateCellResult: Codable, Equatable, Sendable {
    let ok: Bool
}

struct SheetUpdateCellTool: LLMTool {
    let id: String = ToolID.sheetUpdateCell.rawValue
    let description: String = "Update one cell on one row. Value must match the column kind."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["row_id", "column_name", "value", "reasoning", "actor"],
      "properties": {
        "row_id":      {"type": "string"},
        "column_name": {"type": "string"},
        "value":       {},
        "reasoning":   {"type": "string"},
        "actor":       {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(SheetUpdateCellArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        try await db.write { dbase in
            try WorkbookStore.updateCell(
                rowID: args.rowID,
                columnName: args.columnName,
                value: args.value,
                in: dbase
            )
            struct Payload: Encodable {
                let rowID: String
                let columnName: String
                let valueJSON: String
            }
            let valueJSON = (try? ToolJSON.encode(args.value)) ?? "null"
            try EventLog.append(
                actor: actor,
                kind: "sheet_update_cell",
                payload: Payload(
                    rowID: args.rowID.rawValue,
                    columnName: args.columnName,
                    valueJSON: valueJSON
                ),
                text: nil,
                domain: nil,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(SheetUpdateCellResult(ok: true))
    }
}

// MARK: - sheet.archive

struct SheetArchiveArgs: Codable, Equatable, Sendable {
    let sheetID: SheetID
    let reason: String
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case sheetID = "sheet_id"
        case reason, reasoning, actor
    }
}

struct SheetArchiveResult: Codable, Equatable, Sendable {
    let ok: Bool
}

struct SheetArchiveTool: LLMTool {
    let id: String = ToolID.sheetArchive.rawValue
    let description: String = "Archive a sheet (hidden from listings, kept in DB). Pass `reason` so the audit log explains why."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["sheet_id", "reason", "reasoning", "actor"],
      "properties": {
        "sheet_id":  {"type": "string"},
        "reason":    {"type": "string"},
        "reasoning": {"type": "string"},
        "actor":     {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(SheetArchiveArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        try await db.write { dbase in
            try WorkbookStore.archiveSheet(sheetID: args.sheetID, at: timestamp, in: dbase)
            struct Payload: Encodable {
                let sheetID: String
                let reason: String
            }
            try EventLog.append(
                actor: actor,
                kind: "sheet_archive",
                payload: Payload(sheetID: args.sheetID.rawValue, reason: args.reason),
                text: args.reason,
                domain: nil,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(SheetArchiveResult(ok: true))
    }
}
