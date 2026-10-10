import CoreGraphics
import Foundation

/// Every window placement Keystivo can perform. Pure data; see ``SnapGeometry``.
nonisolated public enum SnapPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case firstFourth, secondFourth, thirdFourth, lastFourth
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case maximize, almostMaximize, maximizeHeight, center, reasonableSize

    public var id: String { rawValue }
    public var titleKey: String { "snap.\(rawValue)" }

    public var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .firstThird, .firstTwoThirds, .firstFourth: "rectangle.leadingthird.inset.filled"
        case .centerThird, .centerTwoThirds, .secondFourth, .thirdFourth: "rectangle.center.inset.filled"
        case .lastThird, .lastTwoThirds, .lastFourth: "rectangle.trailingthird.inset.filled"
        case .topLeftQuarter, .topLeftSixth: "rectangle.inset.topleft.filled"
        case .topRightQuarter, .topRightSixth: "rectangle.inset.topright.filled"
        case .bottomLeftQuarter, .bottomLeftSixth: "rectangle.inset.bottomleft.filled"
        case .bottomRightQuarter, .bottomRightSixth: "rectangle.inset.bottomright.filled"
        case .topCenterSixth: "rectangle.tophalf.inset.filled"
        case .bottomCenterSixth: "rectangle.bottomhalf.inset.filled"
        case .maximize: "rectangle.inset.filled"
        case .almostMaximize: "rectangle.center.inset.filled"
        case .maximizeHeight: "arrow.up.and.down.square"
        case .center: "rectangle.center.inset.filled.badge.plus"
        case .reasonableSize: "macwindow"
        }
    }
}

