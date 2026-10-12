import AppKit
import KeystivoCore
import KeystivoTools
import SwiftUI

// MARK: - Area selection

/// Full-screen overlay to pick a recording area: drag for an area, click for the
/// whole display, Esc to cancel.
final class AreaSelector {
    struct Selection {
        let screen: NSScreen
        /// Screen-local points with a top-left origin; nil means the whole screen.
        let rect: CGRect?
    }

    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?

    func select() async -> Selection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let window = SelectionWindow(screen: screen)
                let view = AreaSelectionView(screen: screen) { [weak self] selection in self?.finish(selection) }
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                windows.append(window)
            }
            NSApp.activate()
            (NSScreen.underMouse.flatMap { screen in windows.first { $0.screen == screen } } ?? windows.first)?.makeKey()
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ selection: Selection?) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        continuation.resume(returning: selection)
    }

    private final class SelectionWindow: NSWindow {
        init(screen: NSScreen) {
            super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            level = .screenSaver
            hasShadow = false
            isReleasedWhenClosed = false
            animationBehavior = .none
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            acceptsMouseMovedEvents = true
            setFrame(screen.frame, display: false)
        }

        override var canBecomeKey: Bool { true }
    }
}

private final class AreaSelectionView: NSView {
    private let screen: NSScreen
    private let onFinish: (AreaSelector.Selection?) -> Void
    private var start: CGPoint?
    private var current: CGPoint?
    private var hovering = false

    init(screen: NSScreen, onFinish: @escaping (AreaSelector.Selection?) -> Void) {
        self.screen = screen
        self.onFinish = onFinish
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        let rect = CGRect(from: start, to: current)
        return rect.width >= 4 && rect.height >= 4 ? rect : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(hovering || selection != nil ? 0.38 : 0.22).cgColor)
        if let rect = selection {
            context.addRect(bounds)
            context.addRect(rect)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
            drawBadge("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: rect.maxX, y: rect.maxY + 8), alignRight: true)
        } else {
            context.fill(bounds)
            if hovering {
                drawBadge(L("record.selectHint"), at: CGPoint(x: bounds.midX, y: bounds.midY), centered: true, large: true)
            }
        }
    }

