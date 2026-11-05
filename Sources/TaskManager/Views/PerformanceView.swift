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
    @State private var selection: Resource = .cpu

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Performance") {
                CommandButton(title: "Run new task", icon: .runTask) { RunNewTask.present() }
            }

            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: DS.Space.xxs) { tiles }
                        .padding(DS.Space.s)
                }
                .frame(width: DS.Size.resourceList)

                Rectangle().fill(DS.Palette.stroke).frame(width: 1)

                detail
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Resource tiles

    @ViewBuilder
    private var tiles: some View {
        tile(.cpu, "CPU", [cpuSubtitle], monitor.totalHistory, DS.Palette.cpu)

        if let memory = monitor.memory {
            tile(.memory, "Memory",
                 ["\(Theme.gigabytes(memory.used, unit: false))/\(Theme.gigabytes(memory.total)) (\(Theme.percent(memory.usedFraction)))"],
                 monitor.memoryHistory, DS.Palette.memory)
        }

        ForEach(Array(monitor.disks.enumerated()), id: \.element.id) { index, disk in
            tile(.disk(disk.id), "Disk \(index) (\(disk.id))",
                 [disk.counters.isInternal == false ? "External" : "SSD", Theme.percent(disk.activeTime)],
                 disk.activeHistory, DS.Palette.disk)
        }

        ForEach(monitor.networks) { network in
            tile(.network(network.id), network.displayName,
                 [network.id, rates(network)],
                 network.receiveHistory, DS.Palette.network,
                 secondary: network.sendHistory, maxValue: networkScale(network))
        }

        ForEach(monitor.gpus) { gpu in
            tile(.gpu(gpu.id), "GPU \(gpu.id)", [gpu.reading.name, gpuSubtitle(gpu)], gpu.history, DS.Palette.gpu)
        }
    }

    private func tile(_ resource: Resource, _ title: String, _ lines: [String], _ values: [Double], _ color: Color,
                      secondary: [Double]? = nil, maxValue: Double = 1) -> some View {
        ResourceTile(title: title, lines: lines, values: values, color: color, secondary: secondary,
                     maxValue: maxValue, isSelected: selection == resource)
            .onTapGesture { selection = resource }
    }

    private var cpuSubtitle: String {
        let temperature = monitor.temperature.cpu.map { "  \(Theme.temperature($0))" } ?? ""
        return Theme.percent(monitor.currentTotal) + temperature
    }

    private func gpuSubtitle(_ gpu: GPUState) -> String {
        let temperature = monitor.temperature.gpu.map { " (\(Theme.temperature($0)))" } ?? ""
        return Theme.percent(gpu.reading.utilization) + temperature
    }

    /// "S: 8.0  R: 16.4 Kbps": like Windows, the unit is printed once when both rates share it,
    /// so the line fits the tile.
    private func rates(_ network: NetworkState) -> String {
        let send = Theme.bitRate(network.sendRate), receive = Theme.bitRate(network.receiveRate)
        let unit = { (rate: String) in rate.split(separator: " ").last ?? "" }
        let sendValue = unit(send) == unit(receive) ? String(send.dropLast(unit(send).count + 1)) : send
        return "S: \(sendValue)  R: \(receive)"
    }

    private func networkScale(_ network: NetworkState) -> Double {
        Theme.niceScale(max(network.receiveHistory.max() ?? 0, network.sendHistory.max() ?? 0), minimum: 12_500)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .memory:
            MemoryDetailView()
        case .disk(let id):
            if let index = monitor.disks.firstIndex(where: { $0.id == id }) {
                DiskDetailView(disk: monitor.disks[index], index: index)
            } else {
                CPUDetailView()
            }
        case .network(let id):
            if let network = monitor.networks.first(where: { $0.id == id }) {
                NetworkDetailView(network: network, scale: networkScale(network))
            } else {
                CPUDetailView()
            }
        case .gpu(let index) where index < monitor.gpus.count:
            GPUDetailView(gpu: monitor.gpus[index])
        default:
            CPUDetailView()
        }
    }
}

/// Windows-style resource tile: boxed mini graph, title, and one or two detail lines.
private struct ResourceTile: View {
    var title: String
    var lines: [String]
    var values: [Double]
    var color: Color
    var secondary: [Double]?
    var maxValue: Double
    var isSelected: Bool

    var body: some View {
        HStack(spacing: DS.Space.m) {
            UsageGraph(values: values, color: color, secondary: secondary, maxValue: maxValue, showsGrid: false)
                .frame(width: DS.Size.tileGraph.width, height: DS.Size.tileGraph.height)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Typeface.tileTitle)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .frame(height: DS.Size.tileGraph.height) // every tile the same height, whatever its line count
        .padding(DS.Space.s)
        .rowHighlight(isSelected: isSelected)
    }
}
