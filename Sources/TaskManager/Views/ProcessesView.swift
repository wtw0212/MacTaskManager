import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app (with its helper processes) or a single background process.
struct ProcessGroup: Identifiable {
    var main: ProcessRow
    var children: [ProcessRow]
    var id: pid_t { main.id }

    private var all: [ProcessRow] { [main] + children }
    var cpu: Double? { all.allSatisfy { $0.cpu < 0 } ? nil : all.map { max($0.cpu, 0) }.reduce(0, +) }
    var memory: UInt64? { let total = all.map(\.memory).reduce(0, +); return total == 0 ? nil : total }
    var diskRate: Double? { all.allSatisfy { $0.diskRate < 0 } ? nil : all.map { max($0.diskRate, 0) }.reduce(0, +) }
    var title: String { children.isEmpty ? main.name : "\(main.name) (\(children.count + 1))" }
}

struct ProcessesView: View {
    enum SortKey { case name, cpu, memory, disk }

    var search: String

    @EnvironmentObject private var monitor: PerformanceMonitor
    @State private var selection: pid_t?
    @State private var expanded: Set<pid_t> = []
    @State private var sortKey: SortKey = .cpu
    @State private var ascending = false

    var body: some View {
        let split = groups
        VStack(spacing: 0) {
            PageHeader(title: "Processes") {
                CommandButton(title: "Run new task", icon: .runTask) { RunNewTask.present() }
                CommandButton(title: "End task", icon: .endTask) {
                    if let selection { ProcessSampler.terminate(selection, force: false) }
                }
                .disabled(selection == nil)
                .keyboardShortcut(.delete, modifiers: [])
            }

            columnHeaders
            Rectangle().fill(DS.Palette.stroke).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(split.apps) { groupRows($0) }
                    } header: {
                        ListSectionTitle(title: "Apps (\(split.apps.count))")
                    }
                    Section {
                        ForEach(split.background) { groupRows($0) }
                    } header: {
                        ListSectionTitle(title: "Background processes (\(split.background.count))")
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.bottom, DS.Space.l)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func groupRows(_ group: ProcessGroup) -> some View {
        let isExpanded = expanded.contains(group.id)
        ProcessLine(
            name: group.title,
            icon: group.main.icon,
            indent: 0,
            disclosure: group.children.isEmpty ? nil : isExpanded,
            cpu: group.cpu,
            memory: group.memory,
            disk: group.diskRate,
            totalMemory: monitor.memory?.total ?? 1,
            isSelected: selection == group.id,
            toggle: { toggle(group.id) }
        )
        .onTapGesture(count: 2) { toggle(group.id) }
        .onTapGesture { selection = group.id }
        .contextMenu { menu(for: group.main) }

        if isExpanded {
            ForEach(group.children) { child in
                ProcessLine(
                    name: child.name,
                    icon: child.icon ?? group.main.icon, // helpers show their app's icon, as in Windows
                    indent: 1,
                    disclosure: nil,
                    cpu: child.cpu < 0 ? nil : child.cpu,
                    memory: child.memory == 0 ? nil : child.memory,
                    disk: child.diskRate < 0 ? nil : child.diskRate,
                    totalMemory: monitor.memory?.total ?? 1,
                    isSelected: selection == child.id,
                    toggle: {}
                )
                .onTapGesture { selection = child.id }
                .contextMenu { menu(for: child) }
            }
        }
    }

    @ViewBuilder
    private func menu(for row: ProcessRow) -> some View {
        Button("End task") { ProcessSampler.terminate(row.id, force: false) }
        Button("Force quit") { ProcessSampler.terminate(row.id, force: true) }
        if let path = row.path {
            Divider()
            Button("Open file location") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Divider()
        Text("PID \(row.id)")
    }

    private func toggle(_ id: pid_t) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Column headers

    private var columnHeaders: some View {
        let maxDisk = monitor.disks.map(\.activeTime).max() ?? 0
        return HStack(spacing: 0) {
            // Aligns "Name" with the row icons (after the disclosure chevron).
            header("Name", total: nil, key: .name, alignment: .leading)
                .padding(.leading, DS.Space.xl)
            header("CPU", total: Theme.percent(monitor.currentTotal), key: .cpu, alignment: .trailing)
                .frame(width: DS.Size.valueColumn)
            header("Memory", total: Theme.percent(monitor.memory?.usedFraction), key: .memory, alignment: .trailing)
                .frame(width: DS.Size.valueColumn)
            header("Disk", total: Theme.percent(maxDisk), key: .disk, alignment: .trailing)
                .frame(width: DS.Size.valueColumn)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
    }

    private func header(_ title: String, total: String?, key: SortKey, alignment: HorizontalAlignment) -> some View {
        ColumnHeader(title: title, total: total, alignment: alignment, isSorted: sortKey == key, ascending: ascending) {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = key == .name }
        }
    }

    // MARK: Data

    private var groups: (apps: [ProcessGroup], background: [ProcessGroup]) {
        let rows = monitor.processes
        let appPIDs = Set(rows.filter(\.isApp).map(\.id))
        var children: [pid_t: [ProcessRow]] = [:]
        var background: [ProcessGroup] = []

        for row in rows where !row.isApp {
            if appPIDs.contains(row.responsiblePID) {
                children[row.responsiblePID, default: []].append(row)
            } else {
                background.append(ProcessGroup(main: row, children: []))
            }
        }
        let apps = rows.filter(\.isApp).map { ProcessGroup(main: $0, children: sorted(children[$0.id] ?? [])) }

        func matches(_ group: ProcessGroup) -> Bool {
            search.isEmpty
                || group.main.name.localizedCaseInsensitiveContains(search)
                || "\(group.main.id)" == search
                || group.children.contains { $0.name.localizedCaseInsensitiveContains(search) || "\($0.id)" == search }
        }
        return (sorted(apps.filter(matches)), sorted(background.filter(matches)))
    }

    private func sorted(_ groups: [ProcessGroup]) -> [ProcessGroup] {
        groups.sorted { a, b in
            let ordered: Bool
            switch sortKey {
            case .name: ordered = a.main.name.localizedCaseInsensitiveCompare(b.main.name) == .orderedAscending
            case .cpu: ordered = (a.cpu ?? -1) < (b.cpu ?? -1)
            case .memory: ordered = (a.memory ?? 0) < (b.memory ?? 0)
            case .disk: ordered = (a.diskRate ?? -1) < (b.diskRate ?? -1)
            }
            return ascending ? ordered : !ordered
        }
    }

    private func sorted(_ rows: [ProcessRow]) -> [ProcessRow] {
        sorted(rows.map { ProcessGroup(main: $0, children: []) }).map(\.main)
    }
}

/// One row: disclosure chevron, icon and name, then heat-shaded CPU, Memory and Disk cells.
private struct ProcessLine: View {
    private static let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    var name: String
    var icon: NSImage?
    var indent: Int
    /// nil: no children; true/false: expanded or collapsed.
    var disclosure: Bool?
    var cpu: Double?
    var memory: UInt64?
    var disk: Double?
    var totalMemory: UInt64
    var isSelected: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Button(action: toggle) {
                    Fluent(.chevronRight, size: 10)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(disclosure == true ? 90 : 0))
                        .frame(width: DS.Size.icon, height: DS.Size.listRow)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(disclosure == nil ? 0 : 1)
                .disabled(disclosure == nil)

                Image(nsImage: icon ?? Self.genericIcon)
                    .resizable()
                    .frame(width: DS.Size.icon, height: DS.Size.icon)
                Text(name)
                    .font(DS.Typeface.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, DS.Space.s + CGFloat(indent) * (DS.Size.icon + DS.Space.s))
            .frame(maxWidth: .infinity, alignment: .leading)

            valueCell(cpu.map { String(format: "%.1f%%", $0 * 100) }, heat: (cpu ?? 0) / 0.25)
            valueCell(memory.map(Theme.megabytes), heat: Double(memory ?? 0) / max(Double(totalMemory) * 0.15, 1))
            valueCell(disk.map(Theme.megabyteRate), heat: (disk ?? 0) / 20_000_000)
        }
        .frame(height: DS.Size.listRow)
        .rowHighlight(isSelected: isSelected)
    }

    private func valueCell(_ text: String?, heat: Double) -> some View {
        Text(text ?? "–")
            .font(DS.Typeface.body)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, DS.Space.s)
            .frame(width: DS.Size.valueColumn - 2, height: DS.Size.listRow, alignment: .trailing)
            .background(DS.Palette.heat(text == nil ? 0 : heat))
            .padding(.horizontal, 1)
    }
}

/// Lets the user pick an app or program to launch, like Windows' "Run new task".
enum RunNewTask {
    @MainActor
    static func present() {
        let panel = NSOpenPanel()
        panel.title = "Run new task"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application, .unixExecutable]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
