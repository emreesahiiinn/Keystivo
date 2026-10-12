import AppKit
import CoreGraphics
import IOKit
import KeystivoCore
import Observation

// MARK: - DDC/CI protocol

/// DDC/CI (VESA Monitor Control Command Set) packets for external monitors.
nonisolated public enum DDC {
    /// 7-bit I²C address of the monitor's DDC/CI endpoint.
    public static let chipAddress: UInt32 = 0x37
    /// Host (source) address, sent as the I²C sub-address.
    public static let hostAddress: UInt32 = 0x51

    public enum Feature: UInt8, Sendable {
        case brightness = 0x10
        case contrast = 0x12
        case volume = 0x62
        case inputSource = 0x60
    }

    /// Common MCCS input source codes (some monitors use vendor-specific ones).
    public enum Input: UInt16, CaseIterable, Sendable, Identifiable {
        case vga1 = 0x01, dvi1 = 0x03, displayPort1 = 0x0F, displayPort2 = 0x10, hdmi1 = 0x11, hdmi2 = 0x12, usbC = 0x1B
        public var id: UInt16 { rawValue }
        public var title: String {
            switch self {
            case .vga1: "VGA"
            case .dvi1: "DVI"
            case .displayPort1: "DisplayPort 1"
            case .displayPort2: "DisplayPort 2"
            case .hdmi1: "HDMI 1"
            case .hdmi2: "HDMI 2"
            case .usbC: "USB-C"
            }
        }
    }

    /// "Get VCP Feature" request.
    public static func readRequest(_ code: UInt8) -> [UInt8] {
        packet([0x01, code])
    }

    /// "Set VCP Feature" request.
    public static func writeRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        packet([0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Length byte + payload + checksum. The checksum XORs the destination
    /// address (0x6E), the source address (0x51) and every packet byte.
    static func packet(_ payload: [UInt8]) -> [UInt8] {
        var bytes = [0x80 | UInt8(payload.count)] + payload
        bytes.append(bytes.reduce(0x6E ^ 0x51, ^))
        return bytes
    }

    /// Parses an 11-byte "VCP Feature Reply". Returns nil for corrupt or unsupported replies.
    public static func parseReply(_ reply: [UInt8], code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard reply.count >= 11 else { return nil }
        // Replies come from the monitor (0x6E) to the host's virtual address 0x50.
        guard reply[0..<10].reduce(UInt8(0x50), ^) == reply[10] else { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0 else { return nil }
        return (min(current, maximum), maximum)
    }
}

/// The identifying part of a monitor's EDID, used to pair I²C services with displays.
nonisolated public struct EDIDIdentity: Hashable, Sendable {
    public let vendor: UInt32
    public let product: UInt32
    public let serial: UInt32

    public init(vendor: UInt32, product: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
    }

    public init?(edid: [UInt8]) {
        guard edid.count >= 16, Array(edid[0..<8]) == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00] else { return nil }
        // Manufacturer ID is big-endian; product code and serial are little-endian.
        vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
        product = UInt32(edid[10]) | UInt32(edid[11]) << 8
        serial = UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24
    }

    /// Pairs services (by index) with displays. Exact matches first, then
    /// vendor + product, then a single leftover on each side.
    public static func match(services: [EDIDIdentity?], displays: [(id: CGDirectDisplayID, identity: EDIDIdentity)]) -> [Int: CGDirectDisplayID] {
        var result: [Int: CGDirectDisplayID] = [:]
        var remaining = displays
        func take(_ index: Int, where predicate: (EDIDIdentity) -> Bool) {
            let candidates = remaining.filter { predicate($0.identity) }
            guard candidates.count == 1, let display = candidates.first else { return }
            result[index] = display.id
            remaining.removeAll { $0.id == display.id }
        }
        for (index, identity) in services.enumerated() {
            guard let identity, identity.serial != 0 else { continue }
            take(index) { $0 == identity }
        }
        for (index, identity) in services.enumerated() where result[index] == nil {
            guard let identity else { continue }
            take(index) { $0.vendor == identity.vendor && $0.product == identity.product }
        }
        let unmatched = services.indices.filter { result[$0] == nil }
        if unmatched.count == 1, remaining.count == 1 { result[unmatched[0]] = remaining[0].id }
        return result
    }
}

// MARK: - Private frameworks

/// IOAVService (Apple Silicon) I²C access, resolved at runtime.
nonisolated struct IOAVServiceAPI: @unchecked Sendable {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    let create: Create
    let copyEDID: CopyEDID
    let read: Transfer
    let write: Transfer

    static let shared: IOAVServiceAPI? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let copyEDID = dlsym(handle, "IOAVServiceCopyEDID"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
        return IOAVServiceAPI(
            create: unsafeBitCast(create, to: Create.self),
            copyEDID: unsafeBitCast(copyEDID, to: CopyEDID.self),
            read: unsafeBitCast(read, to: Transfer.self),
            write: unsafeBitCast(write, to: Transfer.self)
        )
    }()
}

/// DisplayServices brightness for the built-in display and Apple displays.
nonisolated struct DisplayServicesAPI: @unchecked Sendable {
    typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    let canChange: CanChange
    let get: Get
    let set: Set

    static let shared: DisplayServicesAPI? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness"),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return DisplayServicesAPI(
            canChange: unsafeBitCast(canChange, to: CanChange.self),
            get: unsafeBitCast(get, to: Get.self),
            set: unsafeBitCast(set, to: Set.self)
        )
    }()

    func brightness(of display: CGDirectDisplayID) -> Double? {
        guard canChange(display) else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? Double(value) : nil
    }
}

