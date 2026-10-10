import AppKit
import KeystivoCore
import KeystivoTools
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// State of one annotation window: the screenshot, its shapes and the current tool.
@Observable
final class AnnotationEditorModel {
    let image: CGImage
    let imageSize: CGSize
    @ObservationIgnored let pixelated: CGImage?
    private(set) var document: AnnotationDocument
    var tool: AnnotationTool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            if tool != .select { selectedID = nil }
            pendingCrop = tool == .crop ? document.crop : nil
            changed()
        }
    }
    var color = AnnotationColor.palette[0] {
        didSet { updateSelected { $0.color = color } }
    }
    var lineWidth: CGFloat = 5 {
        didSet { updateSelected { $0.lineWidth = lineWidth } }
    }
    var filled = false
    var selectedID: UUID? { didSet { changed() } }
    var pendingCrop: CGRect?
    /// Bumped on every visual change so the canvas redraws.
    private(set) var revision = 0

    @ObservationIgnored var onPin: ((NSImage) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onNotify: ((String, String) -> Void)?

    init(image: CGImage, size: CGSize) {
        self.image = image
        imageSize = size
        pixelated = AnnotationRenderer.pixelated(image)
        document = AnnotationDocument(imageSize: size)
    }

    /// What the canvas shows: the full image while cropping, otherwise the crop.
    var visibleRect: CGRect {
        tool == .crop ? CGRect(origin: .zero, size: imageSize) : document.visibleRect
    }

    var textSize: CGFloat { max(14, lineWidth * 3.5 + 8) }
    var selectedShape: AnnotationShape? { document.shapes.first { $0.id == selectedID } }

    func changed() { revision &+= 1 }

    // MARK: Editing

    func add(_ shape: AnnotationShape) {
        document.add(shape)
        changed()
    }

    func replace(_ shape: AnnotationShape) {
        document.replace(shape)
        changed()
    }

    func deleteSelected() {
        guard let selectedID else { return }
        document.remove(id: selectedID)
        self.selectedID = nil
    }

    func undo() {
        document.undo()
        selectedID = nil
        changed()
    }

    func redo() {
        document.redo()
        selectedID = nil
        changed()
    }

    func applyCrop() {
        document.setCrop(pendingCrop)
        pendingCrop = nil
        tool = .select
        changed()
    }

    func resetCrop() {
        document.setCrop(nil)
        pendingCrop = nil
        changed()
    }

    var nextCounter: Int { document.nextCounter }
    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }
    var isCropped: Bool { document.crop != nil }

    private func updateSelected(_ change: (inout AnnotationShape) -> Void) {
        guard var shape = selectedShape else { return }
        change(&shape)
        replace(shape)
    }

    // MARK: Output

    func flattened() -> NSImage? {
        guard let cgImage = AnnotationRenderer.export(image: image, imageSize: imageSize, document: document, pixelated: pixelated) else { return nil }
        return NSImage(cgImage: cgImage, size: document.visibleRect.size)
    }

    private func pngData() -> Data? {
        guard let cgImage = AnnotationRenderer.export(image: image, imageSize: imageSize, document: document, pixelated: pixelated) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = document.visibleRect.size
        return rep.representation(using: .png, properties: [:])
    }

    func copy() {
        guard let image = flattened() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        onNotify?("doc.on.doc", L("annotate.copied"))
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.defaultFileName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url, let data = pngData() else { return }
        do {
            try data.write(to: url, options: .atomic)
            onNotify?("square.and.arrow.down", L("annotate.saved", url.lastPathComponent))
        } catch {
            DiagnosticsCenter.shared.record(error, module: "Tools", context: L("annotate.save"))
        }
    }

    func pin() {
        guard let image = flattened() else { return }
        onPin?(image)
    }

    func share(from view: NSView) {
        guard let data = pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: Self.defaultFileName())
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func done() {
        copy()
        onClose?()
    }

    static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Keystivo \(formatter.string(from: .now)).png"
    }
}

