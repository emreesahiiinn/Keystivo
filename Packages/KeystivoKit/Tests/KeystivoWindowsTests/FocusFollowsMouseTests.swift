import CoreGraphics
@testable import KeystivoWindows
import Testing

@Suite("Focus follows mouse")
struct FocusFollowsMouseTests {
    typealias Entry = PointerWindowResolver.Entry

    // Front to back: Safari over Notes; Notes is larger and extends to the right.
    let safari = Entry(id: 10, pid: 100, layer: 0, bounds: CGRect(x: 0, y: 30, width: 800, height: 600))
    let notes = Entry(id: 20, pid: 200, layer: 0, bounds: CGRect(x: 400, y: 100, width: 900, height: 700))
    let dock = Entry(id: 1, pid: 50, layer: 20, bounds: CGRect(x: 300, y: 1340, width: 1000, height: 100))

    @Test func picksTopmostNormalWindowUnderPointer() {
        let windows = [dock, safari, notes]
        #expect(PointerWindowResolver.window(at: CGPoint(x: 500, y: 200), in: windows)?.id == 10)
        #expect(PointerWindowResolver.window(at: CGPoint(x: 1000, y: 200), in: windows)?.id == 20)
    }

    @Test func desktopDockAndFloatingWindowsAreIgnored() {
        let panel = Entry(id: 30, pid: 300, layer: 3, bounds: CGRect(x: 0, y: 30, width: 200, height: 200))
        let windows = [dock, panel, safari, notes]
        #expect(PointerWindowResolver.window(at: CGPoint(x: 1400, y: 900), in: windows) == nil)
        #expect(PointerWindowResolver.window(at: CGPoint(x: 500, y: 1380), in: windows) == nil)
        #expect(PointerWindowResolver.window(at: CGPoint(x: 100, y: 100), in: windows) == nil)
    }

    @Test func openMenuBlocksSwitching() {
        let menu = Entry(id: 40, pid: 100, layer: PointerWindowResolver.popUpMenuLayer, bounds: CGRect(x: 0, y: 30, width: 150, height: 200))
        #expect(PointerWindowResolver.window(at: CGPoint(x: 1000, y: 200), in: [menu, safari, notes]) == nil)
    }

    @Test func lookPastClickThroughWindows() {
        let overlay = Entry(id: 50, pid: 999, layer: 0, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let invisible = Entry(id: 60, pid: 400, layer: 0, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), alpha: 0)
        #expect(PointerWindowResolver.window(at: CGPoint(x: 500, y: 200), in: [overlay, safari], passThrough: [50])?.id == 10)
        #expect(PointerWindowResolver.window(at: CGPoint(x: 500, y: 200), in: [invisible, safari])?.id == 10)
    }

    @Test func activeWindowIsTheFrontmostAppsFirstWindow() {
        let safariSecond = Entry(id: 11, pid: 100, layer: 0, bounds: CGRect(x: 900, y: 30, width: 500, height: 400))
        let windows = [safari, notes, safariSecond]
        #expect(PointerWindowResolver.isActive(safari, in: windows, frontmostPID: 100))
        #expect(!PointerWindowResolver.isActive(safariSecond, in: windows, frontmostPID: 100))
        #expect(!PointerWindowResolver.isActive(notes, in: windows, frontmostPID: 100))
    }
}
