import Foundation
import IOKit
import KeystivoHelperCore

/// One temperature sensor.
nonisolated public struct SensorReading: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// °C
    public let value: Double
}

/// One fan.
nonisolated public struct FanReading: Identifiable, Hashable, Sendable {
    public let id: Int
    public let rpm: Double
    public let minRPM: Double?
    public let maxRPM: Double?
}

/// GPU load, temperatures, fans and system power (iStat Menus / Stats-style).
/// Reads only: IOAccelerator statistics, the HID thermal sensors Apple Silicon
/// exposes, and SMC keys. Nothing here needs privileges.
nonisolated public final class HardwareSensors: @unchecked Sendable {
    public static let shared = HardwareSensors()

    private let smc = SMC()
    private let lock = NSLock()

    public init() {}

    // MARK: GPU

    /// Device utilization (0…1) of the busiest GPU.
    public func gpuUsage() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let percent = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? Int {
                best = max(best ?? 0, Double(percent) / 100)
            }
        }
        return best
    }

    // MARK: Temperatures

    /// Thermal sensors (Apple Silicon HID services), sorted by name.
    public func temperatures() -> [SensorReading] {
        lock.withLock { HIDThermal.read() }
            .filter { $0.value > 0 && $0.value < 130 }
            .sorted { $0.name < $1.name }
    }

    /// CPU die temperature: the hottest CPU sensor.
    public static func cpuTemperature(from sensors: [SensorReading]) -> Double? {
        let cpu = sensors.filter { sensor in
            let name = sensor.name.lowercased()
            return name.contains("tdie") || name.contains("pacc") || name.contains("eacc") || name.contains("cpu") || name.contains("soc mtr")
        }
        return (cpu.isEmpty ? sensors.filter { $0.name.lowercased().contains("pmu") } : cpu).map(\.value).max()
    }

    // MARK: SMC

    public func fans() -> [FanReading] {
        guard let smc, let count = smc.read("FNum")?.first, count > 0 else { return [] }
        return (0..<Int(count)).compactMap { index in
            guard let rpm = value("F\(index)Ac"), rpm.isFinite, rpm >= 0, rpm < 100_000 else { return nil }
            return FanReading(id: index, rpm: rpm, minRPM: value("F\(index)Mn"), maxRPM: value("F\(index)Mx"))
        }
    }

    /// Whole-system power draw in watts (Apple Silicon "PSTR").
    public func systemPower() -> Double? {
        guard let watts = value("PSTR"), watts > 0, watts < 1000 else { return nil }
        return watts
    }

    /// Decodes an SMC value by its declared type (flt, fpe2, sp78, ui8…).
    private func value(_ key: String) -> Double? {
        guard let smc, let info = smc.keyInfo(key), let bytes = smc.read(key) else { return nil }
        return Self.decode(bytes, type: info.dataType)
    }

    static func fourCC(_ value: UInt32) -> String {
        String(bytes: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)], encoding: .ascii) ?? ""
    }

    static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        switch fourCC(type) {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default: return nil
        }
    }
}

/// Apple Silicon temperature sensors through the IOHIDEventSystem (private API,
/// resolved at runtime; missing symbols simply mean "no sensors").
nonisolated private enum HIDThermal {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let createClient = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self)
    private static let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self)
    private static let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self)
    private static let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self)
    private static let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
    private static let getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloat.self)

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    static func read() -> [SensorReading] {
        guard let createClient, let setMatching, let copyServices, let copyProperty, let copyEvent, let getFloat,
              let client = createClient(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var readings: [String: Double] = [:]
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloat(event, temperatureField)
            // Several sensors can share a name; keep the hottest.
            readings[name] = max(readings[name] ?? 0, value)
        }
        return readings.map { SensorReading(name: $0.key, value: $0.value) }
    }
}
