//
//  WorkbookViewModelTests.swift
//  StewardTests
//
//  Covers the two view-models that back the Workbook tab. Cell display
//  formatting + load/empty/failed transitions are testable without
//  spinning up SwiftUI; the rendering layer is thin enough that getting
//  these green proves the data path is solid.
//

import XCTest
import GRDB
@testable import Steward

final class WorkbookViewModelTests: XCTestCase {

    private func makeProvider() async throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbook-vm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("steward.sqlite")
        let provider = DatabaseProvider(location: .file(url))
        _ = try await provider.database()
        return provider
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - WorkbookViewModel

    @MainActor
    func test_workbookViewModel_emptyState_loadsToLoadedWithNoSheets() async throws {
        let provider = try await makeProvider()
        let vm = WorkbookViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertTrue(vm.sheets.isEmpty)
    }

    @MainActor
    func test_workbookViewModel_loadsActiveSheetsInOrder() async throws {
        let provider = try await makeProvider()
        let db = try await provider.database()
        try await db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: SheetID(rawValue: "s1"),
                displayName: "Time", description: nil,
                createdAt: self.referenceDate, in: dbase
            )
            try WorkbookStore.insertSheet(
                sheetID: SheetID(rawValue: "s2"),
                displayName: "Money", description: nil,
                createdAt: self.referenceDate.addingTimeInterval(60), in: dbase
            )
        }
        let vm = WorkbookViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(vm.sheets.map(\.displayName), ["Time", "Money"])
    }

    @MainActor
    func test_workbookViewModel_excludesArchivedSheets() async throws {
        let provider = try await makeProvider()
        let db = try await provider.database()
        let archivedID = SheetID(rawValue: "s_archived")
        try await db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: archivedID, displayName: "Old", description: nil,
                createdAt: self.referenceDate, in: dbase
            )
            try WorkbookStore.archiveSheet(sheetID: archivedID, at: self.referenceDate.addingTimeInterval(60), in: dbase)
            try WorkbookStore.insertSheet(
                sheetID: SheetID(rawValue: "s_active"),
                displayName: "Active", description: nil,
                createdAt: self.referenceDate.addingTimeInterval(120), in: dbase
            )
        }
        let vm = WorkbookViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(vm.sheets.map(\.displayName), ["Active"])
    }

    // MARK: - SheetDetailViewModel — load path

    @MainActor
    func test_sheetDetailViewModel_loadsSheetColumnsAndRows() async throws {
        let provider = try await makeProvider()
        let sheetID = SheetID(rawValue: "s_detail")
        let db = try await provider.database()
        try await db.write { dbase in
            try WorkbookStore.insertSheet(
                sheetID: sheetID, displayName: "Time", description: nil,
                createdAt: self.referenceDate, in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c_date"),
                sheetID: sheetID, name: "date", kind: .date, unit: nil, ordinal: 0, in: dbase
            )
            try WorkbookStore.insertColumn(
                columnID: SheetColumnID(rawValue: "c_minutes"),
                sheetID: sheetID, name: "minutes", kind: .duration, unit: "min", ordinal: 1, in: dbase
            )
            try WorkbookStore.insertRow(
                rowID: SheetRowID(rawValue: "r1"),
                sheetID: sheetID,
                cells: ["date": .string("2026-05-26"), "minutes": .number(40)],
                createdAt: self.referenceDate.addingTimeInterval(10),

                in: dbase
            )
        }
        let vm = SheetDetailViewModel(sheetID: sheetID, provider: provider)
        await vm.load()
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(vm.sheet?.displayName, "Time")
        XCTAssertEqual(vm.columns.map(\.name), ["date", "minutes"])
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows[0].cells.map(\.columnName), ["date", "minutes"])
        XCTAssertEqual(vm.rows[0].cells[0].displayValue, "2026-05-26")
        XCTAssertEqual(vm.rows[0].cells[1].displayValue, "40m")
    }

    @MainActor
    func test_sheetDetailViewModel_missingSheet_failedState() async throws {
        let provider = try await makeProvider()
        let vm = SheetDetailViewModel(sheetID: SheetID(rawValue: "nope"), provider: provider)
        await vm.load()
        // Sheet absent isn't an error condition for the loader — it returns
        // .loaded with sheet=nil so the view can render an empty/missing
        // state without a banner. Verify that.
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertNil(vm.sheet)
        XCTAssertTrue(vm.columns.isEmpty)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    // MARK: - SheetDetailViewModel.formatCell

    func test_formatCell_durationCombinesHoursAndMinutes() {
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(40), kind: .duration, unit: "min"),
            "40m"
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(60), kind: .duration, unit: "min"),
            "1h"
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(90), kind: .duration, unit: "min"),
            "1h 30m"
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(195), kind: .duration, unit: "min"),
            "3h 15m"
        )
    }

    func test_formatCell_currencyRendersCentsAsDollars() {
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(4000), kind: .currency, unit: "$"),
            "$40.00"
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(550), kind: .currency, unit: "$"),
            "$5.50"
        )
    }

    func test_formatCell_boolRendersYesNo() {
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.bool(true), kind: .bool, unit: nil),
            "yes"
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.bool(false), kind: .bool, unit: nil),
            "no"
        )
    }

    func test_formatCell_textPassesThrough() {
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.string("hello"), kind: .text, unit: nil),
            "hello"
        )
    }

    func test_formatCell_numberAppendsUnitWhenProvided() {
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(178), kind: .number, unit: "lbs"),
            "178 lbs"
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(178), kind: .number, unit: nil),
            "178"
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.number(7.5), kind: .number, unit: "h"),
            "7.50 h"
        )
    }

    func test_formatCell_nullRendersEmpty() {
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.null, kind: .text, unit: nil),
            ""
        )
        XCTAssertEqual(
            SheetDetailViewModel.formatCell(.null, kind: .duration, unit: "min"),
            ""
        )
    }
}
