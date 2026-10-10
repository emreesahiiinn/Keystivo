import AppKit
import ApplicationServices

/// A snapshot of one top-level window.
nonisolated public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let bundleID: String?
    public let appName: String
    public var title: String
    /// Frame in AX coordinates (top-left origin).
    public var frame: CGRect
    public var isMinimized: Bool
    public var isAppHidden: Bool
    /// True for windows on another Space (known only through the window server).
    public var isOnOtherSpace: Bool
    public var element: AXElement?

    public var displayTitle: String { title.isEmpty ? appName : title }

    public static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.id == rhs.id && lhs.pid == rhs.pid }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(pid)
    }

    /// Focuses the window, switching Spaces or un-minimizing as needed.
    @MainActor public func focus() {
        if let element {
            WindowFocus.focus(window: element, windowID: id, pid: pid)
        } else {
            WindowFocus.focus(window: AXElement.application(pid: pid), windowID: id, pid: pid)
        }
    }
}

/// Enumerates windows by combining the Accessibility tree (titles, control,
/// minimized state) with the window server list (z-order, other Spaces).
public final class WindowCatalog {
    public static let shared = WindowCatalog()

    /// Bundle IDs never shown in switchers/previews.
    public var excludedBundleIDs: Set<String> = []

    public init() {}

    nonisolated public struct Options: Sendable {
        public var includeMinimized = true
        public var includeHiddenApps = true
        public var includeOtherSpaces = true
        public init() {}
    }

    /// Windows ordered front-to-back (most recently used first where known).
    public func windows(options: Options = Options()) async -> [WindowInfo] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid()
                && !excludedBundleIDs.contains($0.bundleIdentifier ?? "")
        }
        let appInfo = apps.map { AppRef(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "", hidden: $0.isHidden) }
        let serverWindows = Self.serverWindows()

        // AX queries are IPC; fan out across apps so one slow app doesn't serialize the rest.
        let axWindows: [[WindowInfo]] = await withTaskGroup(of: [WindowInfo].self) { group in
            for app in appInfo {
                group.addTask { await Self.axWindows(for: app) }
            }
            var results: [[WindowInfo]] = []
            for await list in group { results.append(list) }
            return results
        }

        var all = axWindows.flatMap { $0 }
        all.removeAll { window in
            (!options.includeMinimized && window.isMinimized) || (!options.includeHiddenApps && window.isAppHidden)
        }

        // Z-order from the window server (front to back).
        var order: [CGWindowID: Int] = [:]
        for (index, entry) in serverWindows.enumerated() where entry.isOnScreen { order[entry.id] = index }

        if options.includeOtherSpaces {
            let known = Set(all.map(\.id))
            let pidsToApps = Dictionary(uniqueKeysWithValues: appInfo.map { ($0.pid, $0) })
            for entry in serverWindows where !entry.isOnScreen && !known.contains(entry.id) {
                guard let app = pidsToApps[entry.pid], !entry.title.isEmpty,
                      entry.bounds.width > 120, entry.bounds.height > 80 else { continue }
                all.append(WindowInfo(
                    id: entry.id, pid: entry.pid, bundleID: app.bundleID, appName: app.name,
                    title: entry.title, frame: entry.bounds, isMinimized: false,
                    isAppHidden: app.hidden, isOnOtherSpace: true, element: nil
                ))
            }
        }

        return all.sorted { lhs, rhs in
            let left = order[lhs.id] ?? (lhs.isMinimized ? Int.max - 1 : Int.max - 2)
            let right = order[rhs.id] ?? (rhs.isMinimized ? Int.max - 1 : Int.max - 2)
            if left != right { return left < right }
            return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
        }
    }

    /// Windows of one application (current Space, via AX).
    public func windows(pid: pid_t) async -> [WindowInfo] {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
        let ref = AppRef(pid: pid, bundleID: app.bundleIdentifier, name: app.localizedName ?? "", hidden: app.isHidden)
        return await Self.axWindows(for: ref)
    }

    /// The focused window of the frontmost application.
    public func focusedWindow() -> AXElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXElement.application(pid: app.processIdentifier)
        return element.focusedWindow ?? element.mainWindow ?? element.windows.first
    }

    // MARK: Internals

    nonisolated struct AppRef: Sendable {
        let pid: pid_t
        let bundleID: String?
        let name: String
        let hidden: Bool
    }

    /// A window as known to the window server (all Spaces, including off-screen).
    nonisolated public struct ServerWindow: Sendable {
        public let id: CGWindowID
        public let pid: pid_t
        public let title: String
        public let bounds: CGRect
        public let isOnScreen: Bool
    }

    nonisolated private static func axWindows(for app: AppRef) async -> [WindowInfo] {
        let element = AXElement.application(pid: app.pid)
        var result: [WindowInfo] = []
        for window in element.windows {
            let values = window.attributes([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute])
            guard (values[kAXRoleAttribute] as? String) == kAXWindowRole else { continue }
            let subrole = values[kAXSubroleAttribute] as? String
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
            guard let id = window.windowID else { continue }
            var position = CGPoint.zero
            var size = CGSize.zero
            if let value = values[kAXPositionAttribute] { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
            if let value = values[kAXSizeAttribute] { AXValueGetValue(value as! AXValue, .cgSize, &size) }
            result.append(WindowInfo(
                id: id, pid: app.pid, bundleID: app.bundleID, appName: app.name,
                title: values[kAXTitleAttribute] as? String ?? "",
                frame: CGRect(origin: position, size: size),
                isMinimized: (values[kAXMinimizedAttribute] as? Bool) ?? false,
                isAppHidden: app.hidden, isOnOtherSpace: false, element: window
            ))
        }
        return result
    }

    nonisolated public static func serverWindows() -> [ServerWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return ServerWindow(
                id: id, pid: pid,
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            )
        }
    }
}
