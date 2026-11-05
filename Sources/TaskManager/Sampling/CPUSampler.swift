import Darwin

/// Reads per-logical-core tick counters with `host_processor_info` and turns
/// the difference between two reads into a 0...1 utilization per core.
final class CPUSampler {
    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previous: [Ticks] = []

    init() {
        previous = Self.readTicks() ?? []
    }

    var coreCount: Int { previous.count }

    /// Utilization of each logical core since the previous call, 0...1.
    func sample() -> [Double] {
        guard let current = Self.readTicks() else { return [] }
        defer { previous = current }
        guard previous.count == current.count else {
            return Array(repeating: 0, count: current.count)
        }
        return zip(previous, current).map { old, new in
            // Counters are 32-bit and wrap; wrapping subtraction keeps deltas right.
            let busy = Double(new.user &- old.user) + Double(new.system &- old.system) + Double(new.nice &- old.nice)
            let idle = Double(new.idle &- old.idle)
            let total = busy + idle
            return total > 0 ? busy / total : 0
        }
    }

    private static func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            func tick(_ state: Int32) -> UInt32 {
                UInt32(bitPattern: info[core * stride + Int(state)])
            }
            return Ticks(
                user: tick(CPU_STATE_USER),
                system: tick(CPU_STATE_SYSTEM),
                idle: tick(CPU_STATE_IDLE),
                nice: tick(CPU_STATE_NICE)
            )
        }
    }
}
