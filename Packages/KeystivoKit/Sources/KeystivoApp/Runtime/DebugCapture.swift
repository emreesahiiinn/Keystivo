#if DEBUG
import AppKit
import KeystivoAccessibility
import KeystivoCore
@preconcurrency import ScreenCaptureKit

/// Developer aid: captures another app's largest on-screen window to a PNG.
enum DebugCapture {
    /// Logs the accessibility tree of an app's windows (roles, subroles, titles, identifiers).
    static func dumpAccessibility(of bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let root = AXElement.application(pid: app.processIdentifier)
        var lines: [String] = []
        func walk(_ element: AXElement, _ depth: Int) {
            guard depth < 30, lines.count < 600 else { return }
            let v = element.attributes([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute])
            let role = v[kAXRoleAttribute] as? String ?? "?"
            let parts = [v[kAXSubroleAttribute] as? String, (v[kAXTitleAttribute] as? String).map { "t=\($0)" }, (v[kAXDescriptionAttribute] as? String).map { "d=\($0)" },
                         (v[kAXIdentifierAttribute] as? String).map { "id=\($0)" }, (v[kAXValueAttribute]).map { "v=\($0)" }].compactMap { $0 }
            if role != "AXGroup" || !parts.isEmpty { lines.append(String(repeating: " ", count: depth) + role + " " + parts.joined(separator: " ")) }
            for child in element.children() { walk(child, depth + 1) }
        }
        for window in root.windows { walk(window, 0) }
        for line in lines { Log.logger("Debug").notice("ax| \(line, privacy: .public)") }
    }

    static func captureFrontWindow(of bundleID: String, to url: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // `-KSCaptureAnyLayer YES` also matches panels (e.g. our own launcher).
            let anyLayer = UserDefaults.standard.bool(forKey: "KSCaptureAnyLayer")
            let ownApp = bundleID == Bundle.main.bundleIdentifier
            guard let window = content.windows
                .filter({ window in
                    guard window.owningApplication?.bundleIdentifier == bundleID, anyLayer || window.windowLayer == 0 else { return false }
                    guard ownApp else { return true }
                    // Skip full-screen transparent overlays.
                    let coversDisplay = content.displays.contains { window.frame.width >= CGFloat($0.width) && window.frame.height >= CGFloat($0.height) }
                    return window.owningApplication?.processID == getpid() && !coversDisplay && (anyLayer || window.title == "Saver Test")
                })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                Log.logger("Debug").notice("capture: no window for \(bundleID, privacy: .public)")
                return
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            var filter = SCContentFilter(desktopIndependentWindow: window)
            // Panels: grab their region of the display, so materials show what is behind them.
            if anyLayer, let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) {
                filter = SCContentFilter(display: display, excludingWindows: [])
                // `-KSCapturePadding N` widens the region (menus next to the panel).
                let padding = CGFloat(UserDefaults.standard.double(forKey: "KSCapturePadding"))
                let region = window.frame.insetBy(dx: -padding, dy: -padding).intersection(display.frame)
                configuration.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                configuration.width = Int(region.width * 2)
                configuration.height = Int(region.height * 2)
            }
            // `-KSCaptureFrames N -KSCaptureInterval ms`: a sequence (name-1.png, name-2.png, …).
            let frames = max(1, UserDefaults.standard.integer(forKey: "KSCaptureFrames"))
            let interval = max(10, UserDefaults.standard.integer(forKey: "KSCaptureInterval"))
            for frame in 1...frames {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let output = frames == 1 ? url : URL(fileURLWithPath: url.deletingPathExtension().path + "-\(frame).png")
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output)
                if frame < frames { try await Task.sleep(for: .milliseconds(interval)) }
            }
            Log.logger("Debug").notice("capture: saved \(url.path, privacy: .public)")
        } catch {
            Log.logger("Debug").notice("capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
