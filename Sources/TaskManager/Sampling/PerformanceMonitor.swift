import Combine
import Foundation

struct GPUState: Identifiable {
    let id: Int
    var reading: GPUReading
    var history: [Double]
    var rendererHistory: [Double]
    var tilerHistory: [Double]
}

struct DiskState: Identifiable {
    var id: String { counters.bsdName }
    var counters: DiskCounters
    /// Share of the last interval the disk was busy, 0...1.
    var activeTime: Double = 0
    var readRate: Double = 0
    var writeRate: Double = 0
    var activeHistory = PerformanceMonitor.emptyHistory
    var readHistory = PerformanceMonitor.emptyHistory
    var writeHistory = PerformanceMonitor.emptyHistory
}

struct NetworkState: Identifiable {
    var id: String { counters.bsdName }
    var counters: NetworkCounters
    var displayName: String
    var ipv4: String?
    var ipv6: String?
    /// Bytes per second.
    var receiveRate: Double = 0
    var sendRate: Double = 0
    var receiveHistory = PerformanceMonitor.emptyHistory
    var sendHistory = PerformanceMonitor.emptyHistory
}

struct BatteryState {
    var reading: BatteryReading
    /// Battery power in watts as a magnitude (charging or discharging), for the graphs.
    var powerHistory = PerformanceMonitor.emptyHistory
}

/// Windows' View > Update speed.
enum UpdateSpeed: String, CaseIterable, Identifiable {
    case high = "High", normal = "Normal", low = "Low", paused = "Paused"

    var id: Self { self }

    var interval: TimeInterval? {
        switch self {
        case .high: 0.5
        case .normal: 1
        case .low: 4
        case .paused: nil
        }
    }
}

/// Samples everything once per update interval (1 s by default) and keeps the last 60 samples of each graph.
@MainActor
final class PerformanceMonitor: ObservableObject {
    nonisolated static let historyLength = 60
    nonisolated static let emptyHistory = Array(repeating: 0.0, count: 60)

    // CPU
    let coreGroups: [CoreGroup]
    @Published private(set) var coreHistories: [[Double]] = []
    @Published private(set) var totalHistory: [Double] = emptyHistory
    @Published private(set) var temperature = TemperatureReading()
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var processCount = 0
    @Published private(set) var uptime: TimeInterval = 0

    // Memory
    @Published private(set) var memory: MemoryReading?
    @Published private(set) var memoryHistory: [Double] = emptyHistory

    // Disk, network, GPU
    @Published private(set) var disks: [DiskState] = []
    @Published private(set) var networks: [NetworkState] = []
    @Published private(set) var gpus: [GPUState] = []
    @Published private(set) var startupVolume: (available: UInt64, total: UInt64)?
    /// nil on Macs without a battery.
    @Published private(set) var battery: BatteryState?

    // Processes (only sampled while the Processes tab is open)
    @Published private(set) var processes: [ProcessRow] = []
    var samplesProcesses = false {
        didSet {
            guard samplesProcesses != oldValue else { return }
            // Dropping the sampler frees its caches and stops the per-tick nettop runs.
            processSampler = samplesProcesses ? ProcessSampler() : nil
            processes = processSampler?.sample() ?? []
        }
    }

    private let cpu = CPUSampler()
    private let temperatureSampler = TemperatureSampler()
    private let batterySampler = BatterySampler()
    private var processSampler: ProcessSampler?
    private var interfaceNames: [String: String] = NetworkSampler.displayNames()
    private var lastTick = Date()
    private var tickCount = 0
    private var timer: AnyCancellable?
    private var lastInterval: TimeInterval = 1

    @Published var updateSpeed = UpdateSpeed(rawValue: UserDefaults.standard.string(forKey: "updateSpeed") ?? "") ?? .normal {
        didSet {
            UserDefaults.standard.set(updateSpeed.rawValue, forKey: "updateSpeed")
            startTimer()
        }
    }

    /// How many seconds the graphs span at the current update speed.
    var historySeconds: Int { Int(Double(Self.historyLength) * lastInterval) }

    init() {
        coreGroups = CoreTopology.groups(logicalCount: cpu.coreCount)
        coreHistories = Array(repeating: Self.emptyHistory, count: cpu.coreCount)
        disks = DiskSampler.read().map { DiskState(counters: $0) }
        networks = NetworkSampler.read().map { NetworkState(counters: $0, displayName: $0.bsdName) }
        tick()
        startTimer()
    }

    private func startTimer() {
        lastInterval = updateSpeed.interval ?? lastInterval
        timer = updateSpeed.interval.map {
            Timer.publish(every: $0, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
        }
    }

    var currentTotal: Double { totalHistory.last ?? 0 }

    func utilization(of group: CoreGroup) -> Double {
        let values = group.cores.compactMap { $0 < coreHistories.count ? coreHistories[$0].last : nil }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    func refreshProcesses() {
        processes = processSampler?.sample() ?? []
    }

    private func tick() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastTick), 0.001)
        lastTick = now
        tickCount += 1

