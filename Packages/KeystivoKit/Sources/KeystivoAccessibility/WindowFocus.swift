import AppKit
import ApplicationServices

/// Brings a specific window to the front.
///
/// macOS 14+ uses *cooperative* activation, which an agent app cannot always
/// satisfy (for example while a non-activating panel is up). We therefore try
/// the SkyLight SPI that window managers rely on and fall back to public API.
public enum WindowFocus {
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError

    private static let setFrontProcess: SetFrontProcessFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(symbol, to: SetFrontProcessFn.self)
    }()

    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// Deprecated (and hidden from Swift) but still exported; resolved dynamically.
    private static let getProcessForPID: GetProcessForPIDFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
        return unsafeBitCast(symbol, to: GetProcessForPIDFn.self)
    }()

    /// kCPSUserGenerated
    private static let userGenerated: UInt32 = 0x200

    public static func focus(window: AXElement, windowID: CGWindowID? = nil, pid: pid_t) {
        if window.isMinimized { window.setMinimized(false) }
        if let id = windowID ?? window.windowID, bringToFront(pid: pid, windowID: id) {
            window.set(kAXMainAttribute, kCFBooleanTrue)
            window.raise()
            return
        }
        window.set(kAXMainAttribute, kCFBooleanTrue)
        window.raise()
        activate(pid: pid)
    }

    public static func activate(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if bringToFront(pid: pid, windowID: 0) { return }
        if !app.activate(from: .current, options: []) {
            app.activate()
        }
    }

    @discardableResult
    private static func bringToFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        return setFrontProcess(&psn, windowID, userGenerated) == .success
    }
}
