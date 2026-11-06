import Darwin
import IOKit
import Foundation

enum SystemInfo {
    static let cpuName = sysctlString("machdep.cpu.brand_string") ?? "CPU"

    static let physicalCores = sysctlInt("hw.physicalcpu")
    static let logicalCores = sysctlInt("hw.logicalcpu")

    /// Number of CPU performance levels (2 or more on Apple Silicon, 1 or missing on Intel).
    static let perfLevelCount = sysctlInt("hw.nperflevels") ?? 1

    static let bootTime: Date? = {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }()

    static func processCount() -> Int {
        Int(max(proc_listallpids(nil, 0), 0))
    }

    static let sockets = sysctlInt("hw.packages") ?? 1
    static let virtualization = sysctlInt("kern.hv_support") == 1 ? "Supported" : "Not supported"

    /// Total L1 (instruction + data, every core), L2 (every cluster or core) and L3 cache, in bytes.
    static let cacheSizes: (l1: Int64, l2: Int64, l3: Int64) = {
        let value = { (name: String) in sysctlInt64(name) ?? 0 }
        if sysctlInt64("hw.perflevel0.physicalcpu") != nil {
            // Apple silicon: per core type, L1 per core and L2 shared by a cluster of cores.
            var l1: Int64 = 0, l2: Int64 = 0
            for level in 0..<perfLevelCount {
                let prefix = "hw.perflevel\(level)."
                let cores = value(prefix + "physicalcpu")
                l1 += cores * (value(prefix + "l1icachesize") + value(prefix + "l1dcachesize"))
                let perL2 = max(value(prefix + "cpusperl2"), 1)
                l2 += (cores + perL2 - 1) / perL2 * value(prefix + "l2cachesize")
            }
            return (l1, l2, value("hw.l3cachesize"))
        }
        // Intel: L1 and L2 per core, one shared L3.
        let cores = value("hw.physicalcpu")
        return (cores * (value("hw.l1icachesize") + value("hw.l1dcachesize")), cores * value("hw.l2cachesize"),
                value("hw.l3cachesize"))
    }()

    private static let host = mach_host_self()

    /// Threads in all processes, as `top` counts them (no privileges needed).
    static func threadCount() -> Int? {
        var processorSet = processor_set_name_t()
        guard processor_set_default(host, &processorSet) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, processorSet) }
        var info = processor_set_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<processor_set_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                processor_set_statistics(processorSet, PROCESSOR_SET_LOAD_INFO, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.thread_count) : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// For values that may be 32 or 64 bits wide, such as cache sizes.
    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == MemoryLayout<Int32>.size ? Int64(Int32(truncatingIfNeeded: value)) : value
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

/// Small helpers for reading IORegistry properties.
enum IORegistry {
    static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Calls `body` for every service matching `className`, releasing each one afterwards.
    static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }
}
