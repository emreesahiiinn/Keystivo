@testable import KeystivoTools
import Testing

@Suite("Screen tools")
struct ToolsTests {
    @Test func colorFormats() {
        #expect(ColorFormat.hex.format(red: 1, green: 0.5, blue: 0) == "#FF8000")
        #expect(ColorFormat.rgb.format(red: 0, green: 0, blue: 1) == "rgb(0, 0, 255)")
        #expect(ColorFormat.rgb.format(red: 0, green: 0, blue: 1, alpha: 0.5) == "rgba(0, 0, 255, 0.50)")
        #expect(ColorFormat.hsl.format(red: 1, green: 0, blue: 0) == "hsl(0, 100%, 50%)")
        #expect(ColorFormat.hsl.format(red: 0.5, green: 0.5, blue: 0.5) == "hsl(0, 0%, 50%)")
        #expect(ColorFormat.swiftUI.format(red: 0.2, green: 0.4, blue: 0.6).hasPrefix("Color(red: 0.200"))
    }

    @Test func ocrLinesJoinHyphenation() {
        #expect(ScreenCapture.joinLines(["Hello wor-", "ld and", "Next"]) == "Hello world and\nNext")
        #expect(ScreenCapture.joinLines(["Well-", "Known"]) == "Well-\nKnown")
    }

    @Test func memoryAndCPUProbesReturnValues() {
        #expect(SystemMonitor.memoryUsed() > 0)
        #expect(!SystemMonitor.cpuTicks().isEmpty)
        #expect(SystemMonitor.rate(2048).contains("/s"))
    }
}
