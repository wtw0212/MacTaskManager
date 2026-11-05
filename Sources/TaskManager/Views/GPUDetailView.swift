import SwiftUI

struct GPUDetailView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor
    var gpu: GPUState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ResourceHeader(title: "GPU", subtitle: gpu.reading.name)

            LabeledGraph(title: "Utilization", values: gpu.history, color: DS.Palette.gpu)

            // Apple Silicon also reports the renderer (3D) and tiler stages separately.
            if gpu.reading.renderer != nil || gpu.reading.tiler != nil {
                HStack(spacing: DS.Space.l) {
                    LabeledGraph(title: "Renderer", values: gpu.rendererHistory, color: DS.Palette.gpu)
                    LabeledGraph(title: "Tiler", values: gpu.tilerHistory, color: DS.Palette.gpu)
                }
                .frame(height: 130)
            }

            StatsArea(info: infoRows) {
                GridRow {
                    Stat(label: "Utilization", value: Theme.percent(gpu.reading.utilization))
                    Stat(label: "GPU memory in use", value: Theme.bytes(gpu.reading.memoryInUse))
                    Stat(label: monitor.temperature.gpuIsSoC ? "SoC temperature" : "GPU temperature",
                         value: Theme.temperature(monitor.temperature.gpu))
                }
            }
        }
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let cores = gpu.reading.coreCount { rows.append(("GPU cores:", "\(cores)")) }
        rows.append(("Renderer:", Theme.percent(gpu.reading.renderer)))
        rows.append(("Tiler:", Theme.percent(gpu.reading.tiler)))
        return rows
    }
}
