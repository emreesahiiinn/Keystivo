import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import KeystivoCore
import Observation

/// Battery and power-source state, updated by IOKit power-source notifications.
@Observable
public final class PowerMonitor {
    public static let shared = PowerMonitor()

    public private(set) var hasBattery = false
    public private(set) var batteryLevel: Int?
    public private(set) var isCharging = false
    public private(set) var isOnAC = true
    public private(set) var minutesRemaining: Int?
    public private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    public private(set) var thermalState = ProcessInfo.processInfo.thermalState
    public private(set) var cycleCount: Int?
    public private(set) var batteryHealth: String?
    public private(set) var batteryDetails: BatteryDetails?

    /// (isOnAC, level, previousLevel)
    @ObservationIgnored public var onChange: (@MainActor (_ onAC: Bool, _ level: Int?, _ previousLevel: Int?, _ sourceChanged: Bool) -> Void)?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    public init() {}

    public func start() {
        refresh(notify: false)
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().refresh(notify: true)
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalState = ProcessInfo.processInfo.thermalState }
        })
    }

    public func refresh(notify: Bool) {
        let previousLevel = batteryLevel
        let previousAC = isOnAC
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        isOnAC = providing != kIOPSBatteryPowerValue
        hasBattery = false
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            if let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                batteryLevel = Int((Double(current) / Double(max) * 100).rounded())
            }
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let remaining = (isOnAC ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            minutesRemaining = (remaining ?? -1) > 0 ? remaining : nil
            batteryHealth = description[kIOPSBatteryHealthKey] as? String
        }
        if !hasBattery { batteryLevel = nil }
        let details = hasBattery ? Self.readDetails() : nil
        cycleCount = details?.cycleCount
        batteryDetails = details
        if notify { onChange?(isOnAC, batteryLevel, previousLevel, previousAC != isOnAC) }
    }

    /// Everything AppleSmartBattery reports that's worth showing (coconutBattery-style).
    private static func readDetails() -> BatteryDetails? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatteryDetails(dictionary)
    }

    public var symbolName: String {
        guard hasBattery, let level = batteryLevel else { return "powerplug" }
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Keep awake

nonisolated public enum KeepAwakeMode: String, Codable, Sendable, CaseIterable {
    case off
    /// Prevent idle system sleep; the display may still sleep.
    case system
    /// Prevent display sleep too (presentations, long reads).
    case display

    public var titleKey: String { "keepAwake.\(rawValue)" }
}

/// IOPMAssertion wrapper ("caffeinate"), optionally with an expiry.
@Observable
public final class KeepAwakeController {
    public static let shared = KeepAwakeController()

    public private(set) var mode: KeepAwakeMode = .off
    public private(set) var expiresAt: Date?
    /// Whether a power profile (not the user) chose the current mode.
    public var isSetByProfile = false
    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    public init() {}

    public func set(_ mode: KeepAwakeMode, duration: TimeInterval? = nil) {
        release()
        self.mode = mode
        guard mode != .off else { return }
        let type = (mode == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        let reason = "Keystivo: \(L("keepAwake.reason"))" as CFString
        if IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertionID) != kIOReturnSuccess {
            self.mode = .off
            DiagnosticsCenter.shared.record(.error, module: "Power", L("keepAwake.error"))
            return
        }
        if let duration {
            expiresAt = .now.addingTimeInterval(duration)
            expiryTask = Task {
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                set(.off)
            }
        }
    }

    public func toggle() {
        isSetByProfile = false
        set(mode == .off ? .system : .off)
    }

    private func release() {
        expiryTask?.cancel()
        expiryTask = nil
        expiresAt = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}

// MARK: - Power profiles

/// "Pil ve güç profilleri".
nonisolated public struct PowerProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var keepAwake: KeepAwakeMode
    /// Apps quit when the profile is applied (e.g. energy-hungry helpers).
    public var quitApps: [String]
    /// Apps hidden when the profile is applied.
    public var hideApps: [String]
    /// Turn off per-app audio processing to save energy.
    public var suspendsAppAudio: Bool
    /// Pause clipboard monitoring while active.
    public var pausesClipboard: Bool
    /// Automatically apply when switching to this power source.
    public var autoApplyOn: String?

    public init(id: String = UUID().uuidString, name: String, symbolName: String = "bolt", keepAwake: KeepAwakeMode = .off,
                quitApps: [String] = [], hideApps: [String] = [], suspendsAppAudio: Bool = false, pausesClipboard: Bool = false, autoApplyOn: String? = nil) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.keepAwake = keepAwake
        self.quitApps = quitApps
        self.hideApps = hideApps
        self.suspendsAppAudio = suspendsAppAudio
        self.pausesClipboard = pausesClipboard
        self.autoApplyOn = autoApplyOn
    }

    public static let builtIn: [PowerProfile] = [
        PowerProfile(id: "balanced", name: L("power.profile.balanced"), symbolName: "leaf"),
        PowerProfile(id: "saver", name: L("power.profile.saver"), symbolName: "battery.25percent", suspendsAppAudio: true, pausesClipboard: false, autoApplyOn: "battery"),
        PowerProfile(id: "performance", name: L("power.profile.performance"), symbolName: "hare", keepAwake: .system, autoApplyOn: "ac"),
        PowerProfile(id: "presentation", name: L("power.profile.presentation"), symbolName: "play.rectangle", keepAwake: .display),
    ]
}

