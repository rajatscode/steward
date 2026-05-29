//
//  WorkbookViewModel.swift
//  Steward
//
//  Read-only view-model for the Workbook tab. Loads the active sheet
//  list at appear time and exposes a typed snapshot SwiftUI can render.
//  Sheet detail loading lives on SheetDetailViewModel — kept separate so
//  the list view doesn't pay the cost of loading every sheet's rows.
//

import Foundation

@MainActor
final class WorkbookViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var sheets: [Sheet] = []

    private let provider: DatabaseProvider

    init(provider: DatabaseProvider = .shared) {
        self.provider = provider
    }

    func load() async {
        state = .loading
        do {
            let db = try await provider.database()
            let loaded = try await db.read { dbase in
                try WorkbookStore.listSheets(includeArchived: false, in: dbase)
            }
            self.sheets = loaded
            self.state = .loaded
        } catch {
            self.state = .failed(message: String(describing: error))
        }
    }
}
