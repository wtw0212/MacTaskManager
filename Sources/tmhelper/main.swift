// tmhelper: the optional privileged helper.
//
// Adapted from tmhelper in task-manager-for-mac by Yatin Arora (MIT License,
// https://github.com/yatindma/task-manager-for-mac). See LICENSES/task-manager-for-mac.txt.
//
// Installed setuid-root at /Library/Application Support/MacTaskManager/tmhelper (only after
// the user asks for it and enters an administrator password) so the app can read and control
// processes it doesn't own, such as WindowServer and kernel_task. Without root,
// proc_pid_rusage and proc_pidinfo return nothing for other users' processes.
//
// It runs as root for its caller, so it is deliberately small: it never execs, never touches
// the file system and never interprets a path. Every verb added here is new root attack surface.
// It refuses to run unless the real (calling) user is an administrator, who could use sudo anyway.
//
// Protocol, one request per line on stdin, answers on stdout:
//   PING                      -> "PONG <version>"
//   SAMPLE                    -> one line per process, then "END":
//                                "<pid> <start> <cpu> <footprint> <diskRead> <diskWrite> <energy> <threads> <fds>"
//                                start and cpu are mach absolute time units (as in rusage_info), the rest bytes,
//                                nanojoules and counts. Processes that can't be read are left out.
//   SIGNAL <pid> <signal>     -> "OK" | "ERR <errno>"   signal is one of TERM, KILL, STOP, CONT
//   RENICE <pid> <nice>       -> "OK" | "ERR <errno>"   nice in -20...20
//   BACKGROUND <pid> <0|1>    -> "OK" | "ERR <errno>"   Darwin background priority (efficiency mode)
//   QUIT                      -> exits

import Darwin

let helperVersion = 1

// <sys/resource.h> constants Swift doesn't import.
let PRIO_DARWIN_PROCESS: Int32 = 4
let PRIO_DARWIN_BG: Int32 = 0x1000

// MARK: Caller check

/// True when the real user id (the user who started us, not the effective root) is in the admin group.
func callerIsAdministrator() -> Bool {
    let uid = getuid()
    if uid == 0 { return true }
    guard let passwd = getpwuid(uid), let admin = getgrnam("admin") else { return false }
    var groups = [Int32](repeating: 0, count: 64)
    var count = Int32(groups.count)
    let found = groups.withUnsafeMutableBufferPointer { buffer in
        getgrouplist(passwd.pointee.pw_name, Int32(bitPattern: passwd.pointee.pw_gid), buffer.baseAddress, &count)
    }
    guard found != -1 else { return false }
    return groups.prefix(Int(count)).contains(Int32(bitPattern: admin.pointee.gr_gid))
}

guard callerIsAdministrator() else {
    fputs("tmhelper: the calling user is not an administrator\n", stderr)
    exit(77) // EX_NOPERM
}

// MARK: Sampling

func allPIDs() -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = processes.count * stride
    guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
    return processes.prefix(size / stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
}

/// Open file descriptors. Asking for the size alone returns the table size plus slack,
/// not the number in use, so the list is read.
func fileDescriptorCount(_ pid: pid_t) -> Int {
    let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard estimate > 0 else { return 0 }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride)
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buffer, estimate)
    return bytes > 0 ? Int(bytes) / stride : 0
}

func threadCount(_ pid: pid_t) -> Int {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? Int(info.pti_threadnum) : 0
}

func sample() {
    for pid in allPIDs() {
        var usage = rusage_info_v6()
        let readable = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        } == 0
        guard readable else { continue }
        let cpu = usage.ri_user_time &+ usage.ri_system_time
        print("\(pid) \(usage.ri_proc_start_abstime) \(cpu) \(usage.ri_phys_footprint) \(usage.ri_diskio_bytesread) "
              + "\(usage.ri_diskio_byteswritten) \(usage.ri_energy_nj) \(threadCount(pid)) \(fileDescriptorCount(pid))")
    }
    print("END")
}

// MARK: Control

let signals: [Substring: Int32] = ["TERM": SIGTERM, "KILL": SIGKILL, "STOP": SIGSTOP, "CONT": SIGCONT]

/// A target process id: never launchd (1), the kernel (0), or a process group (negative).
func target(_ text: Substring) -> pid_t? {
    guard let pid = pid_t(text), pid > 1 else { return nil }
    return pid
}

func result(_ status: Int32) -> String {
    status == 0 ? "OK" : "ERR \(errno)"
}

func handle(_ parts: [Substring]) -> String {
    switch parts.first.map(String.init) ?? "" {
    case "PING":
        return "PONG \(helperVersion)"
    case "SIGNAL":
        guard parts.count == 3, let pid = target(parts[1]), let signal = signals[parts[2]] else { return "ERR \(EINVAL)" }
        return result(kill(pid, signal))
    case "RENICE":
        guard parts.count == 3, let pid = target(parts[1]), let nice = Int32(parts[2]), (-20...20).contains(nice) else {
            return "ERR \(EINVAL)"
        }
        return result(setpriority(PRIO_PROCESS, id_t(pid), nice))
    case "BACKGROUND":
        guard parts.count == 3, let pid = target(parts[1]), parts[2] == "0" || parts[2] == "1" else { return "ERR \(EINVAL)" }
        return result(setpriority(PRIO_DARWIN_PROCESS, id_t(pid), parts[2] == "1" ? PRIO_DARWIN_BG : 0))
    default:
        return "ERR \(EINVAL)"
    }
}

// MARK: Loop

setvbuf(stdout, nil, _IOFBF, 1 << 16)
while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: " ")
    let verb = parts.first.map(String.init) ?? ""
    if verb == "QUIT" { break }
    if verb == "SAMPLE" {
        sample()
    } else {
        print(handle(parts))
    }
    fflush(stdout)
}
