import Foundation
import IOKit

struct GPUReading {
    var name: String
    /// Overall device utilization, 0...1.
    var utilization: Double?
    /// Apple Silicon only: renderer and tiler utilization, 0...1.
    var renderer: Double?
    var tiler: Double?
    var memoryInUse: UInt64?
    var coreCount: Int?
}

/// Reads GPU statistics from every `IOAccelerator` service in the IORegistry.
/// Apple Silicon (AGX), AMD and Intel drivers publish a `PerformanceStatistics`
/// dictionary there; the keys differ slightly by vendor.
enum GPUSampler {
    /// Name and core count never change, so the large full property list is read only once per GPU.
    private static var identities: [UInt64: (name: String, coreCount: Int?)] = [:]

    static func sample() -> [GPUReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var readings: [GPUReading] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let reading = read(entry) {
                readings.append(reading)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return readings
    }

    private static func read(_ entry: io_registry_entry_t) -> GPUReading? {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        if identities[id] == nil {
            guard let props = properties(of: entry) else { return nil }
            identities[id] = (name(of: entry, props: props), number(props["gpu-core-count"]).map { Int($0) })
        }
        let identity = identities[id]
        let stats = IORegistry.property("PerformanceStatistics", of: entry) as? [String: Any] ?? [:]

        let utilization = percent(stats["Device Utilization %"]) ?? percent(stats["GPU Activity(%)"])
        let memory = number(stats["In use system memory"]) ?? number(stats["vramUsedBytes"])

        return GPUReading(
            name: identity?.name ?? "GPU",
            utilization: utilization,
            renderer: percent(stats["Renderer Utilization %"]),
            tiler: percent(stats["Tiler Utilization %"]),
            memoryInUse: memory.map { UInt64(max($0, 0)) },
            coreCount: identity?.coreCount
        )
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    private static func name(of entry: io_registry_entry_t, props: [String: Any]) -> String {
        if let model = modelString(props["model"]) { return model }
        // Discrete and Intel GPUs keep the model on the parent PCI device.
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            if let parentProps = properties(of: parent), let model = modelString(parentProps["model"]) {
                return model
            }
        }
        return "GPU"
    }

    private static func modelString(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let data = value as? Data {
            let string = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            return string.isEmpty ? nil : string
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func percent(_ value: Any?) -> Double? {
        number(value).map { min(max($0 / 100, 0), 1) }
    }
}