public enum PowerProfileApplier {
    public static func apply(_ profile: PowerProfile, keepAwake: KeepAwakeController = .shared) {
        // A profile without keep-awake doesn't cancel one the user turned on.
        if profile.keepAwake != .off || keepAwake.isSetByProfile || keepAwake.mode == .off {
            keepAwake.set(profile.keepAwake)
            keepAwake.isSetByProfile = profile.keepAwake != .off
        }
        for bundleID in profile.quitApps {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        }
        for bundleID in profile.hideApps {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.hide() }
        }
    }
}


/// Battery health and live power figures from AppleSmartBattery. Pure parsing, unit-tested.
nonisolated public struct BatteryDetails: Equatable, Sendable {
    /// Full-charge capacity now and as designed (mAh).
    public var maxCapacity: Int?
    public var designCapacity: Int?
    public var cycleCount: Int?
    public var designCycleCount: Int?
    /// °C.
    public var temperature: Double?
    /// Positive while charging, negative while discharging (W).
    public var power: Double?
    /// The connected adapter's rating (W).
    public var adapterWatts: Int?
    public var adapterName: String?
    public var serialNumber: String?
    public var manufactureDate: Date?

    /// Remaining capacity versus new, in percent.
    public var health: Int? {
        guard let maxCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())
    }

    public init(_ registry: [String: Any]) {
        // Apple Silicon reports the real full-charge capacity as AppleRawMaxCapacity;
        // MaxCapacity is a percentage there.
        maxCapacity = registry["AppleRawMaxCapacity"] as? Int ?? (registry["MaxCapacity"] as? Int).flatMap { $0 > 100 ? $0 : nil }
        designCapacity = registry["DesignCapacity"] as? Int
        cycleCount = registry["CycleCount"] as? Int
        designCycleCount = registry["DesignCycleCount9C"] as? Int
        // Hundredths of a degree Celsius (3050 = 30.5 °C).
        if let raw = registry["Temperature"] as? Int, raw > 0 {
            temperature = Double(raw) / 100
        }
        if let voltage = registry["Voltage"] as? Int, let amperage = registry["Amperage"] as? Int {
            let amps = Double(Int16(truncatingIfNeeded: amperage)) / 1000
            power = Double(voltage) / 1000 * amps
        }
        if let adapter = registry["AdapterDetails"] as? [String: Any] {
            adapterWatts = adapter["Watts"] as? Int
            adapterName = adapter["Name"] as? String ?? adapter["Description"] as? String
        }
        serialNumber = registry["Serial"] as? String ?? registry["BatterySerialNumber"] as? String
        // ManufactureDate packs (year − 1980) << 9 | month << 5 | day.
        if let packed = registry["ManufactureDate"] as? Int, packed > 0 {
            var components = DateComponents()
            components.year = 1980 + (packed >> 9)
            components.month = (packed >> 5) & 0xF
            components.day = packed & 0x1F
            manufactureDate = Calendar(identifier: .gregorian).date(from: components)
        }
    }
}
