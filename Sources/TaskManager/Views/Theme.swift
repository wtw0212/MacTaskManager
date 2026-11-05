import SwiftUI

enum Theme {
    static let cpu = Color(red: 0.07, green: 0.49, blue: 0.73)
    static let gpu = Color(red: 0.62, green: 0.33, blue: 0.80)

    static func percent(_ value: Double?) -> String {
        guard let value else { return "N/A" }
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
}