/// One external monitor's DDC/CI channel. I²C transfers are slow and must not
/// overlap, so every call is serialized and runs off the main thread.
nonisolated final class DDCChannel: @unchecked Sendable {
    private let service: CFTypeRef
    private let api: IOAVServiceAPI
    private let lock = NSLock()

    init(service: CFTypeRef, api: IOAVServiceAPI) {
        self.service = service
        self.api = api
    }

    func read(_ feature: DDC.Feature) -> (current: UInt16, maximum: UInt16)? {
        lock.withLock {
            var request = DDC.readRequest(feature.rawValue)
            for _ in 0..<4 {
                for _ in 0..<2 {
                    usleep(10_000)
                    _ = api.write(service, DDC.chipAddress, DDC.hostAddress, &request, UInt32(request.count))
                }
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: 11)
                if api.read(service, DDC.chipAddress, DDC.hostAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                   let value = DDC.parseReply(reply, code: feature.rawValue) {
                    return value
                }
                usleep(20_000)
            }
            return nil
        }
    }

    @discardableResult
    func write(_ feature: DDC.Feature, value: UInt16) -> Bool {
        lock.withLock {
            var request = DDC.writeRequest(feature.rawValue, value: value)
            var succeeded = false
            // Some monitors drop single writes; sending twice is the common practice.
            for _ in 0..<2 {
                usleep(10_000)
                if api.write(service, DDC.chipAddress, DDC.hostAddress, &request, UInt32(request.count)) == kIOReturnSuccess { succeeded = true }
            }
            return succeeded
        }
    }

    /// External DCP AV services with their EDID identity.
    static func discover() -> [(channel: DDCChannel, identity: EDIDIdentity?)] {
        guard let api = IOAVServiceAPI.shared else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(DDCChannel, EDIDIdentity?)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External", let service = api.create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var edid: Unmanaged<CFData>?
            let identity = api.copyEDID(service, &edid) == kIOReturnSuccess ? edid.flatMap { EDIDIdentity(edid: [UInt8]($0.takeRetainedValue() as Data)) } : nil
            result.append((DDCChannel(service: service, api: api), identity))
        }
        return result
    }
}

// MARK: - Brightness controller

/// Hardware brightness for every display: DisplayServices for built-in and
/// Apple displays, DDC/CI for external monitors, and a gamma fallback.
@Observable
public final class BrightnessController {
    public static let shared = BrightnessController()

    public enum Method: String, Sendable {
        case native, ddc, software
    }

    public struct Target: Identifiable, Hashable, Sendable {
        public let id: CGDirectDisplayID
        public let name: String
        public let method: Method
        public internal(set) var brightness: Double
    }

    public private(set) var targets: [Target] = []
    public private(set) var isScanning = false
    /// Called after keyboard or action adjustments (for the HUD).
    @ObservationIgnored public var onAdjust: ((Target) -> Void)?

    @ObservationIgnored private var channels: [CGDirectDisplayID: (channel: DDCChannel, maximum: UInt16)] = [:]
    @ObservationIgnored private var pendingWrites: [CGDirectDisplayID: UInt16] = [:]
    @ObservationIgnored private var writing: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.keystivo.ddc", qos: .userInitiated)
    @ObservationIgnored private let reloadDebouncer = Debouncer(delay: .milliseconds(1500))

    /// Gamma used for "0%" in software mode, so the screen never goes fully black.
    nonisolated static let softwareFloor = 0.15

    public init() {}

