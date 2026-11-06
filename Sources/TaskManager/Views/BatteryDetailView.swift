import SwiftUI

/// Battery panel, laid out like the other resources: power graph, charge bar, stats and details.
struct BatteryDetailView: View {
    var battery: BatteryState

    var body: some View {
        let reading = battery.reading
        let scale = Self.scale(battery)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ResourceHeader(title: "Battery", subtitle: reading.isPluggedIn ? reading.adapterName ?? "Power adapter" : "On battery power")

            LabeledGraph(
                title: reading.isCharging ? "Charging power" : "Battery power",
                values: battery.powerHistory,
                color: DS.Palette.battery,
                maxValue: scale,
                topLabel: Theme.watts(scale)
            )

            VStack(spacing: DS.Space.xs) {
                CaptionRow(leading: "Charge", trailing: Theme.percent(reading.charge))
                ChargeBar(charge: reading.charge).frame(height: 40)
            }

            StatsArea(info: infoRows(reading)) {
                GridRow {
                    Stat(label: "Charge", value: Theme.percent(reading.charge))
                    Stat(label: reading.isCharging ? "Charging power" : "Battery power",
                         value: Theme.watts(reading.power.map { abs($0) }))
                    Stat(label: reading.isCharging ? "Time to full" : "Time remaining", value: remaining(reading))
                }
                GridRow {
                    Stat(label: "Health", value: Theme.percent(reading.health))
                    Stat(label: "Cycle count", value: reading.cycleCount.map(String.init) ?? "N/A")
                    Stat(label: "Temperature", value: Theme.temperature(reading.temperature))
                }
            }
        }
    }

    /// "Charging", "Fully charged", "Plugged in" or "On battery", for the tile and header.
    static func state(_ reading: BatteryReading) -> String {
        if reading.isFullyCharged { return "Fully charged" }
        if reading.isCharging { return "Charging" }
        return reading.isPluggedIn ? "Plugged in, not charging" : "On battery"
    }

    /// Graph top in watts: at least 10 W, rounded up to a 1/2/5 step.
    static func scale(_ battery: BatteryState) -> Double {
        Theme.niceScale(battery.powerHistory.max() ?? 0, minimum: 10)
    }

    private func remaining(_ reading: BatteryReading) -> String {
        if reading.isFullyCharged { return "Full" }
        return reading.minutesRemaining.map(Theme.duration(minutes:)) ?? "Calculating…"
    }

    private func infoRows(_ reading: BatteryReading) -> [(String, String)] {
        var rows: [(String, String)] = [("State:", Self.state(reading))]
        if let condition = reading.condition { rows.append(("Condition:", condition)) }
        if let design = reading.designCapacity { rows.append(("Design capacity:", "\(design) mAh")) }
        if let full = reading.fullChargeCapacity { rows.append(("Full charge capacity:", "\(full) mAh")) }
        if let voltage = reading.voltage { rows.append(("Voltage:", String(format: "%.2f V", voltage))) }
        if let amperage = reading.amperage { rows.append(("Current:", String(format: "%.2f A", amperage))) }
        if let watts = reading.adapterWatts { rows.append(("Adapter:", "\(watts) W")) }
        if let system = reading.systemPower { rows.append(("System power:", Theme.watts(system))) }
        return rows
    }
}

/// Charge as a filled bar.
private struct ChargeBar: View {
    var charge: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Palette.battery.opacity(0.12))
                Rectangle()
                    .fill(DS.Palette.battery.opacity(0.45))
                    .frame(width: width * CGFloat(min(max(charge, 0), 1)))
                    .help("Charge: \(Theme.percent(charge))")
            }
            .overlay(Rectangle().stroke(DS.Palette.battery, lineWidth: 1))
        }
    }
}
