import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Columns after Name. CPU, Memory, Disk and Network are always shown, as in Windows;
/// the rest can be turned on and off by right-clicking the column headers.
enum ProcessColumn: String, CaseIterable, Identifiable {
    case status, pid, user, cpu, memory, disk, network, energy, threads, architecture, path

    var id: Self { self }

    var title: String {
        switch self {
        case .status: "Status"
        case .pid: "PID"
        case .user: "User name"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Power usage"
        case .threads: "Threads"
        case .architecture: "Architecture"
        case .path: "Path"
        }
    }

    var isOptional: Bool { ![.cpu, .memory, .disk, .network].contains(self) }
    var isNumeric: Bool { [.pid, .cpu, .memory, .disk, .network, .threads].contains(self) }

    var width: CGFloat {
        switch self {
        case .status: DS.Size.statusColumn
        case .pid, .threads: DS.Size.narrowColumn
        case .path: DS.Size.pathColumn
        default: DS.Size.valueColumn
        }
    }
}

/// Windows' "Power usage" levels, from average watts over the last interval.
enum PowerUsage {
    static let names = ["Very low", "Low", "Moderate", "High", "Very high"]
    // Watts. Measured: idle apps read under 0.01 W, one fully busy performance core about 7 W.
    private static let thresholds = [0.05, 0.5, 2, 10]

    static func level(_ watts: Double) -> Int {
        thresholds.firstIndex { watts < $0 } ?? thresholds.count
    }
}

/// What rows need from the rest of the system to show values and percentages.
struct ProcessContext {
    var totalMemory: Double
    /// All disks' read + write bytes per second, and the busiest disk's active time.
    var diskRate: Double
    var diskActive: Double
    /// Sum of the active network links' speeds in bits per second (0 if unknown).
    var linkSpeed: Double
    var memoryAsPercent: Bool
    var diskAsPercent: Bool
    var networkAsPercent: Bool
}

/// An app (with its helper processes) or a single background process.
struct ProcessGroup: Identifiable {
    var main: ProcessRow
    var children: [ProcessRow]
    var id: pid_t { main.id }

    var title: String { children.isEmpty ? main.name : "\(main.name) (\(children.count + 1))" }
    var all: [ProcessRow] { [main] + children }

