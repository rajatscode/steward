//
//  WorkbookStoreTests.swift
//  StewardTests
//
//  Exercises the GRDB query layer for sheets, columns, rows against
//  a fresh in-memory migrated database. The tool surface is tested
//  separately in SheetToolsTests; this file is pure storage semantics.
//

import XCTest
import GRDB
@testable import Steward

final class WorkbookStoreTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config) // anonymous in-memory
        try Migrations.migrator.migrate(queue)
        return queue
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - sheets

    func test_insertSheet_thenLoad_returnsSameRow() throws {
        let db = try makeDB()
        let id = SheetID(rawValue: "sheet_test")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: id,
                displayName: "Time",
                description: "productive hours",
                createdAt: referenceDate,
                in: dbase
            )
        }
        let loaded = try db.read { try WorkbookStore.loadSheet(sheetID: id, in: $0) }
        XCTAssertEqual(loaded?.sheetID, id)
        XCTAssertEqual(loaded?.displayName, "Time")
        XCTAssertEqual(loaded?.description, "productive hours")
        XCTAssertNil(loaded?.archivedAt)
    }

    func test_insertSheet_emptyDisplayName_throws() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: SheetID(rawValue: "x"),
                displayName: "   ",
                description: nil,
                createdAt: referenceDate,
                in: dbase
            )
        }) { error in
            XCTAssertEqual(error as? SheetValidationError, .emptyDisplayName)
        }
    }

    func test_archiveSheet_excludesFromActiveListing() throws {
        let db = try makeDB()
        let id = SheetID(rawValue: "sheet_archived")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: id,
                displayName: "Money",
                description: nil,
                createdAt: referenceDate,
                in: dbase
            )
        }
        try db.write { dbase in
            try WorkbookStore.archiveSheet(sheetID: id, at: referenceDate.addingTimeInterval(60), in: dbase)
        }
        let active = try db.read { try WorkbookStore.listSheets(includeArchived: false, in: $0) }
        let all = try db.read { try WorkbookStore.listSheets(includeArchived: true, in: $0) }
        XCTAssertEqual(active.count, 0)
        XCTAssertEqual(all.count, 1)
        XCTAssertNotNil(all.first?.archivedAt)
    }

    func test_archiveSheet_missing_throws() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.write { dbase in
            try WorkbookStore.archiveSheet(
                sheetID: SheetID(rawValue: "nonexistent"),
                at: referenceDate,
                in: dbase
            )
        }) { error in
            XCTAssertEqual(error as? SheetValidationError, .sheetNotFound(SheetID(rawValue: "nonexistent")))
        }
    }

    // MARK: - columns

    func test_insertColumn_thenList_returnsInOrdinalOrder() throws {
        let db = try makeDB()
        let sheetID = SheetID(rawValue: "sheet_columns")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID,
                displayName: "Time",
                description: nil,
                createdAt: referenceDate,
                in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c1"),
                sheetID: sheetID,
                name: "minutes",
                kind: .duration,
                unit: "min",
                ordinal: 1,
                in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c0"),
                sheetID: sheetID,
                name: "date",
                kind: .date,
                unit: nil,
                ordinal: 0,
                in: dbase
            )
        }
        let columns = try db.read { try WorkbookStore.listColumns(sheetID: sheetID, in: $0) }
        XCTAssertEqual(columns.map(\.name), ["date", "minutes"])
        XCTAssertEqual(columns.map(\.ordinal), [0, 1])
    }

    func test_insertColumn_duplicateName_throws() throws {
        let db = try makeDB()
        let sheetID = SheetID(rawValue: "sheet_dup")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID,
                displayName: "X",
                description: nil,
                createdAt: referenceDate,
                in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c1"),
                sheetID: sheetID,
                name: "duration",
                kind: .duration,
                unit: nil,
                ordinal: 0,
                in: dbase
            )
        }
        XCTAssertThrowsError(try db.write { dbase in
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c2"),
                sheetID: sheetID,
                name: "duration",
                kind: .number,
                unit: nil,
                ordinal: 1,
                in: dbase
            )
        }) { error in
            XCTAssertEqual(
                error as? SheetValidationError,
                .duplicateColumnName(sheetID: sheetID, name: "duration")
            )
        }
    }

    func test_nextColumnOrdinal_growsMonotonically() throws {
        let db = try makeDB()
        let sheetID = SheetID(rawValue: "sheet_ord")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID,
                displayName: "X",
                description: nil,
                createdAt: referenceDate,
                in: dbase
            )
            XCTAssertEqual(try WorkbookStore.nextColumnOrdinal(sheetID: sheetID, in: dbase), 0)
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c0"),
                sheetID: sheetID,
                name: "a",
                kind: .text,
                unit: nil,
                ordinal: 0,
                in: dbase
            )
            XCTAssertEqual(try WorkbookStore.nextColumnOrdinal(sheetID: sheetID, in: dbase), 1)
        }
    }

    // MARK: - rows

    func test_insertRow_withValidCells_roundTrips() throws {
        let db = try makeDB()
        let sheetID = SheetID(rawValue: "sheet_rows")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID, displayName: "Time", description: nil,
                createdAt: referenceDate, in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c_date"),
                sheetID: sheetID, name: "date", kind: .date, unit: nil, ordinal: 0, in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c_minutes"),
                sheetID: sheetID, name: "minutes", kind: .duration, unit: "min", ordinal: 1, in: dbase
            )
        }
        let rowID = SheetRowID(rawValue: "row_1")
        try db.write { dbase in
            try WorkbookStore.insertRow(
                rowID: rowID,
                sheetID: sheetID,
                cells: [
                    "date": .string("2026-05-26"),
                    "minutes": .number(40),
                ],
                createdAt: referenceDate.addingTimeInterval(10),
                in: dbase
            )
        }
        let rows = try db.read { try WorkbookStore.listRows(sheetID: sheetID, in: $0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].cells["date"], .string("2026-05-26"))
        XCTAssertEqual(rows[0].cells["minutes"], .number(40))
    }

    func test_insertRow_rejectsUnknownColumn() throws {
        let db = try makeDB()
        let sheetID = SheetID(rawValue: "sheet_rows_bad")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID, displayName: "T", description: nil,
                createdAt: referenceDate, in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c"),
                sheetID: sheetID, name: "minutes", kind: .duration, unit: nil, ordinal: 0, in: dbase
            )
        }
        XCTAssertThrowsError(try db.write { dbase in
            try WorkbookStore.insertRow(
                rowID: SheetRowID(rawValue: "r1"),
                sheetID: sheetID,
                cells: ["bogus": .number(1)],
                createdAt: referenceDate,
                in: dbase
            )
        }) { error in
            XCTAssertEqual(
                error as? SheetValidationError,
                .columnNotFound(sheetID: sheetID, name: "bogus")
            )
        }
    }

    func test_insertRow_rejectsTypeMismatch() throws {
        let db = try makeDB()
        let sheetID = SheetID(rawValue: "sheet_rows_typed")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID, displayName: "T", description: nil,
                createdAt: referenceDate, in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c"),
                sheetID: sheetID, name: "flag", kind: .bool, unit: nil, ordinal: 0, in: dbase
            )
        }
        XCTAssertThrowsError(try db.write { dbase in
            try WorkbookStore.insertRow(
                rowID: SheetRowID(rawValue: "r1"),
                sheetID: sheetID,
                cells: ["flag": .number(1)],
                createdAt: referenceDate,
                in: dbase
            )
        })
    }

    func test_updateCell_overwritesValue() throws {
        let db = try makeDB()
        let sheetID = SheetID(rawValue: "sheet_update")
        let rowID = SheetRowID(rawValue: "row_update")
        try db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID, displayName: "T", description: nil,
                createdAt: referenceDate, in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c"),
                sheetID: sheetID, name: "minutes", kind: .duration, unit: nil, ordinal: 0, in: dbase
            )
            try WorkbookStore.insertRow(
                rowID: rowID, sheetID: sheetID,
                cells: ["minutes": .number(30)],
                createdAt: referenceDate, in: dbase
            )
        }
        try db.write { dbase in
            try WorkbookStore.updateCell(
                rowID: rowID,
                columnName: "minutes",
                value: .number(45),
                in: dbase
            )
        }
        let rows = try db.read { try WorkbookStore.listRows(sheetID: sheetID, in: $0) }
        XCTAssertEqual(rows[0].cells["minutes"], .number(45))
    }

    func test_updateCell_unknownRow_throws() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.write { dbase in
            try WorkbookStore.updateCell(
                rowID: SheetRowID(rawValue: "doesnotexist"),
                columnName: "x",
                value: .null,
                in: dbase
            )
        }) { error in
            XCTAssertEqual(
                error as? SheetValidationError,
                .rowNotFound(SheetRowID(rawValue: "doesnotexist"))
            )
        }
    }

    // MARK: - schema migration

    func test_workbookTables_existAfterMigration() throws {
        let db = try makeDB()
        try db.read { dbase in
            let tables = try Row.fetchAll(
                dbase,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
            ).map { $0["name"] as String }
            XCTAssertTrue(tables.contains("sheets"))
            XCTAssertTrue(tables.contains("sheet_columns"))
            XCTAssertTrue(tables.contains("sheet_rows"))
        }
    }
}
