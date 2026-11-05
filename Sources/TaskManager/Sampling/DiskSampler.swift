import Foundation
import IOKit

/// Cumulative counters for one physical disk, read from IOBlockStorageDriver "Statistics".
struct DiskCounters {
    var bsdName: String
    var name: String
    var size: UInt64?
    var isInternal: Bool?
    var bytesRead: UInt64
    var bytesWritten: UInt64
    /// Total time spent on reads and writes, in nanoseconds.
    var busyTime: UInt64
}

enum DiskSampler {
    static func read() -> [DiskCounters] {
        var disks: [DiskCounters] = []
        IORegistry.forEachService(matching: "IOBlockStorageDriver") { driver in
            guard let stats = IORegistry.property("Statistics", of: driver) as? [String: Any] else { return }

            var media: io_registry_entry_t = 0
            guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &media) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(media) }
            guard let bsdName = IORegistry.property("BSD Name", of: media) as? String else { return }
            let size = (IORegistry.property("Size", of: media) as? NSNumber)?.uint64Value

            var name = bsdName
            var isInternal: Bool?
            var device: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS {
                defer { IOObjectRelease(device) }
                let props = IORegistry.properties(of: device) ?? [:]
                let characteristics = props["Device Characteristics"] as? [String: Any]
                if let product = (characteristics?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces),
                   !product.isEmpty {
                    name = product
                }
                if let location = (props["Protocol Characteristics"] as? [String: Any])?["Physical Interconnect Location"] as? String {
                    isInternal = location == "Internal"
                }
            }

            func counter(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            disks.append(DiskCounters(
                bsdName: bsdName,
                name: name,
                size: size,
                isInternal: isInternal,
                bytesRead: counter("Bytes (Read)"),
                bytesWritten: counter("Bytes (Write)"),
                busyTime: counter("Total Time (Read)") + counter("Total Time (Write)")
            ))
        }
        return disks.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }

    /// Free and total space of the startup volume.
    static func startupVolume() -> (available: UInt64, total: UInt64)? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let available = values?.volumeAvailableCapacityForImportantUsage,
              let total = values?.volumeTotalCapacity else { return nil }
        return (UInt64(max(available, 0)), UInt64(max(total, 0)))
    }
}
