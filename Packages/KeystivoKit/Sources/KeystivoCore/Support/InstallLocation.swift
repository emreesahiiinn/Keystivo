import Foundation

/// Where the running app bundle lives. Keystivo should run from an
/// Applications folder: privacy permissions, launch at login and the
/// privileged helper are all tied to a stable bundle location.
nonisolated public enum InstallLocation: Equatable, Sendable {
    /// /Applications or ~/Applications.
    case applications
    /// Opened straight from a mounted disk image (or another volume).
    case diskImage
    /// Quarantined app that macOS runs from a randomized read-only path.
    case translocated
    /// Xcode build products.
    case development
    /// Anywhere else, e.g. Downloads or Desktop.
    case other

    public static func classify(_ path: String, home: String = NSHomeDirectory()) -> InstallLocation {
        let path = (path as NSString).standardizingPath
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return .development }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        return .other
    }

    /// Whether to offer moving the app to /Applications.
    public var shouldOfferMove: Bool {
        switch self {
        case .diskImage, .translocated, .other: true
        case .applications, .development: false
        }
    }

    /// Copy instead of move when the source can't (or shouldn't) be removed.
    public var copiesInsteadOfMoving: Bool {
        self == .diskImage || self == .translocated
    }
}
