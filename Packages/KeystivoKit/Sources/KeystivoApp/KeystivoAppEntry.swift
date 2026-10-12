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

/// Application delegate used by the thin app target.
public final class KeystivoAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        #if !DEBUG
        // Development builds run from DerivedData on purpose.
        if ApplicationMover.offerMoveIfNeeded() { return }
        #endif
        #if DEBUG
        // `-KSAllowSecondInstance YES`: inspect a dev build without quitting the installed app.
        if !UserDefaults.standard.bool(forKey: "KSAllowSecondInstance") { SingleInstance.takeOver() }
        #else
        SingleInstance.takeOver()
        #endif
        KeystivoRuntime.shared.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        KeystivoRuntime.shared.shutdown()
    }

    /// Files (e.g. .html) opened with Keystivo when it acts as the browser router.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let flows = urls.filter { $0.pathExtension == "keystivoflow" }
        if !flows.isEmpty {
            KeystivoRuntime.shared.importWorkflows(from: flows)
        }
        for url in urls where url.scheme?.lowercased() == "keystivo" { KeystivoRuntime.shared.automationSources.handle(url) }
        let links = urls.filter { $0.pathExtension != "keystivoflow" && $0.scheme?.lowercased() != "keystivo" }
        if !links.isEmpty { KeystivoRuntime.shared.linkRouting.open(urls: links) }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { KeystivoRuntime.shared.windowsUI.showSettings() }
        return true
    }
}

/// All SwiftUI scenes of the app (none visible: the control center is AppKit);
/// other windows are managed by ``WindowPresenter``.
public struct KeystivoScenes: Scene {

    public init() {}

    public var body: some Scene {
        // The menu bar item and its panel are AppKit (``MenuBarPanelController``):
        // SwiftUI's menu bar window can't be made see-through or handle ⌘, / Esc.
        // A scene is still required, so this one is never inserted.
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            EmptyView()
        }
    }
}
