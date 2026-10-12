import AppKit
import ApplicationServices

/// Private but long-stable SPI mapping an AX window element to its CGWindowID.
/// Used by most window managers; there is no public equivalent.
@_silgen_name("_AXUIElementGetWindow")
nonisolated func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A thin, typed wrapper over `AXUIElement`.
///
/// All calls are synchronous IPC to the target app; callers keep them off hot
/// paths and rely on `messagingTimeout` so a hung app can't stall Keystivo.
nonisolated public struct AXElement: Hashable, @unchecked Sendable {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public static func application(pid: pid_t) -> AXElement {
        let element = AXElement(AXUIElementCreateApplication(pid))
        element.setMessagingTimeout(0.35)
        return element
    }

    public static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }

    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(raw, seconds)
    }

    // MARK: Attributes

    public func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    public func element(_ name: String) -> AXElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    public func elements(_ name: String) -> [AXElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    /// Batch-fetches several attributes in one IPC round trip.
    public func attributes(_ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(raw, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [CFTypeRef] else { return [:] }
        var result: [String: CFTypeRef] = [:]
        for (name, value) in zip(names, array) {
            // Errors come back as AXValue of type .axError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            result[name] = value
        }
        return result
    }

    public func children(limit: Int? = nil) -> [AXElement] {
        if let limit {
            var value: CFArray?
            guard AXUIElementCopyAttributeValues(raw, kAXChildrenAttribute as CFString, 0, limit, &value) == .success,
                  let array = value as? [AXUIElement] else { return [] }
            return array.map(AXElement.init)
        }
        return elements(kAXChildrenAttribute)
    }

    @discardableResult
    public func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(raw, name as CFString, value) == .success
    }

    public func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(raw, name as CFString, &settable) == .success && settable.boolValue
    }

    // MARK: Common properties

    public var role: String? { attribute(kAXRoleAttribute) }
    public var subrole: String? { attribute(kAXSubroleAttribute) }
    public var title: String? { attribute(kAXTitleAttribute) }
    public var roleDescription: String? { attribute(kAXRoleDescriptionAttribute) }
    public var isEnabled: Bool { attribute(kAXEnabledAttribute) ?? true }
    public var isMinimized: Bool { attribute(kAXMinimizedAttribute) ?? false }
    public var isFullScreen: Bool { attribute("AXFullScreen") ?? false }
    public var isMain: Bool { attribute(kAXMainAttribute) ?? false }

    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
    }

    public var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(raw, &id) == .success && id != 0 ? id : nil
    }

    /// Raw lookup result, for diagnostics.
    public var windowIDLookup: (error: Int32, id: CGWindowID) {
        var id: CGWindowID = 0
        let error = _AXUIElementGetWindow(raw, &id)
        return (error.rawValue, id)
    }

    /// Top-left-origin position in global screen coordinates.
    public var position: CGPoint? {
        AXValues.point(attribute(kAXPositionAttribute) as CFTypeRef?)
    }

    public var size: CGSize? {
        AXValues.size(attribute(kAXSizeAttribute) as CFTypeRef?)
    }

    /// Frame in AX coordinates (top-left origin of the primary display).
    public var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    public func setPosition(_ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return set(kAXPositionAttribute, value)
    }

    @discardableResult
    public func setSize(_ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return set(kAXSizeAttribute, value)
    }

    /// Applies a frame robustly: size → position → size handles windows that
    /// clamp size against the screen edge they are currently on.
    public func setFrame(_ frame: CGRect) {
        setSize(frame.size)
        setPosition(frame.origin)
        setSize(frame.size)
    }

    // MARK: Actions

    public var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    @discardableResult
    public func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }

    @discardableResult
    public func raise() -> Bool { perform(kAXRaiseAction) }

    @discardableResult
    public func press() -> Bool { perform(kAXPressAction) }

    // MARK: Hit testing

    public static func element(at point: CGPoint) -> AXElement? {
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        return AXElement(element)
    }

    public static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

nonisolated public extension AXElement {
    var windows: [AXElement] { elements(kAXWindowsAttribute) }
    var focusedWindow: AXElement? { element(kAXFocusedWindowAttribute) }
    var mainWindow: AXElement? { element(kAXMainWindowAttribute) }
    var focusedElement: AXElement? { element(kAXFocusedUIElementAttribute) }

    /// Standard, user-manipulable windows (skips sheets, palettes, popovers).
    var isStandardWindow: Bool {
        role == kAXWindowRole && (subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole)
    }

    func setMinimized(_ minimized: Bool) {
        set(kAXMinimizedAttribute, minimized as CFBoolean)
    }

    func setFullScreen(_ fullScreen: Bool) {
        set("AXFullScreen", fullScreen as CFBoolean)
    }

    /// Clicks the window's close button.
    func close() {
        element(kAXCloseButtonAttribute)?.press()
    }

    /// Focuses this window: raises it and activates its owning app.
    @MainActor func focus() {
        guard let pid else { return }
        WindowFocus.focus(window: self, pid: pid)
    }
}

/// Reads points and sizes from Accessibility values. Apps return whatever they
/// like for an attribute; a non-AXValue passed to `AXValueGetValue` would crash,
/// so the type is checked first (CF casts with `as!`/`as?` aren't).
nonisolated public enum AXValues {
    public static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value = axValue(value) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    public static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value = axValue(value) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
