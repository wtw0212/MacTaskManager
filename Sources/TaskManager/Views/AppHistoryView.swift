import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Windows' App history page: usage each app has accumulated, with heat-shaded columns.
struct AppHistoryView: View {
    private enum Column: CaseIterable, Identifiable {
        case cpu, network, energy

        var id: Self { self }

        var title: String {
            switch self {
            case .cpu: "CPU time"
            case .network: "Network"
            case .energy: "Energy"
            }
        }

        func value(_ record: AppUsageRecord) -> Double {
            switch self {
            case .cpu: record.cpuSeconds
            case .network: record.networkBytes
            case .energy: record.energyJoules
            }
        }

        func text(_ record: AppUsageRecord) -> String {
            switch self {
            case .cpu: Theme.cpuTime(record.cpuSeconds)
            case .network: Theme.megabytes(UInt64(max(record.networkBytes, 0)))
            case .energy: String(format: "%.2f Wh", record.energyJoules / 3600)
            }
        }
    }

    var search: String

    @ObservedObject private var history = AppHistory.shared
    @State private var selection: String?
    /// nil sorts by name.
    @State private var sortColumn: Column? = .cpu
    @State private var ascending = false
    @State private var confirmDelete = false

    var body: some View {
        let records = visibleRecords
        // Heat is relative to the busiest app in each column, as in Windows.
        let maxima = Dictionary(uniqueKeysWithValues: Column.allCases.map { column in
            (column, max(records.map(column.value).max() ?? 0, .leastNonzeroMagnitude))
        })

        VStack(spacing: 0) {
            PageHeader(title: "App history") {
                CommandButton(title: "Delete usage history", icon: .delete) { confirmDelete = true }
                    .disabled(history.records.isEmpty)
            }

            Text("Resource usage since \(history.since.formatted(date: .numeric, time: .omitted)) by apps you ran while Task Manager was open.")
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.m)

            columnHeaders
            Rectangle().fill(DS.Palette.stroke).frame(height: 1)

            if records.isEmpty {
                Text(history.records.isEmpty ? "Usage appears here after apps have run for a few seconds." : "No apps match your search.")
                    .font(DS.Typeface.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            row(record, maxima)
                                .onTapGesture { selection = record.id }
                                .contextMenu { menu(for: record) }
                        }
                    }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                }
            }
        }
        .alert("Delete usage history?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { history.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The totals for every app start again from zero.")
        }
    }

    private func row(_ record: AppUsageRecord, _ maxima: [Column: Double]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(nsImage: history.icon(for: record) ?? NSWorkspace.shared.icon(for: .application))
                    .resizable()
                    .frame(width: DS.Size.icon, height: DS.Size.icon)
                Text(record.name).font(DS.Typeface.body).lineLimit(1)
            }
            .padding(.leading, DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(Column.allCases) { column in
                    Text(column.text(record))
                        .font(DS.Typeface.body.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, DS.Space.s)
                        .frame(width: DS.Size.valueColumn - 2, height: DS.Size.listRow, alignment: .trailing)
                        .background(DS.Palette.heat(column.value(record) / (maxima[column] ?? 1)))
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: DS.Size.listRow)
        .rowHighlight(isSelected: selection == record.id)
    }

    @ViewBuilder
    private func menu(for record: AppUsageRecord) -> some View {
        if let path = record.path {
            Button("Open file location") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Button("Search online") { SearchOnline.open(record.name) }
    }

    private var columnHeaders: some View {
        HStack(alignment: .bottom, spacing: 0) {
            header(nil, title: "Name", alignment: .leading)
                .padding(.leading, DS.Space.l)
                .frame(maxWidth: .infinity)
            ForEach(Column.allCases) { column in
                header(column, title: column.title, alignment: .trailing).frame(width: DS.Size.valueColumn)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
    }

    private func header(_ column: Column?, title: String, alignment: HorizontalAlignment) -> some View {
        ColumnHeader(title: title, alignment: alignment, isSorted: sortColumn == column, ascending: ascending) {
            if sortColumn == column {
                ascending.toggle()
            } else {
                sortColumn = column
                ascending = column == nil
            }
        }
    }

    private var visibleRecords: [AppUsageRecord] {
        let shown = search.isEmpty ? history.records : history.records.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let column = sortColumn
        let isOrdered = { (a: AppUsageRecord, b: AppUsageRecord) -> Bool in
            if let column { return column.value(a) < column.value(b) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return shown.sorted { ascending ? isOrdered($0, $1) : isOrdered($1, $0) }
    }
}
