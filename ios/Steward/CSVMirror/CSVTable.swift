//
//  CSVTable.swift
//  Steward — Track F
//
//  Value type representing a parsed CSV table. Lives outside any framework so
//  Track C's `InstrumentKind.renderCSV` and `parseCSVOverride` (addendum §1.2)
//  can return/accept it without pulling in Apple's `TabularData` symbols at
//  protocol-conformance time.
//
//  Parsing/serialization uses `TabularData.DataFrame(contentsOfCSVFile:)` in
//  `CSVTable+TabularData.swift` when iOS 16+ is available; the value type
//  itself is plain Swift so unit tests can build tables in memory.
//

import Foundation

/// In-memory representation of a CSV file. Rows are ordered; cell access is by
/// header name (case-sensitive — Numbers preserves header case verbatim).
///
/// Reserved header columns prefixed with `__` are owned by Steward:
/// - `__row_id`             ULID; stable across user edits (addendum §1.4)
/// - `__steward_version`    integer; bumped when Steward rewrites the row
/// - `__last_synced_at`     unix-ms; last write from Steward
struct CSVTable: Equatable, Sendable {
    /// Reserved column names. `parseCSVOverride` consumers must skip these
    /// when looking for user-meaningful cells.
    enum Reserved {
        static let rowID = "__row_id"
        static let stewardVersion = "__steward_version"
        static let lastSyncedAt = "__last_synced_at"

        static let all: Set<String> = [rowID, stewardVersion, lastSyncedAt]
    }

    var header: [String]
    var rows: [Row]

    struct Row: Equatable, Sendable {
        /// `cells[i]` is the value for `header[i]`.
        var cells: [String]

        func value(forColumn name: String, in header: [String]) -> String? {
            guard let idx = header.firstIndex(of: name), idx < cells.count else { return nil }
            return cells[idx]
        }
    }

    init(header: [String], rows: [Row]) {
        self.header = header
        self.rows = rows
    }

    /// Returns rows keyed by the reserved `__row_id` column. Rows missing the
    /// column are returned as `unkeyed`.
    func partitionedByRowID() -> (keyed: [String: Row], unkeyed: [Row]) {
        guard let idx = header.firstIndex(of: Reserved.rowID) else {
            return ([:], rows)
        }
        var keyed: [String: Row] = [:]
        var unkeyed: [Row] = []
        for row in rows {
            guard idx < row.cells.count else {
                unkeyed.append(row)
                continue
            }
            let id = row.cells[idx]
            if id.isEmpty {
                unkeyed.append(row)
            } else {
                keyed[id] = row
            }
        }
        return (keyed, unkeyed)
    }
}

// MARK: - RFC 4180-ish serialization
//
// We intentionally hand-roll a small RFC 4180 parser/serializer:
// - Numbers + Excel + Sheets all read/write quoted strings with `""` doubling
//   for embedded quotes; line endings are CRLF in their output but we also
//   accept LF (TabularData accepts both as of iOS 16).
// - We avoid TabularData here so the value type works in pure-Swift unit tests
//   that don't link UIKit (CI on Linux later, if it happens).
// - The `TabularData` round-trip is still used in CSVMirrorWatcher for actual
//   file I/O on device, where it's the recommended Apple API per spec §4.

extension CSVTable {

    /// Serialize to CSV text. Always CRLF line endings (RFC 4180 §2).
    func serialize() -> String {
        var out = ""
        out.append(Self.escapeRow(header))
        out.append("\r\n")
        for row in rows {
            out.append(Self.escapeRow(row.cells))
            out.append("\r\n")
        }
        return out
    }

    /// Parse CSV text into a `CSVTable`. Throws `CSVTableError.empty` for an
    /// empty document (a real CSV must have at least a header row).
    ///
    /// Line endings are normalized to `\n` before parsing. This is necessary
    /// because Swift's `String.Character` iteration treats `\r\n` as a single
    /// grapheme cluster — so a switch on `Character` literal `"\r"` never
    /// matches when the input came from a CRLF source (Numbers, Excel,
    /// Steward's own writer). The normalized parser then handles `\n` as the
    /// sole row terminator. Embedded line breaks inside quoted cells survive
    /// as `\n` (we accept the loss of CRLF fidelity inside quoted strings —
    /// Numbers / Excel / Sheets don't depend on it).
    static func parse(_ text: String) throws -> CSVTable {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rows = parseRowsLF(normalized)
        guard let head = rows.first else {
            throw CSVTableError.empty
        }
        let body = rows.dropFirst().map { Row(cells: $0) }
        // Filter trailing empty rows (final newline after last record).
        let trimmedBody = body.reversed().drop(while: { $0.cells.allSatisfy(\.isEmpty) }).reversed()
        return CSVTable(header: head, rows: Array(trimmedBody))
    }

    private static func escapeRow(_ cells: [String]) -> String {
        cells.map(Self.escapeCell).joined(separator: ",")
    }

    private static func escapeCell(_ cell: String) -> String {
        let needsQuote = cell.contains(",") || cell.contains("\"") || cell.contains("\n") || cell.contains("\r")
        if needsQuote {
            let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return cell
    }

    /// Parser variant assuming input has already been normalized so the only
    /// row terminator is `\n` (see `parse(_:)`). We iterate over
    /// `unicodeScalars` rather than `Character` because Swift's grapheme
    /// clustering would otherwise merge consecutive CR/LF into a single
    /// Character that doesn't match any of our `\n` / `,` / `"` cases.
    private static func parseRowsLF(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var cell = ""
        var inQuotes = false

        let scalars = Array(text.unicodeScalars)
        var i = 0
        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let newline: Unicode.Scalar = "\n"

        func endCell() {
            current.append(cell)
            cell = ""
        }
        func endRow() {
            endCell()
            rows.append(current)
            current = []
        }

        while i < scalars.count {
            let s = scalars[i]
            if inQuotes {
                if s == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        cell.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    cell.unicodeScalars.append(s)
                    i += 1
                    continue
                }
            } else {
                if s == quote {
                    inQuotes = true
                    i += 1
                } else if s == comma {
                    endCell()
                    i += 1
                } else if s == newline {
                    endRow()
                    i += 1
                } else {
                    cell.unicodeScalars.append(s)
                    i += 1
                }
            }
        }
        // Flush trailing cell/row if text didn't end with newline.
        if !cell.isEmpty || !current.isEmpty {
            endRow()
        }
        return rows
    }
}

enum CSVTableError: Error, CustomStringConvertible {
    case empty
    case missingRequiredColumn(String)
    case fileReadFailed(URL, underlying: Error)
    case fileWriteFailed(URL, underlying: Error)

    var description: String {
        switch self {
        case .empty:
            return "CSV document has no rows (header required)"
        case .missingRequiredColumn(let name):
            return "CSV table missing required column: \(name)"
        case .fileReadFailed(let url, let err):
            return "Failed to read CSV at \(url.lastPathComponent): \(err)"
        case .fileWriteFailed(let url, let err):
            return "Failed to write CSV at \(url.lastPathComponent): \(err)"
        }
    }
}