    public func start() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadDebouncer.schedule { self?.reload() } }
        }
        reload()
    }

    /// Rediscovers displays. DDC reads take ~100 ms each, so this runs in the background.
    public func reload() {
        generation += 1
        let generation = generation
        let screens = NSScreen.screens.map { (id: $0.displayID, name: $0.localizedName) }
        isScanning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let discovered = Self.discover(screens)
            await MainActor.run {
                guard let self, generation == self.generation else { return }
                self.apply(discovered)
            }
        }
    }

    private struct Discovered: Sendable {
        let id: CGDirectDisplayID
        let name: String
        let method: Method
        let brightness: Double?
        let channel: DDCChannel?
        let maximum: UInt16
    }

    nonisolated private static func discover(_ screens: [(id: CGDirectDisplayID, name: String)]) -> [Discovered] {
        let services = DDCChannel.discover()
        let identities = screens.map { (id: $0.id, identity: EDIDIdentity(vendor: CGDisplayVendorNumber($0.id), product: CGDisplayModelNumber($0.id), serial: CGDisplaySerialNumber($0.id))) }
        let external = identities.filter { CGDisplayIsBuiltin($0.id) == 0 }
        let pairs = EDIDIdentity.match(services: services.map(\.identity), displays: external)
        var channelByDisplay: [CGDirectDisplayID: DDCChannel] = [:]
        for (index, display) in pairs { channelByDisplay[display] = services[index].channel }

        return screens.map { screen in
            if let value = DisplayServicesAPI.shared?.brightness(of: screen.id) {
                return Discovered(id: screen.id, name: screen.name, method: .native, brightness: value, channel: nil, maximum: 0)
            }
            if let channel = channelByDisplay[screen.id], let value = channel.read(.brightness) {
                return Discovered(id: screen.id, name: screen.name, method: .ddc, brightness: Double(value.current) / Double(value.maximum), channel: channel, maximum: value.maximum)
            }
            return Discovered(id: screen.id, name: screen.name, method: .software, brightness: nil, channel: nil, maximum: 0)
        }
    }

    private func apply(_ discovered: [Discovered]) {
        isScanning = false
        channels = [:]
        for item in discovered {
            if let channel = item.channel { channels[item.id] = (channel, item.maximum) }
        }
        targets = discovered.map { item in
            let brightness = item.brightness ?? Self.brightness(fromGamma: DisplayManager.shared.dimming[item.id] ?? 1)
            return Target(id: item.id, name: item.name, method: item.method, brightness: brightness)
        }
    }

    // MARK: Contrast, volume, input (DDC monitors)

    /// A DDC monitor's other controls, read on demand (each read takes ~100 ms).
    public struct MonitorControls: Equatable, Sendable {
        public var contrast: Double?
        public var volume: Double?
        public var input: UInt16?
    }

    public private(set) var monitorControls: [CGDirectDisplayID: MonitorControls] = [:]
    @ObservationIgnored private var featureMaximums: [String: UInt16] = [:]

    public func supportsMonitorControls(_ display: CGDirectDisplayID) -> Bool { channels[display] != nil }

    /// Reads contrast, volume and input of a DDC monitor in the background.
    public func loadMonitorControls(_ display: CGDirectDisplayID) {
        guard let channel = channels[display]?.channel else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let contrast = channel.read(.contrast)
            let volume = channel.read(.volume)
            let input = channel.read(.inputSource)
            await MainActor.run {
                guard let self else { return }
                if let contrast { self.featureMaximums["\(display)-\(DDC.Feature.contrast.rawValue)"] = contrast.maximum }
                if let volume { self.featureMaximums["\(display)-\(DDC.Feature.volume.rawValue)"] = volume.maximum }
                self.monitorControls[display] = MonitorControls(
                    contrast: contrast.map { Double($0.current) / Double(max($0.maximum, 1)) },
                    volume: volume.map { Double($0.current) / Double(max($0.maximum, 1)) },
                    input: input.map { $0.current & 0xFF }
                )
            }
        }
    }

    /// Sets contrast or volume (0…1); writes are coalesced while dragging a slider.
    public func setMonitorValue(_ value: Double, feature: DDC.Feature, for display: CGDirectDisplayID) {
        guard let channel = channels[display]?.channel, feature == .contrast || feature == .volume else { return }
        let fraction = min(1, max(0, value))
        if feature == .contrast { monitorControls[display, default: MonitorControls()].contrast = fraction }
        if feature == .volume { monitorControls[display, default: MonitorControls()].volume = fraction }
        let key = "\(display)-\(feature.rawValue)"
        let raw = UInt16((fraction * Double(featureMaximums[key] ?? 100)).rounded())
        pendingFeatureWrites[key] = raw
        guard !writingFeatures.contains(key) else { return }
        writingFeatures.insert(key)
        drainFeature(key, feature: feature, channel: channel)
    }

    @ObservationIgnored private var pendingFeatureWrites: [String: UInt16] = [:]
    @ObservationIgnored private var writingFeatures: Set<String> = []

    private func drainFeature(_ key: String, feature: DDC.Feature, channel: DDCChannel) {
        guard let value = pendingFeatureWrites.removeValue(forKey: key) else {
            writingFeatures.remove(key)
            return
        }
        queue.async { [weak self] in
            channel.write(feature, value: value)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.drainFeature(key, feature: feature, channel: channel) }
            }
        }
    }

    /// Switches the monitor to another input (the Mac's picture may disappear).
    public func setInput(_ input: UInt16, for display: CGDirectDisplayID) {
        guard let channel = channels[display]?.channel else { return }
        monitorControls[display, default: MonitorControls()].input = input
        queue.async { channel.write(.inputSource, value: input) }
    }

    // MARK: Setting brightness

    public func setBrightness(_ value: Double, for display: CGDirectDisplayID) {
        guard let index = targets.firstIndex(where: { $0.id == display }) else { return }
        let value = min(1, max(0, value))
        targets[index].brightness = value
        switch targets[index].method {
        case .native:
            _ = DisplayServicesAPI.shared?.set(display, Float(value))
        case .ddc:
            guard let entry = channels[display] else { return }
            pendingWrites[display] = UInt16((value * Double(entry.maximum)).rounded())
            if !writing.contains(display) { drainWrites(for: display, channel: entry.channel) }
        case .software:
            DisplayManager.shared.setDimming(Self.gamma(fromBrightness: value), for: display)
        }
    }

    /// Steps the brightness of `display` (or the display under the mouse).
    public func adjust(by delta: Double, display: CGDirectDisplayID? = nil) {
        guard let id = display ?? NSScreen.underMouse?.displayID ?? targets.first?.id,
              let target = targets.first(where: { $0.id == id }) else { return }
        // Snap to the step grid so repeated presses land on round values.
        let step = abs(delta)
        let raw = target.brightness + delta
        let snapped = step > 0 ? (raw / step).rounded() * step : raw
        setBrightness(snapped, for: id)
        if let updated = targets.first(where: { $0.id == id }) { onAdjust?(updated) }
    }

    public func target(for display: CGDirectDisplayID) -> Target? {
        targets.first { $0.id == display }
    }

    /// Coalesces slider drags: only the latest value is written once the previous write finishes.
    private func drainWrites(for display: CGDirectDisplayID, channel: DDCChannel) {
        guard let value = pendingWrites.removeValue(forKey: display) else {
            writing.remove(display)
            return
        }
        writing.insert(display)
        queue.async { [weak self] in
            channel.write(.brightness, value: value)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.drainWrites(for: display, channel: channel) }
            }
        }
    }

    nonisolated static func gamma(fromBrightness value: Double) -> Double {
        softwareFloor + (1 - softwareFloor) * min(1, max(0, value))
    }

    nonisolated static func brightness(fromGamma gamma: Double) -> Double {
        min(1, max(0, (gamma - softwareFloor) / (1 - softwareFloor)))
    }
}

