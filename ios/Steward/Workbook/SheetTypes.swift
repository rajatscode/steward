//
//  SheetTypes.swift
//  Steward
//
//  The workbook substrate. A "sheet" is the agent's playground — a
//  freeform typed table the agent owns end-to-end: it decides what
//  columns exist, what kinds those columns are, and what rows fill
//  them. Replaces the rigid seven-instrument-kind protocol for the
//  rework.
//
//  Mental model:
//    Workbook  = the user's whole life-tracking surface
//    Sheet     = one named table inside the workbook
//    Column    = a typed field on a sheet (text/number/date/...)
//    Row       = one record in a sheet; cells keyed by column name
//
//  This file defines the model types. Persistence lives in
//  `WorkbookStore`. Tool surface lives in `Tools/Catalog/SheetTools`.
//

import Foundation

// MARK: - Identifiers (newtype'd strings)

struct SheetID: Sendable, Codable, Equatable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ raw: String) { self.rawValue = raw }
}

struct SheetColumnID: Sendable, Codable, Equatable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ raw: String) { self.rawValue = raw }
}

struct SheetRowID: Sendable, Codable, Equatable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ raw: String) { self.rawValue = raw }
}

// MARK: - Column kinds

/// The typed shape of a column. Picked by the agent at create time.
/// Each kind defines how cell values are stored and validated.
enum SheetColumnKind: String, Sendable, Codable, CaseIterable {
    case text
    case number
    case date         // ISO-8601 string in storage
    case duration     // integer minutes
    case currency     // integer cents (USD-only for now)
    case bool
}

extension SheetColumnKind {
    /// Validate and normalize a free `CellValue` against this column kind.
    /// Returns the canonical storage form, or throws if the value doesn't fit.
    func normalize(_ value: CellValue) throws -> CellValue {
        switch (self, value) {
        case (.text, .string), (.text, .null): return value
        case (.text, .number(let n)): return .string(String(describing: n))
        case (.text, .bool(let b)):   return .string(String(b))
        case (.number, .number), (.number, .null): return value
        case (.number, .string(let s)):
            guard let d = Double(s) else { throw SheetValidationError.cellTypeMismatch(expected: .number, got: value) }
            return .number(d)
        case (.date, .string):
            // Accept any ISO-8601-ish string the agent sends — the model is
            // expected to format dates as ISO strings, but we don't reject
            // best-effort variants since the surface is single-user.
            return value
        case (.date, .null): return .null
        case (.duration, .number(let n)) where n.rounded() == n: return .number(n)
        case (.duration, .null): return .null
        case (.currency, .number(let n)) where n.rounded() == n: return .number(n)
        case (.currency, .null): return .null
        case (.bool, .bool), (.bool, .null): return value
        default:
            throw SheetValidationError.cellTypeMismatch(expected: self, got: value)
        }
    }
}

// MARK: - Cell values

/// A scalar cell value in a sheet row. The union is narrow on purpose —
/// the agent isn't expected to nest objects inside cells; if that's
/// needed, add a sheet.
enum CellValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
}

extension CellValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "CellValue: unknown token")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

// MARK: - Records

struct SheetColumn: Sendable, Codable, Equatable {
    let columnID: SheetColumnID
    let sheetID: SheetID
    let name: String
    let kind: SheetColumnKind
    let unit: String?
    let ordinal: Int
    let archivedAt: Date?
}

struct SheetRow: Sendable, Codable, Equatable {
    let rowID: SheetRowID
    let sheetID: SheetID
    let createdAt: Date
    let archivedAt: Date?
    /// Cells keyed by column name. Value validation happens at write time;
    /// reads return whatever was stored.
    let cells: [String: CellValue]
}

struct Sheet: Sendable, Codable, Equatable {
    let sheetID: SheetID
    let displayName: String
    let description: String?
    let createdAt: Date
    let archivedAt: Date?
}

// MARK: - Errors

enum SheetValidationError: Error, CustomStringConvertible, Equatable {
    case sheetNotFound(SheetID)
    case columnNotFound(sheetID: SheetID, name: String)
    case rowNotFound(SheetRowID)
    case duplicateColumnName(sheetID: SheetID, name: String)
    case emptyDisplayName
    case emptyColumnName
    case cellTypeMismatch(expected: SheetColumnKind, got: CellValue)
    case archived(SheetID)

    var description: String {
        switch self {
        case .sheetNotFound(let id):
            return "Sheet \(id.rawValue) not found"
        case .columnNotFound(let sheetID, let name):
            return "Sheet \(sheetID.rawValue) has no column named '\(name)'"
        case .rowNotFound(let id):
            return "Sheet row \(id.rawValue) not found"
        case .duplicateColumnName(let sheetID, let name):
            return "Sheet \(sheetID.rawValue) already has a column named '\(name)'"
        case .emptyDisplayName:
            return "Sheet display name must not be empty"
        case .emptyColumnName:
            return "Sheet column name must not be empty"
        case .cellTypeMismatch(let expected, let got):
            return "Cell type mismatch: expected \(expected.rawValue), got \(got)"
        case .archived(let id):
            return "Sheet \(id.rawValue) is archived; unarchive before mutating"
        }
    }
}
