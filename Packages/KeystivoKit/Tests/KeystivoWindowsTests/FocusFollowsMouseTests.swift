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

    @Test func frontWindowOfADisplayIsTheOneMostlyOnIt() {
        let second = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let straddling = Entry(id: 40, pid: 400, layer: 0, bounds: CGRect(x: 2200, y: 100, width: 400, height: 300))
        let onSecond = Entry(id: 50, pid: 500, layer: 0, bounds: CGRect(x: 2700, y: 100, width: 900, height: 700))
        let tiny = Entry(id: 60, pid: 600, layer: 0, bounds: CGRect(x: 3000, y: 100, width: 40, height: 20))
        // The straddling window is mostly on the first display; tiny helper windows don't count.
        #expect(PointerWindowResolver.frontWindow(on: second, in: [tiny, straddling, onSecond, safari])?.id == 50)
        #expect(PointerWindowResolver.frontWindow(on: second, in: [safari, notes]) == nil)
        let menu = Entry(id: 70, pid: 700, layer: PointerWindowResolver.popUpMenuLayer, bounds: .zero)
        #expect(PointerWindowResolver.frontWindow(on: second, in: [menu, onSecond]) == nil)
    }

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
