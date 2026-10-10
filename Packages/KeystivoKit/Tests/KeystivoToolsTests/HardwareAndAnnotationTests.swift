import CoreGraphics
import Foundation
@testable import KeystivoTools
import Testing

@Suite("DDC/CI")
struct DDCTests {
    @Test func readRequestChecksum() {
        // Verified against real monitors: length, opcode, VCP code, XOR checksum seeded with 0x6E ^ 0x51.
        #expect(DDC.readRequest(0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func writeRequestEncodesBigEndianValue() {
        #expect(DDC.writeRequest(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        let packet = DDC.writeRequest(0x10, value: 0x0102)
        #expect(packet[3] == 0x01 && packet[4] == 0x02)
        #expect(packet.dropLast().reduce(UInt8(0x6E ^ 0x51), ^) == packet.last)
    }

    @Test func parsesRealReplies() throws {
        let msi = try #require(DDC.parseReply([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x55, 0x95], code: 0x10))
        #expect(msi.current == 85 && msi.maximum == 100)
        let redmi = try #require(DDC.parseReply([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4], code: 0x10))
        #expect(redmi.current == 100 && redmi.maximum == 100)
    }

    @Test func rejectsCorruptOrUnsupportedReplies() {
        // Noise read back while the monitor was still busy.
        #expect(DDC.parseReply([0x5B, 0x8B, 0x40, 0xB7, 0xA6, 0x9C, 0x63, 0x85, 0x19, 0x56, 0xA5], code: 0x10) == nil)
        #expect(DDC.parseReply([UInt8](repeating: 0, count: 11), code: 0x10) == nil)
        #expect(DDC.parseReply([0x6E, 0x88, 0x02], code: 0x10) == nil)
        // Wrong VCP code.
        #expect(DDC.parseReply([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x55, 0x95], code: 0x12) == nil)
        // "Unsupported VCP code" result.
        var unsupported: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x10, 0x00, 0x00, 0x64, 0x00, 0x55]
        unsupported.append(unsupported.reduce(0x50, ^))
        #expect(DDC.parseReply(unsupported, code: 0x10) == nil)
    }
}

@Suite("EDID matching")
struct EDIDTests {
    static func edid(vendor: UInt16, product: UInt16, serial: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        bytes += [UInt8(vendor >> 8), UInt8(vendor & 0xFF), UInt8(product & 0xFF), UInt8(product >> 8)]
        bytes += [UInt8(serial & 0xFF), UInt8((serial >> 8) & 0xFF), UInt8((serial >> 16) & 0xFF), UInt8(serial >> 24)]
        return bytes + [UInt8](repeating: 0, count: 112)
    }

    @Test func parsesIdentity() throws {
        let identity = try #require(EDIDIdentity(edid: Self.edid(vendor: 7252, product: 10052, serial: 1)))
        #expect(identity == EDIDIdentity(vendor: 7252, product: 10052, serial: 1))
        #expect(EDIDIdentity(edid: [0, 1, 2]) == nil)
        #expect(EDIDIdentity(edid: [UInt8](repeating: 0, count: 128)) == nil)
    }

    @Test func matchesByVendorAndProduct() {
        let displays: [(id: CGDirectDisplayID, identity: EDIDIdentity)] = [
            (2, EDIDIdentity(vendor: 7252, product: 10052, serial: 1)),
            (3, EDIDIdentity(vendor: 25001, product: 49156, serial: 1)),
        ]
        let services: [EDIDIdentity?] = [
            EDIDIdentity(vendor: 25001, product: 49156, serial: 1),
            EDIDIdentity(vendor: 7252, product: 10052, serial: 1),
        ]
        #expect(EDIDIdentity.match(services: services, displays: displays) == [0: 3, 1: 2])
    }

    @Test func identicalMonitorsNeedSerials() {
        let a = EDIDIdentity(vendor: 1, product: 2, serial: 100)
        let b = EDIDIdentity(vendor: 1, product: 2, serial: 200)
        #expect(EDIDIdentity.match(services: [b, a], displays: [(10, a), (11, b)]) == [0: 11, 1: 10])
        // Same model without serials is ambiguous: never guess between them.
        let anonymous = EDIDIdentity(vendor: 1, product: 2, serial: 0)
        #expect(EDIDIdentity.match(services: [anonymous, anonymous], displays: [(10, anonymous), (11, anonymous)]).isEmpty)
    }

