import AppKit
import Carbon.HIToolbox
import IOKit.hid
import KeystivoCore
import Observation

nonisolated public struct InputSourceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let languages: [String]
}

/// Keyboard layout / input method switching and per-app/per-device profiles
/// ("klavye ve giriş cihazı profilleri").
@Observable
public final class InputSourceManager {
    public static let shared = InputSourceManager()

    public private(set) var sources: [InputSourceInfo] = []
    public private(set) var currentID: String?
    /// bundle ID → input source ID applied when that app becomes active.
    public var appRules: [String: String] = [:]
    /// Remember the last input source used in each app automatically.
    public var remembersPerApp = false
    @ObservationIgnored private var remembered: [String: String] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastApp: String?

    public init() {}

    public func start() {
        reload()
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.currentID = Self.currentSourceID() }
        })
        observers.append(center.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(bundleID) }
        })
    }

    public func reload() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String, kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        sources = list.compactMap { source in
            guard let id = Self.property(source, kTISPropertyInputSourceID) as String?,
                  let name = Self.property(source, kTISPropertyLocalizedName) as String? else { return nil }
            let languages = (Self.property(source, kTISPropertyInputSourceLanguages) as [String]?) ?? []
            return InputSourceInfo(id: id, name: name, languages: languages)
        }
        currentID = Self.currentSourceID()
    }

    private func appActivated(_ bundleID: String?) {
        if remembersPerApp, let lastApp, let currentID { remembered[lastApp] = currentID }
        lastApp = bundleID
        guard let bundleID else { return }
        if let target = appRules[bundleID] ?? (remembersPerApp ? remembered[bundleID] : nil), target != currentID {
            select(id: target)
        }
    }

    @discardableResult
    public func select(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return false }
        let ok = TISSelectInputSource(source) == noErr
        currentID = Self.currentSourceID()
        return ok
    }

    /// Cycles through enabled input sources.
    public func selectNext() {
        guard !sources.isEmpty else { return }
        let index = sources.firstIndex { $0.id == currentID } ?? -1
        select(id: sources[(index + 1) % sources.count].id)
    }

    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(source, kTISPropertyInputSourceID)
    }

    static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}

// MARK: - Input devices

nonisolated public struct InputDeviceInfo: Identifiable, Hashable, Sendable {
    public var id: String { "\(vendorID):\(productID):\(name)" }
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let kind: Kind

    public enum Kind: String, Codable, Sendable { case keyboard, mouse, trackpad }
}

/// A profile applied when a specific keyboard/mouse is connected.
nonisolated public struct InputDeviceProfile: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    /// Matches ``InputDeviceInfo/id`` or a case-insensitive substring of the device name.
    public var deviceMatch: String
    public var inputSourceID: String?
    /// Actions to run on connect (e.g. switch audio profile, swap modifier-heavy shortcuts).
    public var onConnect: [ActionInvocation] = []
    public var onDisconnect: [ActionInvocation] = []
    public var isEnabled = true

    public init(deviceMatch: String) { self.deviceMatch = deviceMatch }

    public func matches(_ device: InputDeviceInfo) -> Bool {
        device.id == deviceMatch || device.name.localizedCaseInsensitiveContains(deviceMatch)
    }
}

/// Tracks connected HID keyboards/mice via IOKit matching notifications.
@Observable
public final class InputDeviceMonitor {
    public static let shared = InputDeviceMonitor()

    public private(set) var devices: [InputDeviceInfo] = []
    @ObservationIgnored public var onConnect: (@MainActor (InputDeviceInfo) -> Void)?
    @ObservationIgnored public var onDisconnect: (@MainActor (InputDeviceInfo) -> Void)?
    @ObservationIgnored private var manager: IOHIDManager?
    @ObservationIgnored private var initialEnumerationDone = false

    public init() {}

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let info = InputDeviceMonitor.info(for: device)
            MainActor.assumeIsolated {
                Unmanaged<InputDeviceMonitor>.fromOpaque(context).takeUnretainedValue().added(info)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let info = InputDeviceMonitor.info(for: device)
            MainActor.assumeIsolated {
                Unmanaged<InputDeviceMonitor>.fromOpaque(context).takeUnretainedValue().removed(info)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Opening without seizing only enumerates devices; no input is read.
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        DispatchQueue.main.async { MainActor.assumeIsolated { self.initialEnumerationDone = true } }
    }

    nonisolated static func info(for device: IOHIDDevice) -> InputDeviceInfo {
        func property<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        let usage: Int = property(kIOHIDPrimaryUsageKey) ?? 0
        let name: String = property(kIOHIDProductKey) ?? "HID"
        let kind: InputDeviceInfo.Kind = usage == kHIDUsage_GD_Keyboard ? .keyboard : (name.localizedCaseInsensitiveContains("trackpad") ? .trackpad : .mouse)
        return InputDeviceInfo(name: name, vendorID: property(kIOHIDVendorIDKey) ?? 0, productID: property(kIOHIDProductIDKey) ?? 0, kind: kind)
    }

    private func added(_ device: InputDeviceInfo) {
        guard !devices.contains(device) else { return }
        devices.append(device)
        if initialEnumerationDone { onConnect?(device) }
    }

    private func removed(_ device: InputDeviceInfo) {
        devices.removeAll { $0 == device }
        onDisconnect?(device)
    }
}
