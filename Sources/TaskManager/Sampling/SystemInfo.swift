import Darwin
import Foundation

enum SystemInfo {
    static let cpuName = sysctlString("machdep.cpu.brand_string") ?? "CPU"

    static let physicalCores = sysctlInt("hw.physicalcpu")
    static let logicalCores = sysctlInt("hw.logicalcpu")

    /// Apple Silicon splits cores into performance levels: 0 = performance, 1 = efficiency.
    static let performanceCores: Int? = (sysctlInt("hw.nperflevels") ?? 0) >= 2 ? sysctlInt("hw.perflevel0.physicalcpu") : nil
    static let efficiencyCores: Int? = (sysctlInt("hw.nperflevels") ?? 0) >= 2 ? sysctlInt("hw.perflevel1.physicalcpu") : nil

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

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
