import AppKit
import ApplicationServices

/// One command from an app's menu bar ("File › Export › PDF…").
nonisolated public struct MenuItemEntry: Sendable, Hashable, Identifiable {
    /// Parent menu titles, outermost first.
    public let path: [String]
    public let title: String
    public let isEnabled: Bool
    public let isChecked: Bool
    /// Key equivalent: character (e.g. "S") or virtual key code, plus modifiers.
    public let keyCharacter: String?
    public let keyCode: UInt16?
    public let modifiers: NSEvent.ModifierFlags.RawValue
    let element: AXElement

    public var id: String { (path + [title]).joined(separator: "\u{1F}") }
    public var hasShortcut: Bool { keyCharacter != nil || keyCode != nil }

    /// Presses the item (the app performs it even when the menu isn't open).
    public func perform() -> Bool { element.press() }
}

/// Reads an app's menu bar through Accessibility (Raycast's "Search Menu Items").
nonisolated public enum MenuItemCollector {
    /// All commands of `pid`'s menus except the Apple menu. Bounded so huge
    /// dynamic menus (history, bookmarks) can't stall the search.
    public static func items(pid: pid_t, limit: Int = 2500) -> [MenuItemEntry] {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(0.5)
        guard let menuBar = app.element(kAXMenuBarAttribute) else { return [] }
        var result: [MenuItemEntry] = []
        // The first menu bar item is the Apple menu.
        for barItem in menuBar.children().dropFirst() {
            guard let title = barItem.title, !title.isEmpty else { continue }
            for menu in barItem.children() where menu.role == kAXMenuRole {
                collect(menu, path: [title], depth: 0, into: &result, limit: limit)
            }
            if result.count >= limit { break }
        }
        return result
    }

    private static func collect(_ menu: AXElement, path: [String], depth: Int, into result: inout [MenuItemEntry], limit: Int) {
        guard depth < 5 else { return }
        for item in menu.children() {
            guard result.count < limit else { return }
            let values = item.attributes([
                kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdVirtualKeyAttribute,
                kAXMenuItemCmdModifiersAttribute, kAXMenuItemMarkCharAttribute,
            ])
            guard let title = values[kAXTitleAttribute] as? String, !title.isEmpty else { continue }
            let submenu = item.children().first { $0.role == kAXMenuRole }
            if let submenu {
                collect(submenu, path: path + [title], depth: depth + 1, into: &result, limit: limit)
                continue
            }
            let character = (values[kAXMenuItemCmdCharAttribute] as? String).flatMap { $0.isEmpty || $0 == "\u{0}" ? nil : $0 }
            let virtualKey = (values[kAXMenuItemCmdVirtualKeyAttribute] as? NSNumber).map { UInt16(truncating: $0) }
            let rawModifiers = (values[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue ?? 0
            result.append(MenuItemEntry(
                path: path, title: title,
                isEnabled: (values[kAXEnabledAttribute] as? Bool) ?? true,
                isChecked: !((values[kAXMenuItemMarkCharAttribute] as? String) ?? "").isEmpty,
                keyCharacter: character, keyCode: character == nil ? virtualKey : nil,
                modifiers: (character != nil || virtualKey != nil) ? modifierFlags(rawModifiers).rawValue : 0,
                element: item
            ))
        }
    }

    /// AXMenuItemCmdModifiers: bit 0 shift, 1 option, 2 control, 3 "no command".
    static func modifierFlags(_ raw: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if raw & 1 != 0 { flags.insert(.shift) }
        if raw & 2 != 0 { flags.insert(.option) }
        if raw & 4 != 0 { flags.insert(.control) }
        if raw & 8 == 0 { flags.insert(.command) }
        return flags
    }
}
