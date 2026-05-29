//
//  CellEditorView.swift
//  Steward
//
//  Inline cell editor for the SheetDetailView grid. Rendered in a
//  modal sheet when the user taps a cell. The form renders the right
//  control for the column's kind:
//
//     text       → TextField (any string)
//     number     → TextField with .decimalPad keyboard
//     duration   → TextField with .numberPad (minutes)
//     currency   → TextField with .decimalPad (dollars; stored as cents)
//     date       → DatePicker (saves an ISO-8601 date string)
//     bool       → Toggle
//
//  Save routes the edit through SheetDetailViewModel.applyCellEdit,
//  which calls SheetUpdateCellTool. The audit log gets an event with
//  `actor='user'` and a manual-correction reasoning, same shape as an
//  agent-driven edit.
//

import SwiftUI

/// One pending cell edit. Identifiable so SwiftUI's `.sheet(item:)`
/// can present it without losing identity across body re-evals.
struct CellEditTarget: Identifiable, Equatable {
    let rowID: SheetRowID
    let column: SheetColumn
    let initialValue: CellValue

    var id: String { "\(rowID.rawValue):\(column.name)" }
}

struct CellEditorView: View {
    let target: CellEditTarget
    let onSubmit: (CellValue) -> Void
    let onCancel: () -> Void

    // Per-kind draft state. Only the field matching `target.column.kind`
    // is read on submit; the rest stay at their defaults.
    @State private var textDraft: String = ""
    @State private var dateDraft: Date = Date()
    @State private var boolDraft: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    inputControl
                } header: {
                    Text(target.column.name)
                } footer: {
                    Text(footerHint)
                        .font(.caption2)
                }
            }
            .navigationTitle("Edit \(target.column.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: submit)
                        .disabled(!isValid)
                }
            }
            .onAppear(perform: hydrate)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var inputControl: some View {
        switch target.column.kind {
        case .text:
            TextField("Text", text: $textDraft, axis: .vertical)
                .lineLimit(1...4)
        case .number:
            TextField("Number", text: $textDraft)
                .keyboardType(.decimalPad)
        case .duration:
            HStack {
                TextField("Minutes", text: $textDraft)
                    .keyboardType(.numberPad)
                Text("min")
                    .foregroundStyle(.secondary)
            }
        case .currency:
            HStack {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("0.00", text: $textDraft)
                    .keyboardType(.decimalPad)
            }
        case .date:
            DatePicker("Date", selection: $dateDraft, displayedComponents: .date)
                .datePickerStyle(.graphical)
        case .bool:
            Toggle("Yes", isOn: $boolDraft)
        }
    }

    private var footerHint: String {
        switch target.column.kind {
        case .text:     return "Free text."
        case .number:   return "Numeric value." + unitSuffix
        case .duration: return "Total minutes — stored as a number."
        case .currency: return "Dollars and cents — stored as cents."
        case .date:     return "Saved as an ISO-8601 date."
        case .bool:     return "True / false."
        }
    }

    private var unitSuffix: String {
        if let unit = target.column.unit, !unit.isEmpty {
            return " Unit: \(unit)."
        }
        return ""
    }

    // MARK: - Hydration

    private func hydrate() {
        switch (target.column.kind, target.initialValue) {
        case (.text, .string(let s)):
            textDraft = s
        case (.number, .number(let n)), (.duration, .number(let n)):
            textDraft = Self.numericInputString(n)
        case (.currency, .number(let cents)):
            textDraft = String(format: "%.2f", cents / 100)
        case (.date, .string(let s)):
            if let parsed = Self.parseDate(s) { dateDraft = parsed }
        case (.bool, .bool(let b)):
            boolDraft = b
        default:
            break // empty / mismatched — start with defaults
        }
    }

    // MARK: - Submit

    private var isValid: Bool {
        switch target.column.kind {
        case .text, .date, .bool:
            return true
        case .number, .duration, .currency:
            let trimmed = textDraft.trimmingCharacters(in: .whitespaces)
            return Double(trimmed) != nil
        }
    }

    private func submit() {
        let value: CellValue
        switch target.column.kind {
        case .text:
            let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? .null : .string(trimmed)
        case .number, .duration:
            value = Double(textDraft.trimmingCharacters(in: .whitespaces)).map(CellValue.number) ?? .null
        case .currency:
            // Convert "12.34" → 1234 cents. Stored as an integer-valued
            // Double so SheetColumnKind.normalize(.currency) accepts it.
            if let dollars = Double(textDraft.trimmingCharacters(in: .whitespaces)) {
                value = .number((dollars * 100).rounded())
            } else {
                value = .null
            }
        case .date:
            value = .string(Self.dateFormatter.string(from: dateDraft))
        case .bool:
            value = .bool(boolDraft)
        }
        onSubmit(value)
    }

    // MARK: - Helpers

    /// Format a numeric value for display in the text field. Integers
    /// render without trailing `.0` so a user editing "40" doesn't see
    /// "40.000000".
    static func numericInputString(_ n: Double) -> String {
        if n.rounded() == n {
            return String(Int(n))
        }
        return String(n)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if let d = dateFormatter.date(from: s) { return d }
        // Be generous — accept a few common ISO-ish variants too.
        let alt = ISO8601DateFormatter()
        alt.formatOptions = [.withInternetDateTime]
        return alt.date(from: s)
    }
}
