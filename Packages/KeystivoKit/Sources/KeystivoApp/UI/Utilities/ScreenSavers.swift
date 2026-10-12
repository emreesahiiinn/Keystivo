import AppKit
import IOKit.pwr_mgt
import KeystivoAccessibility
import KeystivoCore
import KeystivoScreenSaver
import Observation
import SwiftUI

/// Keystivo's macOS screen savers: the `.saver` bundles shipped inside the app
/// (Contents/Library/Screen Savers), installed into ~/Library/Screen Savers so
/// they appear in System Settings › Screen Saver.
@Observable
final class ScreenSaverManager {
    enum Status: Equatable {
        case notInstalled
        case outdated
        case installed
    }

    private(set) var status: Status = .notInstalled
    @ObservationIgnored private let preview = SaverPreviewController()

    static var bundledFolder: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/Screen Savers", directoryHint: .isDirectory)
    }

    static var installFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Screen Savers", directoryHint: .isDirectory)
    }

    static func fileName(_ style: SaverStyle) -> String { "Keystivo \(style.bundleName).saver" }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.bundledFolder.appending(path: Self.fileName(.flip)).path)
    }

    func refresh() {
        let fileManager = FileManager.default
        var installed = 0
        var current = 0
        for style in SaverStyle.allCases {
            let bundled = Self.bundledFolder.appending(path: Self.fileName(style))
            let target = Self.installFolder.appending(path: Self.fileName(style))
            guard fileManager.fileExists(atPath: target.path) else { continue }
            installed += 1
            let executable = "Contents/MacOS/Keystivo \(style.bundleName)"
            if fileManager.contentsEqual(atPath: bundled.appending(path: executable).path, andPath: target.appending(path: executable).path) {
                current += 1
            }
        }
        status = installed == 0 ? .notInstalled : (current == SaverStyle.allCases.count ? .installed : .outdated)
    }

    /// Copies every Keystivo screen saver into ~/Library/Screen Savers
    /// (older copies go to the Trash) and shows them in System Settings.
    @discardableResult
    func install(openSettings: Bool = true) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.installFolder, withIntermediateDirectories: true)
        // Remove Keystivo designs that were retired or renamed.
        let current = Set(SaverStyle.allCases.map(Self.fileName))
        for name in (try? fileManager.contentsOfDirectory(atPath: Self.installFolder.path)) ?? []
        where name.hasPrefix("Keystivo ") && name.hasSuffix(".saver") && !current.contains(name) {
            try? fileManager.trashItem(at: Self.installFolder.appending(path: name), resultingItemURL: nil)
        }
        var count = 0
        for style in SaverStyle.allCases {
            let source = Self.bundledFolder.appending(path: Self.fileName(style))
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = Self.installFolder.appending(path: Self.fileName(style))
            if fileManager.fileExists(atPath: target.path) { try fileManager.trashItem(at: target, resultingItemURL: nil) }
            try fileManager.copyItem(at: source, to: target)
            count += 1
        }
        refresh()
        if openSettings { Self.openSystemSettings() }
        return count
    }

    /// Moves the installed Keystivo screen savers to the Trash.
    func uninstall() throws {
        let fileManager = FileManager.default
        for style in SaverStyle.allCases {
            let target = Self.installFolder.appending(path: Self.fileName(style))
            if fileManager.fileExists(atPath: target.path) { try fileManager.trashItem(at: target, resultingItemURL: nil) }
        }
        refresh()
    }

    private static let extensions = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")

    /// Opens the screen saver chooser. Since macOS 26 it is a sheet behind the
    /// "Screen Saver…" button of the Wallpaper pane, which has no URL of its
    /// own, so Keystivo opens the pane and presses that button for the user.
    static func openSystemSettings() {
        Task { _ = await presentChooser() }
    }

    /// Makes `style` the macOS screen saver: opens the chooser, switches it to
    /// "Custom" (where third-party savers are listed) and picks the design.
    /// Returns whether the design could be selected.
    @discardableResult
    func use(_ style: SaverStyle) async -> Bool {
        refresh()
        if status != .installed { _ = try? install(openSettings: false) }
        guard await Self.presentChooser(), AXIsProcessTrusted() else { return false }
        let names = Self.displayNames(of: style)
        let custom = Self.localizedTable(key: "CUSTOM", fallback: "Custom")
        var openedShowAll = false
        var scrollPosition = 0.6
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(200))
            // Third-party savers only appear once "Custom" is chosen.
            if let radio = Self.find(role: kAXRadioButtonRole, labels: custom),
               (radio.attribute(kAXValueAttribute) as NSNumber?)?.intValue != 1 {
                radio.press()
                continue
            }
            if let tile = Self.find(role: kAXButtonRole, labels: names) {
                tile.press()
                return true
            }
            // The list is built lazily: "Other" (third-party savers) only exists
            // once scrolled into view, and it is the last section. Its "Show All"
            // page lists every saver in it, including Keystivo's.
            if !openedShowAll {
                if Self.scrollScreenSaverList(to: 1), let showAll = Self.lastShowAllButton() {
                    showAll.press()
                    openedShowAll = true
                }
            } else {
                // The expanded grid also loads lazily: sweep down through it.
                scrollPosition = scrollPosition >= 1 ? 0.6 : min(1, scrollPosition + 0.08)
                Self.scrollScreenSaverList(to: scrollPosition)
            }
        }
        return false
    }

    private static let legacyPane = extensions.appending(path: "ScreenSaver.appex")

    /// Opens the pane and, on macOS 26+, the screen saver sheet. Returns once it is visible.
    private static func presentChooser() async -> Bool {
        if FileManager.default.fileExists(atPath: legacyPane.path) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
            return true
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
        guard AXIsProcessTrusted() else { return false }
        let titles = localizedTable(key: "SCREEN_SAVER_BUTTON_TITLE", fallback: "Screen Saver…")
        // The pane loads asynchronously; look for the button for a few seconds.
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(200))
            if let button = find(role: kAXButtonRole, labels: titles) {
                button.press()
                try? await Task.sleep(for: .milliseconds(500))
                return true
            }
        }
        return false
    }

    /// A string of the Wallpaper pane in every language macOS ships.
    private static func localizedTable(key: String, fallback: String) -> Set<String> {
        let table = extensions.appending(path: "Wallpaper.appex/Contents/Resources/Localizable.loctable")
        guard let data = try? Data(contentsOf: table),
              let languages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
            return [fallback]
        }
        var values = Set(languages.values.compactMap { $0[key] as? String })
        values.insert(fallback)
        return values
    }

    /// The names System Settings may show for a design (its localized bundle names).
    static func displayNames(of style: SaverStyle) -> Set<String> {
        var names: Set<String> = ["Keystivo \(style.bundleName)"]
        let resources = installFolder.appending(path: fileName(style)).appending(path: "Contents/Resources")
        let languages = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        for folder in languages where folder.hasSuffix(".lproj") {
            if let strings = NSDictionary(contentsOf: resources.appending(path: folder).appending(path: "InfoPlist.strings")) as? [String: String],
               let name = strings["CFBundleName"] {
                names.insert(name)
            }
        }
        return names
    }

    @discardableResult
    private static func scrollScreenSaverList(to value: Double) -> Bool {
        guard let list = find(role: kAXScrollAreaRole, identifier: "SCREENSAVERS"),
              let scrollBar = list.element(kAXVerticalScrollBarAttribute) else { return false }
        scrollBar.set(kAXValueAttribute, NSNumber(value: value))
        return true
    }

    /// The "Show All" button of the last section of the screen saver list ("Other").
    private static func lastShowAllButton() -> AXElement? {
        guard let list = find(role: kAXScrollAreaRole, identifier: "SCREENSAVERS") else { return nil }
        return list.children().last { element in
            element.role == kAXButtonRole && ((element.attribute(kAXIdentifierAttribute) as String?)?.hasPrefix("Show All") ?? false)
        }
    }

    private static func find(role: String, identifier: String) -> AXElement? {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return nil }
        let app = AXElement.application(pid: settings.processIdentifier)
        var queue: [(AXElement, Int)] = app.windows.map { ($0, 0) }
        var visited = 0
        while !queue.isEmpty, visited < 6_000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let values = element.attributes([kAXRoleAttribute, kAXIdentifierAttribute])
            if values[kAXRoleAttribute] as? String == role, values[kAXIdentifierAttribute] as? String == identifier { return element }
            if depth < 25 { queue.append(contentsOf: element.children().map { ($0, depth + 1) }) }
        }
        return nil
    }

    private static func find(role: String, labels: Set<String>) -> AXElement? {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return nil }
        let app = AXElement.application(pid: settings.processIdentifier)
        app.setMessagingTimeout(0.5)
        var queue: [(AXElement, Int)] = app.windows.map { ($0, 0) }
        var visited = 0
        while !queue.isEmpty, visited < 6_000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let values = element.attributes([kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
            if values[kAXRoleAttribute] as? String == role {
                let label = (values[kAXTitleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (values[kAXDescriptionAttribute] as? String) ?? ""
                if labels.contains(label) { return element }
            }
            if depth < 25 { queue.append(contentsOf: element.children().map { ($0, depth + 1) }) }
        }
        return nil
    }

    /// Starts the screen saver chosen in System Settings.
    static func startSystemScreenSaver() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }

    /// Shows a design full screen inside Keystivo; any key, click or mouse move ends it.
    func showPreview(_ style: SaverStyle, backdrop: SaverBackdrop = .design) {
        preview.show(style, backdrop: backdrop)
    }

    var isShowingPreview: Bool { preview.isShowing }

    // MARK: Keystivo's own screen saver

    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var saverSettings = KeystivoSaverSettings()

    func apply(_ settings: KeystivoSaverSettings) {
        saverSettings = settings
        idleTimer?.invalidate()
        idleTimer = nil
        guard settings.startsWhenIdle else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Starts Keystivo's screen saver now, with the chosen design and backdrop.
    func startKeystivoSaver() {
        preview.show(saverSettings.style, backdrop: saverSettings.backdrop)
    }

    private func checkIdle() {
        guard !preview.isShowing else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle >= Double(saverSettings.idleMinutes * 60), !Self.displaySleepIsPrevented(), !Self.isScreenLocked() else { return }
        startKeystivoSaver()
    }

    /// Something (a video, a call, Keep Awake) keeps the display on: macOS
    /// wouldn't start its screen saver either.
    static func displaySleepIsPrevented() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let values = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (values["PreventUserIdleDisplaySleep"] ?? 0) > 0 || (values["NoDisplaySleepAssertion"] ?? 0) > 0
    }

    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }
}