/// Pure placement math, independent of AppKit so it is fully unit-testable.
/// All rects use a top-left origin (AX coordinates).
nonisolated public enum SnapGeometry {
    /// Computes the target frame for `position` inside `area` (a screen's visible frame).
    /// - Parameters:
    ///   - gap: spacing between windows and from screen edges, in points.
    ///   - current: the window's current frame, needed for `center` and `maximizeHeight`.
    public static func frame(for position: SnapPosition, in area: CGRect, gap: CGFloat = 0, current: CGRect? = nil) -> CGRect {
        let inner = area.insetBy(dx: gap, dy: gap)
        let halfGap = gap / 2

        func columns(_ count: Int, _ index: Int, span: Int = 1) -> CGRect {
            let width = inner.width / CGFloat(count)
            var rect = CGRect(x: inner.minX + width * CGFloat(index), y: inner.minY, width: width * CGFloat(span), height: inner.height)
            if index > 0 { rect.origin.x += halfGap; rect.size.width -= halfGap }
            if index + span < count { rect.size.width -= halfGap }
            return rect
        }

        func rows(_ rect: CGRect, _ count: Int, _ index: Int) -> CGRect {
            let height = rect.height / CGFloat(count)
            var result = CGRect(x: rect.minX, y: rect.minY + height * CGFloat(index), width: rect.width, height: height)
            if index > 0 { result.origin.y += halfGap; result.size.height -= halfGap }
            if index < count - 1 { result.size.height -= halfGap }
            return result
        }

        func grid(_ cols: Int, _ col: Int, _ rowCount: Int, _ row: Int) -> CGRect {
            rows(columns(cols, col), rowCount, row)
        }

        switch position {
        case .leftHalf: return columns(2, 0)
        case .rightHalf: return columns(2, 1)
        case .topHalf: return rows(inner, 2, 0)
        case .bottomHalf: return rows(inner, 2, 1)
        case .firstThird: return columns(3, 0)
        case .centerThird: return columns(3, 1)
        case .lastThird: return columns(3, 2)
        case .firstTwoThirds: return columns(3, 0, span: 2)
        case .lastTwoThirds: return columns(3, 1, span: 2)
        case .centerTwoThirds:
            let width = inner.width * 2 / 3
            return CGRect(x: inner.midX - width / 2, y: inner.minY, width: width, height: inner.height)
        case .firstFourth: return columns(4, 0)
        case .secondFourth: return columns(4, 1)
        case .thirdFourth: return columns(4, 2)
        case .lastFourth: return columns(4, 3)
        case .topLeftQuarter: return grid(2, 0, 2, 0)
        case .topRightQuarter: return grid(2, 1, 2, 0)
        case .bottomLeftQuarter: return grid(2, 0, 2, 1)
        case .bottomRightQuarter: return grid(2, 1, 2, 1)
        case .topLeftSixth: return grid(3, 0, 2, 0)
        case .topCenterSixth: return grid(3, 1, 2, 0)
        case .topRightSixth: return grid(3, 2, 2, 0)
        case .bottomLeftSixth: return grid(3, 0, 2, 1)
        case .bottomCenterSixth: return grid(3, 1, 2, 1)
        case .bottomRightSixth: return grid(3, 2, 2, 1)
        case .maximize: return inner
        case .almostMaximize:
            let width = inner.width * 0.9
            let height = inner.height * 0.9
            return CGRect(x: inner.midX - width / 2, y: inner.midY - height / 2, width: width, height: height)
        case .maximizeHeight:
            let frame = current ?? inner
            return CGRect(x: frame.minX, y: inner.minY, width: min(frame.width, inner.width), height: inner.height)
        case .center:
            let frame = current ?? CGRect(x: 0, y: 0, width: inner.width * 0.6, height: inner.height * 0.7)
            let width = min(frame.width, inner.width)
            let height = min(frame.height, inner.height)
            return CGRect(x: inner.midX - width / 2, y: inner.midY - height / 2, width: width, height: height)
        case .reasonableSize:
            let width = min(max(inner.width * 0.6, 800), inner.width)
            let height = min(max(inner.height * 0.7, 600), inner.height)
            return CGRect(x: inner.midX - width / 2, y: inner.midY - height / 2, width: width, height: height)
        }
    }

    /// Maps a frame proportionally from one screen area to another (for moving
    /// windows between displays of different sizes).
    public static func translate(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        let relX = (frame.minX - source.minX) / source.width
        let relY = (frame.minY - source.minY) / source.height
        let relW = frame.width / source.width
        let relH = frame.height / source.height
        var result = CGRect(
            x: target.minX + relX * target.width,
            y: target.minY + relY * target.height,
            width: min(relW * target.width, target.width),
            height: min(relH * target.height, target.height)
        )
        result = clamp(result, to: target)
        return result.integral
    }

    /// Keeps a frame fully inside `area`, shrinking it if necessary.
    public static func clamp(_ frame: CGRect, to area: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(result.width, area.width)
        result.size.height = min(result.height, area.height)
        result.origin.x = min(max(result.minX, area.minX), area.maxX - result.width)
        result.origin.y = min(max(result.minY, area.minY), area.maxY - result.height)
        return result
    }

    /// Grows or shrinks a frame around its center by `step` points per side.
    public static func resize(_ frame: CGRect, by step: CGFloat, within area: CGRect) -> CGRect {
        var result = frame.insetBy(dx: -step, dy: -step)
        if result.width < 200 || result.height < 150 { return frame }
        result = clamp(result, to: area)
        return result
    }

    /// Moves a frame by an offset without leaving `area`.
    public static func nudge(_ frame: CGRect, dx: CGFloat, dy: CGFloat, within area: CGRect) -> CGRect {
        clamp(frame.offsetBy(dx: dx, dy: dy), to: area)
    }

    /// Positions in a cycle used when the same shortcut is pressed repeatedly
    /// (e.g. left half → left two-thirds → left third).
    public static func cycle(after position: SnapPosition) -> SnapPosition? {
        switch position {
        case .leftHalf: .firstTwoThirds
        case .firstTwoThirds: .firstThird
        case .rightHalf: .lastTwoThirds
        case .lastTwoThirds: .lastThird
        default: nil
        }
    }

    /// Lays out `count` windows in a near-square grid (used by tiling/stacking).
    public static func gridFrames(count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = Int(ceil(sqrt(Double(count))))
        let rowCount = Int(ceil(Double(count) / Double(columns)))
        var frames: [CGRect] = []
        let inner = area.insetBy(dx: gap, dy: gap)
        let cellHeight = (inner.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount)
        for row in 0..<rowCount {
            let itemsInRow = min(columns, count - row * columns)
            let cellWidth = (inner.width - gap * CGFloat(itemsInRow - 1)) / CGFloat(itemsInRow)
            for column in 0..<itemsInRow {
                frames.append(CGRect(
                    x: inner.minX + CGFloat(column) * (cellWidth + gap),
                    y: inner.minY + CGFloat(row) * (cellHeight + gap),
                    width: cellWidth, height: cellHeight
                ).integral)
            }
        }
        return frames
    }

    /// Cascades windows diagonally from the top-left of `area`.
    public static func cascadeFrames(count: Int, in area: CGRect, offset: CGFloat = 28, sizeRatio: CGFloat = 0.7) -> [CGRect] {
        guard count > 0 else { return [] }
        let width = area.width * sizeRatio
        let height = area.height * sizeRatio
        let maxSteps = max(1, Int(min((area.width - width) / offset, (area.height - height) / offset)))
        return (0..<count).map { index in
            let step = CGFloat(index % (maxSteps + 1))
            return CGRect(x: area.minX + step * offset, y: area.minY + step * offset, width: width, height: height).integral
        }
    }

    /// Master-stack layout: one large window on the left, the rest stacked on the right.
    public static func stackFrames(count: Int, in area: CGRect, gap: CGFloat, masterRatio: CGFloat = 0.6) -> [CGRect] {
        guard count > 0 else { return [] }
        let inner = area.insetBy(dx: gap, dy: gap)
        guard count > 1 else { return [inner] }
        let masterWidth = (inner.width - gap) * masterRatio
        var frames = [CGRect(x: inner.minX, y: inner.minY, width: masterWidth, height: inner.height)]
        let stackX = inner.minX + masterWidth + gap
        let stackWidth = inner.maxX - stackX
        let others = count - 1
        let height = (inner.height - gap * CGFloat(others - 1)) / CGFloat(others)
        for index in 0..<others {
            frames.append(CGRect(x: stackX, y: inner.minY + CGFloat(index) * (height + gap), width: stackWidth, height: height).integral)
        }
        return frames
    }
}
