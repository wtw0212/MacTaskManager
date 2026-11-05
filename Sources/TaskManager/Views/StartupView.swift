import AppKit
import SwiftUI

struct StartupView: View {
    enum SortKey { case name, publisher, status, startup, scope }

    var search: String

    @State private var items: [StartupItem] = []
    @State private var selection: StartupItem.ID?
    @State private var sortKey: SortKey = .name
    @State private var ascending = true
    @AppStorage("showSystemDaemons") private var showsSystem = false
    @State private var message: String?

    private let columns: (publisher: CGFloat, status: CGFloat, startup: CGFloat, scope: CGFloat) = (140, 90, 130, 170)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Startup apps") {
                if let message {
                    Text(message)
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, DS.Space.s)
                }
                CommandButton(title: showsSystem ? "Hide system daemons" : "Show system daemons", icon: .filter) {
                    showsSystem.toggle()
                }
                CommandButton(title: "Refresh", icon: .refresh) { reload() }
                CommandButton(
                    title: selectedItem?.isDisabled == true ? "Enable" : "Disable",
                    icon: selectedItem?.isDisabled == true ? .enable : .endTask
                ) {
                    if let item = selectedItem { setEnabled(item.isDisabled, item) }
                }
                .disabled(selectedItem == nil)
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

            Rectangle().fill(DS.Palette.stroke).frame(height: 1)
            Text("Lists the launchd agents and daemons that start automatically. Changes apply at the next login or restart. Login Items from System Settings can't be read by other apps, so they aren't listed.")
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.s)
        }
        .onAppear(perform: reload)
    }

    // MARK: Rows

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(nsImage: StartupIcons.icon(for: item))
                    .resizable()
                    .frame(width: DS.Size.icon, height: DS.Size.icon)
                Text(item.name).font(DS.Typeface.body).lineLimit(1)
            }
            .padding(.leading, DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.program ?? item.label)

            cell(item.publisher, width: columns.publisher)
            cell(item.isDisabled ? "Disabled" : "Enabled", width: columns.status, secondary: item.isDisabled)
            cell(item.startup, width: columns.startup)
            cell(item.scope.rawValue, width: columns.scope, secondary: true)
        }
        .frame(height: DS.Size.listRow)
        .rowHighlight(isSelected: selection == item.id)
    }

    private func cell(_ text: String, width: CGFloat, secondary: Bool = false) -> some View {
        Text(text)
            .font(DS.Typeface.body)
            .foregroundStyle(secondary ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, DS.Space.s)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func menu(for item: StartupItem) -> some View {
        Button(item.isDisabled ? "Enable" : "Disable") { setEnabled(item.isDisabled, item) }
        Divider()
        Button("Open file location") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.program ?? item.plistPath)])
        }
        Button("Show launchd plist") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
        }
        Divider()
        Text(item.label)
    }

    // MARK: Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            header("Name", key: .name).padding(.leading, DS.Space.l)
            header("Publisher", key: .publisher).frame(width: columns.publisher)
            header("Status", key: .status).frame(width: columns.status)
            header("Starts", key: .startup).frame(width: columns.startup)
            header("Scope", key: .scope).frame(width: columns.scope)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
    }

    private func header(_ title: String, key: SortKey) -> some View {
        ColumnHeader(title: title, isSorted: sortKey == key, ascending: ascending) {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = true }
        }
    }

    // MARK: Data

    private var selectedItem: StartupItem? {
        items.first { $0.id == selection }
    }

    private var visibleItems: [StartupItem] {
        items
            .filter { showsSystem || $0.scope != .system }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.label.localizedCaseInsensitiveContains(search) }
            .sorted { a, b in
                let ordered: Bool
                switch sortKey {
                case .name: ordered = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .publisher: ordered = a.publisher.localizedCaseInsensitiveCompare(b.publisher) == .orderedAscending
                case .status: ordered = !a.isDisabled && b.isDisabled
                case .startup: ordered = a.startup < b.startup
                case .scope: ordered = a.scope.rawValue < b.scope.rawValue
                }
                return ascending ? ordered : !ordered
            }
    }

    private func reload() {
        items = StartupScanner.scan()
    }

    private func setEnabled(_ enabled: Bool, _ item: StartupItem) {
        let ok = StartupScanner.setEnabled(enabled, for: item)
        message = ok ? "\(item.name) \(enabled ? "enabled" : "disabled")." : "Couldn't change \(item.name)."
        reload()
    }
}

private extension StartupItem {
    var startup: String {
        keepAlive ? "Always running" : runAtLoad ? "At login" : "On demand"
    }
}

/// App icon for an item's program (or its .app bundle), cached.
private enum StartupIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: StartupItem) -> NSImage {
        let path: String = {
            guard let program = item.program else { return "" }
            if let range = program.range(of: ".app/") ?? program.range(of: ".app", options: .backwards),
               program.hasSuffix(".app") || program.contains(".app/") {
                return String(program[..<range.upperBound]).replacingOccurrences(of: ".app/", with: ".app")
            }
            return program
        }()
        if let cached = cache[path] { return cached }
        let icon = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .unixExecutable)
        cache[path] = icon
        return icon
    }
}
