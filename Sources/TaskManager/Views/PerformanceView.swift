import SwiftUI

enum Resource: Hashable {
    case cpu
    case gpu(Int)
}

struct PerformanceView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor
    @State private var selection: Resource? = .cpu

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                SidebarRow(
                    title: "CPU",
                    subtitle: Theme.percent(monitor.currentTotal),
                    values: monitor.totalHistory,
                    color: Theme.cpu
                )
                .tag(Resource.cpu)

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
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            Group {
                switch selection {
                case .some(.gpu(let index)) where index < monitor.gpus.count:
                    GPUDetailView(gpu: monitor.gpus[index])
                default:
                    CPUDetailView()
                }
            }
            .padding(20)
        }
        .navigationTitle("Performance")
    }
}

private struct SidebarRow: View {
    var title: String
    var subtitle: String
    var values: [Double]
    var color: Color

    var body: some View {
        HStack(spacing: 10) {
            UsageGraph(values: values, color: color, showsGrid: false)
                .frame(width: 64, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
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
