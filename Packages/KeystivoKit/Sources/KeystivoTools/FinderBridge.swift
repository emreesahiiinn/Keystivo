import AppKit
import KeystivoCore

/// Finder extras macOS lacks: new file here, open terminal/editor here, copy paths.
public enum FinderBridge {
    /// POSIX path of the frontmost Finder window (Desktop when none).
    public static func currentFolder() throws -> URL {
        let script = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (path to desktop folder)
            end if
        end tell
        """
        return URL(fileURLWithPath: try run(script), isDirectory: true)
    }

    /// POSIX paths of the selected Finder items.
    public static func selection() throws -> [URL] {
        let script = """
        tell application "Finder"
            set output to ""
            repeat with anItem in (get selection)
                set output to output & POSIX path of (anItem as alias) & linefeed
            end repeat
            return output
        end tell
        """
        return try run(script).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Creates an empty file with a unique name in the current Finder folder and reveals it.
    @discardableResult
    public static func newFile(named baseName: String = L("finder.untitled"), extension ext: String = "txt") throws -> URL {
        let folder = try currentFolder()
        let url = uniqueURL(in: folder, base: baseName, ext: ext)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw ActionError.failed(L("finder.error.create"))
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    nonisolated static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    /// Opens the current Finder folder in an app (Terminal, iTerm, VS Code…).
    public static func openCurrentFolder(withBundleID bundleID: String) throws {
        let folder = try currentFolder()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ActionError.notAvailable(L("apps.error.notInstalled", bundleID))
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Copies the selected items' paths (or the current folder's) to the clipboard.
    @discardableResult
    public static func copySelectedPaths() throws -> String {
        let selection = try selection()
        let text = selection.isEmpty ? try currentFolder().path : selection.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    private static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ActionError.failed(L("system.error.script")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { throw ActionError.permissionRequired(.automation) }
            throw ActionError.failed(error[NSAppleScript.errorMessage] as? String ?? L("system.error.script"))
        }
        return result.stringValue ?? ""
    }
}
