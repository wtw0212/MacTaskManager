import AppKit
import Darwin

// Exported by libSystem but not in the public headers; Activity Monitor uses it to group
// helper processes (for example browser renderers) under the app they belong to.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

struct ProcessRow: Identifiable {
    let id: pid_t
    var name: String
    var path: String?
    var isApp: Bool
    var icon: NSImage?
    /// Share of the whole machine (all cores), 0...1, like Windows. -1 when not readable.
    var cpu: Double
    /// Physical footprint in bytes (what Activity Monitor shows as Memory). 0 when not readable.
    var memory: UInt64
    var threads: Int?
    /// Disk read + write in bytes per second. -1 when not readable.
    var diskRate: Double = -1
    /// The process macOS holds responsible for this one (the app, for helpers).
    var responsiblePID: pid_t = 0
    var pid: Int32 { id }
}

/// Lists all processes with per-process CPU and memory from `proc_pid_rusage`.
/// Processes owned by other users (e.g. root) need privileges to read, so their
/// CPU and memory show as unavailable.
final class ProcessSampler {
    private struct Identity: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    private struct Cached {
        var name: String
        var path: String?
    }

    private var previousCPU: [Identity: UInt64] = [:]
    private var previousDisk: [Identity: UInt64] = [:]
    private var previousTime = DispatchTime.now().uptimeNanoseconds
    private var names: [Identity: Cached] = [:]
    private let ticksToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    private let coreCount = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))

    func sample() -> [ProcessRow] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - previousTime)
        previousTime = now

        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = app
        }

        var rows: [ProcessRow] = []
        var currentCPU: [Identity: UInt64] = [:]
        var currentDisk: [Identity: UInt64] = [:]
        var currentNames: [Identity: Cached] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            var usage = rusage_info_v4()
            let readable = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0

            let identity = Identity(pid: pid, start: readable ? usage.ri_proc_start_abstime : 0)
            let cached = names[identity] ?? Self.lookUpName(pid)
            currentNames[identity] = cached

            var cpu = -1.0
            var memory: UInt64 = 0
            var diskRate = -1.0
            if readable {
                let ticks = usage.ri_user_time + usage.ri_system_time
                currentCPU[identity] = ticks
                if let previous = previousCPU[identity], elapsed > 0, ticks >= previous {
                    cpu = min(Double(ticks - previous) * ticksToNanoseconds / elapsed / coreCount, 1)
                } else {
                    cpu = 0
                }
                memory = usage.ri_phys_footprint
                let disk = usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten
                currentDisk[identity] = disk
                if let previous = previousDisk[identity], elapsed > 0, disk >= previous {
                    diskRate = Double(disk - previous) / (elapsed / 1_000_000_000)
                } else {
                    diskRate = 0
                }
            }

            let app = apps[pid]
            rows.append(ProcessRow(
                id: pid,
                name: app?.localizedName ?? cached.name,
                path: cached.path,
                isApp: app != nil,
                icon: app?.icon,
                cpu: cpu,
                memory: memory,
                threads: Self.threadCount(pid),
                diskRate: diskRate,
                responsiblePID: responsibility_get_pid_responsible_for_pid(pid)
            ))
        }

        previousCPU = currentCPU
        previousDisk = currentDisk
        names = currentNames
        return rows
    }

    static func terminate(_ pid: pid_t, force: Bool) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(pid, force ? SIGKILL : SIGTERM)
        }
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private static func lookUpName(_ pid: pid_t) -> Cached {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = length > 0 ? String(cString: pathBuffer) : nil
        if let path {
            return Cached(name: (path as NSString).lastPathComponent, path: path)
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        return Cached(name: name.isEmpty ? "PID \(pid)" : name, path: nil)
    }

    private static func threadCount(_ pid: pid_t) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }
}
