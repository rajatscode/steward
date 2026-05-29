//
//  SheetDetailView.swift
//  Steward
//
//  Per-sheet detail surface. Renders the sheet's columns as a header
//  row and the rows as horizontally-scrollable rows below — the
//  "spreadsheet feel" the user wants for visibility into the agent's
//  workbook. Read-only in v1; inline cell edit lands later.
//

import SwiftUI

struct SheetDetailView: View {
    @StateObject private var viewModel: SheetDetailViewModel

    init(sheetID: SheetID, provider: DatabaseProvider = .shared) {
        _viewModel = StateObject(
            wrappedValue: SheetDetailViewModel(sheetID: sheetID, provider: provider)
        )
    }

    var body: some View {
        content
            .navigationTitle(viewModel.sheet?.displayName ?? "Sheet")
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
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
                Text("Couldn't load this sheet.")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            grid
        }
    }

    private var grid: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider()
                if viewModel.rows.isEmpty {
                    emptyRowsState
                        .padding(24)
                } else {
                    ForEach(viewModel.rows) { row in
                        rowView(row)
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            createdAtHeaderCell
            ForEach(viewModel.columns, id: \.columnID) { column in
                headerCell(for: column)
            }
        }
        .padding(.horizontal, 8)
    }

    private func rowView(_ row: SheetDetailViewModel.DisplayRow) -> some View {
        HStack(spacing: 0) {
            // Pinned timestamp column — always first, helps the user orient.
            cellText(Self.dateFormatter.string(from: row.createdAt))
                .frame(width: Self.timestampColumnWidth, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
            ForEach(row.cells) { cell in
                cellText(cell.displayValue)
                    .frame(width: Self.dataColumnWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Cells

    private func headerCell(for column: SheetColumn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(column.name)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 4) {
                Text(column.kind.rawValue)
                if let unit = column.unit, !unit.isEmpty {
                    Text("· \(unit)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(width: Self.dataColumnWidth, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var createdAtHeaderCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("logged")
                .font(.subheadline.weight(.semibold))
            Text("when")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.timestampColumnWidth, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func cellText(_ value: String) -> some View {
        Text(value.isEmpty ? "—" : value)
            .font(.callout)
            .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
            .lineLimit(2)
    }

    private var emptyRowsState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No rows yet")
                .font(.headline)
            Text("This sheet's schema is set up. Ask Outkeep to log something into it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Constants

    private static let timestampColumnWidth: CGFloat = 110
    private static let dataColumnWidth: CGFloat = 140

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}
