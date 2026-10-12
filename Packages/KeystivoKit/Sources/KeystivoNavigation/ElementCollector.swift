import AppKit
import ApplicationServices
import KeystivoAccessibility
import KeystivoCore

/// An actionable on-screen element discovered through the Accessibility tree.
nonisolated public struct NavigableElement: Identifiable, Sendable {
    public let id = UUID()
    public let element: AXElement
    /// Frame in AX (top-left) coordinates.
    public let frame: CGRect
    public let role: String
    public let title: String
    public let canPress: Bool
    public let isScrollArea: Bool

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

nonisolated public struct CollectorOptions: Sendable {
    public var maxElements = 600
    public var maxDepth = 40
    /// Wall-clock budget so a huge web page can't freeze the UI.
    public var timeBudget: Duration = .milliseconds(450)
    public var includeMenuBar = true
    public var includeDock = false
    public init() {}
}

/// Walks the AX tree of the frontmost window (plus optional menu bar/Dock) and
/// returns clickable or scrollable elements that are actually visible.
public enum ElementCollector {
    nonisolated static let clickableRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXMenuBarItemRole, kAXMenuItemRole, "AXLink", kAXTextFieldRole, kAXTextAreaRole,
        kAXComboBoxRole, kAXSliderRole, kAXIncrementorRole, kAXDisclosureTriangleRole, kAXTabGroupRole,
        kAXCellRole, kAXRowRole, kAXColorWellRole, "AXSegmentedControl", "AXDockItem", kAXImageRole,
        "AXSearchField", kAXStaticTextRole,
    ]

    /// Containers whose children we never need to descend into.
    nonisolated static let opaqueRoles: Set<String> = [kAXTextAreaRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXSliderRole]

    public static func collect(mode: Mode, options: CollectorOptions = CollectorOptions()) async -> [NavigableElement] {
        // Chromium and Electron build their web accessibility tree only on request.
        if let app = NSWorkspace.shared.frontmostApplication, WebAccessibility.enable(for: app) {
            try? await Task.sleep(for: .milliseconds(350))
        }
        let roots = roots(options: options, mode: mode)
        let screenRects = NSScreen.screens.map { ScreenGeometry.frameAX(of: $0) }
        let deadline = ContinuousClock.now + options.timeBudget
        // Accessibility requests to our own process aren't IPC: AppKit answers
        // them on the calling thread, walking SwiftUI view graphs that must
        // only be touched on the main thread. Keystivo's own windows (e.g.
        // Settings) are therefore walked on the main actor.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            var results: [NavigableElement] = []
            for (root, clip) in roots {
                walk(root, clip: clip, depth: 0, mode: mode, options: options, screens: screenRects, deadline: deadline, into: &results)
                if results.count >= options.maxElements { break }
            }
            return dedupe(results)
        }
        return await Task.detached(priority: .userInitiated) {
            var results: [NavigableElement] = []
            for (root, clip) in roots {
                walk(root, clip: clip, depth: 0, mode: mode, options: options, screens: screenRects, deadline: deadline, into: &results)
                if results.count >= options.maxElements { break }
            }
            return dedupe(results)
        }.value
    }

    nonisolated public enum Mode: Sendable {
        case click
        case scroll
    }

    private static func roots(options: CollectorOptions, mode: Mode) -> [(AXElement, CGRect?)] {
        var roots: [(AXElement, CGRect?)] = []
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXElement.application(pid: app.processIdentifier)
            appElement.setMessagingTimeout(0.25)
            if let window = appElement.focusedWindow ?? appElement.mainWindow {
                roots.append((window, window.frame))
            }
            // Sheets and popovers are separate windows of the same app.
            for window in appElement.windows where window.subrole != kAXStandardWindowSubrole {
                if let frame = window.frame { roots.append((window, frame)) }
            }
            if mode == .click, options.includeMenuBar, let menuBar = appElement.element(kAXMenuBarAttribute) {
                roots.append((menuBar, nil))
            }
        }
        if mode == .click, options.includeDock,
           let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let dockElement = AXElement.application(pid: dock.processIdentifier)
            if let list = dockElement.children().first { roots.append((list, nil)) }
        }
        return roots
    }

    nonisolated private static func walk(
        _ element: AXElement, clip: CGRect?, depth: Int, mode: Mode, options: CollectorOptions,
        screens: [CGRect], deadline: ContinuousClock.Instant, into results: inout [NavigableElement]
    ) {
        guard depth < options.maxDepth, results.count < options.maxElements, ContinuousClock.now < deadline else { return }
        let values = element.attributes([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                         kAXEnabledAttribute, "AXHidden", kAXValueAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute])
        let role = values[kAXRoleAttribute] as? String ?? ""
        if (values["AXHidden"] as? Bool) == true { return }

        var frame: CGRect?
        if let point = AXValues.point(values[kAXPositionAttribute]), let size = AXValues.size(values[kAXSizeAttribute]) {
            frame = CGRect(origin: point, size: size)
        }

        // Skip subtrees that are entirely outside the visible area.
        var nextClip = clip
        if let frame, frame.width > 0, frame.height > 0 {
            if let clip, !clip.intersects(frame) { return }
            if !screens.contains(where: { $0.intersects(frame) }) { return }
            if role == kAXScrollAreaRole || role == kAXGroupRole || role == "AXWebArea" {
                nextClip = clip.map { $0.intersection(frame) } ?? frame
            }
        }

        if let frame, frame.width >= 4, frame.height >= 4 {
            let visible = clip.map { $0.intersection(frame) } ?? frame
            let enabled = (values[kAXEnabledAttribute] as? Bool) ?? true
            switch mode {
            case .click:
                if enabled, !visible.isNull, visible.width >= 4, visible.height >= 4, isClickable(element, role: role) {
                    // Static text only counts when it is a link-like leaf with a press action.
                    if role != kAXStaticTextRole || element.actionNames.contains(kAXPressAction) {
                        let title = label(element, role: role, values: values)
                        results.append(NavigableElement(
                            element: element, frame: visible, role: role, title: title,
                            canPress: element.actionNames.contains(kAXPressAction), isScrollArea: false
                        ))
                    }
                }
            case .scroll:
                if role == kAXScrollAreaRole || role == "AXWebArea", visible.width > 60, visible.height > 60 {
                    let title = text(values[kAXTitleAttribute]) ?? text(values[kAXDescriptionAttribute]) ?? ""
                    results.append(NavigableElement(element: element, frame: visible, role: role, title: title, canPress: false, isScrollArea: true))
                }
            }
            if mode == .click, opaqueRoles.contains(role) { return }
        }

        for child in element.children(limit: 400) {
            walk(child, clip: nextClip, depth: depth + 1, mode: mode, options: options, screens: screens, deadline: deadline, into: &results)
            if results.count >= options.maxElements || ContinuousClock.now >= deadline { return }
        }
    }

    nonisolated private static func isClickable(_ element: AXElement, role: String) -> Bool {
        if clickableRoles.contains(role) {
            if role == kAXImageRole || role == kAXCellRole || role == kAXRowRole || role == kAXStaticTextRole {
                return element.actionNames.contains(kAXPressAction)
            }
            return true
        }
        return element.actionNames.contains(kAXPressAction)
    }

    // MARK: Labels

    /// Roles whose visible text usually lives in child static-text elements.
    nonisolated static let containerTextRoles: Set<String> = [
        "AXLink", kAXButtonRole, kAXCellRole, kAXRowRole, kAXMenuItemRole, kAXRadioButtonRole,
        kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXGroupRole, "AXDockItem",
    ]

    /// The name a user would search for: title, description, a short value,
    /// placeholder or help text, or the text of the element's children.
    nonisolated static func label(_ element: AXElement, role: String, values: [String: CFTypeRef]) -> String {
        if let title = text(values[kAXTitleAttribute]) { return title }
        if let description = text(values[kAXDescriptionAttribute]) { return description }
        let valueRoles: Set<String> = [kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXStaticTextRole, kAXComboBoxRole, "AXLink"]
        if valueRoles.contains(role), let value = text(values[kAXValueAttribute]), value.count <= 80 { return value }
        if let placeholder = text(values[kAXPlaceholderValueAttribute]) { return placeholder }
        if containerTextRoles.contains(role), let childText = childText(element) { return childText }
        return text(values[kAXHelpAttribute]) ?? ""
    }

    /// Joins the static text found up to two levels below `element`.
    nonisolated static func childText(_ element: AXElement) -> String? {
        var parts: [String] = []
        var queue: [(AXElement, Int)] = element.children(limit: 8).map { ($0, 1) }
        while !queue.isEmpty, parts.count < 4 {
            let (child, depth) = queue.removeFirst()
            let values = child.attributes([kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
            let role = values[kAXRoleAttribute] as? String
            if role == kAXStaticTextRole, let value = text(values[kAXValueAttribute]) {
                parts.append(value)
            } else if let title = text(values[kAXTitleAttribute]) ?? (role == kAXImageRole ? text(values[kAXDescriptionAttribute]) : nil) {
                parts.append(title)
            } else if depth < 2 {
                queue.append(contentsOf: child.children(limit: 8).map { ($0, depth + 1) })
            }
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : String(joined.prefix(120))
    }

    nonisolated static func text(_ value: CFTypeRef?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Removes elements whose frame is (almost) identical to a previous one,
    /// e.g. a button and its inner image. When duplicates differ, the one with
    /// a name wins so it stays searchable.
    nonisolated static func dedupe(_ elements: [NavigableElement]) -> [NavigableElement] {
        var kept: [NavigableElement] = []
        for element in elements {
            let duplicate = kept.firstIndex { existing in
                abs(existing.frame.midX - element.frame.midX) < 6 && abs(existing.frame.midY - element.frame.midY) < 6
            }
            if let duplicate {
                if kept[duplicate].title.isEmpty, !element.title.isEmpty { kept[duplicate] = element }
            } else {
                kept.append(element)
            }
        }
        return kept
    }
}

/// Chromium-based browsers and Electron apps only expose their web content to
/// accessibility clients that ask for it, the way screen readers do.
public enum WebAccessibility {
    private static var enabledPIDs = Set<pid_t>()

    nonisolated static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "company.thebrowser.Browser", "company.thebrowser.dia",
    ]

    /// Returns true when the tree was just switched on and needs a moment to build.
    @discardableResult
    public static func enable(for app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        guard !enabledPIDs.contains(pid) else { return false }
        enabledPIDs = enabledPIDs.filter { NSRunningApplication(processIdentifier: $0) != nil }
        let kind = engine(of: app)
        guard kind != .none else { return false }
        let element = AXElement.application(pid: pid)
        var changed = element.set("AXManualAccessibility", kCFBooleanTrue)
        if kind == .chromium { changed = element.set("AXEnhancedUserInterface", kCFBooleanTrue) || changed }
        enabledPIDs.insert(pid)
        return changed
    }

    enum Engine { case chromium, electron, none }

    static func engine(of app: NSRunningApplication) -> Engine {
        if let id = app.bundleIdentifier, chromiumBundleIDs.contains(id) { return .chromium }
        guard let frameworks = app.bundleURL?.appending(path: "Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return .none }
        if names.contains("Electron Framework.framework") { return .electron }
        if names.contains(where: { $0.hasSuffix("Framework.framework") && ($0.contains("Chrom") || $0.contains("Edge") || $0.contains("Brave")) }) {
            return .chromium
        }
        return .none
    }
}