        sampleCPU()
        temperature = temperatureSampler.sample()
        thermalState = ProcessInfo.processInfo.thermalState

        if let reading = MemorySampler.sample() {
            memory = reading
            Self.push(reading.usedFraction, onto: &memoryHistory)
        }

        sampleDisks(elapsed: elapsed)
        sampleNetworks(elapsed: elapsed)
        sampleGPUs()
        sampleBattery()

        if tickCount % 10 == 1 {
            startupVolume = DiskSampler.startupVolume()
            interfaceNames = NetworkSampler.displayNames()
        }
        if let processSampler {
            processes = processSampler.sample()
        }

        processCount = SystemInfo.processCount()
        uptime = SystemInfo.bootTime.map { now.timeIntervalSince($0) } ?? ProcessInfo.processInfo.systemUptime
    }

    private func sampleCPU() {
        let cores = cpu.sample()
        guard !cores.isEmpty else { return }
        if coreHistories.count != cores.count {
            coreHistories = Array(repeating: Self.emptyHistory, count: cores.count)
        }
        for (index, value) in cores.enumerated() {
            Self.push(value, onto: &coreHistories[index])
        }
        Self.push(cores.reduce(0, +) / Double(cores.count), onto: &totalHistory)
    }

    private func sampleDisks(elapsed: TimeInterval) {
        let previous = Dictionary(disks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        disks = DiskSampler.read().map { counters in
            guard var state = previous[counters.bsdName] else { return DiskState(counters: counters) }
            let old = state.counters
            state.counters = counters
            state.readRate = Double(counters.bytesRead &- old.bytesRead) / elapsed
            state.writeRate = Double(counters.bytesWritten &- old.bytesWritten) / elapsed
            if counters.bytesRead < old.bytesRead { state.readRate = 0 }
            if counters.bytesWritten < old.bytesWritten { state.writeRate = 0 }
            let busy = counters.busyTime >= old.busyTime ? Double(counters.busyTime - old.busyTime) : 0
            state.activeTime = min(busy / (elapsed * 1_000_000_000), 1)
            Self.push(state.activeTime, onto: &state.activeHistory)
            Self.push(state.readRate, onto: &state.readHistory)
            Self.push(state.writeRate, onto: &state.writeHistory)
            return state
        }
    }

    private func sampleNetworks(elapsed: TimeInterval) {
        let previous = Dictionary(networks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let addresses = NetworkSampler.addresses()
        networks = NetworkSampler.read()
            .filter { Self.isUserFacing($0.bsdName) && (addresses[$0.bsdName] != nil || $0.bytesIn + $0.bytesOut > 0) }
            .map { counters in
                var state = previous[counters.bsdName]
                    ?? NetworkState(counters: counters, displayName: counters.bsdName)
                let old = state.counters
                state.counters = counters
                state.displayName = interfaceNames[counters.bsdName] ?? counters.bsdName
                state.ipv4 = addresses[counters.bsdName]?.ipv4
                state.ipv6 = addresses[counters.bsdName]?.ipv6
                state.receiveRate = counters.bytesIn >= old.bytesIn ? Double(counters.bytesIn - old.bytesIn) / elapsed : 0
                state.sendRate = counters.bytesOut >= old.bytesOut ? Double(counters.bytesOut - old.bytesOut) / elapsed : 0
                Self.push(state.receiveRate, onto: &state.receiveHistory)
                Self.push(state.sendRate, onto: &state.sendHistory)
                return state
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Ethernet/Wi-Fi ("en") and cellular; hides loopback, AirDrop, VPN tunnels and bridges.
    private static func isUserFacing(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    private func sampleGPUs() {
        let readings = GPUSampler.sample()
        gpus = readings.enumerated().map { index, reading in
            var state = index < gpus.count
                ? gpus[index]
                : GPUState(id: index, reading: reading, history: Self.emptyHistory,
                           rendererHistory: Self.emptyHistory, tilerHistory: Self.emptyHistory)
            state.reading = reading
            Self.push(reading.utilization ?? 0, onto: &state.history)
            Self.push(reading.renderer ?? 0, onto: &state.rendererHistory)
            Self.push(reading.tiler ?? 0, onto: &state.tilerHistory)
            return state
        }
    }

    private func sampleBattery() {
        guard var reading = batterySampler?.sample() else {
            battery = nil
            return
        }
        reading.temperature = reading.temperature ?? temperature.battery
        var state = battery ?? BatteryState(reading: reading)
        state.reading = reading
        Self.push(abs(reading.power ?? 0), onto: &state.powerHistory)
        battery = state
    }

    private static func push(_ value: Double, onto history: inout [Double]) {
        history.append(value)
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
    }
}
