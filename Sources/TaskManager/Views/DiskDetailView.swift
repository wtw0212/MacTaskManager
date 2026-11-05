import SwiftUI

struct DiskDetailView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor
    var disk: DiskState
    var index: Int

    var body: some View {
        let scale = Theme.niceScale(max(disk.readHistory.max() ?? 0, disk.writeHistory.max() ?? 0), minimum: 1_000_000)
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: "Disk \(index) (\(disk.id))", subtitle: disk.counters.name)

            LabeledGraph(title: "Active time", values: disk.activeHistory, color: Theme.disk)

            LabeledGraph(
                title: "Disk transfer rate",
                values: disk.readHistory,
                color: Theme.disk,
                secondary: disk.writeHistory,
                maxValue: scale,
                topLabel: Theme.byteRate(scale)
            )
            .frame(height: 150)

            HStack(alignment: .top, spacing: 40) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    GridRow {
                        Stat(label: "Active time", value: Theme.percent(disk.activeTime), large: true)
                        Stat(label: "Read speed", value: Theme.byteRate(disk.readRate), large: true, color: Theme.disk)
                        Stat(label: "Write speed", value: Theme.byteRate(disk.writeRate), large: true, dashed: true, color: Theme.disk)
                    }
                }
                InfoList(rows: infoRows)
                Spacer()
            }
        }
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let size = disk.counters.size {
            rows.append(("Capacity:", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let isInternal = disk.counters.isInternal {
            rows.append(("Type:", isInternal ? "Internal" : "External"))
        }
        // On Apple Silicon and T2 Macs the startup volume lives on disk0.
        if disk.id == "disk0", let volume = monitor.startupVolume {
            let free = ByteCountFormatter.string(fromByteCount: Int64(volume.available), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(volume.total), countStyle: .file)
            rows.append(("Startup volume:", "\(free) free of \(total)"))
        }
        return rows
    }
}
