import AppKit
import KeystivoCore

/// Offers to move Keystivo into /Applications when it's launched from a disk
/// image, Downloads or similar, then relaunches the installed copy.
enum ApplicationMover {
    private static let suppressionKey = "KSDontOfferMoveToApplications"

    /// Returns true when Keystivo is relaunching from /Applications and this
    /// instance should stop launching.
    static func offerMoveIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL.standardizedFileURL
        let location = InstallLocation.classify(source.path)
        guard location.shouldOfferMove, !UserDefaults.standard.bool(forKey: suppressionKey) else { return false }

        NSApp.activate()
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = L("install.move.title")
        alert.informativeText = L("install.move.message")
        alert.addButton(withTitle: L("install.move.button"))
        alert.addButton(withTitle: L("install.move.later"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("install.move.dontAsk")
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressionKey) }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            let destination = try install(source, location: location)
            let volume = location == .diskImage ? (try? source.resourceValues(forKeys: [.volumeURLKey]))?.volume : nil
            relaunch(destination, detaching: volume)
            return true
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = L("install.move.failed")
            failure.informativeText = error.localizedDescription
            failure.runModal()
            DiagnosticsCenter.shared.record(error, module: "App", context: L("install.move.title"))
            return false
        }
    }

    /// Puts the bundle into /Applications, moving any previous version to the Trash.
    private static func install(_ source: URL, location: InstallLocation) throws -> URL {
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true).appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        SingleInstance.quitOthers(at: destination)
        if fileManager.fileExists(atPath: destination.path) {
            // Trash rather than delete, so the previous version can be recovered.
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        if location.copiesInsteadOfMoving {
            try fileManager.copyItem(at: source, to: destination)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
        return destination
    }

    /// Waits for this process to exit, opens the installed copy and ejects the disk image.
    private static func relaunch(_ application: URL, detaching volume: URL?) {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open "$2"
        if [ -n "$3" ]; then /usr/bin/hdiutil detach "$3" -quiet; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "keystivo-relaunch", String(ProcessInfo.processInfo.processIdentifier), application.path, volume?.path ?? ""]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(application)
        }
        NSApp.terminate(nil)
    }
}

/// Keeps a single Keystivo running: two copies would register every shortcut,
/// gesture and event tap twice.
enum SingleInstance {
    /// Quits other running copies (e.g. the previous version after an update)
    /// and waits briefly for them to release their shortcuts.
    static func takeOver() {
        quitOthers(at: nil)
    }

    static func quitOthers(at bundleURL: URL?) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { other in
            other != .current && (bundleURL == nil || other.bundleURL?.standardizedFileURL == bundleURL?.standardizedFileURL)
        }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = Date.now.addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date.now < deadline {
            RunLoop.current.run(until: .now.addingTimeInterval(0.1))
        }
    }
}