    /// Sum over the processes we can read; nil when none is readable.
    private func total(_ value: (ProcessRow) -> Double) -> Double? {
        let values = all.map(value).filter { $0 >= 0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var cpu: Double? { total(\.cpu) }
    var memory: Double? { total { $0.memory == 0 ? -1 : Double($0.memory) } }
    var diskRate: Double? { total(\.diskRate) }
    var networkRate: Double? { total(\.networkRate) }
    var energy: Double? { total(\.energy) }
    var threads: Double? { total { Double($0.threads ?? -1) } }

    var statusText: String {
        switch main.status {
        case .suspended: "Suspended"
        case .efficiency: "Efficiency mode"
        case nil: ""
        }
    }

    /// Text and heat shading (nil: none) for a column.
    func cell(_ column: ProcessColumn, _ context: ProcessContext) -> (text: String, heat: Double?) {
        switch column {
        case .status: return (statusText, nil)
        case .pid: return ("\(main.id)", nil)
        case .user: return (main.user, nil)
        case .architecture: return (main.architecture, nil)
        case .path: return (main.path ?? "", nil)
        case .threads: return (threads.map { "\(Int($0))" } ?? "–", nil)
        case .cpu:
            guard let cpu else { return ("–", 0) }
            return (Theme.precisePercent(cpu), cpu / 0.25)
        case .memory:
            guard let memory else { return ("–", 0) }
            let share = memory / max(context.totalMemory, 1)
            return (context.memoryAsPercent ? Theme.precisePercent(share) : Theme.megabytes(UInt64(memory)), share / 0.15)
        case .disk:
            guard let diskRate else { return ("–", 0) }
            // The process's share of all disk traffic, applied to the busiest disk's active time.
            let share = context.diskRate > 0 ? min(diskRate / context.diskRate, 1) * context.diskActive : 0
            return (context.diskAsPercent ? Theme.precisePercent(share) : Theme.megabyteRate(diskRate), diskRate / 20_000_000)
        case .network:
            guard let networkRate else { return ("–", 0) }
            let text = context.networkAsPercent && context.linkSpeed > 0
                ? Theme.precisePercent(networkRate * 8 / context.linkSpeed)
                : Theme.megabitRate(networkRate)
            return (text, networkRate / 2_000_000)
        case .energy:
            guard let energy else { return ("–", 0) }
            let level = PowerUsage.level(energy)
            return (PowerUsage.names[level], Double(level) / 4)
        }
    }

    /// Column titles and this row's values, tab-separated, ready to paste into a spreadsheet.
    func details(_ columns: [ProcessColumn], _ context: ProcessContext) -> String {
        let titles = ["Name"] + columns.map(\.title)
        let values = [title] + columns.map { cell($0, context).text }
        return titles.joined(separator: "\t") + "\n" + values.joined(separator: "\t")
    }

    func sortValue(_ column: ProcessColumn) -> Double? {
        switch column {
        case .pid: Double(main.id)
        case .cpu: cpu
        case .memory: memory
        case .disk: diskRate
        case .network: networkRate
        case .energy: energy
        case .threads: threads
        case .status, .user, .architecture, .path: nil
        }
    }
}

struct ProcessesView: View {
    private struct ListSection {
        var title: String?
        var groups: [ProcessGroup]
    }

    private struct ProcessAlert {
        var title: String
        var message: String
        /// Destructive confirmation button; nil for a plain OK alert.
        var confirm: String?
        var action: () -> Void = {}
    }

    var search: String

    @EnvironmentObject private var monitor: PerformanceMonitor
    @StateObject private var keys = KeyMonitor()
    @State private var selection: pid_t?
    @State private var expanded: Set<pid_t> = []
    /// nil sorts by Name.
    @State private var sortColumn: ProcessColumn? = .cpu
    @State private var ascending = false
    @State private var alert: ProcessAlert?
    @State private var properties: ProcessRow?

    @AppStorage("processHiddenColumns") private var hiddenColumns = "pid,user,threads,architecture,path"
    @AppStorage("groupByType") private var groupByType = true
    @AppStorage("memoryAsPercent") private var memoryAsPercent = false
    @AppStorage("diskAsPercent") private var diskAsPercent = false
    @AppStorage("networkAsPercent") private var networkAsPercent = false

    var body: some View {
        let sections = self.sections
        let columns = self.columns
        let context = self.context
        let selected = group(for: selection, in: sections)
        let _ = keys.handler = { handleKey($0, sections) }

        VStack(spacing: 0) {
            PageHeader(title: "Processes") {
                CommandButton(title: "Run new task", icon: .runTask) { RunNewTask.present() }
                CommandButton(title: "End task", icon: .endTask) {
                    if let selection { ProcessSampler.terminate(selection, force: false) }
                }
                .disabled(selected == nil)
                CommandButton(title: "Efficiency mode", icon: .efficiency, isOn: selected?.main.status == .efficiency) {
                    if let selected { setEfficiency(selected, selected.main.status != .efficiency) }
                }
                .disabled(selected == nil)
                CommandMenu(title: "View", icon: .view) { viewMenu(sections) }
            }

            // Scrolls sideways when the visible columns don't fit, like Windows.
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        columnHeaders(columns)
                        Rectangle().fill(DS.Palette.stroke).frame(height: 1)
                        rows(sections, columns, context)
                    }
                    .frame(width: max(geometry.size.width, minimumWidth(columns)), height: geometry.size.height)
                }
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { alert in
            if let confirm = alert.confirm {
                Button(confirm, role: .destructive, action: alert.action)
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK") {}
            }
        } message: { Text($0.message) }
        .sheet(item: $properties) { ProcessPropertiesView(row: $0) }
        .onAppear {
            keys.start()
            monitor.samplesProcesses = true
        }
        .onDisappear {
            keys.stop()
            monitor.samplesProcesses = false
        }
    }

    // MARK: Rows

    private func rows(_ sections: [ListSection], _ columns: [ProcessColumn], _ context: ProcessContext) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections.indices, id: \.self) { index in
                        Section {
                            ForEach(sections[index].groups) { groupRows($0, columns, context) }
                        } header: {
                            if let title = sections[index].title { ListSectionTitle(title: title) }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, groupByType ? 0 : DS.Space.s)
                .padding(.bottom, DS.Space.l)
                .font(DS.Typeface.body.monospacedDigit())
                .lineLimit(1)
            }
            .onChange(of: selection) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private func groupRows(_ group: ProcessGroup, _ columns: [ProcessColumn], _ context: ProcessContext) -> some View {
        let isExpanded = expanded.contains(group.id)
        let line = ProcessLine(group: group, title: group.title, icon: group.main.icon, indent: 0,
                               disclosure: group.children.isEmpty ? nil : isExpanded,
                               columns: columns, context: context, isSelected: selection == group.id,
                               toggle: { toggle(group.id) })
        if group.children.isEmpty {
            line
                .id(group.id)
                .onTapGesture { selection = group.id }
                .contextMenu { menu(for: group, columns, context) }
        } else {
            line
                .id(group.id)
                .onTapGesture(count: 2) { toggle(group.id) }
                .onTapGesture { selection = group.id }
                .contextMenu { menu(for: group, columns, context) }
        }

        if isExpanded {
            ForEach(group.children) { child in
                let single = ProcessGroup(main: child, children: [])
                // Helpers show their app's icon, as in Windows.
                ProcessLine(group: single, title: child.name, icon: child.icon ?? group.main.icon, indent: 1,
                            disclosure: nil, columns: columns, context: context,
                            isSelected: selection == child.id, toggle: {})
                    .id(child.id)
                    .onTapGesture { selection = child.id }
                    .contextMenu { menu(for: single, columns, context) }
            }
        }
    }

