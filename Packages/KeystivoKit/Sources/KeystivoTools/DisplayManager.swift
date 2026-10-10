import AppKit
import CoreGraphics
import KeystivoCore
import Observation

nonisolated public struct DisplayModeInfo: Identifiable, Hashable, Sendable {
    public let id: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double

    public var isHiDPI: Bool { pixelWidth > width }
    public var title: String {
        let rate = refreshRate > 0 ? " · \(Int(refreshRate.rounded())) Hz" : ""
        return "\(width) × \(height)\(isHiDPI ? " (HiDPI)" : "")\(rate)"
    }
}

nonisolated public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let isMain: Bool
    public let currentMode: DisplayModeInfo?
    public let modes: [DisplayModeInfo]
}

/// Resolution switching and software brightness ("BetterDisplay / MonitorControl lite").
///
/// Brightness for external displays is applied through the gamma table, which
/// works on any monitor without DDC; the original curves are restored on quit.
@Observable
public final class DisplayManager {
    public static let shared = DisplayManager()

    public private(set) var displays: [DisplayInfo] = []
    /// Software dimming per display (1 = untouched).
    public private(set) var dimming: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    public init() {}

    public func start() {
        reload()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                self?.reapplyDimming()
            }
        }
    }

    public func reload() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let names = Dictionary(NSScreen.screens.map { ($0.displayID, $0.localizedName) }, uniquingKeysWith: { first, _ in first })
        displays = ids.map { id in
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [])
                .filter { $0.isUsableForDesktopGUI() }
                .map(Self.info)
            var unique: [DisplayModeInfo] = []
            for mode in modes.sorted(by: { ($0.width, $0.isHiDPI ? 1 : 0, $0.refreshRate) > ($1.width, $1.isHiDPI ? 1 : 0, $1.refreshRate) })
            where !unique.contains(where: { $0.width == mode.width && $0.height == mode.height && $0.isHiDPI == mode.isHiDPI && abs($0.refreshRate - mode.refreshRate) < 0.5 }) {
                unique.append(mode)
            }
            return DisplayInfo(
                id: id, name: names[id] ?? "Display \(id)", isBuiltIn: CGDisplayIsBuiltin(id) != 0, isMain: CGDisplayIsMain(id) != 0,
                currentMode: CGDisplayCopyDisplayMode(id).map(Self.info), modes: unique
            )
        }
    }

    nonisolated static func info(_ mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(id: mode.ioDisplayModeID, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }

    public func setMode(_ mode: DisplayModeInfo, for display: CGDirectDisplayID) throws {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let target = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode])?.first(where: { $0.ioDisplayModeID == mode.id }) else {
            throw ActionError.notAvailable(L("display.error.mode"))
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { throw ActionError.failed(L("display.error.mode")) }
        CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            throw ActionError.failed(L("display.error.mode"))
        }
        reload()
    }

    /// Dims a display to `level` (0.1…1) by scaling its gamma curve.
    public func setDimming(_ level: Double, for display: CGDirectDisplayID) {
        let clamped = min(max(level, 0.1), 1)
        dimming[display] = clamped
        apply(clamped, to: display)
    }

    private func apply(_ level: Double, to display: CGDirectDisplayID) {
        if level >= 0.999 {
            CGDisplayRestoreColorSyncSettings()
            for (other, value) in dimming where other != display && value < 0.999 { apply(value, to: other) }
            return
        }
        let max = CGGammaValue(level)
        CGSetDisplayTransferByFormula(display, 0, max, 1, 0, max, 1, 0, max, 1)
    }

    private func reapplyDimming() {
        for (display, level) in dimming where level < 0.999 { apply(level, to: display) }
    }

    /// Restores every display's original color curves.
    public func restoreAll() {
        dimming.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }
}
