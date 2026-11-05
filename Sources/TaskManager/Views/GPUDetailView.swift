import SwiftUI

struct GPUDetailView: View {
    var gpu: GPUState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("GPU").font(.largeTitle)
                Spacer()
                Text(gpu.reading.name).font(.title3).foregroundStyle(.secondary)
            }

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
                if let cores = gpu.reading.coreCount {
                    Stat(label: "GPU cores", value: "\(cores)", large: true)
                }
                Spacer()
            }
        }
    }
}
