import SwiftUI

struct MemoryDetailView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor

    var body: some View {
        let memory = monitor.memory
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ResourceHeader(title: "Memory", subtitle: memory.map { "\(Theme.gigabytes($0.total)) unified memory" } ?? "")

            LabeledGraph(
                title: "Memory usage",
                values: monitor.memoryHistory,
                color: DS.Palette.memory,
                topLabel: memory.map { Theme.gigabytes($0.total) } ?? "100%"
            )

            if let memory {
                VStack(spacing: DS.Space.xs) {
                    CaptionRow(leading: "Memory composition", trailing: "")
                    CompositionBar(memory: memory).frame(height: 40)
                }

                StatsArea(info: [
                    ("App memory:", Theme.bytes(memory.app)),
                    ("Wired memory:", Theme.bytes(memory.wired)),
                    ("Compressed:", Theme.bytes(memory.compressed)),
                    ("Cached files:", Theme.bytes(memory.cached)),
                ]) {
                    GridRow {
                        Stat(label: "In use (Compressed)", value: "\(Theme.gigabytes(memory.used)) (\(Theme.bytes(memory.compressed)))")
                        Stat(label: "Available", value: Theme.gigabytes(memory.available))
                    }
                    GridRow {
                        Stat(label: "Memory pressure", value: pressureLabel(memory.pressureLevel))
                        Stat(label: "Swap used", value: "\(Theme.bytes(memory.swapUsed)) / \(Theme.bytes(memory.swapTotal))")
                    }
                }
            }
        }
    }

    private func pressureLabel(_ level: Int?) -> String {
        switch level {
        case 1: "Normal"
        case 2: "Warning"
        case 4: "Critical"
        default: "N/A"
        }
    }
}

/// Stacked bar like Windows' memory composition: wired, app, compressed, cached, free.
private struct CompositionBar: View {
    var memory: MemoryReading

    var body: some View {
        let total = Double(max(memory.total, 1))
        let cached = min(memory.cached, memory.available)
        let parts: [(String, UInt64, Double)] = [
            ("Wired", memory.wired, 0.55),
            ("App memory", memory.app, 0.35),
            ("Compressed", memory.compressed, 0.22),
            ("Cached files", cached, 0.10),
            ("Free", memory.available - cached, 0.0),
        ]
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(parts, id: \.0) { part in
                    Rectangle()
                        .fill(DS.Palette.memory.opacity(part.2))
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(DS.Palette.memory).frame(width: 1)
                        }
                        .frame(width: max(proxy.size.width * CGFloat(Double(part.1) / total), 0))
                        .help("\(part.0): \(Theme.bytes(part.1))")
                }
            }
            .overlay(Rectangle().stroke(DS.Palette.memory, lineWidth: 1))
        }
    }
}
