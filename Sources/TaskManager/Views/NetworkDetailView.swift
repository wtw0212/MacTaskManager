import SwiftUI

struct NetworkDetailView: View {
    var network: NetworkState
    var scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ResourceHeader(title: network.displayName, subtitle: network.id)

            LabeledGraph(
                title: "Throughput",
                values: network.receiveHistory,
                color: DS.Palette.network,
                secondary: network.sendHistory,
                maxValue: scale,
                topLabel: Theme.bitRate(scale)
            )

            StatsArea(info: [
                ("Interface:", network.id),
                ("IPv4 address:", network.ipv4 ?? "N/A"),
                ("IPv6 address:", network.ipv6 ?? "N/A"),
                ("Total received:", Theme.bytes(network.counters.bytesIn)),
                ("Total sent:", Theme.bytes(network.counters.bytesOut)),
            ]) {
                GridRow {
                    Stat(label: "Send", value: Theme.bitRate(network.sendRate), legend: DS.Palette.network, dashed: true)
                    Stat(label: "Receive", value: Theme.bitRate(network.receiveRate), legend: DS.Palette.network)
                }
            }
        }
    }
}
