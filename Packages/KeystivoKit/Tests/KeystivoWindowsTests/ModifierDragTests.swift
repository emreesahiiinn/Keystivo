import CoreGraphics
@testable import KeystivoWindows
import Testing

@Suite("Modifier drag")
struct ModifierDragTests {
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func cornerFollowsWhereTheDragStarted() {
        #expect(ModifierDragGeometry.corner(for: CGPoint(x: 150, y: 150), in: frame) == (true, true))
        #expect(ModifierDragGeometry.corner(for: CGPoint(x: 850, y: 650), in: frame) == (false, false))
    }

    @Test func resizesFromTheGrabbedCorner() {
        // Bottom-right corner: grows right and down.
        #expect(ModifierDragGeometry.resized(frame, by: CGSize(width: 50, height: 30), corner: (false, false)) == CGRect(x: 100, y: 100, width: 850, height: 630))
        // Top-left corner: the opposite corner stays put.
        let topLeft = ModifierDragGeometry.resized(frame, by: CGSize(width: 50, height: 30), corner: (true, true))
        #expect(topLeft == CGRect(x: 150, y: 130, width: 750, height: 570))
        #expect(topLeft.maxX == frame.maxX && topLeft.maxY == frame.maxY)
    }

    @Test func neverShrinksBelowTheMinimum() {
        let tiny = ModifierDragGeometry.resized(frame, by: CGSize(width: -2000, height: -2000), corner: (false, false))
        #expect(tiny.size == ModifierDragGeometry.minimumSize)
        let fromLeft = ModifierDragGeometry.resized(frame, by: CGSize(width: 2000, height: 0), corner: (true, false))
        #expect(fromLeft.width == ModifierDragGeometry.minimumSize.width && fromLeft.maxX == frame.maxX)
    }
}
