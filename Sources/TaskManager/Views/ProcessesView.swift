import AppKit
import SwiftUI

struct ProcessesView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case apps = "Apps"
        case background = "Background processes"
        var id: Self { self }
    }

    @EnvironmentObject private var monitor: PerformanceMonitor
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var selection: ProcessRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()
                Text("CPU \(Theme.percent(monitor.currentTotal))")
                Text("Memory \(Theme.percent(monitor.memory?.usedFraction))")
                Button("End task") { endSelected(force: false) }
                    .disabled(selection == nil)
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .monospacedDigit()
            .padding(10)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 6) {
                        Image(nsImage: row.icon ?? Self.genericIcon)
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(row.name)
                    }
                }
                .width(min: 180, ideal: 280)
                TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit() }
                    .width(60)
                TableColumn("CPU", value: \.cpu) { row in
                    Text(row.cpu < 0 ? "–" : String(format: "%.1f%%", row.cpu * 100))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(70)
                TableColumn("Memory", value: \.memory) { row in
                    Text(row.memory == 0 ? "–" : Theme.bytes(row.memory))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(90)
                TableColumn("Threads") { row in
                    Text(row.threads.map(String.init) ?? "–")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(60)
                TableColumn("Type") { row in
                    Text(row.isApp ? "App" : "Background")
                        .foregroundStyle(.secondary)
                }
                .width(90)
            }
            .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
                if let pid = ids.first {
                    Button("End task") { ProcessSampler.terminate(pid, force: false) }
                    Button("Force quit") { ProcessSampler.terminate(pid, force: true) }
                    if let path = monitor.processes.first(where: { $0.id == pid })?.path {
                        Divider()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .onAppear { monitor.samplesProcesses = true }
        .onDisappear { monitor.samplesProcesses = false }
        .overlay(alignment: .bottomLeading) {
            Text("CPU and memory of processes owned by other users (such as root) need administrator rights to read.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private static let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    private var rows: [ProcessRow] {
        monitor.processes
            .filter { row in
                switch filter {
                case .all: true
                case .apps: row.isApp
                case .background: !row.isApp
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || "\($0.pid)" == search }
            .sorted(using: sortOrder)
    }

    private func endSelected(force: Bool) {
        guard let pid = selection else { return }
        ProcessSampler.terminate(pid, force: force)
    }
}
