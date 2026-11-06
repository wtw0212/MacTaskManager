import AppKit
import ApplicationServices
import Darwin

// Exported by libSystem but not in the public headers; Activity Monitor uses it to group
// helper processes (for example browser renderers) under the app they belong to.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

// <sys/resource.h> constants Swift doesn't import.
private let PRIO_DARWIN_PROCESS: Int32 = 4
private let PRIO_DARWIN_BG: Int32 = 0x1000
// <sys/proc.h>: the process runs under Rosetta.
private let P_TRANSLATED: Int32 = 0x0002_0000

struct ProcessRow: Identifiable {
    enum Status { case suspended, efficiency, notResponding }

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
    /// Open file descriptors, the macOS counterpart of Windows handles.
    var handles: Int?
    /// Scheduling priority (nice), -20 (highest) to 20 (lowest).
    var nice: Int32 = 0
    /// The app a helper process belongs to, or the app's own name (Windows' "Description").
    var description = ""
    /// Disk read + write in bytes per second. -1 when not readable.
    var diskRate: Double = -1
    var diskReadRate: Double = -1
    var diskWriteRate: Double = -1
    /// Share of the GPU, 0...1, and the graphics API in use. -1 / "" when the process doesn't use the GPU.
    var gpu: Double = -1
    var gpuAPI = ""
    /// Network received + sent in bytes per second, from nettop. -1 when not available.
    var networkRate: Double = -1
    /// Average power over the last interval in watts. -1 when not readable.
    var energy: Double = -1
    /// The process macOS holds responsible for this one (the app, for helpers).
    var responsiblePID: pid_t = 0
    var parentPID: pid_t = 0
    var user = ""
    var uid: uid_t = 0
    var status: Status?
    var architecture = ""
    var startTime: Date?
}

/// Lists all processes with per-process CPU and memory from `proc_pid_rusage`.
/// Processes owned by other users (e.g. root) need privileges to read: their CPU and memory
/// come from the optional privileged helper, and show as unavailable without it.
final class ProcessSampler {
    private struct Identity: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    private struct Cached {
        var name: String
        var path: String?
        var description = ""
    }

    private struct Counters {
        var cpu: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var energy: UInt64
    }

    private var previous: [Identity: Counters] = [:]
    private var previousTime = DispatchTime.now().uptimeNanoseconds
    private var names: [Identity: Cached] = [:]
    private var userNames: [uid_t: String] = [:]
    private let network = ProcessNetworkSampler()
    private let gpuSampler = ProcessGPUSampler()
    private let hangDetector = HangDetector()
    private let ticksToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    private let coreCount = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
    #if arch(arm64)
    private let nativeArchitecture = "Apple"
    #else
    private let nativeArchitecture = "Intel"
    #endif

