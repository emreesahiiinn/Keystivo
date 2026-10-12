import AppKit
@testable import KeystivoScreenSaver
import SwiftUI
import Testing

@Suite("Screen savers")
struct ScreenSaverTests {
    @Test func everyStyleHasAUniqueBundleName() {
        let names = SaverStyle.allCases.map(\.bundleName)
        #expect(Set(names).count == names.count)
        #expect(!SaverStyle.rotating.contains(.shuffle))
    }

    @Test func seeThroughShuffleOnlyPicksClocks() {
        for slot in 0..<SaverStyle.rotating.count * 2 {
            let date = Date(timeIntervalSinceReferenceDate: Double(slot) * 180 + 1)
            #expect(SaverRootView.resolved(.shuffle, at: date, clocksOnly: true).supportsBackdrop)
        }
        #expect(!SaverStyle.aurora.supportsBackdrop)
        #expect(SaverStyle.glass.supportsBackdrop)
    }

    @Test func artworkIgnoresSeeThroughBackdrop() {
        #expect(SaverRootView(style: .aurora, backdrop: .clear).backdrop == .design)
        #expect(SaverRootView(style: .flip, backdrop: .frosted).backdrop == .frosted)
    }

    @Test func driftStaysSmall() {
        for offset in stride(from: 0.0, through: 600, by: 37) {
            let drift = SaverClock.drift(Date(timeIntervalSinceReferenceDate: offset), amplitude: 20)
            #expect(abs(drift.width) <= 20 && abs(drift.height) <= 12)
        }
    }

    @Test func seededRandomIsDeterministic() {
        var a = SeededRandom(seed: 3)
        var b = SeededRandom(seed: 3)
        let first = (0..<5).map { _ in a.next() }
        #expect(first == (0..<5).map { _ in b.next() })
        #expect(first.allSatisfy { (0..<1).contains($0) })
    }

    @Test func hourMinuteIsPadded() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 5))!
        let time = SaverClock.hourMinute(date)
        #expect(time.minute == "05")
        #expect(SaverClock.uses12Hour ? time.hour == "9" : time.hour == "09")
    }

    @Test(arguments: SaverStyle.allCases)
    @MainActor func everyStyleRenders(style: SaverStyle) throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 10, minute: 9, second: 30))!
        let renderer = ImageRenderer(content: SaverRootView(style: style, fixedDate: date).frame(width: 480, height: 300))
        let image = try #require(renderer.cgImage)
        #expect(image.width == 480 && image.height == 300)
    }
}