    @Test func singleLeftoverIsPaired() {
        let display = EDIDIdentity(vendor: 9, product: 9, serial: 0)
        #expect(EDIDIdentity.match(services: [nil], displays: [(5, display)]) == [0: 5])
    }
}

@Suite("Brightness")
struct BrightnessMappingTests {
    @Test func softwareGammaRoundTrips() {
        for value in stride(from: 0.0, through: 1.0, by: 0.125) {
            let gamma = BrightnessController.gamma(fromBrightness: value)
            #expect(gamma >= BrightnessController.softwareFloor && gamma <= 1)
            #expect(abs(BrightnessController.brightness(fromGamma: gamma) - value) < 0.0001)
        }
        #expect(BrightnessController.gamma(fromBrightness: 2) == 1)
    }
}

@Suite("Annotation document")
struct AnnotationDocumentTests {
    let red = AnnotationColor.palette[0]

    func rectangle(_ rect: CGRect) -> AnnotationShape {
        AnnotationShape(kind: .rectangle(rect, filled: false), color: red, lineWidth: 4)
    }

    @Test func undoRedo() {
        var document = AnnotationDocument(imageSize: CGSize(width: 400, height: 300))
        document.add(rectangle(CGRect(x: 10, y: 10, width: 50, height: 50)))
        document.add(AnnotationShape(kind: .arrow(from: .zero, to: CGPoint(x: 100, y: 100)), color: red, lineWidth: 4))
        #expect(document.shapes.count == 2)
        document.undo()
        #expect(document.shapes.count == 1 && document.canRedo)
        document.redo()
        #expect(document.shapes.count == 2 && !document.canRedo)
        document.undo()
        document.add(rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)))
        #expect(!document.canRedo, "a new edit clears the redo stack")
    }

    @Test func ignoresAccidentalClicks() {
        var document = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        document.add(rectangle(CGRect(x: 10, y: 10, width: 1, height: 1)))
        document.add(AnnotationShape(kind: .text("   ", origin: .zero, size: 20), color: red, lineWidth: 4))
        #expect(document.shapes.isEmpty && !document.canUndo)
    }

    @Test func countersIncrement() {
        var document = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        #expect(document.nextCounter == 1)
        document.add(AnnotationShape(kind: .counter(1, center: CGPoint(x: 10, y: 10)), color: red, lineWidth: 4))
        document.add(AnnotationShape(kind: .counter(2, center: CGPoint(x: 30, y: 10)), color: red, lineWidth: 4))
        #expect(document.nextCounter == 3)
    }

    @Test func cropIsClampedAndUndoable() {
        var document = AnnotationDocument(imageSize: CGSize(width: 200, height: 100))
        document.setCrop(CGRect(x: 150, y: -20, width: 100, height: 60))
        #expect(document.crop == CGRect(x: 150, y: 0, width: 50, height: 40))
        #expect(document.visibleRect == document.crop)
        document.setCrop(CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(document.crop == nil, "cropping to the full image clears the crop")
        document.undo()
        #expect(document.crop == CGRect(x: 150, y: 0, width: 50, height: 40))
    }

    @Test func hitTesting() {
        let outline = rectangle(CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(outline.hitTest(CGPoint(x: 10, y: 50)))
        #expect(!outline.hitTest(CGPoint(x: 60, y: 60)), "outlined shapes are hit on their stroke")
        let filled = AnnotationShape(kind: .ellipse(CGRect(x: 0, y: 0, width: 100, height: 50), filled: true), color: red, lineWidth: 4)
        #expect(filled.hitTest(CGPoint(x: 50, y: 25)))
        #expect(!filled.hitTest(CGPoint(x: 2, y: 2)))
        let line = AnnotationShape(kind: .line(from: .zero, to: CGPoint(x: 100, y: 0)), color: red, lineWidth: 4)
        #expect(line.hitTest(CGPoint(x: 50, y: 3)))
        #expect(!line.hitTest(CGPoint(x: 50, y: 20)))
    }

    @Test func topmostShapeWins() {
        var document = AnnotationDocument(imageSize: CGSize(width: 200, height: 200))
        let first = AnnotationShape(kind: .pixelate(CGRect(x: 0, y: 0, width: 100, height: 100)), color: red, lineWidth: 4)
        let second = AnnotationShape(kind: .pixelate(CGRect(x: 50, y: 50, width: 100, height: 100)), color: red, lineWidth: 4)
        document.add(first)
        document.add(second)
        #expect(document.shape(at: CGPoint(x: 75, y: 75))?.id == second.id)
        #expect(document.shape(at: CGPoint(x: 10, y: 10))?.id == first.id)
    }

    @Test func movingKeepsGeometry() {
        let path = AnnotationShape(kind: .path([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5)], highlighter: false), color: red, lineWidth: 2)
        let moved = path.offsetBy(dx: 5, dy: -5)
        #expect(moved.kind == .path([CGPoint(x: 5, y: -5), CGPoint(x: 15, y: 0)], highlighter: false))
        #expect(moved.id == path.id)
    }
}

