import Foundation
@testable import KeystivoSystem
import Testing

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test func largeOutputDoesNotDeadlock() async throws {
        // 200 KB is well past the 64 KB pipe buffer.
        let output = try await SystemCommandRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\\\0' 'x'"], timeout: .seconds(10))
        #expect(output.count == 200_000)
    }

    @Test func passesInputAndReturnsOutput() async throws {
        let output = try await SystemCommandRunner.run("/usr/bin/tr", ["a-z", "A-Z"], input: "keystivo", timeout: .seconds(10))
        #expect(output == "KEYSTIVO")
    }

    @Test func stopsAtTheTimeout() async throws {
        let start = Date.now
        await #expect(throws: (any Error).self) {
            try await SystemCommandRunner.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        }
        #expect(Date.now.timeIntervalSince(start) < 5)
    }

    @Test func reportsFailuresWithOutput() async throws {
        await #expect(throws: (any Error).self) {
            try await SystemCommandRunner.run("/bin/sh", ["-c", "echo broken >&2; exit 3"], timeout: .seconds(10))
        }
    }

    @Test func runsAppleScriptOffTheMainThread() async throws {
        let output = try await SystemCommandRunner.appleScript("return 6 * 7")
        #expect(output == "42")
    }
}

@Suite("Meeting links")
struct MeetingLinkTests {
    @Test func findsVideoCallLinks() {
        #expect(MeetingLinks.find(in: ["Join: https://us02web.zoom.us/j/123456?pwd=abc"])?.host() == "us02web.zoom.us")
        #expect(MeetingLinks.find(in: ["Room 4", "Agenda… https://meet.google.com/abc-defg-hij"])?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(MeetingLinks.find(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting"]) != nil)
        #expect(MeetingLinks.find(in: ["See https://example.com/docs and https://github.com"]) == nil)
        #expect(MeetingLinks.find(in: []) == nil)
    }
}

@Suite("Battery details")
struct BatteryDetailsTests {
    @Test func parsesAppleSiliconRegistry() throws {
        let details = BatteryDetails([
            "AppleRawMaxCapacity": 4_400, "MaxCapacity": 100, "DesignCapacity": 5_000, "CycleCount": 212,
            "Temperature": 3_050, "Voltage": 12_500, "Amperage": -1_200,
            "AdapterDetails": ["Watts": 70, "Name": "70W USB-C Power Adapter"], "ManufactureDate": (44 << 9) | (3 << 5) | 15,
        ])
        #expect(details.health == 88)
        #expect(details.cycleCount == 212)
        #expect(abs((details.temperature ?? 0) - 30.5) < 0.01)
        #expect(abs((details.power ?? 0) + 15) < 0.01)
        #expect(details.adapterWatts == 70)
        let date = try #require(details.manufactureDate)
        #expect(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date) == DateComponents(year: 2024, month: 3, day: 15))
    }

    @Test func handlesMissingValues() {
        let details = BatteryDetails(["MaxCapacity": 100])
        #expect(details.maxCapacity == nil && details.health == nil && details.power == nil)
    }
}
