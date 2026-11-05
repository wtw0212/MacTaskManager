import SwiftUI

struct CPUDetailView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case logical = "Logical processors"
        case overall = "Overall utilization"
        var id: Self { self }
    }

    @EnvironmentObject private var monitor: PerformanceMonitor
    @AppStorage("cpuGraphMode") private var mode: Mode = .logical

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.largeTitle)
                Spacer()
                Text(SystemInfo.cpuName).font(.title3).foregroundStyle(.secondary)
            }

            HStack {
                Text("% Utilization over \(PerformanceMonitor.historyLength) seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Graph", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            switch mode {
            case .overall:
                UsageGraph(values: monitor.totalHistory, color: Theme.cpu)
            case .logical:
                CoreGrid(histories: monitor.coreHistories)
            }

            stats
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 40) {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    Stat(label: "Utilization", value: Theme.percent(monitor.currentTotal), large: true)
                    Stat(label: "Processes", value: "\(monitor.processCount)", large: true)
                }
                GridRow {
                    Stat(label: "Up time", value: Theme.uptime(monitor.uptime), large: true)
                        .gridCellColumns(2)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if let performance = SystemInfo.performanceCores, let efficiency = SystemInfo.efficiencyCores {
                    info("Performance cores:", "\(performance)")
                    info("Efficiency cores:", "\(efficiency)")
                } else if let cores = SystemInfo.physicalCores {
                    info("Cores:", "\(cores)")
                }
                info("Logical processors:", "\(monitor.coreHistories.count)")
            }
            .font(.callout)
            Spacer()
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// Fills the available space with one small graph per logical core.
private struct CoreGrid: View {
    var histories: [[Double]]
    private let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let count = max(histories.count, 1)
            let grid = layout(count: count, size: proxy.size)
            let columns = grid.columns
            let rows = grid.rows
            let width = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (proxy.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)

            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < histories.count {
                                UsageGraph(values: histories[index], color: Theme.cpu)
                                    .overlay(alignment: .topLeading) {
                                        Text("CPU \(index)  \(Theme.percent(histories[index].last))")
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                            .padding(4)
                                    }
                                    .frame(width: width, height: height)
                            } else {
                                Color.clear.frame(width: width, height: height)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Picks the column count that makes each cell closest to the graph's 2:1 shape.
    private func layout(count: Int, size: CGSize) -> (columns: Int, rows: Int) {
        guard size.width > 0, size.height > 0 else { return (count, 1) }
        var best = (columns: count, rows: 1)
        var bestScore = Double.infinity
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let aspect = (size.width / CGFloat(columns)) / (size.height / CGFloat(rows))
            let score = abs(log(Double(aspect) / 2))
            if score < bestScore {
                bestScore = score
                best = (columns, rows)
            }
        }
        return best
    }
}