@Suite("Annotation rendering")
struct AnnotationRenderingTests {
    static func solidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test @MainActor func exportAppliesCropAtPixelScale() throws {
        // A 2× "Retina" capture: 200×100 points stored as 400×200 pixels.
        let image = Self.solidImage(width: 400, height: 200)
        var document = AnnotationDocument(imageSize: CGSize(width: 200, height: 100))
        document.add(AnnotationShape(kind: .rectangle(CGRect(x: 20, y: 20, width: 60, height: 40), filled: true), color: AnnotationColor.palette[4], lineWidth: 4))
        document.setCrop(CGRect(x: 10, y: 10, width: 100, height: 50))
        let output = try #require(AnnotationRenderer.export(image: image, imageSize: document.imageSize, document: document, pixelated: nil))
        #expect(output.width == 200 && output.height == 100)
    }

    @Test @MainActor func pixelatedCopyKeepsSize() throws {
        let image = Self.solidImage(width: 320, height: 180)
        let pixelated = try #require(AnnotationRenderer.pixelated(image))
        #expect(pixelated.width == 320 && pixelated.height == 180)
    }

    @Test @MainActor func arrowHasAHead() {
        let path = AnnotationRenderer.arrowPath(from: .zero, to: CGPoint(x: 100, y: 0), width: 4)
        #expect(path.boundingBox.maxX >= 99.9)
        #expect(path.boundingBox.height > 8, "the head is wider than the shaft")
        #expect(AnnotationRenderer.arrowPath(from: .zero, to: .zero, width: 4).isEmpty)
    }

    @Test func recordingFileName() {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 10
        components.hour = 9
        components.minute = 5
        components.second = 7
        let date = Calendar.current.date(from: components)!
        #expect(ScreenRecorder.fileName(date: date) == "Keystivo Recording 2026-10-10 at 09.05.07.mov")
    }
}

@Suite("Process sampler")
struct ProcessSamplerTests {
    @Test func measuresOwnProcess() throws {
        let sampler = ProcessSampler()
        let me = getpid()
        _ = sampler.sample(apps: [:])
        // Burn a little CPU so the second sample has something to measure.
        var x = 0.0
        for i in 0..<3_000_000 { x += sqrt(Double(i)) }
        #expect(x > 0)
        let usage = sampler.sample(apps: [:])
        let mine = try #require(usage.first { $0.id == me })
        #expect(mine.cpu > 0)
        #expect(mine.memory > 1_000_000)
        #expect(!mine.name.isEmpty)
    }

    @Test func helpersAreGroupedUnderTheirApp() {
        let me = getpid()
        let usage = ProcessSampler().sample(apps: [me: (name: "Test Host", bundleID: "com.example.test")])
        #expect(usage.contains { $0.id == me && $0.name == "Test Host" && $0.isApp })
    }
}

@Suite("Network usage")
struct NetworkUsageTests {
    @Test func parsesNettopCSV() {
        let output = """
        ,bytes_in,bytes_out,
        mDNSResponder.475,7181124,2026865,
        com.apple.WebKi.1816,468,1592,
        Aspire.Dashboar.1321,443981378,2726786,
        garbage line
        """
        let parsed = NetworkUsageSampler.parse(output)
        #expect(parsed.count == 3)
        #expect(parsed[1816]?.name == "com.apple.WebKi" && parsed[1816]?.down == 468 && parsed[1816]?.up == 1592)
        #expect(parsed[1321]?.name == "Aspire.Dashboar", "names may contain dots")
    }

    @Test func snapshotIsAvailableWithoutPrivileges() throws {
        let output = try #require(NetworkUsageSampler.snapshot())
        #expect(!NetworkUsageSampler.parse(output).isEmpty)
    }
}