/// Full-screen preview of a design on every display.
final class SaverPreviewController {
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var startPointer: CGPoint = .zero

    var isShowing: Bool { !windows.isEmpty }

    func show(_ style: SaverStyle, backdrop: SaverBackdrop = .design) {
        close()
        startPointer = NSEvent.mouseLocation
        let backdrop = style.supportsBackdrop ? backdrop : .design
        for screen in NSScreen.screens {
            let window = SaverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = backdrop == .design
            window.backgroundColor = backdrop == .design ? .black : .clear
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = Self.content(style: style, backdrop: backdrop, size: screen.frame.size)
            window.setFrame(screen.frame, display: false)
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = backdrop == .design ? 0.25 : 0.8
                window.animator().alphaValue = 1
            }
            windows.append(window)
        }
        windows.first?.makeKey()
        NSApp.activate()
        NSCursor.hide()
        let dismiss: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .mouseMoved {
                    let pointer = NSEvent.mouseLocation
                    // Ignore tiny jitters right after it starts.
                    guard hypot(pointer.x - self.startPointer.x, pointer.y - self.startPointer.y) > 24 else { return }
                }
                self.close()
            }
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .scrollWheel]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in dismiss(event); return nil }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: dismiss) { monitors.append(global) }
    }

    func close() {
        guard !windows.isEmpty else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.unhide()
    }

    /// The design over its backdrop: a blur of the desktop behind the window for
    /// frosted, a dark veil for dimmed, nothing for clear.
    private static func content(style: SaverStyle, backdrop: SaverBackdrop, size: CGSize) -> NSView {
        let hosting = NSHostingView(rootView: SaverRootView(style: style, backdrop: backdrop)
            .background(backdrop == .dim ? Color.black.opacity(0.55) : backdrop == .clear ? Color.black.opacity(0.12) : Color.clear))
        guard backdrop == .frosted else { return hosting }
        let blur = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        return blur
    }

    private final class SaverWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}
