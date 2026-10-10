import KeystivoApp
import SwiftUI

/// Thin app entry point. All functionality lives in the KeystivoKit package.
@main
struct KeystivoMain: App {
    @NSApplicationDelegateAdaptor(KeystivoAppDelegate.self) private var appDelegate

    var body: some Scene {
        KeystivoScenes()
    }
}
