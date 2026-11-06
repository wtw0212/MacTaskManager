import AppKit
import SwiftUI

/// launchd services, laid out like Windows' Services page.
struct ServicesView: View {
    private enum SortKey { case name, pid, status, domain, path }

    var search: String

    @StateObject private var model = ServicesModel()
    @State private var selection: ServiceItem.ID?
    @State private var sortKey: SortKey = .name
    @State private var ascending = true

    var body: some View {
        let selected = model.items.first { $0.id == selection }
        VStack(spacing: 0) {
            PageHeader(title: "Services") {
                if let message = model.message {
                    Text(message)
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.trailing, DS.Space.s)
                }
                CommandButton(title: "Start", icon: .start) { if let selected { model.perform(.start, on: selected) } }
                    .disabled(selected == nil || selected?.isRunning == true)
                CommandButton(title: "Stop", icon: .stop) { if let selected { model.perform(.stop, on: selected) } }
                    .disabled(selected?.isRunning != true)
                CommandButton(title: "Restart", icon: .refresh) { if let selected { model.perform(.restart, on: selected) } }
                    .disabled(selected == nil)
            }

            columnHeaders
            Rectangle().fill(DS.Palette.stroke).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleItems) { item in
                        row(item)
                            .onTapGesture { selection = item.id }
                            .contextMenu { menu(for: item) }
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
            }
        }
        .onAppear(perform: model.start)
        .onDisappear(perform: model.stop)
    }

    private func row(_ item: ServiceItem) -> some View {
        HStack(spacing: 0) {
            Text(item.label)
                .font(DS.Typeface.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, DS.Space.l + DS.Space.s) // + ColumnHeader's inner padding, so names line up with "Name"
                .frame(maxWidth: .infinity, alignment: .leading)
            ListCell(text: item.isRunning ? "\(item.pid)" : "", width: DS.Size.narrowColumn, alignment: .trailing)
            ListCell(text: item.isRunning ? "Running" : "Stopped", width: DS.Size.valueColumn, secondary: !item.isRunning)
            ListCell(text: item.domain.rawValue, width: DS.Size.valueColumn, secondary: true)
            ListCell(text: item.program ?? "", width: DS.Size.pathColumn, secondary: true)
        }
        .frame(height: DS.Size.listRow)
        .rowHighlight(isSelected: selection == item.id)
    }

    @ViewBuilder
    private func menu(for item: ServiceItem) -> some View {
        Button("Start") { model.perform(.start, on: item) }.disabled(item.isRunning)
        Button("Stop") { model.perform(.stop, on: item) }.disabled(!item.isRunning)
        Button("Restart") { model.perform(.restart, on: item) }
        Divider()
        if let program = item.program {
            Button("Open file location") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program)])
            }
        }
        Button("Search online") { SearchOnline.open(item.label) }
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            header("Name", key: .name).padding(.leading, DS.Space.l)
            header("PID", key: .pid, alignment: .trailing).frame(width: DS.Size.narrowColumn)
            header("Status", key: .status).frame(width: DS.Size.valueColumn)
            header("Domain", key: .domain).frame(width: DS.Size.valueColumn)
            header("Program path", key: .path).frame(width: DS.Size.pathColumn)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
    }

    private func header(_ title: String, key: SortKey, alignment: HorizontalAlignment = .leading) -> some View {
        ColumnHeader(title: title, alignment: alignment, isSorted: sortKey == key, ascending: ascending) {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = true }
        }
    }

    private var visibleItems: [ServiceItem] {
        let shown = search.isEmpty ? model.items : model.items.filter {
            $0.label.localizedCaseInsensitiveContains(search) || "\($0.pid)" == search
        }
        let isOrdered = { (a: ServiceItem, b: ServiceItem) -> Bool in
            switch sortKey {
            case .name: a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            case .pid: a.pid < b.pid
            case .status: a.isRunning && !b.isRunning
            case .domain: a.domain.rawValue < b.domain.rawValue
            case .path: (a.program ?? "") < (b.program ?? "")
            }
        }
        return shown.sorted { ascending ? isOrdered($0, $1) : isOrdered($1, $0) }
    }
}
