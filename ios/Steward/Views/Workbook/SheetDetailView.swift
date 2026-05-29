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
    @State private var editTarget: CellEditTarget?

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
            .sheet(item: $editTarget) { target in
                CellEditorView(
                    target: target,
                    onSubmit: { newValue in
                        editTarget = nil
                        Task {
                            await viewModel.applyCellEdit(
                                rowID: target.rowID,
                                column: target.column,
                                value: newValue
                            )
                        }
                    },
                    onCancel: { editTarget = nil }
                )
            }
            .alert(
                "Edit failed",
                isPresented: Binding(
                    get: { viewModel.lastEditError != nil },
                    set: { if !$0 { viewModel.lastEditError = nil } }
                ),
                presenting: viewModel.lastEditError
            ) { _ in
                Button("OK") { viewModel.lastEditError = nil }
            } message: { message in
                Text(message)
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
            ForEach(Array(zip(row.cells, viewModel.columns)), id: \.0.id) { cell, column in
                Button(action: { beginEdit(rowID: SheetRowID(rawValue: row.id), column: column) }) {
                    cellText(cell.displayValue)
                        .frame(width: Self.dataColumnWidth, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func beginEdit(rowID: SheetRowID, column: SheetColumn) {
        // DisplayRow only carries formatted strings — fetch the typed
        // value off the DB so the editor's input control hydrates with
        // the right CellValue case. Start the sheet with `.null` so it
        // opens fast; the awaited fetch overwrites with the real value
        // before the user types.
        editTarget = CellEditTarget(rowID: rowID, column: column, initialValue: .null)
        Task { @MainActor in
            let raw = await viewModel.rawCellValue(rowID: rowID, columnName: column.name)
            editTarget = CellEditTarget(rowID: rowID, column: column, initialValue: raw)
        }
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