    private func drawBadge(_ text: String, at point: CGPoint, alignRight: Bool = false, centered: Bool = false, large: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: large ? NSFont.systemFont(ofSize: 15, weight: .semibold) : NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let padding: CGFloat = large ? 14 : 6
        var origin = point
        if alignRight { origin.x -= size.width + padding * 2 }
        if centered { origin = CGPoint(x: point.x - size.width / 2 - padding, y: point.y - size.height / 2 - padding / 2) }
        let badge = CGRect(x: origin.x, y: origin.y, width: size.width + padding * 2, height: size.height + padding)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2.4, yRadius: badge.height / 2.4).fill()
        string.draw(at: CGPoint(x: badge.minX + padding, y: badge.minY + padding / 2), withAttributes: attributes)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if !hovering {
            hovering = true
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selection
        start = nil
        current = nil
        onFinish(AreaSelector.Selection(screen: screen, rect: rect?.integral))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCodes.escape: onFinish(nil)
        case KeyCodes.returnKey, KeyCodes.space: onFinish(AreaSelector.Selection(screen: screen, rect: nil))
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Recording controller

/// Screen recording flow: permission → area → countdown → record → stop → save.
final class RecordingController {
    private unowned let runtime: KeystivoRuntime
    private var controlPanel: FloatingPanel?
    private var borderWindow: NSWindow?
    private var countdownWindow: NSWindow?
    private var isPreparing = false
    private let recorder = ScreenRecorder.shared

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
        recorder.onFinish = { [weak self] result in self?.finished(result) }
    }

    var isRecording: Bool { recorder.isActive }

    func toggle() async {
        if recorder.isActive {
            recorder.stop()
            return
        }
        guard !isPreparing else { return }
        PermissionCenter.shared.refresh()
        guard PermissionCenter.shared.isGranted(.screenRecording) else {
            PermissionCenter.shared.request(.screenRecording)
            runtime.hud.show(symbol: "rectangle.dashed.badge.record", text: L("record.needsPermission"), style: .warning)
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        guard let selection = await AreaSelector().select() else { return }
        let settings = runtime.config.tools
        if settings.recordingCountdown {
            guard await countdown(on: selection.screen, rect: selection.rect) else { return }
        }
        showChrome(for: selection)

        var options = RecordingOptions(folder: URL(fileURLWithPath: (settings.recordingFolder as NSString).expandingTildeInPath, isDirectory: true))
        options.showsCursor = settings.recordingShowsCursor
        options.capturesSystemAudio = settings.recordingCapturesAudio
        options.capturesMicrophone = settings.recordingCapturesMicrophone
        options.usesHEVC = settings.recordingUsesHEVC
        options.framesPerSecond = settings.recordingFrameRate
        options.excludedWindowNumbers = [controlPanel, borderWindow].compactMap { $0?.windowNumber }
        do {
            try await recorder.start(display: selection.screen.displayID, area: selection.rect, options: options)
        } catch {
            hideChrome()
            runtime.hud.show(symbol: "exclamationmark.triangle", text: error.localizedDescription, style: .warning)
            DiagnosticsCenter.shared.record(error, module: "Tools", context: L("action.tools.recordScreen"))
        }
    }

    private func finished(_ result: Result<URL, any Error>) {
        hideChrome()
        let format = runtime.config.tools.recordingFormat
        if case .success(let movie) = result, format != .mov {
            // Convert first (GIF can take a moment), then reveal/open/copy the result.
            runtime.hud.show(symbol: "hourglass", text: L("record.converting", L(format.titleKey)))
            Task {
                do {
                    let converted = try await RecordingExporter.export(movie, as: format)
                    finished(converted)
                } catch {
                    // The original movie is kept if conversion fails.
                    runtime.hud.show(symbol: "exclamationmark.triangle", text: L("record.convertFailed"), style: .warning)
                    finished(movie)
                }
            }
            return
        }
        switch result {
        case .success(let url):
            finished(url)
        case .failure(let error):
            runtime.hud.show(symbol: "exclamationmark.triangle", text: error.localizedDescription, style: .warning)
            DiagnosticsCenter.shared.record(error, module: "Tools", context: L("action.tools.recordScreen"))
        }
    }

    private func finished(_ url: URL) {
        do {
            runtime.hud.show(symbol: "checkmark.circle", text: L("record.saved", url.lastPathComponent))
            switch runtime.config.tools.recordingAfter {
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
            case .open: NSWorkspace.shared.open(url)
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
        }
    }

    // MARK: Chrome

    /// 3-2-1 countdown before recording starts.
    private func countdown(on screen: NSScreen, rect: CGRect?) async -> Bool {
        let size = CGSize(width: 150, height: 150)
        let area = rect.map { Self.globalRect($0, on: screen) } ?? screen.frame
        let window = NSWindow(contentRect: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let model = CountdownModel()
        window.contentView = NSHostingView(rootView: CountdownView(model: model))
        window.orderFrontRegardless()
        countdownWindow = window
        defer {
            window.orderOut(nil)
            countdownWindow = nil
        }
        for value in stride(from: 3, through: 1, by: -1) {
            model.value = value
            try? await Task.sleep(for: .milliseconds(850))
        }
        return true
    }

    private func showChrome(for selection: AreaSelector.Selection) {
        if let rect = selection.rect {
            let frame = Self.globalRect(rect, on: selection.screen).insetBy(dx: -3, dy: -3)
            let border = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            border.isOpaque = false
            border.backgroundColor = .clear
            border.ignoresMouseEvents = true
            border.hasShadow = false
            border.level = .statusBar
            border.isReleasedWhenClosed = false
            border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            border.contentView = NSHostingView(rootView: RecordingBorderView())
            border.orderFrontRegardless()
            borderWindow = border
        }

        let panel = FloatingPanel(size: CGSize(width: 210, height: 46), level: .statusBar)
        panel.host(RecordingControlView(recorder: recorder) { [weak self] in self?.recorder.stop() })
        let visible = selection.screen.visibleFrame
        var origin = CGPoint(x: visible.midX - 105, y: visible.minY + 24)
        if let rect = selection.rect {
            let area = Self.globalRect(rect, on: selection.screen)
            // Below the area when there's room, otherwise inside its bottom edge.
            origin = CGPoint(x: area.midX - 105, y: area.minY - 58 >= visible.minY ? area.minY - 58 : area.minY + 12)
        }
        panel.setFrameOrigin(origin)
        panel.presentAnimated(makeKey: false)
        controlPanel = panel
    }

    private func hideChrome() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
        controlPanel?.dismissAnimated()
        controlPanel = nil
    }

    /// Screen-local top-left rect → global AppKit (bottom-left) coordinates.
    static func globalRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

@Observable
private final class CountdownModel {
    var value = 3
}

private struct CountdownView: View {
    let model: CountdownModel

    var body: some View {
        Text("\(model.value)")
            .font(.system(size: 76, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .contentTransition(.numericText(countsDown: true))
            .frame(width: 130, height: 130)
            .background(Circle().fill(.black.opacity(0.55)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .animation(.snappy, value: model.value)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingBorderView: View {
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.red.opacity(pulse ? 0.95 : 0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

private struct RecordingControlView: View {
    let recorder: ScreenRecorder
    let onStop: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.8), radius: pulse ? 6 : 1)
                .scaleEffect(pulse ? 1 : 0.8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            Button(action: onStop) {
                Label(L("record.stop"), systemImage: "stop.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.red.opacity(0.9)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(width: 210, height: 46)
        .keystivoPanelBackground(cornerRadius: 23)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func elapsed(at date: Date) -> String {
        guard case .recording(let since) = recorder.state else { return "00:00" }
        let seconds = max(0, Int(date.timeIntervalSince(since)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