    @MainActor
    func sample() -> [ProcessRow] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - previousTime)
        previousTime = now

        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = app
        }
        let networkRates = network.rates()
        let gpuUsage = gpuSampler.sample()
        let privileged = PrivilegedHelper.shared.sample()
        let hung = hangDetector.update(apps: Array(apps.keys))

        var rows: [ProcessRow] = []
        var current: [Identity: Counters] = [:]
        var currentNames: [Identity: Cached] = [:]

        for info in Self.allProcesses() where info.kp_proc.p_pid > 0 {
            let pid = info.kp_proc.p_pid
            var usage = rusage_info_v6()
            let readable = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0

            // Our own processes are read directly; other users' come from the helper, if installed.
            let helper = readable ? nil : privileged[pid]
            let startTime = readable ? usage.ri_proc_start_abstime : helper?.start ?? 0
            let identity = Identity(pid: pid, start: startTime)
            let cached = names[identity] ?? Self.lookUpName(pid)
            currentNames[identity] = cached

            let app = apps[pid]
            let uid = info.kp_eproc.e_ucred.cr_uid
            let start = info.kp_proc.p_un.__p_starttime
            let status: ProcessRow.Status? = info.kp_proc.p_stat == SSTOP ? .suspended
                : hung.contains(pid) ? .notResponding
                : Self.isEfficient(pid) ? .efficiency : nil
            var row = ProcessRow(
                id: pid,
                name: app?.localizedName ?? cached.name,
                path: cached.path,
                isApp: app != nil,
                icon: app?.icon,
                cpu: -1,
                memory: 0,
                threads: Self.threadCount(pid) ?? helper?.threads,
                handles: readable ? Self.handleCount(pid) : helper?.handles,
                nice: Int32(info.kp_proc.p_nice),
                description: app?.localizedName ?? cached.description,
                networkRate: networkRates.map { $0[pid] ?? 0 } ?? -1,
                responsiblePID: responsibility_get_pid_responsible_for_pid(pid),
                parentPID: info.kp_eproc.e_ppid,
                user: userName(uid),
                uid: uid,
                status: status,
                architecture: info.kp_proc.p_flag & P_TRANSLATED != 0 ? "Intel" : nativeArchitecture,
                startTime: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
            )

            let readings: (counters: Counters, footprint: UInt64)?
            if readable {
                readings = (Counters(cpu: usage.ri_user_time + usage.ri_system_time, diskRead: usage.ri_diskio_bytesread,
                                     diskWrite: usage.ri_diskio_byteswritten, energy: usage.ri_energy_nj),
                            usage.ri_phys_footprint)
            } else if let helper {
                readings = (Counters(cpu: helper.cpu, diskRead: helper.diskRead, diskWrite: helper.diskWrite,
                                     energy: helper.energy),
                            helper.footprint)
            } else {
                readings = nil
            }

            if let readings {
                let counters = readings.counters
                current[identity] = counters
                let old = previous[identity]
                func delta(_ value: KeyPath<Counters, UInt64>) -> Double? {
                    guard let old, elapsed > 0, counters[keyPath: value] >= old[keyPath: value] else { return nil }
                    return Double(counters[keyPath: value] - old[keyPath: value])
                }
                row.cpu = min((delta(\.cpu) ?? 0) * ticksToNanoseconds / max(elapsed, 1) / coreCount, 1)
                row.memory = readings.footprint
                let seconds = max(elapsed, 1) / 1_000_000_000
                row.diskReadRate = (delta(\.diskRead) ?? 0) / seconds
                row.diskWriteRate = (delta(\.diskWrite) ?? 0) / seconds
                row.diskRate = row.diskReadRate + row.diskWriteRate
                // Nanojoules per nanosecond = watts. A counter that never moved means it isn't reported here.
                row.energy = counters.energy == 0 ? -1 : (delta(\.energy) ?? 0) / max(elapsed, 1)
            }
            if let gpu = gpuUsage[pid] {
                row.gpu = gpu.share
                row.gpuAPI = gpu.api
            } else if !gpuUsage.isEmpty {
                row.gpu = 0
            }
            rows.append(row)
        }

        previous = current
        names = currentNames
        return rows
    }

    private func userName(_ uid: uid_t) -> String {
        if let name = userNames[uid] { return name }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userNames[uid] = name
        return name
    }

    /// The process macOS holds responsible for `pid`: the app, for its helpers.
    static func responsiblePID(_ pid: pid_t) -> pid_t {
        responsibility_get_pid_responsible_for_pid(pid)
    }

    // MARK: Actions

    @MainActor
    static func terminate(_ pid: pid_t, force: Bool) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            _ = send(force ? SIGKILL : SIGTERM, to: pid)
        }
    }

    /// Windows' End process tree: the process and everything it started, children first.
    /// Returns an error message for the first process that couldn't be ended.
    @MainActor
    static func terminateTree(_ pid: pid_t) -> String? {
        var failure: String?
        for process in descendants(of: pid).reversed() + [pid] {
            if let error = send(SIGKILL, to: process), process == pid || failure == nil {
                failure = error
            }
        }
        return failure
    }

    /// Darwin background priority: throttled CPU and I/O, efficiency cores only. Like Windows'
    /// efficiency mode. Returns an error message on failure (other users' processes need the helper).
    @MainActor
    static func setEfficiency(_ pid: pid_t, _ on: Bool) -> String? {
        if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0 { return nil }
        let error = String(cString: strerror(errno))
        return PrivilegedHelper.shared.isRunning ? PrivilegedHelper.shared.setBackground(pid, on) : error
    }

    /// SIGSTOP / SIGCONT. Returns an error message on failure.
    @MainActor
    static func setSuspended(_ pid: pid_t, _ suspended: Bool) -> String? {
        send(suspended ? SIGSTOP : SIGCONT, to: pid)
    }

    /// Sets the nice value (Windows' "Set priority"). Lowering it below 0, or changing another
    /// user's process, needs root: the helper does it if installed. Returns an error message on failure.
    @MainActor
    static func setNice(_ pid: pid_t, _ nice: Int32) -> String? {
        if setpriority(PRIO_PROCESS, id_t(pid), nice) == 0 { return nil }
        let error = String(cString: strerror(errno))
        return PrivilegedHelper.shared.isRunning ? PrivilegedHelper.shared.setNice(pid, nice) : error
    }

    /// Sends a signal, through the helper when the process belongs to another user.
    @MainActor
    static func send(_ signal: Int32, to pid: pid_t) -> String? {
        if kill(pid, signal) == 0 { return nil }
        let error = errno
        guard error == EPERM, PrivilegedHelper.shared.isRunning else { return String(cString: strerror(error)) }
        return PrivilegedHelper.shared.signal(pid, signal)
    }

    /// Every process started by `pid`, directly or not, parents before their children.
    /// Adapted from task-manager-for-mac by Yatin Arora (MIT License).
    static func descendants(of pid: pid_t) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for info in allProcesses() where info.kp_proc.p_pid > 1 && info.kp_proc.p_pid != info.kp_eproc.e_ppid {
            children[info.kp_eproc.e_ppid, default: []].append(info.kp_proc.p_pid)
        }
        var result: [pid_t] = []
        var queue = [pid]
        var seen: Set<pid_t> = [pid]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for child in children[current] ?? [] where seen.insert(child).inserted {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// Command-line arguments from KERN_PROCARGS2 (only for processes we may inspect).
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc, executable path, NUL padding, argc NUL-terminated arguments, environment.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let bytes = buffer[MemoryLayout<Int32>.size..<size]
        guard let pathEnd = bytes.firstIndex(of: 0) else { return nil }
        let rest = bytes[pathEnd...].drop { $0 == 0 }
        return rest.split(separator: 0, maxSplits: Int(argc), omittingEmptySubsequences: false)
            .prefix(Int(argc))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Reading

    /// Darwin background state, set by us or another process (EXT) or by the process itself.
    /// getpriority() can't be used: it only reports the caller's own state.
    private static func isEfficient(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_flags & UInt32(PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG) != 0
    }

    /// Every process in one sysctl: PID, parent, owner, state, flags and start time.
    static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func lookUpName(_ pid: pid_t) -> Cached {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = length > 0 ? String(cString: pathBuffer) : nil
        if let path {
            return Cached(name: (path as NSString).lastPathComponent, path: path, description: bundleName(containing: path))
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        return Cached(name: name.isEmpty ? "PID \(pid)" : name, path: nil)
    }

    /// The display name of the outermost app bundle containing `path`, or "".
    private static func bundleName(containing path: String) -> String {
        guard let range = path.range(of: ".app/") else { return "" }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        let bundle = Bundle(path: bundlePath)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Open file descriptors. Asking for the size alone gives the table size plus slack, so the list is read.
    private static func handleCount(_ pid: pid_t) -> Int? {
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buffer, estimate)
        return bytes > 0 ? Int(bytes) / stride : nil
    }

    private static func threadCount(_ pid: pid_t) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }
}

