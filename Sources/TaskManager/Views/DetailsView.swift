import AppKit
import SwiftUI

/// Windows' Details page: every process on its own row (no grouping), with PID, status, user,
/// priority and handles, and the low-level actions: End process tree and Set priority.
struct DetailsView: View {
    var search: String

    @EnvironmentObject private var monitor: PerformanceMonitor
    @StateObject private var keys = KeyMonitor()
    @AppStorage(DetailsNavigation.selectionKey) private var storedSelection = 0
    @State private var sortColumn: ProcessColumn? = .cpu
    @State private var ascending = false
    @State private var alert: ProcessAlert?
    @State private var properties: ProcessRow?
    @AppStorage("detailsHiddenColumns") private var hiddenColumns = "disk,diskRead,diskWrite,network,gpu,gpuEngine,energy"
    @AppStorage("memoryAsPercent") private var memoryAsPercent = false

    private var selection: pid_t? { storedSelection == 0 ? nil : pid_t(storedSelection) }

    var body: some View {
        let rows = self.rows
        let columns = self.columns
        let context = self.context
        let selected = selection.flatMap { id in rows.first { $0.id == id } }
        let _ = keys.handler = { handleKey($0, rows) }

        VStack(spacing: 0) {
            PageHeader(title: "Details") {
                CommandButton(title: "Run new task", icon: .runTask) { RunNewTask.present() }
                CommandButton(title: "End task", icon: .endTask) {
                    if let selected { ProcessSampler.terminate(selected.id, force: false) }
                }
                .disabled(selected == nil)
                CommandButton(title: "Efficiency mode", icon: .efficiency, isOn: selected?.status == .efficiency) {
                    if let selected { setEfficiency(selected, selected.status != .efficiency) }
                }
                .disabled(selected == nil)
            }
            HelperBanner()

            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        columnHeaders(columns)
                        Rectangle().fill(DS.Palette.stroke).frame(height: 1)
                        list(rows, columns, context)
                    }
                    .frame(width: max(geometry.size.width, minimumWidth(columns)), height: geometry.size.height)
                }
            }
        }
        .processAlert($alert)
        .sheet(item: $properties) { ProcessPropertiesView(row: $0) }
        .onAppear { keys.start() }
        .onDisappear { keys.stop() }
    }

    // MARK: Rows

    private func list(_ rows: [ProcessRow], _ columns: [ProcessColumn], _ context: ProcessContext) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        ProcessLine(group: ProcessGroup(main: row, children: []), title: row.name, icon: row.icon,
                                    indent: 0, disclosure: nil, columns: columns, context: context,
                                    isSelected: selection == row.id, toggle: {})
                            .id(row.id)
                            .onTapGesture { storedSelection = Int(row.id) }
                            .contextMenu { menu(for: row) }
                    }
                }
                .padding(DS.Space.s)
                .padding(.bottom, DS.Space.s)
                .font(DS.Typeface.body.monospacedDigit())
                .lineLimit(1)
            }
            .onAppear {
                // Arriving from "Go to details" on another page.
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
            .onChange(of: storedSelection) { id in
                if id != 0 { proxy.scrollTo(pid_t(id)) }
            }
        }
    }

    @ViewBuilder
    private func menu(for row: ProcessRow) -> some View {
        Button("End task") { ProcessSampler.terminate(row.id, force: false) }
        Button("End process tree") { alert = .endProcessTree(row) { monitor.refreshProcesses() } }
        Divider()
        Toggle("Efficiency mode", isOn: Binding(get: { row.status == .efficiency }, set: { setEfficiency(row, $0) }))
        Button(row.status == .suspended ? "Resume" : "Suspend…") { suspend(row, row.status != .suspended) }
        Menu("Set priority") {
            let current = PriorityClass(nice: row.nice)
            ForEach(PriorityClass.allCases) { priority in
                Toggle(priority.rawValue, isOn: Binding(get: { current == priority },
                                                        set: { if $0 { confirmPriority(row, priority) } }))
            }
        }
        // macOS has no API to pin a process to cores; shown disabled so it's clear why it's missing.
        Button("Set affinity (not available on macOS)") {}.disabled(true)
        Divider()
        if let path = row.path {
            Button("Open file location") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        Button("Search online") { SearchOnline.open(row.name) }
        Button("Copy details") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ProcessGroup(main: row, children: []).details(columns, context), forType: .string)
        }
        Button("Properties") { properties = row }
    }

    // MARK: Actions

    private func setEfficiency(_ row: ProcessRow, _ on: Bool) {
        if let error = ProcessSampler.setEfficiency(row.id, on) {
            alert = ProcessAlert(title: "Couldn't change efficiency mode",
                                 message: "\(row.name): \(error). It belongs to \(row.user); install the helper in Settings to change other users' processes.")
        }
        monitor.refreshProcesses()
    }

    private func suspend(_ row: ProcessRow, _ suspend: Bool) {
        let apply = {
            if let error = ProcessSampler.setSuspended(row.id, suspend) {
                alert = ProcessAlert(title: "Couldn't \(suspend ? "suspend" : "resume") \(row.name)",
                                     message: "\(error). It belongs to \(row.user).")
            }
            monitor.refreshProcesses()
        }
        guard suspend else { return apply() }
        alert = ProcessAlert(
            title: "Suspend \(row.name)?",
            message: "It stops running until you choose Resume. Anything that depends on it may stall.",
            confirm: "Suspend",
            action: apply
        )
    }

    /// Windows asks before changing a priority, and warns about Realtime.
    private func confirmPriority(_ row: ProcessRow, _ priority: PriorityClass) {
        let warning = priority == .realtime
            ? " Realtime gives it the highest priority macOS allows (nice -20); it can make the rest of the system less responsive."
            : ""
        alert = ProcessAlert(
            title: "Change the priority of \(row.name)?",
            message: "Changing the priority of some processes can make the system unstable.\(warning) Raising a priority, or changing another user's process, needs the helper (Settings).",
            confirm: "Change priority",
            action: {
                if let error = ProcessSampler.setNice(row.id, priority.nice) {
                    alert = ProcessAlert(title: "Couldn't change the priority of \(row.name)", message: error)
                }
                monitor.refreshProcesses()
            }
        )
    }

    // MARK: Keyboard

    /// Delete ends the task; the arrow keys move the selection.
    private func handleKey(_ event: NSEvent, _ rows: [ProcessRow]) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            guard let selection else { return false }
            ProcessSampler.terminate(selection, force: false)
        case 125, 126: // Down, Up
            guard !rows.isEmpty else { return false }
            let step = event.keyCode == 125 ? 1 : -1
            let index = selection.flatMap { id in rows.firstIndex { $0.id == id } }.map { min(max($0 + step, 0), rows.count - 1) } ?? 0
            storedSelection = Int(rows[index].id)
        default:
            return false
        }
        return true
    }

    // MARK: Columns

    private static let available: [ProcessColumn] = [.pid, .status, .user, .cpu, .memory, .disk, .diskRead, .diskWrite,
                                                     .network, .gpu, .gpuEngine, .energy, .threads, .handles, .priority,
                                                     .architecture, .description, .path]

    private var columns: [ProcessColumn] {
        let hidden = Set(hiddenColumns.split(separator: ",").map(String.init))
        return Self.available.filter { !hidden.contains($0.rawValue) }
    }

    private func minimumWidth(_ columns: [ProcessColumn]) -> CGFloat {
        DS.Size.nameColumnMin + columns.map(\.width).reduce(0, +) + DS.Space.s * 2
    }

    private func columnHeaders(_ columns: [ProcessColumn]) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            header(nil, title: "Name")
                .padding(.leading, DS.Space.xl)
                .frame(minWidth: DS.Size.nameColumnMin)
            ForEach(columns) { column in
                header(column, title: column.title).frame(width: column.width)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
        .contextMenu {
            ForEach(Self.available) { column in
                Toggle(column.title, isOn: Binding(
                    get: { columns.contains(column) },
                    set: { show in
                        let hidden = Self.available.filter { $0 == column ? !show : !columns.contains($0) }
                        hiddenColumns = hidden.map(\.rawValue).joined(separator: ",")
                    }
                ))
            }
        }
    }

    private func header(_ column: ProcessColumn?, title: String) -> some View {
        ColumnHeader(title: title, alignment: column?.isNumeric == true ? .trailing : .leading,
                     isSorted: sortColumn == column, ascending: ascending) {
            if sortColumn == column {
                ascending.toggle()
            } else {
                sortColumn = column
                ascending = column.map { !$0.sortsByValue || $0 == .pid } ?? true
            }
        }
    }

    // MARK: Data

    private var context: ProcessContext {
        var context = ProcessContext(monitor: monitor, memoryAsPercent: memoryAsPercent, diskAsPercent: false,
                                     networkAsPercent: false)
        context.showsRunning = true
        return context
    }

    private var rows: [ProcessRow] {
        let shown = monitor.processes.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || "\($0.id)" == search
                || $0.description.localizedCaseInsensitiveContains(search)
        }
        return ProcessGroup.sorted(shown.map { ProcessGroup(main: $0, children: []) }, by: sortColumn,
                                   ascending: ascending, context: context).map(\.main)
    }
}
