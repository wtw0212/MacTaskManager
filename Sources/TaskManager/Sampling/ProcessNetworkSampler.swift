import Foundation

/// Per-process network traffic from `nettop`: macOS has no public per-process network API.
/// Takes one quick sample per tick and diffs the per-process byte totals; nettop's own continuous
/// mode (-L 0) spins more than a whole core, so it isn't used. Samples run off the main thread
/// because `waitUntilExit` spins the run loop, which would re-enter the monitor's timer.
final class ProcessNetworkSampler {
    private let queue = DispatchQueue(label: "ProcessNetworkSampler", qos: .utility, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var latest: [pid_t: Double]?
    private var isSampling = false
    // Only touched on `queue`.
    private var previous: [pid_t: Double] = [:]
    private var previousTime: TimeInterval?

    init() {
        assert(Self.parse("ABDownloadManag.888,10,5,").map { $0 == 888 && $1 == 15 } == true && Self.parse(",bytes_in,bytes_out,") == nil)
    }

    /// Bytes per second (received + sent) by PID from the last finished sample, or nil when
    /// nettop can't be read. Also starts the next sample.
    func rates() -> [pid_t: Double]? {
        lock.lock()
        defer { lock.unlock() }
        if !isSampling {
            isSampling = true
            queue.async { [self] in
                let rates = sample()
                lock.lock()
                latest = rates
                isSampling = false
                lock.unlock()
            }
        }
        return latest
    }

    private func sample() -> [pid_t: Double]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-n", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A stuck nettop mustn't freeze the column for good.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel() // otherwise it keeps this Process and its pipe alive for the full 5 s

        var totals: [pid_t: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let (pid, bytes) = Self.parse(line) { totals[pid, default: 0] += bytes }
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = totals; previousTime = now }
        guard !totals.isEmpty, let previousTime, now > previousTime else { return nil }
        return totals.reduce(into: [:]) { result, entry in
            result[entry.key] = max(entry.value - (previous[entry.key] ?? entry.value), 0) / (now - previousTime)
        }
    }

    /// "name.pid,bytes_in,bytes_out," -> (pid, bytes). The name may itself contain dots.
    static func parse<S: StringProtocol>(_ line: S) -> (pid_t, Double)? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
              let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
              let received = Double(fields[1]), let sent = Double(fields[2]) else { return nil }
        return (pid, received + sent)
    }
}