    private func toggle(_ id: pid_t) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for group: ProcessGroup, _ columns: [ProcessColumn], _ context: ProcessContext) -> some View {
        let row = group.main
        if !group.children.isEmpty {
            Button(expanded.contains(group.id) ? "Collapse" : "Expand") { toggle(group.id) }
        }
        if row.isApp {
            Button("Switch to") { NSRunningApplication(processIdentifier: row.id)?.activate(options: []) }
        }
        Button("End task") { ProcessSampler.terminate(row.id, force: false) }
        Button("Force quit") { ProcessSampler.terminate(row.id, force: true) }
        Divider()
        Toggle("Efficiency mode", isOn: Binding(get: { row.status == .efficiency },
                                                set: { setEfficiency(group, $0) }))
        Button(row.status == .suspended ? "Resume" : "Suspend…") { suspend(group, row.status != .suspended) }
        resourceValuesMenu
        Divider()
        if let path = row.path {
            Button("Open file location") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Button("Search online") { SearchOnline.open(row.name) }
        Button("Copy details") { copyDetails(group, columns, context) }
        Button("Properties") { properties = row }
    }

    @ViewBuilder
    private func viewMenu(_ sections: [ListSection]) -> some View {
        Toggle("Group by type", isOn: $groupByType)
        Button("Expand all") {
            expanded = Set(sections.flatMap(\.groups).filter { !$0.children.isEmpty }.map(\.id))
        }
        Button("Collapse all") { expanded = [] }
        Divider()
        resourceValuesMenu
        Picker("Update speed", selection: $monitor.updateSpeed) {
            ForEach(UpdateSpeed.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private var resourceValuesMenu: some View {
        Menu("Resource values") {
            ForEach([("Memory", $memoryAsPercent), ("Disk", $diskAsPercent), ("Network", $networkAsPercent)], id: \.0) { name, binding in
                Picker(name, selection: binding) {
                    Text("Values").tag(false)
                    Text("Percents").tag(true)
                }
            }
        }
    }

    // MARK: Actions

    /// Applies to the app and all its helpers, as Windows does for a process tree.
    private func setEfficiency(_ group: ProcessGroup, _ on: Bool) {
        let failures = group.all.compactMap { row in ProcessSampler.setEfficiency(row.id, on).map { (row, $0) } }
        guard let (row, error) = failures.first else { return monitor.refreshProcesses() }
        alert = ProcessAlert(
            title: "Couldn't change efficiency mode",
            message: "\(row.name): \(error). macOS only lets you change your own processes; this one belongs to \(row.user)."
        )
        monitor.refreshProcesses()
    }

    private func suspend(_ group: ProcessGroup, _ suspend: Bool) {
        let apply = {
            let failures = group.all.compactMap { row in ProcessSampler.setSuspended(row.id, suspend).map { (row, $0) } }
            if let (row, error) = failures.first {
                alert = ProcessAlert(title: "Couldn't \(suspend ? "suspend" : "resume") \(row.name)",
                                     message: "\(error). It belongs to \(row.user).")
            }
            monitor.refreshProcesses()
        }
        guard suspend else { return apply() }
        alert = ProcessAlert(
            title: "Suspend \(group.main.name)?",
            message: "It stops running until you choose Resume. A suspended app doesn't respond, and anything that depends on it may stall.",
            confirm: "Suspend",
            action: apply
        )
    }

    private func copyDetails(_ group: ProcessGroup, _ columns: [ProcessColumn], _ context: ProcessContext) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(group.details(columns, context), forType: .string)
    }

    // MARK: Keyboard

    /// Delete ends the task, arrows move the selection, Space/→ expand and ← collapses.
    private func handleKey(_ event: NSEvent, _ sections: [ListSection]) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let groups = sections.flatMap(\.groups)
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            guard let selection else { return false }
            ProcessSampler.terminate(selection, force: false)
        case 125, 126: // Down, Up
            let order = groups.flatMap { [$0.id] + (expanded.contains($0.id) ? $0.children.map(\.id) : []) }
            guard !order.isEmpty else { return false }
            let step = event.keyCode == 125 ? 1 : -1
            let index = selection.flatMap(order.firstIndex).map { min(max($0 + step, 0), order.count - 1) } ?? 0
            selection = order[index]
        case 124, 49: // Right, Space
            if let group = groups.first(where: { $0.id == selection }), !group.children.isEmpty, !expanded.contains(group.id) {
                toggle(group.id)
            }
        case 123: // Left: collapse, or from a helper go up to its app
            if let selection, expanded.contains(selection) {
                toggle(selection)
            } else if let parent = groups.first(where: { $0.children.contains { $0.id == selection } }) {
                selection = parent.id
            }
        default:
            return false
        }
        return true
    }

    // MARK: Column headers

    private var columns: [ProcessColumn] {
        let hidden = Set(hiddenColumns.split(separator: ",").map(String.init))
        return ProcessColumn.allCases.filter { !hidden.contains($0.rawValue) }
    }

    private func minimumWidth(_ columns: [ProcessColumn]) -> CGFloat {
        DS.Size.nameColumnMin + columns.map(\.width).reduce(0, +) + DS.Space.s * 2
    }

    private func columnHeaders(_ columns: [ProcessColumn]) -> some View {
        let networkAvailable = monitor.processes.contains { $0.networkRate >= 0 }
        return HStack(alignment: .bottom, spacing: 0) {
            // Aligns "Name" with the row icons (after the disclosure chevron).
            header(nil, title: "Name", total: nil)
                .padding(.leading, DS.Space.xl)
                .frame(minWidth: DS.Size.nameColumnMin)
            ForEach(columns) { column in
                header(column, title: column.title, total: total(column))
                    .frame(width: column.width)
                    .help(column == .network && !networkAvailable
                          ? "Per-process network usage comes from /usr/bin/nettop, which isn't delivering data."
                          : "")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
        .contextMenu {
            ForEach(ProcessColumn.allCases.filter(\.isOptional)) { column in
                Toggle(column.title, isOn: Binding(
                    get: { columns.contains(column) },
                    set: { show in
                        let hidden = ProcessColumn.allCases.filter { $0.isOptional && ($0 == column ? !show : !columns.contains($0)) }
                        hiddenColumns = hidden.map(\.rawValue).joined(separator: ",")
                    }
                ))
            }
        }
    }

    private func header(_ column: ProcessColumn?, title: String, total: String?) -> some View {
        ColumnHeader(title: title, total: total, alignment: column?.isNumeric == true ? .trailing : .leading,
                     isSorted: sortColumn == column, ascending: ascending) {
            if sortColumn == column {
                ascending.toggle()
            } else {
                sortColumn = column
                ascending = column.map { !$0.isNumeric || $0 == .pid } ?? true
            }
        }
    }

    /// Whole-system totals above the resource columns, as in Windows.
    private func total(_ column: ProcessColumn) -> String? {
        switch column {
        case .cpu: return Theme.percent(monitor.currentTotal)
        case .memory: return Theme.percent(monitor.memory?.usedFraction)
        case .disk: return Theme.percent(monitor.disks.map(\.activeTime).max() ?? 0)
        case .network:
            let rate = monitor.networks.map { $0.receiveRate + $0.sendRate }.reduce(0, +)
            let speed = Double(monitor.networks.map(\.counters.linkSpeed).reduce(0, +))
            return speed > 0 ? Theme.percent(rate * 8 / speed) : Theme.megabitRate(rate)
        default: return nil
        }
    }

    // MARK: Data

    private var context: ProcessContext {
        ProcessContext(
            totalMemory: Double(monitor.memory?.total ?? 1),
            diskRate: monitor.disks.map { $0.readRate + $0.writeRate }.reduce(0, +),
            diskActive: monitor.disks.map(\.activeTime).max() ?? 0,
            linkSpeed: Double(monitor.networks.map(\.counters.linkSpeed).reduce(0, +)),
            memoryAsPercent: memoryAsPercent,
            diskAsPercent: diskAsPercent,
            networkAsPercent: networkAsPercent
        )
    }

    private var sections: [ListSection] {
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
            search.isEmpty || group.all.contains { $0.name.localizedCaseInsensitiveContains(search) || "\($0.id)" == search }
        }
        let shownApps = sorted(apps.filter(matches))
        let shownBackground = sorted(background.filter(matches))
        guard groupByType else { return [ListSection(groups: sorted(shownApps + shownBackground))] }
        return [ListSection(title: "Apps (\(shownApps.count))", groups: shownApps),
                ListSection(title: "Background processes (\(shownBackground.count))", groups: shownBackground)]
    }

    private func group(for id: pid_t?, in sections: [ListSection]) -> ProcessGroup? {
        guard let id else { return nil }
        for group in sections.flatMap(\.groups) {
            if group.id == id { return group }
            if let child = group.children.first(where: { $0.id == id }) { return ProcessGroup(main: child, children: []) }
        }
        return nil
    }

    private func sorted(_ groups: [ProcessGroup]) -> [ProcessGroup] {
        let context = self.context
        let column = sortColumn
        let isOrdered = { (a: ProcessGroup, b: ProcessGroup) -> Bool in
            if let column, column.isNumeric || column == .energy {
                return (a.sortValue(column) ?? -1) < (b.sortValue(column) ?? -1)
            }
            let text = { (group: ProcessGroup) in column.map { group.cell($0, context).text } ?? group.main.name }
            return text(a).localizedCaseInsensitiveCompare(text(b)) == .orderedAscending
        }
        // Swap the operands for descending: negating would make ties compare true both ways.
        return groups.sorted { ascending ? isOrdered($0, $1) : isOrdered($1, $0) }
    }

    private func sorted(_ rows: [ProcessRow]) -> [ProcessRow] {
        sorted(rows.map { ProcessGroup(main: $0, children: []) }).map(\.main)
    }
}

/// One row: disclosure chevron, icon and name, then a cell per visible column.
private struct ProcessLine: View {
    private static let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    var group: ProcessGroup
    var title: String
    var icon: NSImage?
    var indent: Int
    /// nil: no children; true/false: expanded or collapsed.
    var disclosure: Bool?
    var columns: [ProcessColumn]
    var context: ProcessContext
    var isSelected: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                if let disclosure {
                    Button(action: toggle) {
                        Fluent(.chevronRight, size: 10)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(disclosure ? 90 : 0))
                            .frame(width: DS.Size.icon, height: DS.Size.listRow)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: DS.Size.icon, height: DS.Size.listRow)
                }

                Image(nsImage: icon ?? Self.genericIcon)
                    .resizable()
                    .frame(width: DS.Size.icon, height: DS.Size.icon)
                Text(title).font(DS.Typeface.body)
            }
            .padding(.leading, DS.Space.s + CGFloat(indent) * (DS.Size.icon + DS.Space.s))
            .frame(minWidth: DS.Size.nameColumnMin, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(columns) { cell($0) }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: DS.Size.listRow)
        .rowHighlight(isSelected: isSelected)
    }

    /// Fonts and line limits are set once per list (see `rows`) rather than on each cell:
    /// every modifier here is repeated for each column of each realized row.
    @ViewBuilder
    private func cell(_ column: ProcessColumn) -> some View {
        let value = group.cell(column, context)
        switch column {
        case .status:
            HStack(spacing: DS.Space.xs) {
                if let status = group.main.status {
                    Fluent(status == .efficiency ? .efficiency : .pause, size: DS.Size.icon)
                        .foregroundStyle(status == .efficiency ? DS.Palette.efficiency : .secondary)
                }
                Text(value.text)
            }
            .modifier(CellFrame(column: column, heat: value.heat))
        case .path:
            Text(value.text)
                .truncationMode(.middle)
                .modifier(CellFrame(column: column, heat: value.heat))
                .help(value.text)
        default:
            Text(value.text)
                .minimumScaleFactor(column.isNumeric ? 0.6 : 1)
                .modifier(CellFrame(column: column, heat: value.heat))
        }
    }
}

