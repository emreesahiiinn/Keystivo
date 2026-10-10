import AppKit
import ScreenSaver
import SwiftUI

/// The macOS screen saver view: hosts a Keystivo design (SwiftUI) full screen.
/// Each `.saver` bundle subclasses it with its own style (see build-savers.sh).
class KeystivoSaverHost: ScreenSaverView {
    class var saverStyle: SaverStyle { .shuffle }

    private var stopObserver: (any NSObjectProtocol)?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp(isPreview: isPreview)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp(isPreview: false)
    }

    private func setUp(isPreview: Bool) {
        // SwiftUI drives the animation; the screen saver timer only needs to tick rarely.
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let hosting = NSHostingView(rootView: SaverRootView(style: Self.saverStyle, isPreview: isPreview))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        if !isPreview {
            // Since macOS 14 the screen saver host process keeps running (and
            // animating) after the saver is dismissed; leave together with it.
            stopObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
            ) { _ in exit(0) }
        }
    }

    override func animateOneFrame() {}
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
