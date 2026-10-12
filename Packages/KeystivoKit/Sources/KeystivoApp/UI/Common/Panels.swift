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

/// Borderless floating panel hosting SwiftUI content.
///
/// Non-activating by default: it takes keyboard focus without making Keystivo
/// the active app, so the previous app keeps its menu bar and receives pastes
/// after the panel closes — the same behavior as Spotlight.
class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var acceptsKey = true

    init(size: CGSize = .zero, activating: Bool = false, level: NSWindow.Level = .floating) {
        var style: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if !activating { style.insert(.nonactivatingPanel) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: true)
        isFloatingPanel = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Hosts a SwiftUI view, sizing the panel to `size` (or the view's fitting size).
    final func host<Content: View>(_ view: Content, size: CGSize? = nil) {
        let hosting = NSHostingView(rootView: view.localizedRoot())
        hosting.sizingOptions = size == nil ? [.preferredContentSize] : []
        contentView = hosting
        if let size { setContentSize(size) } else { setContentSize(hosting.fittingSize) }
    }

    /// Centers horizontally on `screen`, with the top at `topFraction` of its height.
    final func position(on screen: NSScreen?, topFraction: CGFloat = 0.22) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - visible.height * topFraction - size.height
        setFrameOrigin(NSPoint(x: x.rounded(), y: max(visible.minY, y).rounded()))
    }

    /// Fades in while gliding up a few points — a soft, spring-like entrance.
    final func presentAnimated(makeKey: Bool, rise: CGFloat = 10) {
        let target = frame
        alphaValue = 0
        setFrame(target.offsetBy(dx: 0, dy: -rise), display: false)
        if makeKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    /// Quick fade-out, then removes the panel from screen.
    final func dismissAnimated(completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.alphaValue = 1
                completion?()
            }
        })
    }

    final func center(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded()))
    }
}

/// Full-screen, click-through overlay window (hints, mouse trail).
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
}