// MARK: - Canvas

/// AppKit canvas: precise mouse handling, inline text editing and Core Graphics drawing.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    let model: AnnotationEditorModel

    private enum Interaction {
        case drawing(AnnotationShape, start: CGPoint)
        case moving(AnnotationShape, start: CGPoint)
        case cropping(start: CGPoint, original: CGRect?, moves: Bool)
    }

    private var interaction: Interaction?
    private var textField: NSTextField?
    private var editingTextID: UUID?
    private var editingTextOrigin: CGPoint = .zero

    init(model: AnnotationEditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var visible: CGRect { model.visibleRect }
    private var scale: CGFloat { bounds.width / max(visible.width, 1) }

    private func toDocument(_ point: CGPoint) -> CGPoint {
        CGPoint(x: visible.minX + point.x / scale, y: visible.minY + point.y / scale)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - visible.minX) * scale, y: (point.y - visible.minY) * scale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let imageRect = CGRect(origin: .zero, size: model.imageSize)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        context.interpolationQuality = .high

        context.saveGState()
        context.translateBy(x: 0, y: model.imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(model.image, in: imageRect)
        context.restoreGState()

        var skipped = editingTextID
        if case .moving(let shape, _) = interaction { skipped = shape.id }
        AnnotationRenderer.draw(model.document.shapes, in: context, imageRect: imageRect, pixelated: model.pixelated, skipping: skipped)
        switch interaction {
        case .drawing(let shape, _), .moving(let shape, _):
            AnnotationRenderer.draw([shape], in: context, imageRect: imageRect, pixelated: model.pixelated)
        default:
            break
        }
        context.restoreGState()

        drawSelection(in: context)
        if model.tool == .crop { drawCropOverlay(in: context) }
    }

    private func drawSelection(in context: CGContext) {
        var shape = model.selectedShape
        if case .moving(let moving, _) = interaction { shape = moving }
        guard let shape, model.tool == .select else { return }
        let origin = toView(shape.bounds.origin)
        let rect = CGRect(origin: origin, size: CGSize(width: shape.bounds.width * scale, height: shape.bounds.height * scale)).insetBy(dx: -4, dy: -4)
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(rect)
        context.restoreGState()
    }

    private func drawCropOverlay(in context: CGContext) {
        guard let crop = model.pendingCrop?.standardized else {
            context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            context.fill(bounds)
            return
        }
        let rect = CGRect(origin: toView(crop.origin), size: CGSize(width: crop.width * scale, height: crop.height * scale))
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addRect(bounds)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect)
        // Rule-of-thirds guides.
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(0.5)
        for fraction in [1.0 / 3, 2.0 / 3] {
            context.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        context.strokePath()
        context.setFillColor(NSColor.white.cgColor)
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            context.fillEllipse(in: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8))
        }
        context.restoreGState()
        let label = "\(Int(crop.width)) × \(Int(crop.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)
        let badge = CGRect(x: rect.minX, y: max(2, rect.minY - size.height - 8), width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        label.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 2), withAttributes: attributes)
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    func refresh() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if model.tool != .text, textField != nil { commitText() }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textField != nil { commitText() }
        let point = toDocument(convert(event.locationInWindow, from: nil))
        let color = model.color
        let width = model.lineWidth

        switch model.tool {
        case .select:
            if let shape = model.document.shape(at: point) {
                model.selectedID = shape.id
                if event.clickCount == 2, case .text(let string, let origin, _) = shape.kind {
                    beginText(at: origin, existing: shape.id, text: string)
                    return
                }
                interaction = .moving(shape, start: point)
            } else {
                model.selectedID = nil
            }
        case .arrow:
            interaction = .drawing(AnnotationShape(kind: .arrow(from: point, to: point), color: color, lineWidth: width), start: point)
        case .line:
            interaction = .drawing(AnnotationShape(kind: .line(from: point, to: point), color: color, lineWidth: width), start: point)
        case .rectangle:
            interaction = .drawing(AnnotationShape(kind: .rectangle(CGRect(origin: point, size: .zero), filled: model.filled), color: color, lineWidth: width), start: point)
        case .ellipse:
            interaction = .drawing(AnnotationShape(kind: .ellipse(CGRect(origin: point, size: .zero), filled: model.filled), color: color, lineWidth: width), start: point)
        case .pixelate:
            interaction = .drawing(AnnotationShape(kind: .pixelate(CGRect(origin: point, size: .zero)), color: color, lineWidth: width), start: point)
        case .pen, .highlighter:
            interaction = .drawing(AnnotationShape(kind: .path([point], highlighter: model.tool == .highlighter), color: color, lineWidth: width), start: point)
        case .text:
            if let shape = model.document.shape(at: point), case .text(let string, let origin, _) = shape.kind {
                beginText(at: origin, existing: shape.id, text: string)
            } else {
                beginText(at: point, existing: nil, text: "")
            }
        case .counter:
            model.add(AnnotationShape(kind: .counter(model.nextCounter, center: point), color: color, lineWidth: width))
        case .crop:
            let moves = model.pendingCrop?.standardized.contains(point) == true
            interaction = .cropping(start: point, original: model.pendingCrop, moves: moves)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = toDocument(convert(event.locationInWindow, from: nil))
        let constrained = event.modifierFlags.contains(.shift)
        switch interaction {
        case .drawing(var shape, let start):
            switch shape.kind {
            case .arrow: shape.kind = .arrow(from: start, to: constrained ? Self.snapAngle(point, from: start) : point)
            case .line: shape.kind = .line(from: start, to: constrained ? Self.snapAngle(point, from: start) : point)
            case .rectangle(_, let filled): shape.kind = .rectangle(Self.rect(start, point, square: constrained), filled: filled)
            case .ellipse(_, let filled): shape.kind = .ellipse(Self.rect(start, point, square: constrained), filled: filled)
            case .pixelate: shape.kind = .pixelate(Self.rect(start, point, square: constrained))
            case .path(var points, let highlighter):
                if let last = points.last, last.distance(to: point) >= 1.5 { points.append(point) }
                // Shift draws straight highlighter strokes.
                if constrained, let first = points.first { points = [first, CGPoint(x: point.x, y: first.y)] }
                shape.kind = .path(points, highlighter: highlighter)
            default:
                break
            }
            interaction = .drawing(shape, start: start)
        case .moving(let shape, let start):
            guard let original = model.document.shapes.first(where: { $0.id == shape.id }) else { return }
            interaction = .moving(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y), start: start)
        case .cropping(let start, let original, let moves):
            let bounds = CGRect(origin: .zero, size: model.imageSize)
            if moves, let original {
                var moved = original.standardized.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
                moved.origin.x = min(max(moved.minX, 0), bounds.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, 0), bounds.maxY - moved.height)
                model.pendingCrop = moved
            } else {
                model.pendingCrop = Self.rect(start, point, square: constrained).intersection(bounds)
            }
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            interaction = nil
            needsDisplay = true
        }
        switch interaction {
        case .drawing(let shape, _):
            model.add(shape)
        case .moving(let shape, _):
            model.replace(shape)
            model.selectedID = shape.id
        case .cropping:
            if let crop = model.pendingCrop, crop.width < 8 || crop.height < 8 { model.pendingCrop = nil }
        case nil:
            break
        }
    }

    static func snapAngle(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let angle = atan2(point.y - start.y, point.x - start.x)
        let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
        let length = start.distance(to: point)
        return CGPoint(x: start.x + cos(snapped) * length, y: start.y + sin(snapped) * length)
    }

    static func rect(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        guard square else { return CGRect(from: a, to: b) }
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGRect(from: a, to: CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side)))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        switch event.keyCode {
        case KeyCodes.delete, 117:
            model.deleteSelected()
        case KeyCodes.escape:
            if model.tool == .crop { model.tool = .select } else if model.selectedID != nil { model.selectedID = nil } else { model.onClose?() }
        case KeyCodes.returnKey, KeyCodes.keypadEnter:
            if model.tool == .crop { model.applyCrop() } else { model.done() }
        case KeyCodes.leftArrow, KeyCodes.rightArrow, KeyCodes.upArrow, KeyCodes.downArrow:
            nudge(event)
        default:
            if flags.isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first {
                if let tool = AnnotationTool.allCases.first(where: { $0.key == character }) {
                    model.tool = tool
                    return
                }
                if let digit = character.wholeNumberValue, (1...AnnotationColor.palette.count).contains(digit) {
                    model.color = AnnotationColor.palette[digit - 1]
                    return
                }
            }
            super.keyDown(with: event)
        }
        needsDisplay = true
    }

    private func nudge(_ event: NSEvent) {
        guard let shape = model.selectedShape else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let (dx, dy): (CGFloat, CGFloat) = switch event.keyCode {
        case KeyCodes.leftArrow: (-step, 0)
        case KeyCodes.rightArrow: (step, 0)
        case KeyCodes.upArrow: (0, -step)
        default: (0, step)
        }
        model.replace(shape.offsetBy(dx: dx, dy: dy))
    }

    // MARK: Text

    private func beginText(at origin: CGPoint, existing: UUID?, text: String) {
        let size = existing.flatMap { id in
            model.document.shapes.first { $0.id == id }.flatMap { shape -> CGFloat? in
                if case .text(_, _, let size) = shape.kind { size } else { nil }
            }
        } ?? model.textSize
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size * scale, weight: .bold)
        field.textColor = NSColor(cgColor: model.color.cgColor)
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = L("annotate.textPlaceholder")
        let viewOrigin = toView(origin)
        field.frame = CGRect(x: viewOrigin.x - 2, y: viewOrigin.y, width: max(160, bounds.width - viewOrigin.x), height: size * scale * 1.35)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        editingTextID = existing
        editingTextOrigin = origin
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.stringValue = editingTextID == nil ? "" : textField?.stringValue ?? ""
            commitText()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        let size = (field.font?.pointSize ?? model.textSize * scale) / scale
        if let id = editingTextID, let shape = model.document.shapes.first(where: { $0.id == id }) {
            var updated = shape
            updated.kind = .text(text, origin: editingTextOrigin, size: size)
            model.replace(updated)
        } else {
            model.add(AnnotationShape(kind: .text(text, origin: editingTextOrigin, size: size), color: model.color, lineWidth: model.lineWidth))
        }
        editingTextID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

