import AppKit
import Darwin

// The client side of Sources/tmhelper. The helper approach (a setuid-root tool installed once
// behind an administrator prompt) is adapted from task-manager-for-mac by Yatin Arora
// (MIT License, https://github.com/yatindma/task-manager-for-mac). See LICENSES/task-manager-for-mac.txt.

/// What the helper reports for one process (the same counters `proc_pid_rusage` gives for our own).
struct PrivilegedStats {
    var start: UInt64
    var cpu: UInt64
    var footprint: UInt64
    var diskRead: UInt64
    var diskWrite: UInt64
    var energy: UInt64
    var threads: Int
    var handles: Int
}

/// Talks to the optional setuid-root helper, which reads and controls processes owned by other
/// users (root and the system accounts). Everything works without it; those processes then show
/// no CPU or memory, and actions on them fail with "Operation not permitted".
@MainActor
final class PrivilegedHelper: ObservableObject {
    enum State: Equatable {
        case notInstalled
        /// Installed, but from an older build: reinstall to update.
        case outdated
        case running
        case installing
        case failed(String)
    }

    static let shared = PrivilegedHelper()

    /// Matches `helperVersion` in Sources/tmhelper/main.swift.
    private static let expectedVersion = 1
    static let installPath = "/Library/Application Support/MacTaskManager/tmhelper"

    @Published private(set) var state: State = .notInstalled

    var isRunning: Bool { state == .running }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    private init() {
        // A dead helper must not kill the app when we write to its pipe.
        Darwin.signal(SIGPIPE, SIG_IGN)
        connect()
    }

    // MARK: Connection

    private func connect() {
        disconnect()
        guard FileManager.default.isExecutableFile(atPath: Self.installPath) else {
            state = .notInstalled
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.installPath)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        guard let pong = request("PING").first, pong.hasPrefix("PONG ") else {
            disconnect()
            state = .failed("The helper didn't answer. It only runs for administrator accounts.")
            return
        }
        state = Int(pong.dropFirst(5)) == Self.expectedVersion ? .running : .outdated
        if state == .outdated { disconnect() }
    }

    private func disconnect() {
        if let process, process.isRunning {
            try? input?.write(contentsOf: Data("QUIT\n".utf8))
            process.terminate()
        }
        process = nil
        input = nil
        output = nil
        buffer = Data()
    }

    /// Sends one line and reads the answer: one line, or for SAMPLE every line up to "END".
    /// Returns [] if the helper has gone away.
    private func request(_ line: String, multiline: Bool = false) -> [String] {
        guard let input, let output else { return [] }
        do {
            try input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            helperDied()
            return []
        }
        var lines: [String] = []
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !multiline { return [text] }
                if text == "END" { return lines }
                lines.append(text)
                continue
            }
            guard let chunk = try? output.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                helperDied()
                return []
            }
            buffer.append(chunk)
        }
    }

    private func helperDied() {
        disconnect()
        state = .failed("The helper stopped. Reinstall it from Settings.")
    }

    // MARK: Requests

    /// Counters for every process the helper can read, keyed by PID.
    func sample() -> [pid_t: PrivilegedStats] {
        guard isRunning else { return [:] }
        var result: [pid_t: PrivilegedStats] = [:]
        for line in request("SAMPLE", multiline: true) {
            let fields = line.split(separator: " ")
            guard fields.count == 9, let pid = pid_t(fields[0]) else { continue }
            let numbers = fields.dropFirst().map { UInt64($0) ?? 0 }
            result[pid] = PrivilegedStats(start: numbers[0], cpu: numbers[1], footprint: numbers[2], diskRead: numbers[3],
                                          diskWrite: numbers[4], energy: numbers[5], threads: Int(numbers[6]),
                                          handles: Int(numbers[7]))
        }
        return result
    }

    /// nil on success, else an error message.
    func signal(_ pid: pid_t, _ signal: Int32) -> String? {
        let names = [SIGTERM: "TERM", SIGKILL: "KILL", SIGSTOP: "STOP", SIGCONT: "CONT"]
        guard let name = names[signal] else { return String(cString: strerror(EINVAL)) }
        return answer(request("SIGNAL \(pid) \(name)"))
    }

    func setNice(_ pid: pid_t, _ nice: Int32) -> String? {
        answer(request("RENICE \(pid) \(nice)"))
    }

    func setBackground(_ pid: pid_t, _ on: Bool) -> String? {
        answer(request("BACKGROUND \(pid) \(on ? 1 : 0)"))
    }

    private func answer(_ lines: [String]) -> String? {
        guard let line = lines.first else { return "The helper isn't running." }
        if line == "OK" { return nil }
        let code = Int32(line.split(separator: " ").last ?? "") ?? EINVAL
        return String(cString: strerror(code))
    }

    // MARK: Install

    /// The helper built next to the app (Contents/MacOS in the bundle, or the build folder for `swift run`).
    private static var bundledHelper: String? {
        let candidates = [Bundle.main.url(forAuxiliaryExecutable: "tmhelper"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tmhelper")]
        return candidates.compactMap { $0?.path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Copies the helper into place and makes it setuid root, after macOS asks for an administrator password.
    func install() {
        guard let source = Self.bundledHelper else {
            state = .failed("The helper is missing from the app.")
            return
        }
        let folder = (Self.installPath as NSString).deletingLastPathComponent
        let q = Shell.shellQuoted
        let script = "/bin/mkdir -p \(q(folder)) && /bin/chmod 755 \(q(folder)) && "
            + "/bin/cp -f \(q(source)) \(q(Self.installPath)) && "
            + "/usr/sbin/chown root:wheel \(q(Self.installPath)) && /bin/chmod 4755 \(q(Self.installPath))"
        runPrivileged(script)
    }

    func uninstall() {
        let folder = (Self.installPath as NSString).deletingLastPathComponent
        disconnect()
        runPrivileged("/bin/rm -f \(Shell.shellQuoted(Self.installPath)) && /bin/rmdir \(Shell.shellQuoted(folder)) || true")
    }

    private func runPrivileged(_ script: String) {
        disconnect()
        state = .installing
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.runAsAdministrator("/bin/sh", ["-c", script])
            DispatchQueue.main.async {
                self.connect()
                // -128: the user cancelled the password prompt.
                if result.status != 0, !result.output.contains("-128"), self.state != .running {
                    self.state = .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }
}
