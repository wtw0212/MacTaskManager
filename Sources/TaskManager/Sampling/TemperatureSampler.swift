import Foundation

// Apple has no public API for chip temperatures. These IOHIDEventSystem functions are
// exported by IOKit (and used by Activity-Monitor-style tools) but are not in the public
// headers, so they are declared here. This rules out the Mac App Store, not direct distribution.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

struct TemperatureReading {
    /// Hottest CPU sensor in °C (on M2 and later: hottest SoC die sensor).
    var cpu: Double?
    /// GPU temperature in °C: SMC "Tg" sensors, else HID GPU sensors, else the SoC reading.
    var gpu: Double?
    /// True when `gpu` is the shared SoC die reading because no GPU-only sensor exists.
    var gpuIsSoC = false
    /// Hottest of the battery gas gauge's sensors in °C.
    var battery: Double?
    var sensors: [(name: String, celsius: Double)] = []
}

final class TemperatureSampler {
    private static let temperatureEvent: Int64 = 15 // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16

    private var client: CFTypeRef?
    private var services: [(name: String, service: CFTypeRef)] = []
    private let smc = SMC()

    init() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // Usage page 0xff00, usage 5: Apple vendor temperature sensors.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        guard let list = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return }
        services = list.compactMap { service in
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else {
                return nil
            }
            return (name, service)
        }
    }

    func sample() -> TemperatureReading {
        var sensors: [(name: String, celsius: Double)] = []
        for (name, service) in services {
            guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else {
                continue
            }
            let value = IOHIDEventGetFloatValue(event, Self.temperatureField)
            if value > 0, value < 150 {
                sensors.append((name, value))
            }
        }

        // M1 names CPU clusters "pACC/eACC MTR Temp"; later chips report "PMU tdie" die sensors.
        let cpuSensors = sensors.filter { $0.name.contains("ACC MTR") }
        let dieSensors = sensors.filter { $0.name.contains("tdie") }
        let gpuSensors = sensors.filter { $0.name.contains("GPU MTR") }

        let cpu = (cpuSensors.isEmpty ? dieSensors : cpuSensors).map(\.celsius).max()
        let gpu = smc?.gpuTemperature() ?? gpuSensors.map(\.celsius).max()
        return TemperatureReading(
            cpu: cpu,
            gpu: gpu ?? cpu,
            gpuIsSoC: gpu == nil && cpu != nil,
            battery: sensors.filter { $0.name.contains("gas gauge battery") }.map(\.celsius).max(),
            sensors: sensors.sorted { $0.name < $1.name }
        )
    }
}
