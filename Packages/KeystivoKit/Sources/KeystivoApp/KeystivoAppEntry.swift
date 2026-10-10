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
        let links = urls.filter { $0.pathExtension != "keystivoflow" }
        if !links.isEmpty { KeystivoRuntime.shared.linkRouting.open(urls: links) }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { KeystivoRuntime.shared.windowsUI.showSettings() }
        return true
    }
}

/// All SwiftUI scenes of the app. The menu bar extra is the control center;
/// other windows are managed by ``WindowPresenter``.
public struct KeystivoScenes: Scene {
    @State private var runtime = KeystivoRuntime.shared

    public init() {}

    public var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { runtime.config.general.showsMenuBarIcon },
            set: { runtime.config.general.showsMenuBarIcon = $0 }
        )) {
            ControlCenterView(runtime: runtime)
                .localizedRoot()
        } label: {
            Image(systemName: "command.square.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
