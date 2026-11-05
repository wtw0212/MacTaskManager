import SwiftUI

struct GPUDetailView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor
    var gpu: GPUState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: "GPU", subtitle: gpu.reading.name)

            LabeledGraph(title: "Utilization", values: gpu.history, color: Theme.gpu)

            // Apple Silicon also reports the renderer (3D) and tiler stages separately.
            if gpu.reading.renderer != nil || gpu.reading.tiler != nil {
                HStack(spacing: 16) {
                    LabeledGraph(title: "Renderer", values: gpu.rendererHistory, color: Theme.gpu)
                    LabeledGraph(title: "Tiler", values: gpu.tilerHistory, color: Theme.gpu)
                }
                .frame(height: 140)
            }

            HStack(alignment: .top, spacing: 28) {
                Stat(label: "Utilization", value: Theme.percent(gpu.reading.utilization), large: true)
                Stat(label: "GPU memory in use", value: Theme.bytes(gpu.reading.memoryInUse), large: true)
                if let celsius = monitor.temperature.gpu {
                    Stat(label: "Temperature", value: Theme.temperature(celsius), large: true)
                } else if let celsius = monitor.temperature.cpu {
                    // Newer chips (e.g. M5) expose only shared SoC die sensors, no GPU-specific one.
                    Stat(label: "SoC temperature", value: Theme.temperature(celsius), large: true)
                }
                if let cores = gpu.reading.coreCount {
                    Stat(label: "GPU cores", value: "\(cores)", large: true)
                }
                Spacer()
            }
        }
    }
}
