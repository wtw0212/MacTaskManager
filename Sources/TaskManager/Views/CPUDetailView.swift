import SwiftUI

struct CPUDetailView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case logical = "Logical processors"
        case overall = "Overall utilization"
        var id: Self { self }
    }

    @EnvironmentObject private var monitor: PerformanceMonitor
    @AppStorage("cpuGraphMode") private var mode: Mode = .logical
    @AppStorage(AppPreferences.graphSummaryKey) private var summary = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ResourceHeader(title: "CPU", subtitle: SystemInfo.cpuName)

            VStack(spacing: DS.Space.xs) {
                CaptionRow(leading: "% Utilization over \(monitor.historySeconds) seconds", trailing: "100%")
                Group {
                    switch mode {
                    case .overall:
                        UsageGraph(values: monitor.totalHistory, color: DS.Palette.cpu)
                    case .logical:
                        GroupedCoreGrid(groups: monitor.coreGroups, histories: monitor.coreHistories)
                    }
                }
                // Same as Windows: right-click the graph to switch views.
                .contextMenu {
                    Picker("Change graph to", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    PerformanceCopy.menuItems(summary: $summary)
                }
                CaptionRow(leading: "Right-click to change graph", trailing: "0")
            }

            StatsArea(info: infoRows) {
                GridRow {
                    Stat(label: "Utilization", value: Theme.percent(monitor.currentTotal))
                    Stat(label: "Temperature", value: Theme.temperature(monitor.temperature.cpu))
                    ForEach(monitor.coreGroups.prefix(2)) { group in
                        Stat(label: monitor.coreGroups.count > 1 ? "\(group.name) cores" : "All cores",
                             value: Theme.percent(monitor.utilization(of: group)))
                    }
                }
                GridRow {
                    Stat(label: "Processes", value: "\(monitor.processCount)")
                    Stat(label: "Threads", value: monitor.threadCount.map(String.init) ?? "–")
                    // Every process's open files need the helper; without it the total would be partial.
                    Stat(label: "Handles", value: monitor.handleCount.map(String.init) ?? "–")
                        .help(monitor.handleCount == nil ? "Install the helper in Settings to count every process's open files." : "")
                }
                GridRow {
                    Stat(label: "Up time", value: Theme.uptime(monitor.uptime))
                }
            }
        }
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if monitor.coreGroups.count > 1 {
            for group in monitor.coreGroups {
                rows.append(("\(group.name) cores:", "\(group.cores.count)"))
            }
        } else if let cores = SystemInfo.physicalCores {
            rows.append(("Cores:", "\(cores)"))
        }
        rows.append(("Logical processors:", "\(monitor.coreHistories.count)"))
        rows.append(("Sockets:", "\(SystemInfo.sockets)"))
        rows.append(("Virtualization:", SystemInfo.virtualization))
        let caches = SystemInfo.cacheSizes
        for (name, size) in [("L1 cache:", caches.l1), ("L2 cache:", caches.l2), ("L3 cache:", caches.l3)] where size > 0 {
            rows.append((name, Theme.cacheSize(size)))
        }
        rows.append(("Thermal state:", monitor.thermalState.label))
        return rows
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious (throttling)"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

/// One section per core type (e.g. Super, Performance), each a grid of per-core graphs,
/// sized to fill the available space.
private struct GroupedCoreGrid: View {
    var groups: [CoreGroup]
    var histories: [[Double]]

    private let spacing: CGFloat = DS.Space.xs
    private let headerHeight: CGFloat = 16
    private let sectionSpacing: CGFloat = DS.Space.m

    var body: some View {
        GeometryReader { proxy in
            let columns = bestColumnCount(for: proxy.size)
            let rows = groups.map { rowCount(for: $0, columns: columns) }
            let totalRows = max(rows.reduce(0, +), 1)
            let showHeaders = groups.count > 1
            let fixed = (showHeaders ? CGFloat(groups.count) * (headerHeight + DS.Space.xs) : 0)
                + sectionSpacing * CGFloat(groups.count - 1)
                + spacing * CGFloat(max(totalRows - groups.count, 0))
            let cellHeight = max((proxy.size.height - fixed) / CGFloat(totalRows), 20)
            let cellWidth = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)

            VStack(alignment: .leading, spacing: sectionSpacing) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        if showHeaders {
                            CaptionRow(leading: "\(group.name) cores (\(group.cores.count))", trailing: Theme.percent(average(group)))
                                .frame(width: proxy.size.width, height: headerHeight)
                        }
                        cells(for: group, rows: rows[index], columns: columns, width: cellWidth, height: cellHeight)
                    }
                }
            }
        }
    }

    private func cells(for group: CoreGroup, rows: Int, columns: Int, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        let position = row * columns + column
                        if position < group.cores.count {
                            let core = group.cores[position]
                            UsageGraph(values: core < histories.count ? histories[core] : [], color: DS.Palette.cpu)
                                .frame(width: width, height: height)
                                .help("CPU \(core)")
                        }
                    }
                }
            }
        }
    }

    private func average(_ group: CoreGroup) -> Double {
        let values = group.cores.compactMap { $0 < histories.count ? histories[$0].last : nil }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func rowCount(for group: CoreGroup, columns: Int) -> Int {
        Int((Double(group.cores.count) / Double(columns)).rounded(.up))
    }

    /// Picks the column count that makes each cell closest to a 2:1 shape while leaving
    /// few empty slots at the end of each section.
    private func bestColumnCount(for size: CGSize) -> Int {
        let largest = max(groups.map(\.cores.count).max() ?? 1, 1)
        guard size.width > 0, size.height > 0 else { return largest }
        var best = largest
        var bestScore = Double.infinity
        for columns in 1...largest {
            let rows = groups.map { rowCount(for: $0, columns: columns) }.reduce(0, +)
            let aspect = (size.width / CGFloat(columns)) / (size.height / CGFloat(max(rows, 1)))
            let empty = Double(rows * columns - groups.map(\.cores.count).reduce(0, +)) / Double(rows * columns)
            let score = abs(log(Double(aspect) / 2)) + 3 * empty
            if score < bestScore {
                bestScore = score
                best = columns
            }
        }
        return best
    }
}
