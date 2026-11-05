import SwiftUI

struct NetworkDetailView: View {
    var network: NetworkState

    var body: some View {
        let scale = Theme.niceScale(max(network.receiveHistory.max() ?? 0, network.sendHistory.max() ?? 0), minimum: 12_500)
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: network.displayName, subtitle: network.id)

            LabeledGraph(
                title: "Throughput",
                values: network.receiveHistory,
                color: Theme.network,
                secondary: network.sendHistory,
                maxValue: scale,
                topLabel: Theme.bitRate(scale)
            )

            HStack(alignment: .top, spacing: 40) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    GridRow {
                        Stat(label: "Send", value: Theme.bitRate(network.sendRate), large: true, dashed: true, color: Theme.network)
                        Stat(label: "Receive", value: Theme.bitRate(network.receiveRate), large: true, color: Theme.network)
                    }
                }
                InfoList(rows: [
                    ("Interface:", network.id),
                    ("IPv4 address:", network.ipv4 ?? "N/A"),
                    ("IPv6 address:", network.ipv6 ?? "N/A"),
                    ("Total received:", Theme.bytes(network.counters.bytesIn)),
                    ("Total sent:", Theme.bytes(network.counters.bytesOut)),
                ])
                Spacer()
            }
        }
    }
}
