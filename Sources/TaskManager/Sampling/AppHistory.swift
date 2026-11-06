import AppKit
import Combine

/// One app's accumulated usage.
struct AppUsageRecord: Codable, Identifiable {
    /// Bundle identifier, or the bundle path for apps without one.
    var id: String
    var name: String
    var path: String?
    var cpuSeconds: Double = 0
    var networkBytes: Double = 0
    var energyJoules: Double = 0
}

/// Windows' App history: CPU time, network and energy that each app (with its helper processes)
/// has used, accumulated while Task Manager runs and saved to
/// ~/Library/Application Support/TaskManager/app-history.json.
///
/// Samples every 10 seconds whatever page is open. All state changes on the main thread;
/// the process reads and nettop run on a background queue.
final class AppHistory: ObservableObject {
    static let shared = AppHistory()
    private static let interval: TimeInterval = 10
    private static let saveInterval: TimeInterval = 60

    private struct SavedHistory: Codable {
        var since: Date
        var apps: [String: AppUsageRecord]
    }

    @Published private(set) var records: [AppUsageRecord] = []
    @Published private(set) var since = Date()

    private var store: [String: AppUsageRecord] = [:]
    private let sampler = AppUsageSampler()
    private let queue = DispatchQueue(label: "AppHistory", qos: .utility, autoreleaseFrequency: .workItem)
    private var subscriptions: Set<AnyCancellable> = []
    private var isSampling = false
    private var isDirty = false
    private var lastSave = Date()
    private var icons: [String: NSImage] = [:]

    private let fileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("TaskManager", isDirectory: true)
        .appendingPathComponent("app-history.json")

    /// Loads the saved history and starts sampling. Call once, on the main thread.
    func start() {
        guard subscriptions.isEmpty else { return }
        load()
        Timer.publish(every: Self.interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.save() }
            .store(in: &subscriptions)
        tick()
    }

    /// Windows' "Delete usage history".
    func reset() {
        store = [:]
        records = []
        since = Date()
        isDirty = true
        save()
    }

    func icon(for record: AppUsageRecord) -> NSImage? {
        guard let path = record.path else { return nil }
        if let icon = icons[path] { return icon }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    // MARK: Sampling

    private func tick() {
        guard !isSampling else { return }
        isSampling = true
        var apps: [pid_t: AppUsageSampler.App] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let path = app.bundleURL?.path
            guard let key = app.bundleIdentifier ?? path else { continue }
            apps[app.processIdentifier] = .init(key: key, name: app.localizedName ?? key, path: path)
        }
        let sampler = self.sampler
        queue.async {
            let usage = sampler.sample(apps: apps)
            DispatchQueue.main.async { [weak self] in self?.apply(usage) }
        }
    }

    private func apply(_ usage: [String: AppUsageRecord]) {
        isSampling = false
        guard !usage.isEmpty else { return }
        for (key, delta) in usage {
            var record = store[key] ?? AppUsageRecord(id: key, name: delta.name, path: delta.path)
            record.name = delta.name
            record.path = delta.path ?? record.path
            record.cpuSeconds += delta.cpuSeconds
            record.networkBytes += delta.networkBytes
            record.energyJoules += delta.energyJoules
            store[key] = record
        }
        records = Array(store.values)
        isDirty = true
        if Date().timeIntervalSince(lastSave) >= Self.saveInterval { save() }
    }

    // MARK: Saving

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(SavedHistory.self, from: data) else { return }
        since = saved.since
        store = saved.apps
        records = Array(store.values)
    }

    private func save() {
        lastSave = Date()
        guard isDirty, let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(SavedHistory(since: since, apps: store)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: fileURL, options: .atomic)) != nil { isDirty = false }
    }
}

/// Reads CPU time, energy and network totals of every process that belongs to a regular app
/// (the app itself or a helper it is responsible for) and returns the growth since the last call,
/// summed per app. The first call only records a baseline. Used only from AppHistory's queue.
final class AppUsageSampler: @unchecked Sendable {
    struct App {
        var key: String
        var name: String
        var path: String?
    }

    private struct Identity: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    private struct Counters {
        var cpu: UInt64
        var energy: UInt64
        var network: Double
    }

    private var previous: [Identity: Counters]?
    private let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    func sample(apps: [pid_t: App]) -> [String: AppUsageRecord] {
        let network = ProcessNetworkSampler.totals() ?? [:]
        var current: [Identity: Counters] = [:]
        var usage: [String: AppUsageRecord] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            guard let app = apps[pid] ?? apps[ProcessSampler.responsiblePID(pid)] else { continue }
            var info = rusage_info_v6()
            let readable = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0
            guard readable else { continue }

            let identity = Identity(pid: pid, start: info.ri_proc_start_abstime)
            let counters = Counters(cpu: info.ri_user_time + info.ri_system_time, energy: info.ri_energy_nj,
                                    network: network[pid] ?? 0)
            current[identity] = counters
            // First call: baseline only. Later, a process we haven't seen started since the last
            // call, so all of its usage is new.
            guard let previous else { continue }
            let old = previous[identity] ?? Counters(cpu: 0, energy: 0, network: 0)

            var record = usage[app.key] ?? AppUsageRecord(id: app.key, name: app.name, path: app.path)
            record.cpuSeconds += Double(counters.cpu >= old.cpu ? counters.cpu - old.cpu : 0) * ticksToSeconds
            record.energyJoules += Double(counters.energy >= old.energy ? counters.energy - old.energy : 0) / 1_000_000_000
            // nettop counts open connections only, so a total can drop when one closes.
            record.networkBytes += max(counters.network - old.network, 0)
            usage[app.key] = record
        }

        previous = current
        return usage
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }
}
