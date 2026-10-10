import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Model

nonisolated public enum AnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, counter, pixelate, crop

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut inside the editor.
    public var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .pixelate: "b"
        case .crop: "c"
        }
    }

    public var titleKey: String { "annotate.tool.\(rawValue)" }
}

nonisolated public struct AnnotationColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let palette: [AnnotationColor] = [
        AnnotationColor(red: 1.00, green: 0.23, blue: 0.19), // red
        AnnotationColor(red: 1.00, green: 0.62, blue: 0.04), // orange
        AnnotationColor(red: 1.00, green: 0.84, blue: 0.04), // yellow
        AnnotationColor(red: 0.20, green: 0.78, blue: 0.35), // green
        AnnotationColor(red: 0.04, green: 0.52, blue: 1.00), // blue
        AnnotationColor(red: 0.69, green: 0.32, blue: 0.87), // purple
        AnnotationColor(red: 1.00, green: 1.00, blue: 1.00), // white
        AnnotationColor(red: 0.00, green: 0.00, blue: 0.00), // black
    ]

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// Black or white, whichever reads better on this color.
    public var contrasting: CGColor {
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.6 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }
}

nonisolated public struct AnnotationShape: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rectangle(CGRect, filled: Bool)
        case ellipse(CGRect, filled: Bool)
        case path([CGPoint], highlighter: Bool)
        case text(String, origin: CGPoint, size: CGFloat)
        case counter(Int, center: CGPoint)
        case pixelate(CGRect)
    }

    public let id: UUID
    public var kind: Kind
    public var color: AnnotationColor
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), kind: Kind, color: AnnotationColor, lineWidth: CGFloat) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    public var counterDiameter: CGFloat { max(26, lineWidth * 6) }

    /// Approximate bounds in document coordinates (used for hit testing and selection).
    public var bounds: CGRect {
        let pad = lineWidth / 2
        switch kind {
        case .arrow(let from, let to), .line(let from, let to):
            return CGRect(from: from, to: to).insetBy(dx: -pad - lineWidth * 2, dy: -pad - lineWidth * 2)
        case .rectangle(let rect, _), .ellipse(let rect, _):
            return rect.standardized.insetBy(dx: -pad, dy: -pad)
        case .path(let points, let highlighter):
            guard let first = points.first else { return .null }
            let width = highlighter ? lineWidth * 4 : lineWidth
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -width / 2, dy: -width / 2)
        case .text(let string, let origin, let size):
            let measured = AnnotationRenderer.attributedText(string, size: size, color: color).size()
            return CGRect(origin: origin, size: CGSize(width: max(measured.width, size), height: max(measured.height, size * 1.2)))
        case .counter(_, let center):
            let d = counterDiameter
            return CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        case .pixelate(let rect):
            return rect.standardized
        }
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        switch kind {
        case .arrow(let from, let to), .line(let from, let to):
            return point.distance(toSegment: from, to) <= lineWidth / 2 + tolerance
        case .path(let points, let highlighter):
            let width = highlighter ? lineWidth * 4 : lineWidth
            return zip(points, points.dropFirst()).contains { point.distance(toSegment: $0, $1) <= width / 2 + tolerance }
                || (points.count == 1 && points[0].distance(to: point) <= width / 2 + tolerance)
        case .rectangle(let rect, let filled):
            let rect = rect.standardized
            if filled { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            let outer = rect.insetBy(dx: -lineWidth / 2 - tolerance, dy: -lineWidth / 2 - tolerance)
            let inner = rect.insetBy(dx: lineWidth / 2 + tolerance, dy: lineWidth / 2 + tolerance)
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
        case .ellipse(let rect, let filled):
            let rect = rect.standardized
            guard rect.width > 0, rect.height > 0 else { return false }
            let dx = (point.x - rect.midX) / (rect.width / 2)
            let dy = (point.y - rect.midY) / (rect.height / 2)
            let distance = (dx * dx + dy * dy).squareRoot()
            if filled { return distance <= 1.05 }
            let band = (lineWidth / 2 + tolerance) / min(rect.width, rect.height) * 2
            return abs(distance - 1) <= band
        case .text, .counter, .pixelate:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> AnnotationShape {
        var copy = self
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + dx, y: point.y + dy) }
        switch kind {
        case .arrow(let from, let to): copy.kind = .arrow(from: move(from), to: move(to))
        case .line(let from, let to): copy.kind = .line(from: move(from), to: move(to))
        case .rectangle(let rect, let filled): copy.kind = .rectangle(rect.offsetBy(dx: dx, dy: dy), filled: filled)
        case .ellipse(let rect, let filled): copy.kind = .ellipse(rect.offsetBy(dx: dx, dy: dy), filled: filled)
        case .path(let points, let highlighter): copy.kind = .path(points.map(move), highlighter: highlighter)
        case .text(let string, let origin, let size): copy.kind = .text(string, origin: move(origin), size: size)
        case .counter(let number, let center): copy.kind = .counter(number, center: move(center))
        case .pixelate(let rect): copy.kind = .pixelate(rect.offsetBy(dx: dx, dy: dy))
        }
        return copy
    }

    /// Shapes too small to be intentional (a click without a drag).
    public var isDegenerate: Bool {
        switch kind {
        case .arrow(let from, let to), .line(let from, let to): from.distance(to: to) < 4
        case .rectangle(let rect, _), .ellipse(let rect, _), .pixelate(let rect): abs(rect.width) < 4 || abs(rect.height) < 4
        case .path(let points, _): points.isEmpty
        case .text(let string, _, _): string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter: false
        }
    }
}

