import AppKit
import UniformTypeIdentifiers

/// File-system locations used by Keystivo.
public nonisolated enum AppPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Keystivo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var configurationFile: URL { applicationSupport.appendingPathComponent("configuration.json") }
    public static var clipboardDatabase: URL { applicationSupport.appendingPathComponent("clipboard.sqlite") }
    public static var historyDatabase: URL { applicationSupport.appendingPathComponent("history.sqlite") }

    public static var pluginsDirectory: URL {
        let url = applicationSupport.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var backupsDirectory: URL {
        let url = applicationSupport.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Resolves application names and icons with caching.
public enum AppDisplayName {
    private static var cache: [String: String] = [:]

    public static func name(forBundleID bundleID: String) -> String? {
        if let cached = cache[bundleID] { return cached }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName {
            cache[bundleID] = name
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        cache[bundleID] = name
        return name
    }
}

public final class AppIconCache {
    public static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    public init() { cache.countLimit = 300 }

    public func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID else { return genericIcon }
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        let image: NSImage
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let icon = app.icon {
            image = icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = genericIcon
        }
        cache.setObject(image, forKey: bundleID as NSString)
        return image
    }

    public func icon(forPath path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    public var genericIcon: NSImage { NSWorkspace.shared.icon(for: .application) }
}

/// Coalesces bursts of calls into one, on the main actor.
public final class Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(delay: Duration) { self.delay = delay }

    public func schedule(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    public func cancel() { task?.cancel() }
}

public extension NSRunningApplication {
    /// Regular, user-facing applications (excludes agents and background helpers).
    var isUserFacing: Bool { activationPolicy == .regular }
}

public extension NSScreen {
    /// Stable identifier for a display across launches.
    var displayUUID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Screen containing a point in Cocoa (bottom-left origin) coordinates.
    static func screen(containing point: CGPoint) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// The screen under the mouse pointer, falling back to the main screen.
    static var underMouse: NSScreen? {
        screen(containing: NSEvent.mouseLocation) ?? main
    }
}
