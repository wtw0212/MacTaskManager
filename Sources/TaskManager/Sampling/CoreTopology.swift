import Foundation
import IOKit

/// A set of logical CPUs of the same kind, such as Apple's performance or efficiency cores.
struct CoreGroup: Identifiable {
    /// The performance level; 0 is the fastest.
    let id: Int
    /// Apple's own name for the level from `hw.perflevelN.name`, e.g. "Performance" or "Efficiency".
    let name: String
    /// Logical CPU numbers, matching the order of `host_processor_info`.
    let cores: [Int]
}

enum CoreTopology {
    static func groups(logicalCount: Int) -> [CoreGroup] {
        let levels = (0..<SystemInfo.perfLevelCount).map { level in
            (
                name: SystemInfo.sysctlString("hw.perflevel\(level).name") ?? "Level \(level)",
                count: SystemInfo.sysctlInt("hw.perflevel\(level).logicalcpu") ?? 0
            )
        }
        guard levels.count >= 2 else {
            return [CoreGroup(id: 0, name: "Logical processors", cores: Array(0..<logicalCount))]
        }

        if let groups = fromDeviceTree(levels: levels, logicalCount: logicalCount) {
            return groups
        }

        // Fallback: Apple Silicon numbers the slower clusters first.
        var next = 0
        var groups: [CoreGroup] = []
        for (level, info) in levels.enumerated().reversed() {
            let end = min(next + info.count, logicalCount)
            groups.append(CoreGroup(id: level, name: info.name, cores: Array(next..<end)))
            next = end
        }
        return groups.sorted { $0.id < $1.id }
    }

    /// Reads `cluster-type` ("E", "P", ...) for every CPU node under IODeviceTree:/cpus,
    /// then matches each cluster type to a performance level by core count.
    private static func fromDeviceTree(levels: [(name: String, count: Int)], logicalCount: Int) -> [CoreGroup]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var clusters: [String: [Int]] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let type = string(IORegistry.property("cluster-type", of: entry)),
               let id = integer(IORegistry.property("logical-cpu-id", of: entry)) ?? integer(IORegistry.property("cpu-id", of: entry)),
               id < logicalCount {
                clusters[type, default: []].append(id)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        guard clusters.values.reduce(0, { $0 + $1.count }) == logicalCount else { return nil }

        var remaining = clusters
        var groups: [CoreGroup] = []
        for (level, info) in levels.enumerated() {
            let isLast = level == levels.count - 1
            // Prefer a cluster with the right size; "E" clusters belong to the slowest level.
            let candidates = remaining.keys.sorted { rank($0) < rank($1) }
            let key = candidates.first { remaining[$0]?.count == info.count && (isLast || $0 != "E") }
                ?? candidates.first
            guard let key, let cores = remaining.removeValue(forKey: key) else { continue }
            groups.append(CoreGroup(id: level, name: info.name, cores: cores.sorted()))
        }
        return remaining.isEmpty ? groups : nil
    }

    private static func rank(_ clusterType: String) -> Int {
        clusterType == "E" ? 1 : 0
    }

    private static func string(_ value: Any?) -> String? {
        guard let data = value as? Data else { return value as? String }
        let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let data = value as? Data, data.count >= 4 else { return nil }
        let bytes = Array(data.prefix(4))
        return Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
    }
}
