import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

/// One entry of the focus history: a window the user focused.
nonisolated public struct FocusRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(pid)-\(windowID)" }
    public let windowID: CGWindowID
    public let pid: pid_t
    public let bundleID: String?
    public let appName: String
    public var title: String
    public var lastFocused: Date
    public var focusCount: Int
}

/// Most-recently-used window order, fed by ``WindowEventHub``.
///
/// Powers the switcher ordering (MRU), "return to previous window" and the
/// window history list.
@Observable
public final class FocusHistory {
    public static let shared = FocusHistory()

    public private(set) var records: [FocusRecord] = []
    public var capacity = 200

    @ObservationIgnored private var subscription: UUID?

    public init() {}

    public func start(hub: WindowEventHub = .shared) {
        guard subscription == nil else { return }
        subscription = hub.subscribe { [weak self] event in
            switch event {
            case .windowFocused(let pid, let window):
                self?.recordFocus(pid: pid, window: window)
            case .appTerminated(let pid, _):
                self?.records.removeAll { $0.pid == pid }
            default:
                break
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication,
           let window = AXElement.application(pid: app.processIdentifier).focusedWindow {
            recordFocus(pid: app.processIdentifier, window: window)
        }
    }

    private func recordFocus(pid: pid_t, window: AXElement) {
        guard let windowID = window.windowID, pid != getpid() else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        let title = window.title ?? ""
        if let index = records.firstIndex(where: { $0.windowID == windowID && $0.pid == pid }) {
            var record = records.remove(at: index)
            record.title = title.isEmpty ? record.title : title
            record.lastFocused = .now
            record.focusCount += 1
            records.insert(record, at: 0)
        } else {
            records.insert(FocusRecord(
                windowID: windowID, pid: pid, bundleID: app?.bundleIdentifier,
                appName: app?.localizedName ?? "", title: title, lastFocused: .now, focusCount: 1
            ), at: 0)
            if records.count > capacity { records.removeLast(records.count - capacity) }
        }
    }

    /// MRU rank for a window (lower = more recent); unknown windows sort last.
    public func rank(of windowID: CGWindowID) -> Int {
        records.firstIndex { $0.windowID == windowID } ?? Int.max
    }

    /// The window focused before the current one, if it still exists.
    public func previousWindow() -> FocusRecord? {
        let live = Set(WindowCatalog.serverWindows().map(\.id))
        return records.dropFirst().first { live.contains($0.windowID) }
    }

    public func clear() { records.removeAll() }
}