private struct AnnotationCanvas: NSViewRepresentable {
    let model: AnnotationEditorModel
    let revision: Int
    let tool: AnnotationTool

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(model: model)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.refresh()
    }
}

// MARK: - Editor view

struct AnnotationEditorView: View {
    @Bindable var model: AnnotationEditorModel
    @State private var shareAnchor: NSView?

    private let tools: [[AnnotationTool]] = [
        [.select, .crop],
        [.arrow, .line, .rectangle, .ellipse, .pen, .highlighter],
        [.text, .counter, .pixelate],
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            ZStack {
                CheckerboardBackground()
                AnnotationCanvas(model: model, revision: model.revision, tool: model.tool)
                    .aspectRatio(model.visibleRect.size, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .padding(18)
            }
            if model.tool == .crop { cropBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.2), value: model.tool == .crop)
        .frame(minWidth: 640, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Array(tools.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider().frame(height: 20).padding(.horizontal, 4) }
                    ForEach(group, id: \.self) { tool in toolButton(tool) }
                }
            }
            Divider().frame(height: 20)
            HStack(spacing: 5) {
                ForEach(Array(AnnotationColor.palette.enumerated()), id: \.offset) { index, color in
                    colorSwatch(color, index: index)
                }
            }
            Menu {
                ForEach([(2.0, "annotate.width.thin"), (5.0, "annotate.width.medium"), (9.0, "annotate.width.thick"), (14.0, "annotate.width.heavy")], id: \.0) { width, key in
                    Button {
                        model.lineWidth = width
                    } label: {
                        if model.lineWidth == width { Label(L(key), systemImage: "checkmark") } else { Text(L(key)) }
                    }
                }
                Divider()
                Toggle(L("annotate.filled"), isOn: $model.filled)
            } label: {
                Image(systemName: "lineweight")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("annotate.width"))
            Spacer(minLength: 8)
            iconButton("arrow.uturn.backward", help: "annotate.undo", disabled: !model.canUndo) { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
            iconButton("arrow.uturn.forward", help: "annotate.redo", disabled: !model.canRedo) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Divider().frame(height: 20)
            iconButton("pin", help: "annotate.pin") { model.pin() }
            iconButton("square.and.arrow.down", help: "annotate.save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
            iconButton("square.and.arrow.up", help: "annotate.share") {
                if let shareAnchor { model.share(from: shareAnchor) }
            }
            .background(AnchorView(view: $shareAnchor))
            iconButton("doc.on.doc", help: "annotate.copy") { model.copy() }
                .keyboardShortcut("c", modifiers: .command)
            Button(L("annotate.done")) { model.done() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var cropBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "crop").foregroundStyle(.secondary)
            Text(L("annotate.cropHint")).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if model.isCropped { Button(L("annotate.resetCrop")) { model.resetCrop() } }
            Button(L("common.cancel")) { model.tool = .select }
                .keyboardShortcut(.cancelAction)
            Button(L("annotate.applyCrop")) { model.applyCrop() }
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingCrop == nil && !model.isCropped)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isOn = model.tool == tool
        return Button {
            model.tool = tool
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isOn ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(L(tool.titleKey)) (\(String(tool.key).uppercased()))")
        .animation(.snappy(duration: 0.15), value: isOn)
    }

    private func colorSwatch(_ color: AnnotationColor, index: Int) -> some View {
        let isOn = model.color == color
        return Button {
            model.color = color
        } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: isOn ? 20 : 16, height: isOn ? 20 : 16)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isOn ? 2 : 0).padding(-3))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("\(index + 1)")
        .animation(.snappy(duration: 0.15), value: isOn)
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(L(help))
    }
}

