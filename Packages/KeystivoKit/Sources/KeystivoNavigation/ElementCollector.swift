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
        let roots = roots(options: options, mode: mode)
        let screenRects = NSScreen.screens.map { ScreenGeometry.frameAX(of: $0) }
        let deadline = ContinuousClock.now + options.timeBudget
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
        let values = element.attributes([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute, "AXHidden"])
        let role = values[kAXRoleAttribute] as? String ?? ""
        if (values["AXHidden"] as? Bool) == true { return }

        var frame: CGRect?
        if let positionValue = values[kAXPositionAttribute], let sizeValue = values[kAXSizeAttribute] {
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
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
            let title = (values[kAXTitleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (values[kAXDescriptionAttribute] as? String) ?? ""
            switch mode {
            case .click:
                if enabled, !visible.isNull, visible.width >= 4, visible.height >= 4, isClickable(element, role: role) {
                    // Static text only counts when it is a link-like leaf with a press action.
                    if role != kAXStaticTextRole || element.actionNames.contains(kAXPressAction) {
                        results.append(NavigableElement(
                            element: element, frame: visible, role: role, title: title,
                            canPress: element.actionNames.contains(kAXPressAction), isScrollArea: false
                        ))
                    }
                }
            case .scroll:
                if role == kAXScrollAreaRole || role == "AXWebArea", visible.width > 60, visible.height > 60 {
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

    /// Removes elements whose frame is (almost) identical to a previous one,
    /// e.g. a button and its inner image.
    nonisolated static func dedupe(_ elements: [NavigableElement]) -> [NavigableElement] {
        var kept: [NavigableElement] = []
        for element in elements {
            let duplicate = kept.contains { existing in
                abs(existing.frame.midX - element.frame.midX) < 6 && abs(existing.frame.midY - element.frame.midY) < 6
            }
            if !duplicate { kept.append(element) }
        }
        return kept
    }
}
