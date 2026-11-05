import SwiftUI

enum Resource: Hashable {
    case cpu
    case memory
    case disk(String)
    case network(String)
    case gpu(Int)
}

struct PerformanceView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor
    @State private var selection: Resource? = .cpu

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                SidebarRow(title: "CPU", subtitle: cpuSubtitle, values: monitor.totalHistory, color: Theme.cpu)
                    .tag(Resource.cpu)

                if let memory = monitor.memory {
                    SidebarRow(
                        title: "Memory",
                        subtitle: "\(Theme.gigabytes(memory.used))/\(Theme.gigabytes(memory.total)) (\(Theme.percent(memory.usedFraction)))",
                        values: monitor.memoryHistory,
                        color: Theme.memory
                    )
                    .tag(Resource.memory)
                }

                ForEach(Array(monitor.disks.enumerated()), id: \.element.id) { index, disk in
                    SidebarRow(
                        title: "Disk \(index) (\(disk.id))",
                        subtitle: "\(disk.counters.name)\n\(Theme.percent(disk.activeTime))",
                        values: disk.activeHistory,
                        color: Theme.disk
                    )
                    .tag(Resource.disk(disk.id))
                }

                ForEach(monitor.networks) { network in
                    SidebarRow(
                        title: network.displayName,
                        subtitle: "\(network.id)\nS: \(Theme.bitRate(network.sendRate)) R: \(Theme.bitRate(network.receiveRate))",
                        values: network.receiveHistory,
                        color: Theme.network,
                        secondary: network.sendHistory,
                        maxValue: Theme.niceScale(max(network.receiveHistory.max() ?? 0, network.sendHistory.max() ?? 0), minimum: 12_500)
                    )
                    .tag(Resource.network(network.id))
                }

                ForEach(monitor.gpus) { gpu in
                    SidebarRow(
                        title: monitor.gpus.count > 1 ? "GPU \(gpu.id)" : "GPU",
                        subtitle: "\(gpu.reading.name)\n\(Theme.percent(gpu.reading.utilization))",
                        values: gpu.history,
                        color: Theme.gpu
                    )
                    .tag(Resource.gpu(gpu.id))
                }
            }
            .listStyle(.sidebar)
            .frame(width: 250)

            Divider()

            detail
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var cpuSubtitle: String {
        var text = Theme.percent(monitor.currentTotal)
        if let celsius = monitor.temperature.cpu {
            text += "  \(Theme.temperature(celsius))"
        }
        return text
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .some(.memory):
            MemoryDetailView()
        case .some(.disk(let id)):
            if let disk = monitor.disks.first(where: { $0.id == id }) {
                DiskDetailView(disk: disk, index: monitor.disks.firstIndex { $0.id == id } ?? 0)
            } else {
                CPUDetailView()
            }
        case .some(.network(let id)):
            if let network = monitor.networks.first(where: { $0.id == id }) {
                NetworkDetailView(network: network)
            } else {
                CPUDetailView()
            }
        case .some(.gpu(let index)) where index < monitor.gpus.count:
            GPUDetailView(gpu: monitor.gpus[index])
        default:
            CPUDetailView()
        }
    }
}

private struct SidebarRow: View {
    var title: String
    var subtitle: String
    var values: [Double]
    var color: Color
    var secondary: [Double]? = nil
    var maxValue: Double = 1

    var body: some View {
        HStack(spacing: 10) {
            UsageGraph(values: values, color: color, secondary: secondary, maxValue: maxValue, showsGrid: false)
                .frame(width: 64, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
