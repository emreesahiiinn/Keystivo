import CoreGraphics
@testable import KeystivoWindows
import Testing

@Suite("Snap geometry")
struct SnapGeometryTests {
    let area = CGRect(x: 0, y: 25, width: 1200, height: 800)

    @Test func halves() {
        #expect(SnapGeometry.frame(for: .leftHalf, in: area) == CGRect(x: 0, y: 25, width: 600, height: 800))
        #expect(SnapGeometry.frame(for: .rightHalf, in: area) == CGRect(x: 600, y: 25, width: 600, height: 800))
        #expect(SnapGeometry.frame(for: .topHalf, in: area) == CGRect(x: 0, y: 25, width: 1200, height: 400))
        #expect(SnapGeometry.frame(for: .bottomHalf, in: area) == CGRect(x: 0, y: 425, width: 1200, height: 400))
    }

    @Test func thirdsTileTheScreen() {
        let first = SnapGeometry.frame(for: .firstThird, in: area)
        let center = SnapGeometry.frame(for: .centerThird, in: area)
        let last = SnapGeometry.frame(for: .lastThird, in: area)
        #expect(first.width == 400 && center.minX == 400 && last.maxX == 1200)
        #expect(SnapGeometry.frame(for: .firstTwoThirds, in: area).width == 800)
        #expect(SnapGeometry.frame(for: .lastTwoThirds, in: area).minX == 400)
    }

    @Test func quartersAndSixths() {
        #expect(SnapGeometry.frame(for: .bottomRightQuarter, in: area) == CGRect(x: 600, y: 425, width: 600, height: 400))
        let sixth = SnapGeometry.frame(for: .topCenterSixth, in: area)
        #expect(sixth.minX == 400 && sixth.width == 400 && sixth.height == 400)
    }

    @Test func gapsSeparateNeighbours() {
        let gap: CGFloat = 10
        let left = SnapGeometry.frame(for: .leftHalf, in: area, gap: gap)
        let right = SnapGeometry.frame(for: .rightHalf, in: area, gap: gap)
        #expect(left.minX == area.minX + gap)
        #expect(right.maxX == area.maxX - gap)
        #expect(right.minX - left.maxX == gap)
        #expect(left.minY == area.minY + gap)
    }

    @Test func centerKeepsSize() {
        let current = CGRect(x: 0, y: 0, width: 500, height: 300)
        let centered = SnapGeometry.frame(for: .center, in: area, current: current)
        #expect(centered.size == current.size)
        #expect(centered.midX == area.midX && centered.midY == area.midY)
    }

    @Test func translateBetweenDisplaysKeepsProportions() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let target = CGRect(x: 1000, y: 0, width: 2000, height: 1000)
        let frame = SnapGeometry.translate(CGRect(x: 500, y: 0, width: 500, height: 500), from: source, to: target)
        #expect(frame == CGRect(x: 2000, y: 0, width: 1000, height: 500))
    }

    @Test func clampKeepsWindowInside() {
        let clamped = SnapGeometry.clamp(CGRect(x: 1100, y: -50, width: 300, height: 2000), to: area)
        #expect(area.contains(clamped))
        #expect(clamped.height == area.height)
    }

    @Test func resizeRefusesTinyWindows() {
        let small = CGRect(x: 100, y: 100, width: 210, height: 160)
        #expect(SnapGeometry.resize(small, by: -40, within: area) == small)
        #expect(SnapGeometry.resize(small, by: 40, within: area).width == 290)
    }

    @Test func cycleSequence() {
        #expect(SnapGeometry.cycle(after: .leftHalf) == .firstTwoThirds)
        #expect(SnapGeometry.cycle(after: .firstTwoThirds) == .firstThird)
        #expect(SnapGeometry.cycle(after: .firstThird) == nil)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 7, 9, 12])
    func gridFramesDoNotOverlap(count: Int) {
        let frames = SnapGeometry.gridFrames(count: count, in: area, gap: 8)
        #expect(frames.count == count)
        for (i, a) in frames.enumerated() {
            #expect(area.contains(a))
            for b in frames[(i + 1)...] { #expect(!a.insetBy(dx: 1, dy: 1).intersects(b)) }
        }
    }

    @Test func masterStack() {
        let frames = SnapGeometry.stackFrames(count: 3, in: area, gap: 0)
        #expect(frames.count == 3)
        #expect(frames[0].height == area.height)
        #expect(frames[1].minX == frames[2].minX)
        #expect(abs(frames[0].width - area.width * 0.6) < 1)
    }

    @Test func cascadeStaysOnScreen() {
        for frame in SnapGeometry.cascadeFrames(count: 30, in: area) {
            #expect(area.contains(frame))
        }
    }

    @Test func everyPositionFitsInsideArea() {
        for position in SnapPosition.allCases {
            let frame = SnapGeometry.frame(for: position, in: area, gap: 6, current: CGRect(x: 10, y: 40, width: 700, height: 500))
            #expect(area.contains(frame), "\(position) overflowed: \(frame)")
        }
    }
}

@Suite("Drag to snap zones")
struct DragSnapZoneTests {
    let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)

    @Test func edgesAndCorners() {
        #expect(DragSnapZones.position(for: CGPoint(x: 1, y: 450), in: screen) == .leftHalf)
        #expect(DragSnapZones.position(for: CGPoint(x: 1499, y: 450), in: screen) == .rightHalf)
        #expect(DragSnapZones.position(for: CGPoint(x: 750, y: 899), in: screen) == .maximize)
        #expect(DragSnapZones.position(for: CGPoint(x: 2, y: 880), in: screen) == .topLeftQuarter)
        #expect(DragSnapZones.position(for: CGPoint(x: 1498, y: 5), in: screen) == .bottomRightQuarter)
        #expect(DragSnapZones.position(for: CGPoint(x: 750, y: 450), in: screen) == nil)
    }

    @Test func bottomEdgeThirds() {
        #expect(DragSnapZones.position(for: CGPoint(x: 300, y: 1), in: screen) == .firstThird)
        #expect(DragSnapZones.position(for: CGPoint(x: 750, y: 1), in: screen) == .centerThird)
        #expect(DragSnapZones.position(for: CGPoint(x: 1200, y: 1), in: screen) == .lastThird)
        var configuration = DragSnapZones.Configuration()
        configuration.bottomEdgeThirds = false
        configuration.topEdgeMaximizes = false
        #expect(DragSnapZones.position(for: CGPoint(x: 750, y: 1), in: screen, configuration: configuration) == .bottomHalf)
        #expect(DragSnapZones.position(for: CGPoint(x: 750, y: 899), in: screen, configuration: configuration) == .topHalf)
    }

    @Test func worksOnOffsetScreens() {
        let secondary = CGRect(x: 1500, y: -200, width: 1920, height: 1080)
        #expect(DragSnapZones.position(for: CGPoint(x: 1501, y: 300), in: secondary) == .leftHalf)
    }
}