/// Finds apps that have stopped answering events, which Windows shows as "Not responding".
/// macOS has no public API for this (Activity Monitor uses a private one), so each app is asked
/// for its window title through Accessibility with a short timeout: only a timeout counts.
/// Needs the Accessibility permission (System Settings > Privacy & Security); without it, nothing is reported.
/// Approach adapted from task-manager-for-mac by Yatin Arora (MIT License).
final class HangDetector {
    static let enabledKey = "detectNotResponding"

    private let queue = DispatchQueue(label: "HangDetector", qos: .utility, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var hung: Set<pid_t> = []
    private var running = false
    private var lastRun = Date.distantPast

    /// The apps found hung by the last check; starts a new check in the background every few seconds.
    func update(apps: [pid_t]) -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard enabled, AXIsProcessTrusted() else {
            hung = []
            return []
        }
        if !running, Date().timeIntervalSince(lastRun) >= 3 {
            running = true
            lastRun = Date()
            let own = getpid()
            queue.async { [weak self] in
                let found = Set(apps.filter { $0 != own && Self.isHung($0) })
                guard let self else { return }
                self.lock.lock()
                self.hung = found
                self.running = false
                self.lock.unlock()
            }
        }
        return hung
    }

    private static func isHung(_ pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        // Other errors (no title, not accessible, sandboxed) mean "can't tell", not "not responding".
        return AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .cannotComplete
    }
}
