import AppKit
import ApplicationServices

/// Event-driven AX notifications for one application process.
///
/// Callbacks arrive on the main run loop. Used for focus history, default window
/// placement and Dock hover detection, avoiding any polling.
public final class AXObserverBridge {
    public typealias Handler = @MainActor (_ notification: String, _ element: AXElement) -> Void

    public let pid: pid_t
    private var observer: AXObserver?
    private var registered: [(AXElement, String)] = []
    private let handler: Handler
    private var context: Unmanaged<Box>?

    private final class Box {
        weak var bridge: AXObserverBridge?
        init(_ bridge: AXObserverBridge) { self.bridge = bridge }
    }

    public init?(pid: pid_t, handler: @escaping Handler) {
        self.pid = pid
        self.handler = handler
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            nonisolated(unsafe) let element = element
            let name = notification as String
            MainActor.assumeIsolated {
                let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
                box.bridge?.handler(name, AXElement(element))
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
        self.observer = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        context = Unmanaged.passRetained(Box(self))
    }

    deinit {
        MainActor.assumeIsolated {
            removeAll()
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            context?.release()
        }
    }

    @discardableResult
    public func observe(_ notification: String, on element: AXElement) -> Bool {
        guard let observer, let context else { return false }
        let status = AXObserverAddNotification(observer, element.raw, notification as CFString, context.toOpaque())
        if status == .success || status == .notificationAlreadyRegistered {
            registered.append((element, notification))
            return true
        }
        return false
    }

    public func removeAll() {
        guard let observer else { return }
        for (element, notification) in registered {
            AXObserverRemoveNotification(observer, element.raw, notification as CFString)
        }
        registered.removeAll()
    }
}