private struct CellFrame: ViewModifier {
    var column: ProcessColumn
    var heat: Double?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DS.Space.s)
            .frame(width: column.width - 2, height: DS.Size.listRow, alignment: column.isNumeric ? .trailing : .leading)
            .background(heat.map { DS.Palette.heat($0) } ?? .clear)
    }
}

/// Windows' Properties, as a sheet: where the process lives, who runs it and how it was started.
private struct ProcessPropertiesView: View {
    var row: ProcessRow

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let arguments = ProcessSampler.arguments(row.id)
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(spacing: DS.Space.m) {
                Image(nsImage: row.icon ?? NSWorkspace.shared.icon(for: .unixExecutable))
                    .resizable()
                    .frame(width: 32, height: 32)
                Text(row.name).font(DS.Typeface.pageTitle).lineLimit(1)
            }
            InfoTable(rows: [
                ("PID", "\(row.id)"),
                ("Parent PID", "\(row.parentPID)"),
                ("User name", row.user),
                ("Started", row.startTime?.formatted(date: .abbreviated, time: .standard) ?? "Unknown"),
                ("Architecture", row.architecture),
                ("Threads", row.threads.map(String.init) ?? "Unknown"),
            ])
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Location").font(DS.Typeface.bodyStrong)
                Text(row.path ?? "Unavailable").textSelection(.enabled)
                    .font(DS.Typeface.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Command line").font(DS.Typeface.bodyStrong)
                ScrollView {
                    Text(arguments?.joined(separator: " ") ?? "Unavailable: the process belongs to another user.")
                        .font(DS.Typeface.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s)
                }
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.fieldBackground))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.stroke))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 560)
    }
}

/// Feeds key presses to the Processes list while it's on screen, except while typing
/// in a text field or when a sheet or alert is up. (`onKeyPress` needs macOS 14.)
private final class KeyMonitor: ObservableObject {
    var handler: (NSEvent) -> Bool = { _ in false }
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window, window.attachedSheet == nil, window.sheetParent == nil,
                  !(window.firstResponder is NSText) else { return event }
            return self.handler(event) ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Windows' "Search online": opens a web search for a process or service name.
enum SearchOnline {
    static func open(_ name: String) {
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        if let url = components.url { NSWorkspace.shared.open(url) }
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
