import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

/// One window inside a saved layout.
nonisolated public struct LayoutEntry: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var bundleID: String
    public var appName: String
    public var title: String
    /// Index among this app's windows when captured; used when titles change.
    public var windowIndex: Int
    public var displayUUID: String
    /// Frame relative to the display's visible area (0…1), so layouts survive
    /// resolution changes.
    public var relativeFrame: CGRect
    public var isMinimized: Bool

    public init(bundleID: String, appName: String, title: String, windowIndex: Int, displayUUID: String, relativeFrame: CGRect, isMinimized: Bool) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.windowIndex = windowIndex
        self.displayUUID = displayUUID
        self.relativeFrame = relativeFrame
        self.isMinimized = isMinimized
    }
}

/// A saved desktop arrangement (feature: save/restore layouts, multi-monitor layouts).
nonisolated public struct WindowLayout: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var createdAt = Date.now
    /// Display set this layout was captured on (see ``LayoutManager/displaySignature``).
    public var displaySignature: String
    public var displayCount: Int
    /// Restore automatically when this exact monitor arrangement is connected.
    public var restoresOnDisplayChange = false
    /// Launch apps that aren't running when restoring.
    public var launchesMissingApps = false
    public var entries: [LayoutEntry]

    public init(name: String, displaySignature: String, displayCount: Int, entries: [LayoutEntry]) {
        self.name = name
        self.displaySignature = displaySignature
        self.displayCount = displayCount
        self.entries = entries
    }
}

/// Captures and restores window layouts; reacts to monitor changes.
@Observable
public final class LayoutManager {
    public static let shared = LayoutManager()

    public var layouts: [WindowLayout] = [] {
        didSet { onChange?(layouts) }
    }
    @ObservationIgnored public var onChange: (([WindowLayout]) -> Void)?
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastSignature = ""
    @ObservationIgnored private let debouncer = Debouncer(delay: .seconds(2))

    public init() {}

    /// Stable identity of the connected monitor set.
    public static func displaySignature() -> String {
        NSScreen.screens.map { "\($0.displayUUID)@\(Int($0.frame.width))x\(Int($0.frame.height))" }.sorted().joined(separator: "|")
    }

    public func startMonitoringDisplays() {
        lastSignature = Self.displaySignature()
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Displays reconnect in stages; wait for the arrangement to settle.
                self?.debouncer.schedule { self?.displaysChanged() }
            }
        }
    }

    private func displaysChanged() {
        let signature = Self.displaySignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        if let layout = layouts.first(where: { $0.restoresOnDisplayChange && $0.displaySignature == signature }) {
            Task { await restore(layout) }
        }
    }

    // MARK: Capture

    public func capture(name: String) async -> WindowLayout {
        var options = WindowCatalog.Options()
        options.includeOtherSpaces = false
        let windows = await WindowCatalog.shared.windows(options: options)
        var perAppIndex: [String: Int] = [:]
        var entries: [LayoutEntry] = []
        // Capture back-to-front so restoring preserves stacking order.
        for window in windows.reversed() {
            guard let bundleID = window.bundleID, let screen = ScreenGeometry.screen(forAXRect: window.frame) else { continue }
            let area = ScreenGeometry.visibleFrameAX(of: screen)
            let index = perAppIndex[bundleID, default: 0]
            perAppIndex[bundleID] = index + 1
            entries.append(LayoutEntry(
                bundleID: bundleID, appName: window.appName, title: window.title, windowIndex: index,
                displayUUID: screen.displayUUID,
                relativeFrame: CGRect(
                    x: (window.frame.minX - area.minX) / area.width,
                    y: (window.frame.minY - area.minY) / area.height,
                    width: window.frame.width / area.width,
                    height: window.frame.height / area.height
                ),
                isMinimized: window.isMinimized
            ))
        }
        return WindowLayout(name: name, displaySignature: Self.displaySignature(), displayCount: NSScreen.screens.count, entries: entries)
    }

    public func save(_ layout: WindowLayout) {
        if let index = layouts.firstIndex(where: { $0.id == layout.id }) {
            layouts[index] = layout
        } else {
            layouts.append(layout)
        }
    }

    public func delete(_ id: UUID) { layouts.removeAll { $0.id == id } }

    // MARK: Restore

    @discardableResult
    public func restore(_ layout: WindowLayout) async -> Int {
        let screensByUUID = Dictionary(NSScreen.screens.map { ($0.displayUUID, $0) }, uniquingKeysWith: { first, _ in first })
        var restored = 0
        let grouped = Dictionary(grouping: layout.entries, by: \.bundleID)

        for (bundleID, entries) in grouped {
            var app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            if app == nil, layout.launchesMissingApps,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                // Give the app a moment to create its windows.
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if let pid = app?.processIdentifier, !AXElement.application(pid: pid).windows.isEmpty { break }
                }
            }
            guard let app else { continue }
            var available = AXElement.application(pid: app.processIdentifier).windows.filter(\.isStandardWindow)
            for entry in entries.sorted(by: { $0.windowIndex < $1.windowIndex }) {
                guard !available.isEmpty else { break }
                let matchIndex = available.firstIndex { ($0.title ?? "") == entry.title && !entry.title.isEmpty }
                    ?? (available.indices.contains(entry.windowIndex) ? entry.windowIndex : 0)
                let window = available.remove(at: matchIndex)
                let screen = screensByUUID[entry.displayUUID] ?? NSScreen.main
                guard let screen else { continue }
                let area = ScreenGeometry.visibleFrameAX(of: screen)
                let frame = CGRect(
                    x: area.minX + entry.relativeFrame.minX * area.width,
                    y: area.minY + entry.relativeFrame.minY * area.height,
                    width: entry.relativeFrame.width * area.width,
                    height: entry.relativeFrame.height * area.height
                ).integral
                if entry.isMinimized {
                    window.setMinimized(true)
                } else {
                    if window.isMinimized { window.setMinimized(false) }
                    WindowManager.shared.setFrame(SnapGeometry.clamp(frame, to: area), for: window)
                }
                restored += 1
            }
        }
        return restored
    }
}
