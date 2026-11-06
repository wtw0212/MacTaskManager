import Foundation
import IOKit
import IOKit.ps

struct BatteryReading {
    /// Charge, 0...1.
    var charge: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFullyCharged: Bool
    /// Battery power in watts: positive while charging, negative while discharging.
    var power: Double?
    /// Power the whole Mac draws, from the power telemetry (watts).
    var systemPower: Double?
    var voltage: Double?
    var amperage: Double?
    /// Minutes until empty (on battery) or full (charging); nil while macOS is still estimating.
    var minutesRemaining: Int?
    /// Full-charge capacity over design capacity, 0...1.
    var health: Double?
    var designCapacity: Int?
    var fullChargeCapacity: Int?
    var cycleCount: Int?
    var temperature: Double?
    var adapterWatts: Int?
    var adapterName: String?
    /// macOS's verdict, e.g. "Good" or "Check Battery".
    var condition: String?
}

/// Reads the internal battery from the AppleSmartBattery service, plus macOS's health verdict
/// from IOPowerSources. The service is looked up once and kept.
final class BatterySampler {
    private let service: io_registry_entry_t
    private var cachedSource: (condition: String?, minutes: Int?) = (nil, nil)
    private var samplesSinceSource = Int.max
    private var wasCharging = false

    /// nil when the Mac has no battery.
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        guard IORegistry.property("BatteryInstalled", of: service) as? Bool ?? true else {
            IOObjectRelease(service)
            return nil
        }
        self.service = service
    }

    deinit {
        IOObjectRelease(service)
    }

    func sample() -> BatteryReading? {
        func int(_ key: String) -> Int? { (IORegistry.property(key, of: service) as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { IORegistry.property(key, of: service) as? Bool ?? false }

        // On Apple Silicon CurrentCapacity and MaxCapacity are percentages; on Intel they're mAh.
        guard let current = int("CurrentCapacity"), let maximum = int("MaxCapacity"), maximum > 0 else { return nil }
        let batteryData = IORegistry.property("BatteryData", of: service) as? [String: Any] ?? [:]
        let nested = { (key: String) in (batteryData[key] as? NSNumber)?.intValue }

        let isCharging = bool("IsCharging")
        var reading = BatteryReading(charge: min(Double(current) / Double(maximum), 1), isCharging: isCharging,
                                     isPluggedIn: bool("ExternalConnected"), isFullyCharged: bool("FullyCharged"))

        // Amperage is a signed value the registry may hand back as a huge unsigned one.
        let amperage = (IORegistry.property("Amperage", of: service) as? NSNumber).map { Int64(bitPattern: $0.uint64Value) }
        if let millivolts = int("Voltage"), let amperage {
            reading.voltage = Double(millivolts) / 1000
            reading.amperage = Double(amperage) / 1000
            reading.power = Double(millivolts) * Double(amperage) / 1_000_000
        }
        if let telemetry = IORegistry.property("PowerTelemetryData", of: service) as? [String: Any],
           // SystemPowerIn is adapter input, 0 on battery; SystemLoad is what the Mac draws either way.
           let milliwatts = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, milliwatts > 0 {
            reading.systemPower = milliwatts / 1000
        }

        let design = int("DesignCapacity") ?? nested("DesignCapacity")
        let full = nested("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        reading.designCapacity = design
        // Health uses the nominal figure, as macOS's Maximum Capacity does; this line is the measured one.
        reading.fullChargeCapacity = nested("FullChargeCapacity") ?? full
        if let design, let full, design > 0 { reading.health = min(Double(full) / Double(design), 1) }

        reading.cycleCount = int("CycleCount") ?? nested("CycleCount")
        // Absent on recent Apple Silicon; PerformanceMonitor then uses the gas gauge's HID sensors.
        if let centi = int("Temperature") ?? int("VirtualTemperature") { reading.temperature = Double(centi) / 100 }
        if let adapter = IORegistry.property("AdapterDetails", of: service) as? [String: Any], reading.isPluggedIn {
            reading.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
            reading.adapterName = adapter["Name"] as? String ?? adapter["Description"] as? String
        }
        // These change slowly; asking IOPowerSources every tick isn't worth it, except when charging starts or stops.
        if samplesSinceSource >= 60 || isCharging != wasCharging {
            cachedSource = Self.powerSource(isCharging: isCharging)
            samplesSinceSource = 0
        }
        samplesSinceSource += 1
        wasCharging = isCharging
        reading.condition = cachedSource.condition
        if !reading.isFullyCharged { reading.minutesRemaining = cachedSource.minutes }
        return reading
    }

    /// Health verdict and macOS's own time estimate (the one `pmset -g batt` shows; -1 while
    /// calculating) from IOPowerSources for the internal battery.
    private static func powerSource(isCharging: Bool) -> (condition: String?, minutes: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil) }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let minutes = description[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            return (description[kIOPSBatteryHealthKey] as? String, minutes.flatMap { $0 > 0 ? $0 : nil })
        }
        return (nil, nil)
    }
}
