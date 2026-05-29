//
//  WorkbookView.swift
//  Steward
//
//  The Workbook tab — a flat list of the sheets the agent has built.
//  Tapping a row drills into SheetDetailView.
//
//  v1 of this surface is intentionally minimal: no manual create
//  affordance, no archive UX. New sheets come from the agent
//  (sheet.create tool). Manual creation can land later if a friction
//  signal shows up during dogfooding.
//

import SwiftUI

struct WorkbookView: View {
    @StateObject private var viewModel = WorkbookViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Workbook")
                .task { await viewModel.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Couldn't load the workbook.")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Try again") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where viewModel.sheets.isEmpty:
            EmptyWorkbookView()
        case .loaded:
            sheetList
        }
    }

    private var sheetList: some View {
        List(viewModel.sheets, id: \.sheetID) { sheet in
            NavigationLink(value: sheet.sheetID) {
                SheetListRowView(sheet: sheet)
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: SheetID.self) { sheetID in
            SheetDetailView(sheetID: sheetID)
        }
    }
}

// MARK: - Row

private struct SheetListRowView: View {
    let sheet: Sheet

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sheet.displayName)
                .font(.headline)
            if let description = sheet.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(Self.relativeCreatedString(sheet.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func relativeCreatedString(_ date: Date) -> String {
        "started \(relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }
}

// MARK: - Empty state

private struct EmptyWorkbookView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No sheets yet")
                .font(.headline)
            Text("Ask Outkeep in the Chat tab to start tracking something — it'll build a sheet for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    WorkbookView()
}
