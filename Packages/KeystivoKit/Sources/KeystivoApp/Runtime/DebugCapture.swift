#if DEBUG
import AppKit
import KeystivoAccessibility
import KeystivoCore
import KeystivoWindows
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
/// Developer aid: end-to-end check of focus follows mouse with real pointer
/// events. Enables the engine in memory only (the configuration is untouched)
/// and puts the pointer and the active app back afterwards.
enum FocusFollowsMouseSelfTest {
    static func run(output: URL) async {
        var log: [String] = []
        func note(_ line: String) { log.append(line) }
        let engine = FocusFollowsMouse.shared
        let originalPoint = CGEvent(source: nil)?.location ?? .zero
        let originalApp = NSWorkspace.shared.frontmostApplication
        engine.delay = 0.2
        engine.isEnabled = true
        defer {
            engine.isEnabled = false
            try? log.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }

        let windows = PointerWindowResolver.onScreenWindows()
        let passThrough = FocusFollowsMouse.ownPassThroughWindows()
        let own = getpid()
        // Two windows of different apps, each with a visible spot the pointer can rest on.
        func visibleSpot(of window: PointerWindowResolver.Entry) -> CGPoint? {
            for fy in stride(from: 0.2, through: 0.8, by: 0.15) {
                for fx in stride(from: 0.2, through: 0.8, by: 0.15) {
                    let point = CGPoint(x: window.bounds.minX + window.bounds.width * fx, y: window.bounds.minY + window.bounds.height * fy)
                    if PointerWindowResolver.window(at: point, in: windows, passThrough: passThrough)?.id == window.id { return point }
                }
            }
            return nil
        }
        let candidates = windows.filter { $0.layer == 0 && $0.pid != own && $0.bounds.width > 200 && $0.bounds.height > 150 }
            .compactMap { window in visibleSpot(of: window).map { (window, $0) } }
        guard let first = candidates.first, let second = candidates.first(where: { $0.0.pid != first.0.pid }) else {
            note("SKIP: need visible windows of two different apps (found \(candidates.count))")
            return
        }
        func app(_ pid: pid_t) -> String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "\(pid)" }
        func frontmost() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        func glide(to point: CGPoint, flags: CGEventFlags = []) async {
            let start = CGEvent(source: nil)?.location ?? point
            for step in 1...12 {
                let t = CGFloat(step) / 12
                let p = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
                let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
        note("A = \(app(first.0.pid)) window \(first.0.id), B = \(app(second.0.pid)) window \(second.0.id)")

        // 1. Resting on A activates A.
        await glide(to: first.1)
        try? await Task.sleep(for: .milliseconds(600))
        note((frontmost() == first.0.pid ? "PASS" : "FAIL") + " rest on A activates A (frontmost: \(app(frontmost() ?? 0)))")

        // 2. Resting on B activates B.
        await glide(to: second.1)
        try? await Task.sleep(for: .milliseconds(600))
        note((frontmost() == second.0.pid ? "PASS" : "FAIL") + " rest on B activates B (frontmost: \(app(frontmost() ?? 0)))")

        // 3. Switching away by other means, then nudging the pointer inside B, keeps the switch.
        WindowFocus.activate(pid: first.0.pid)
        try? await Task.sleep(for: .milliseconds(400))
        await glide(to: CGPoint(x: second.1.x + 12, y: second.1.y + 8))
        try? await Task.sleep(for: .milliseconds(600))
        note((frontmost() == first.0.pid ? "PASS" : "FAIL") + " nudging inside B keeps A active (frontmost: \(app(frontmost() ?? 0)))")

        // 4. Holding a modifier while entering another window keeps the current one.
        engine.isEnabled = false
        engine.isEnabled = true
        await glide(to: CGPoint(x: second.1.x - 10, y: second.1.y - 10), flags: .maskShift)
        try? await Task.sleep(for: .milliseconds(600))
        note((frontmost() == first.0.pid ? "PASS" : "FAIL") + " holding ⇧ keeps A active (frontmost: \(app(frontmost() ?? 0)))")

        // Restore.
        engine.isEnabled = false
        await glide(to: originalPoint)
        if let originalApp { WindowFocus.activate(pid: originalApp.processIdentifier) }
    }
}
/// Developer aid: drags another app's window with ⌃⌥ (move) and ⌃⌥ right-drag
/// (resize) through real events, checks the result and restores the window.
enum ModifierDragSelfTest {
    static func run(output: URL) async {
        var log: [String] = []
        let engine = ModifierDragEngine.shared
        engine.modifiers = [.control, .option]
        engine.raisesWindow = false
        engine.isEnabled = true
        let originalPoint = CGEvent(source: nil)?.location ?? .zero
        defer {
            engine.isEnabled = false
            try? log.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        let screen = NSScreen.screens.first?.frame.size ?? .zero
        let frontApp = NSWorkspace.shared.frontmostApplication
        // A movable window (smaller than the screen); brought to the front first.
        // `-KSTestTargetBundle com.apple.finder`: only that app's windows (front first).
        let targetBundle = UserDefaults.standard.string(forKey: "KSTestTargetBundle")
        let candidates = PointerWindowResolver.onScreenWindows().filter { window in
            window.layer == 0 && window.pid != getpid() && window.bounds.width > 300
                && window.bounds.width < screen.width - 200 && window.bounds.height < screen.height - 200
                && (targetBundle == nil || NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier == targetBundle)
        }
        // Bring each candidate to the front and find it under the pointer, as the engine does.
        var found: (AXElement, CGRect)?
        var notes: [String] = []
        for candidate in candidates {
            WindowFocus.focus(window: AXElement.application(pid: candidate.pid), windowID: candidate.id, pid: candidate.pid)
            try? await Task.sleep(for: .milliseconds(600))
            let center = CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
            let hit = AXElement.element(at: center)
            let topmost = PointerWindowResolver.window(at: center, in: PointerWindowResolver.onScreenWindows(), passThrough: FocusFollowsMouse.ownPassThroughWindows())
            notes.append("\(NSRunningApplication(processIdentifier: candidate.pid)?.localizedName ?? "?") \(candidate.id) \(candidate.bounds): hit=\(hit?.role ?? "nil") pid=\(hit?.pid ?? -1) topmost=\(topmost.map { "\($0.id)/\($0.pid)" } ?? "nil")")
            if let hit, let window = hit.role == kAXWindowRole ? hit : hit.element(kAXWindowAttribute),
               window.pid == candidate.pid, let frame = window.frame {
                found = (window, frame)
                break
            }
        }
        log += notes
        defer { if let frontApp { WindowFocus.activate(pid: frontApp.processIdentifier) } }
        guard let (element, original) = found else {
            log.append("SKIP: no movable window found under the pointer (\(candidates.count) candidates)")
            return
        }
        log.append("Window: \(NSRunningApplication(processIdentifier: element.pid ?? 0)?.localizedName ?? "?") \(original)")
        func post(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.flags = [.maskControl, .maskAlternate]
            event?.post(tap: .cghidEventTap)
        }
        func drag(from start: CGPoint, by delta: CGSize, right: Bool) async {
            post(right ? .rightMouseDown : .leftMouseDown, start, button: right ? .right : .left)
            try? await Task.sleep(for: .milliseconds(150))
            for step in 1...10 {
                let t = CGFloat(step) / 10
                post(right ? .rightMouseDragged : .leftMouseDragged, CGPoint(x: start.x + delta.width * t, y: start.y + delta.height * t), button: right ? .right : .left)
                try? await Task.sleep(for: .milliseconds(16))
            }
            post(right ? .rightMouseUp : .leftMouseUp, CGPoint(x: start.x + delta.width, y: start.y + delta.height), button: right ? .right : .left)
            try? await Task.sleep(for: .milliseconds(400))
        }

        let center = CGPoint(x: original.midX, y: original.midY)
        await drag(from: center, by: CGSize(width: 80, height: 40), right: false)
        let moved = element.frame ?? .zero
        let moveOK = abs(moved.minX - original.minX - 80) <= 2 && abs(moved.minY - original.minY - 40) <= 2 && moved.size == original.size
        log.append((moveOK ? "PASS" : "FAIL") + " ⌃⌥ drag moves the window by (80, 40): \(moved)")

        let corner = CGPoint(x: moved.maxX - 30, y: moved.maxY - 30)
        await drag(from: corner, by: CGSize(width: 60, height: 30), right: true)
        let resized = element.frame ?? .zero
        let resizeOK = abs(resized.width - moved.width - 60) <= 2 && abs(resized.height - moved.height - 30) <= 2 && abs(resized.minX - moved.minX) <= 2
        log.append((resizeOK ? "PASS" : "FAIL") + " ⌃⌥ right-drag resizes from the bottom-right corner: \(resized)")

        element.setFrame(original)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        log.append("Restored: \(element.frame ?? .zero)")
    }
}
#endif
