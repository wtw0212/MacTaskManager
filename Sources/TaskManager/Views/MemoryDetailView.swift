import SwiftUI

struct MemoryDetailView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor

    var body: some View {
        let memory = monitor.memory
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: "Memory", subtitle: memory.map { "\(Theme.gigabytes($0.total)) unified memory" } ?? "")

            LabeledGraph(
                title: "Memory usage",
                values: monitor.memoryHistory,
                color: Theme.memory,
                topLabel: memory.map { Theme.gigabytes($0.total) } ?? "100%"
            )

            if let memory {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory composition").font(.caption).foregroundStyle(.secondary)
                    CompositionBar(memory: memory)
                        .frame(height: 44)
                }

                HStack(alignment: .top, spacing: 40) {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                        GridRow {
                            Stat(label: "In use (Compressed)", value: "\(Theme.gigabytes(memory.used)) (\(Theme.bytes(memory.compressed)))", large: true)
                            Stat(label: "Available", value: Theme.gigabytes(memory.available), large: true)
                        }
                        GridRow {
                            Stat(label: "Memory pressure", value: pressureLabel(memory.pressureLevel), large: true)
                            Stat(label: "Swap used", value: "\(Theme.bytes(memory.swapUsed)) / \(Theme.bytes(memory.swapTotal))", large: true)
                        }
                    }
                    InfoList(rows: [
                        ("App memory:", Theme.bytes(memory.app)),
                        ("Wired memory:", Theme.bytes(memory.wired)),
                        ("Compressed:", Theme.bytes(memory.compressed)),
                        ("Cached files:", Theme.bytes(memory.cached)),
                    ])
                    Spacer()
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

/// Stacked bar: wired, app, compressed, cached files, free — like Windows' memory composition.
private struct CompositionBar: View {
    var memory: MemoryReading

    var body: some View {
        let total = Double(max(memory.total, 1))
        let cached = min(memory.cached, memory.available)
        let parts: [(String, UInt64, Double)] = [
            ("Wired", memory.wired, 0.9),
            ("App", memory.app, 0.6),
            ("Compressed", memory.compressed, 0.4),
            ("Cached", cached, 0.18),
            ("Free", memory.available - cached, 0.0),
        ]
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(parts, id: \.0) { part in
                    let width = proxy.size.width * CGFloat(Double(part.1) / total)
                    Rectangle()
                        .fill(Theme.memory.opacity(part.2))
                        .overlay(Rectangle().stroke(Theme.memory.opacity(0.6), lineWidth: 0.5))
                        .frame(width: max(width, 0))
                        .help("\(part.0): \(Theme.bytes(part.1))")
                }
            }
            .overlay(Rectangle().stroke(Theme.memory.opacity(0.8), lineWidth: 1))
        }
    }
}
