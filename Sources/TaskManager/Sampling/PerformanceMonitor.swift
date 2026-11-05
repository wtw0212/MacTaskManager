import Combine
import Foundation

struct GPUState: Identifiable {
    let id: Int
    var reading: GPUReading
    var history: [Double]
    var rendererHistory: [Double]
    var tilerHistory: [Double]
}

/// Samples CPU and GPU once per second and keeps the last 60 seconds of each.
@MainActor
final class PerformanceMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var coreHistories: [[Double]] = []
    @Published private(set) var totalHistory: [Double] = []
    @Published private(set) var gpus: [GPUState] = []
    @Published private(set) var processCount = 0
    @Published private(set) var uptime: TimeInterval = 0

    private let cpu = CPUSampler()
    private var timer: AnyCancellable?

    init() {
        let empty = Array(repeating: 0.0, count: Self.historyLength)
        coreHistories = Array(repeating: empty, count: cpu.coreCount)
        totalHistory = empty
        tick()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    var currentTotal: Double { totalHistory.last ?? 0 }

    private func tick() {
        let cores = cpu.sample()
        if !cores.isEmpty {
            if coreHistories.count != cores.count {
                coreHistories = Array(repeating: Array(repeating: 0, count: Self.historyLength), count: cores.count)
            }
            for (index, value) in cores.enumerated() {
                Self.push(value, onto: &coreHistories[index])
            }
            Self.push(cores.reduce(0, +) / Double(cores.count), onto: &totalHistory)
        }

        let readings = GPUSampler.sample()
        var updated: [GPUState] = []
        for (index, reading) in readings.enumerated() {
            let empty = Array(repeating: 0.0, count: Self.historyLength)
            var state = index < gpus.count
                ? gpus[index]
                : GPUState(id: index, reading: reading, history: empty, rendererHistory: empty, tilerHistory: empty)
            state.reading = reading
            Self.push(reading.utilization ?? 0, onto: &state.history)
            Self.push(reading.renderer ?? 0, onto: &state.rendererHistory)
            Self.push(reading.tiler ?? 0, onto: &state.tilerHistory)
            updated.append(state)
        }
        gpus = updated

        processCount = SystemInfo.processCount()
        uptime = SystemInfo.bootTime.map { Date().timeIntervalSince($0) } ?? ProcessInfo.processInfo.systemUptime
    }

    private static func push(_ value: Double, onto history: inout [Double]) {
        history.append(value)
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
    }
}
