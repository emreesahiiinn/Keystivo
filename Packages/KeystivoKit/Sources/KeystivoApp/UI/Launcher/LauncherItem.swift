import AppKit
import KeystivoAccessibility
import KeystivoAudio
import KeystivoAutomation
import KeystivoClipboard
import KeystivoCore
import KeystivoFiles
import KeystivoInput
import KeystivoLinks
import KeystivoNavigation
import KeystivoPlugins
import KeystivoSearch
import KeystivoSystem
import KeystivoTools
import KeystivoWindows
import SwiftUI

/// Launcher modes: the root search and focused sub-views.
enum LauncherMode: Equatable {
    case root
    case clipboard
    case snippets
    case files
    case windows
    case textActions
    case pluginOutput(title: String)

    var placeholderKey: String {
        switch self {
        case .root: "launcher.placeholder.root"
        case .clipboard: "launcher.placeholder.clipboard"
        case .snippets: "launcher.placeholder.snippets"
        case .files: "launcher.placeholder.files"
        case .windows: "launcher.placeholder.windows"
        case .textActions: "launcher.placeholder.textActions"
        case .pluginOutput: "launcher.placeholder.plugin"
        }
    }

    var titleKey: String? {
        switch self {
        case .root: nil
        case .clipboard: "launcher.mode.clipboard"
        case .snippets: "launcher.mode.snippets"
        case .files: "launcher.mode.files"
        case .windows: "launcher.mode.windows"
        case .textActions: "launcher.mode.textActions"
        case .pluginOutput: nil
        }
    }

    var symbol: String {
        switch self {
        case .root: "magnifyingglass"
        case .clipboard: "clipboard"
        case .snippets: "text.badge.plus"
        case .files: "doc.text.magnifyingglass"
        case .windows: "macwindow"
        case .textActions: "text.cursor"
        case .pluginOutput: "puzzlepiece.extension"
        }
    }
}

enum LauncherSection: Int, CaseIterable, Comparable {
    case calculator, recent, suggestions, apps, windows, commands, workflows, snippets, clipboard, files, results, fallback

    static func < (lhs: LauncherSection, rhs: LauncherSection) -> Bool { lhs.rawValue < rhs.rawValue }

    var titleKey: String { "launcher.section.\(self)" }

    /// Max items shown per section in the root view.
    var limit: Int {
        switch self {
        case .calculator: 2
        case .apps: 8
        case .commands: 10
        case .windows: 6
        case .files: 6
        case .fallback: 4
        default: 8
        }
    }
}

struct LauncherAction: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var shortcut: KeyCombo?
    /// Close the launcher after running (most actions).
    var dismisses = true
    var isDestructive = false
    var perform: @MainActor () async -> Void
}

struct LauncherItem: Identifiable {
    enum Icon {
        case app(bundleID: String?, path: String?)
        case symbol(String, Color)
        case file(String)
        case image(NSImage)
        case color(String)
    }

    enum Accessory {
        case shortcut(KeyCombo)
        case text(String)
    }

    enum Preview {
        case text(String)
        case image(Data)
        case clipboard(ClipboardItem)
    }

    let id: String
    var title: String
    var subtitle: String?
    var icon: Icon
    var accessory: Accessory?
    var section: LauncherSection
    var score: Double = 0
    var highlight: [Int] = []
    var primary: LauncherAction
    var actions: [LauncherAction] = []
    var preview: Preview?
    /// Key for frecency tracking; nil = not tracked.
    var usageKey: String?
    /// Destructive primary actions need a second ↩.
    var requiresConfirmation = false

    var allActions: [LauncherAction] { [primary] + actions }
}

extension KeyCombo {
    static let commandReturn = KeyCombo(keyCode: KeyCodes.returnKey, modifiers: .command)
    static let optionReturn = KeyCombo(keyCode: KeyCodes.returnKey, modifiers: .option)
    static func command(_ letter: Character, shift: Bool = false) -> KeyCombo {
        KeyCombo(keyCode: KeyCodes.letterKeyCodes[letter] ?? 0, modifiers: shift ? [.command, .shift] : .command)
    }
    static let commandDelete = KeyCombo(keyCode: KeyCodes.delete, modifiers: .command)
}