/// An image plus its annotations, with snapshot-based undo.
nonisolated public struct AnnotationDocument: Sendable {
    public let imageSize: CGSize
    public private(set) var shapes: [AnnotationShape] = []
    public private(set) var crop: CGRect?

    private struct Snapshot: Sendable {
        var shapes: [AnnotationShape]
        var crop: CGRect?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    public init(imageSize: CGSize) {
        self.imageSize = imageSize
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// The visible area: the crop, or the whole image.
    public var visibleRect: CGRect { crop ?? CGRect(origin: .zero, size: imageSize) }

    /// Next number for the counter tool.
    public var nextCounter: Int {
        shapes.reduce(0) { result, shape in
            if case .counter(let number, _) = shape.kind { max(result, number) } else { result }
        } + 1
    }

    private mutating func checkpoint() {
        undoStack.append(Snapshot(shapes: shapes, crop: crop))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func add(_ shape: AnnotationShape) {
        guard !shape.isDegenerate else { return }
        checkpoint()
        shapes.append(shape)
    }

    public mutating func replace(_ shape: AnnotationShape) {
        guard let index = shapes.firstIndex(where: { $0.id == shape.id }), shapes[index] != shape else { return }
        checkpoint()
        if shape.isDegenerate { shapes.remove(at: index) } else { shapes[index] = shape }
    }

    public mutating func remove(id: AnnotationShape.ID) {
        guard shapes.contains(where: { $0.id == id }) else { return }
        checkpoint()
        shapes.removeAll { $0.id == id }
    }

    public mutating func setCrop(_ rect: CGRect?) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clamped = rect.map { $0.standardized.intersection(bounds).integral }
        let normalized = clamped.flatMap { $0.isEmpty || $0.size == imageSize ? nil : $0 }
        guard normalized != crop else { return }
        checkpoint()
        crop = normalized
    }

    public mutating func clear() {
        guard !shapes.isEmpty || crop != nil else { return }
        checkpoint()
        shapes.removeAll()
        crop = nil
    }

    public mutating func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(shapes: shapes, crop: crop))
        shapes = snapshot.shapes
        crop = snapshot.crop
    }

    public mutating func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(shapes: shapes, crop: crop))
        shapes = snapshot.shapes
        crop = snapshot.crop
    }

    /// Topmost shape under the point.
    public func shape(at point: CGPoint) -> AnnotationShape? {
        shapes.last { $0.hitTest(point) }
    }
}

// MARK: - Rendering