// MARK: - Brightness keys

/// Makes the keyboard's brightness keys work on external monitors. Events for
/// displays macOS already controls (built-in, Apple displays) pass through.
public final class BrightnessKeyHandler: EventTapHandler {
    public static let shared = BrightnessKeyHandler()

    public var isEnabled = false {
        didSet { if isEnabled != oldValue { EventTapManager.shared.refresh() } }
    }
    /// Fraction per key press (default 1/16, like macOS).
    public var step = 1.0 / 16

    static let systemDefined = CGEventType(rawValue: 14)!
    static let brightnessUp = 2
    static let brightnessDown = 3

    public init() {}

    public var eventTapPriority: Int { 650 }
    public var eventTapTypes: Set<CGEventType> { isEnabled ? [Self.systemDefined] : [] }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        guard type == Self.systemDefined, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return .pass }
        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        guard keyCode == Self.brightnessUp || keyCode == Self.brightnessDown else { return .pass }
        let controller = BrightnessController.shared
        guard let screen = NSScreen.underMouse, let target = controller.target(for: screen.displayID), target.method != .native else { return .pass }
        let isKeyDown = (nsEvent.data1 & 0xFF00) >> 8 == 0x0A
        if isKeyDown {
            // ⌥⇧ gives quarter steps, as in macOS.
            let fine = nsEvent.modifierFlags.contains([.option, .shift])
            let amount = fine ? step / 4 : step
            controller.adjust(by: keyCode == Self.brightnessUp ? amount : -amount, display: target.id)
        }
        return .consume
    }
}