/// Exposes an AppKit view for anchoring popovers such as the share picker.
private struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .windowBackgroundColor)))
            for row in 0..<Int(size.height / tile) + 1 {
                for column in 0..<Int(size.width / tile) + 1 where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)), with: .color(.primary.opacity(0.035)))
                }
            }
        }
    }
}

// MARK: - Presenter

/// Opens annotation windows (one per image).
final class AnnotationEditorPresenter: NSObject, NSWindowDelegate {
    private unowned let runtime: KeystivoRuntime
    private var windows: [NSWindow] = []

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    var hasOpenWindows: Bool { windows.contains { $0.isVisible } }

    func open(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let model = AnnotationEditorModel(image: cgImage, size: image.size)
        let screen = NSScreen.underMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = CGSize(width: 36, height: 36 + 50 + 28)
        let fit = min(1, (visible.width * 0.85 - chrome.width) / image.size.width, (visible.height * 0.85 - chrome.height) / image.size.height)
        let size = CGSize(width: max(760, image.size.width * fit + chrome.width), height: max(480, image.size.height * fit + chrome.height))

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("annotate.title")
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: AnnotationEditorView(model: model).localizedRoot())
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        model.onClose = { [weak window] in window?.close() }
        model.onPin = { [weak self] image in self?.runtime.screenTools.pin(image) }
        model.onNotify = { [weak self] symbol, text in self?.runtime.hud.show(symbol: symbol, text: text) }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        runtime.applyActivationPolicy()
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
        DispatchQueue.main.async { [weak self] in self?.runtime.applyActivationPolicy() }
    }
}
