import ApplicationServices
import CoreGraphics
@testable import KeystivoWindows
import Testing

@Suite("Window buttons")
@MainActor
struct WindowButtonTests {
    @Test func recognizesButtonsBySubrole() {
        #expect(WindowButton(subrole: kAXCloseButtonSubrole) == .close)
        #expect(WindowButton(subrole: kAXMinimizeButtonSubrole) == .minimize)
        #expect(WindowButton(subrole: kAXZoomButtonSubrole) == .zoom)
        #expect(WindowButton(subrole: "AXFullScreenButton") == .zoom)
        #expect(WindowButton(subrole: "AXToolbarButton") == nil)
        #expect(WindowButton(subrole: nil) == nil)
    }

    @Test func onlyTheTopLeftCornerIsExamined() {
        let window = CGRect(x: 200, y: 100, width: 900, height: 600)
        #expect(WindowButtonGeometry.isInButtonArea(CGPoint(x: 214, y: 114), window: window))
        #expect(WindowButtonGeometry.isInButtonArea(CGPoint(x: 270, y: 150), window: window))
        #expect(!WindowButtonGeometry.isInButtonArea(CGPoint(x: 600, y: 114), window: window))
        #expect(!WindowButtonGeometry.isInButtonArea(CGPoint(x: 214, y: 400), window: window))
        #expect(!WindowButtonGeometry.isInButtonArea(CGPoint(x: 190, y: 114), window: window))
    }

    @Test func looksThroughOverlaysAboveTheNormalLayer() {
        let overlay = PointerWindowResolver.Entry(id: 1, pid: 10, layer: 1000, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let app = PointerWindowResolver.Entry(id: 2, pid: 20, layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600))
        let behind = PointerWindowResolver.Entry(id: 3, pid: 30, layer: 0, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let point = CGPoint(x: 114, y: 114)
        #expect(PointerWindowResolver.normalWindow(at: point, in: [overlay, app, behind])?.id == 2)
        // The full-screen click-through overlay used to hide every window from the engine.
        #expect(PointerWindowResolver.window(at: point, in: [overlay, app, behind]) == nil)
        let menu = PointerWindowResolver.Entry(id: 4, pid: 40, layer: PointerWindowResolver.popUpMenuLayer, bounds: CGRect(x: 600, y: 600, width: 200, height: 300))
        #expect(PointerWindowResolver.normalWindow(at: point, in: [menu, overlay, app]) == nil)
    }

    @Test func listensOnlyForConfiguredClickTypes() {
        let engine = WindowButtonEngine()
        #expect(engine.eventTapTypes.isEmpty)
        engine.isEnabled = true
        #expect(engine.eventTapTypes.isEmpty)
        engine.actions = [WindowButtonEngine.key(.close, rightClick: false): .quitApp]
        #expect(engine.eventTapTypes == [.leftMouseDown, .leftMouseUp])
        engine.actions[WindowButtonEngine.key(.zoom, rightClick: true)] = .maximize
        #expect(engine.eventTapTypes == [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
        #expect(engine.action(for: .minimize, rightClick: false) == .standard)
        #expect(engine.action(for: .close, rightClick: false) == .quitApp)
        engine.isEnabled = false
        #expect(engine.eventTapTypes.isEmpty)
    }
}
