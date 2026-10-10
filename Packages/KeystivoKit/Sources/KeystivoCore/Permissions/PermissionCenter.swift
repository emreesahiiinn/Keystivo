import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Security
import Observation

nonisolated public enum PermissionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case audioCapture
    case automation

    public var id: String { rawValue }

    public var titleKey: String { "permission.\(rawValue).title" }
    public var reasonKey: String { "permission.\(rawValue).reason" }

    public var symbolName: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .inputMonitoring: "keyboard.badge.eye"
        case .audioCapture: "waveform"
        case .automation: "gearshape.2"
        }
    }

    /// Whether core features stop working without it.
    public var isEssential: Bool { self == .accessibility }

    /// Deep link into the matching System Settings privacy pane.
    public var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .audioCapture: "Privacy_AudioCapture"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

nonisolated public enum PermissionStatus: String, Sendable, Codable {
    case granted
    case denied
    case notDetermined
    /// macOS offers no reliable preflight API; status is learned on first use.
    case unknown
}

/// Single source of truth for TCC permission state. Refreshes on app activation and
/// on the accessibility-trust distributed notification instead of continuous polling.
@Observable
public final class PermissionCenter {
    public static let shared = PermissionCenter()

    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// Called after any status changes (e.g. to start features once access is granted).
    @ObservationIgnored public var onChange: (@MainActor (_ old: [PermissionKind: PermissionStatus], _ new: [PermissionKind: PermissionStatus]) -> Void)?

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard

    public init() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Posted by the system whenever the accessibility trust list changes.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The TCC database is updated slightly after the notification fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        })
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .unknown }
    public func isGranted(_ kind: PermissionKind) -> Bool { status(kind) == .granted }

    public var missingEssential: Bool { !isGranted(.accessibility) }

    /// True for locally built, ad-hoc signed copies. Their privacy grants are
    /// tied to the exact build, so a stale entry can look enabled in System
    /// Settings while access is still denied.
    public static let isAdHocSigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || dict[kSecCodeInfoTeamIdentifier as String] == nil
    }()

    public func refresh() {
        var next: [PermissionKind: PermissionStatus] = [:]
        next[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        next[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .denied
        next[.inputMonitoring] = switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .notDetermined
        }
        next[.audioCapture] = PermissionStatus(rawValue: defaults.string(forKey: "permission.audioCapture") ?? "") ?? .unknown
        next[.automation] = automationStatus(bundleID: "com.apple.systemevents")
        if next != statuses {
            let old = statuses
            statuses = next
            onChange?(old, next)
        }
    }

    /// Records the outcome of an operation that implicitly requires a permission
    /// (e.g. creating an audio process tap).
    public func noteOutcome(_ kind: PermissionKind, granted: Bool) {
        if kind == .audioCapture {
            defaults.set(granted ? PermissionStatus.granted.rawValue : PermissionStatus.denied.rawValue, forKey: "permission.audioCapture")
        }
        refresh()
    }

    public func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .inputMonitoring:
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { openSettings(kind) }
        case .audioCapture:
            openSettings(kind)
        case .automation:
            Task.detached {
                _ = Self.requestAutomation(bundleID: "com.apple.systemevents")
                await MainActor.run { PermissionCenter.shared.refresh() }
            }
        }
        startWatching()
    }

    public func openSettings(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
        startWatching()
    }

    /// Short-lived watcher while the user is in System Settings granting access.
    public func startWatching(duration: TimeInterval = 60) {
        watchTimer?.invalidate()
        let deadline = Date.now.addingTimeInterval(duration)
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if Date.now > deadline {
                    self.watchTimer?.invalidate()
                    self.watchTimer = nil
                }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func automationStatus(bundleID: String) -> PermissionStatus {
        var target = AEAddressDesc()
        defer { AEDisposeDesc(&target) }
        let created = bundleID.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &target)
        }
        guard created == noErr else { return .unknown }
        let result = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch Int(result) {
        case Int(noErr): return .granted
        case Int(errAEEventNotPermitted): return .denied
        case -1744: return .notDetermined // errAEEventWouldRequireUserConsent
        default: return .unknown // e.g. procNotFound when the target isn't running
        }
    }

    private nonisolated static func requestAutomation(bundleID: String) -> OSStatus {
        var target = AEAddressDesc()
        defer { AEDisposeDesc(&target) }
        let created = bundleID.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &target)
        }
        guard created == noErr else { return OSStatus(created) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
    }
}
