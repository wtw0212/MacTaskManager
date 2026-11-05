import AppKit
import SwiftUI

struct StartupView: View {
    @State private var items: [StartupItem] = []
    @State private var selection: StartupItem.ID?
    @State private var sortOrder = [KeyPathComparator(\StartupItem.name)]
    @State private var showsSystem = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Show system daemons", isOn: $showsSystem)
                Spacer()
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button("Refresh") { reload() }
                Button(selectedItem?.isDisabled == true ? "Enable" : "Disable") { toggleSelected() }
                    .disabled(selectedItem == nil)
            }
            .padding(10)

            Table(visibleItems, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { item in
                    Text(item.name).help(item.program ?? "")
                }
                .width(min: 160, ideal: 220)
                TableColumn("Label", value: \.label) { Text($0.label).foregroundStyle(.secondary) }
                    .width(min: 160, ideal: 260)
                TableColumn("Publisher", value: \.publisher)
                    .width(90)
                TableColumn("Status") { item in
                    Text(item.isDisabled ? "Disabled" : "Enabled")
                        .foregroundStyle(item.isDisabled ? .secondary : .primary)
                }
                .width(70)
                TableColumn("Running") { Text($0.isRunning ? "Yes" : "") }
                    .width(60)
                TableColumn("Starts") { item in
                    Text(item.keepAlive ? "Always (keep alive)" : item.runAtLoad ? "At login" : "On demand")
                }
                .width(120)
                TableColumn("Scope") { Text($0.scope.rawValue).foregroundStyle(.secondary) }
                    .width(min: 140, ideal: 170)
            }
            .contextMenu(forSelectionType: StartupItem.ID.self) { ids in
                if let item = items.first(where: { $0.id == ids.first }) {
                    Button(item.isDisabled ? "Enable" : "Disable") { setEnabled(item.isDisabled, item) }
                    Divider()
                    Button("Show plist in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
                    }
                    if let program = item.program {
                        Button("Show program in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program)])
                        }
                    }
                }
            }

            Text("These are the launchd agents and daemons that start automatically. Enable and Disable take effect at the next login or restart. Apps added under System Settings → General → Login Items aren't listed, because macOS doesn't let other apps read that list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .onAppear(perform: reload)
    }

    private var selectedItem: StartupItem? {
        items.first { $0.id == selection }
    }

    private var visibleItems: [StartupItem] {
        items.filter { showsSystem || $0.scope != .system }.sorted(using: sortOrder)
    }

    private func reload() {
        items = StartupScanner.scan()
    }

    private func toggleSelected() {
        guard let item = selectedItem else { return }
        setEnabled(item.isDisabled, item)
    }

    private func setEnabled(_ enabled: Bool, _ item: StartupItem) {
        let ok = StartupScanner.setEnabled(enabled, for: item)
        message = ok
            ? "\(item.name) \(enabled ? "enabled" : "disabled")."
            : "Couldn't change \(item.name)."
        reload()
    }
}
