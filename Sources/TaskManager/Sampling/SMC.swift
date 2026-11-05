import Foundation
import IOKit

/// Minimal reader for the System Management Controller (AppleSMC), used for GPU temperature.
/// SMC keys are four-character codes; GPU temperature sensors start with "Tg".
/// Key names differ between chips, so the sensors are discovered by enumerating all keys.
final class SMC {
    // Matches the C struct SMCKeyData_t used by the AppleSMC user client (80 bytes).
    private struct KeyData {
        struct Version {
            var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
            var release: UInt16 = 0
        }
        struct LimitData {
            var version: UInt16 = 0, length: UInt16 = 0
            var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
        }
        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }
        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readKey = 5
        case keyFromIndex = 8
        case keyInfo = 9
    }

    private struct Sensor {
        let key: UInt32
        let info: KeyData.KeyInfo
    }

    private var connection: io_connect_t = 0
    private var gpuSensors: [Sensor] = []

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        assert(MemoryLayout<KeyData>.size == 80, "SMCKeyData_t layout mismatch")
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        gpuSensors = discoverSensors(prefix: "Tg")
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    var hasGPUSensors: Bool { !gpuSensors.isEmpty }

    /// Average of the GPU temperature sensors that currently report a plausible value, in °C.
    func gpuTemperature() -> Double? {
        let values = gpuSensors.compactMap { read($0) }.filter { $0 > 0 && $0 < 150 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: Private

    private func discoverSensors(prefix: String) -> [Sensor] {
        guard let countBytes = readRaw(key: Self.fourCC("#KEY")), countBytes.count >= 4 else { return [] }
        let count = countBytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        var sensors: [Sensor] = []
        for index in 0..<min(count, 10_000) {
            var input = KeyData()
            input.command = Command.keyFromIndex.rawValue
            input.data32 = index
            guard let output = call(&input) else { continue }
            let name = Self.string(output.key)
            guard name.hasPrefix(prefix), let info = keyInfo(output.key) else { continue }
            let type = Self.string(info.dataType)
            guard type == "flt " || type == "sp78" else { continue }
            sensors.append(Sensor(key: output.key, info: info))
        }
        // Keep only sensors that report a plausible temperature right now.
        return sensors.filter { read($0).map { $0 > 0 && $0 < 150 } ?? false }
    }

    private func keyInfo(_ key: UInt32) -> KeyData.KeyInfo? {
        var input = KeyData()
        input.key = key
        input.command = Command.keyInfo.rawValue
        return call(&input)?.keyInfo
    }

    private func read(_ sensor: Sensor) -> Double? {
        guard let bytes = readRaw(key: sensor.key, info: sensor.info) else { return nil }
        switch Self.string(sensor.info.dataType) {
        case "flt " where bytes.count >= 4:
            // Apple Silicon: little-endian 32-bit float.
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78" where bytes.count >= 2:
            // Intel: signed 8.8 fixed point, big-endian.
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    private func readRaw(key: UInt32, info: KeyData.KeyInfo? = nil) -> [UInt8]? {
        guard let info = info ?? keyInfo(key) else { return nil }
        var input = KeyData()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.readKey.rawValue
        guard var output = call(&input) else { return nil }
        let size = Int(min(info.dataSize, 32))
        return withUnsafeBytes(of: &output.bytes) { Array($0.prefix(size)) }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &outputSize)
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
