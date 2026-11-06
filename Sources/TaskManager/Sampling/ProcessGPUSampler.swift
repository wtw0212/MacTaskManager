import Foundation
import IOKit

/// Per-process GPU usage. Every Metal (or OpenGL) client has a user client under the GPU's
/// IOAccelerator service, with `IOUserClientCreator` = "pid 419, WindowServer" and `AppUsage` =
/// [{API: "Metal", accumulatedGPUTime: ns, ...}]. GPU share = growth of the summed GPU time / wall time.
final class ProcessGPUSampler {
    struct Usage {
        /// Share of the GPU over the last interval, 0...1.
        var share: Double
        /// The graphics API the process used most, e.g. "Metal".
        var api: String
    }

    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: UInt64?

    /// Usage by PID since the last call; empty on the first call.
    func sample() -> [pid_t: Usage] {
        var times: [pid_t: UInt64] = [:]
        var apis: [pid_t: (name: String, time: UInt64)] = [:]

        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(iterator) }
            var client = IOIteratorNext(iterator)
            while client != 0 {
                defer {
                    IOObjectRelease(client)
                    client = IOIteratorNext(iterator)
                }
                guard let creator = IORegistry.property("IOUserClientCreator", of: client) as? String,
                      let pid = Self.pid(fromCreator: creator),
                      let usage = IORegistry.property("AppUsage", of: client) as? [[String: Any]] else { continue }
                for entry in usage {
                    let time = (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                    times[pid, default: 0] &+= time
                    if let api = entry["API"] as? String, time >= apis[pid]?.time ?? 0 {
                        apis[pid] = (api, time)
                    }
                }
            }
        }

        let now = DispatchTime.now().uptimeNanoseconds
        defer {
            previous = times
            previousTime = now
        }
        guard let previousTime, now > previousTime else { return [:] }
        let elapsed = Double(now - previousTime)
        var result: [pid_t: Usage] = [:]
        for (pid, time) in times {
            let old = previous[pid] ?? time
            let share = time >= old ? min(Double(time - old) / elapsed, 1) : 0
            result[pid] = Usage(share: share, api: apis[pid]?.name ?? "")
        }
        return result
    }

    /// "pid 419, WindowServer" -> 419.
    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        return pid_t(creator.dropFirst(4).prefix { $0.isNumber })
    }
}
