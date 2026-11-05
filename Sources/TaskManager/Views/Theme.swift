import Foundation

/// Number formatting shared by every page.
enum Theme {
    static func percent(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "N/A" }
        return "\(Int((value * 100).rounded()))%"
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d:%02d:%02d", total / 86_400, total / 3_600 % 24, total / 60 % 60, total % 60)
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "N/A" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func gigabytes(_ value: UInt64, unit: Bool = true) -> String {
        String(format: unit ? "%.1f GB" : "%.1f", Double(value) / 1_073_741_824)
    }

    static func megabytes(_ value: UInt64) -> String {
        String(format: "%.1f MB", Double(value) / 1_048_576)
    }

    static func megabyteRate(_ value: Double) -> String {
        String(format: "%.1f MB/s", value / 1_048_576)
    }

    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 bytes/s", not "Zero KB/s"
        return formatter
    }()

    /// Bytes per second, e.g. "12.3 MB/s".
    static func byteRate(_ value: Double) -> String {
        rateFormatter.string(fromByteCount: Int64(max(value, 0))) + "/s"
    }

    /// Bytes per second shown as bits, e.g. "4.2 Mbps", like Windows does for networks.
    static func bitRate(_ bytesPerSecond: Double) -> String {
        var value = max(bytesPerSecond, 0) * 8
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(Int(value)) \(units[0])" : String(format: "%.1f %@", value, units[unit])
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "N/A" }
        return String(format: "%.0f °C", celsius)
    }

    /// Rounds a graph's top value up to 1, 2 or 5 times a power of ten.
    static func niceScale(_ value: Double, minimum: Double) -> Double {
        let value = max(value, minimum)
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 2.0, 5.0, 10.0] where step * magnitude >= value {
            return step * magnitude
        }
        return 10 * magnitude
    }
}