/// Draws annotations with Core Graphics in a top-left-origin coordinate space.
/// Used both by the live editor and for export, so what you see is what you get.
public enum AnnotationRenderer {
    /// A pixelated copy of the whole image; pixelate shapes reveal it through a clip.
    public static func pixelated(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(10, CGFloat(image.width) / 70))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent)
    }

    nonisolated static func attributedText(_ string: String, size: CGFloat, color: AnnotationColor) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(cgColor: color.contrasting)?.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = max(2, size / 8)
        shadow.shadowOffset = .zero
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .red,
            .shadow: shadow,
        ])
    }

    /// Draws `shapes` into `context`, which must be flipped (y grows downwards).
    /// `pixelated` is the precomputed pixelated image drawn at `imageRect`.
    public static func draw(_ shapes: [AnnotationShape], in context: CGContext, imageRect: CGRect, pixelated: CGImage?, skipping skippedID: UUID? = nil) {
        for shape in shapes where shape.id != skippedID {
            context.saveGState()
            draw(shape, in: context, imageRect: imageRect, pixelated: pixelated)
            context.restoreGState()
        }
    }

    static func draw(_ shape: AnnotationShape, in context: CGContext, imageRect: CGRect, pixelated: CGImage?) {
        let color = shape.color.cgColor
        let width = shape.lineWidth
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)
        let shadow = CGColor(gray: 0, alpha: 0.35)

        switch shape.kind {
        case .arrow(let from, let to):
            context.setShadow(offset: .zero, blur: 3, color: shadow)
            context.addPath(arrowPath(from: from, to: to, width: width))
            context.fillPath()

        case .line(let from, let to):
            context.setShadow(offset: .zero, blur: 3, color: shadow)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case .rectangle(let rect, let filled):
            let rect = rect.standardized
            let path = CGPath(roundedRect: rect, cornerWidth: min(width * 1.5, rect.width / 2), cornerHeight: min(width * 1.5, rect.height / 2), transform: nil)
            context.setShadow(offset: .zero, blur: 3, color: shadow)
            context.addPath(path)
            if filled { context.fillPath() } else { context.strokePath() }

        case .ellipse(let rect, let filled):
            context.setShadow(offset: .zero, blur: 3, color: shadow)
            context.addEllipse(in: rect.standardized)
            if filled { context.fillPath() } else { context.strokePath() }

        case .path(let points, let highlighter):
            guard let first = points.first else { return }
            if highlighter {
                // Translucent rather than multiply, so it also shows on dark screenshots.
                context.setAlpha(0.4)
                context.setLineWidth(width * 4)
                context.setLineCap(.butt)
            } else {
                context.setShadow(offset: .zero, blur: 2, color: shadow)
            }
            context.move(to: first)
            if points.count == 1 { context.addLine(to: first) }
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()

        case .text(let string, let origin, let size):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            attributedText(string, size: size, color: shape.color).draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()

        case .counter(let number, let center):
            let d = shape.counterDiameter
            let circle = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            context.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: shadow)
            context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(max(1.5, d / 14))
            context.strokeEllipse(in: circle.insetBy(dx: d / 28, dy: d / 28))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: d * 0.52, weight: .heavy),
                .foregroundColor: NSColor(cgColor: shape.color.contrasting) ?? .white,
            ])
            let size = label.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()

        case .pixelate(let rect):
            guard let pixelated else { return }
            context.clip(to: rect.standardized)
            // The context is flipped; flip the image back so it isn't drawn upside down.
            context.translateBy(x: 0, y: imageRect.maxY + imageRect.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(pixelated, in: imageRect)
        }
    }

    /// A tapered arrow: a shaft that widens towards a filled head.
    static func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat) -> CGPath {
        let length = from.distance(to: to)
        let path = CGMutablePath()
        guard length > 0 else { return path }
        let headLength = min(length, max(14, width * 4.5))
        let headWidth = max(12, width * 3.6)
        let angle = atan2(to.y - from.y, to.x - from.x)
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: from.x + cos(angle) * along - sin(angle) * across,
                    y: from.y + sin(angle) * along + cos(angle) * across)
        }
        let base = length - headLength
        path.move(to: point(0, -width * 0.25))
        path.addLine(to: point(base, -width * 0.6))
        path.addLine(to: point(base - headLength * 0.15, -headWidth / 2))
        path.addLine(to: point(length, 0))
        path.addLine(to: point(base - headLength * 0.15, headWidth / 2))
        path.addLine(to: point(base, width * 0.6))
        path.addLine(to: point(0, width * 0.25))
        path.closeSubpath()
        return path
    }

    /// Renders the final image (annotations flattened, crop applied) at full resolution.
    public static func export(image: CGImage, imageSize: CGSize, document: AnnotationDocument, pixelated: CGImage?) -> CGImage? {
        let scale = CGFloat(image.width) / max(imageSize.width, 1)
        let visible = document.visibleRect
        let pixelWidth = Int((visible.width * scale).rounded())
        let pixelHeight = Int((visible.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Flip to a top-left origin, scale to pixels and move the crop to the origin.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        let imageRect = CGRect(origin: .zero, size: imageSize)
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: imageRect)
        context.restoreGState()
        draw(document.shapes, in: context, imageRect: imageRect, pixelated: pixelated)
        return context.makeImage()
    }
}

// MARK: - Geometry helpers

nonisolated public extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

nonisolated public extension CGRect {
    /// The rectangle spanned by two corner points.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
