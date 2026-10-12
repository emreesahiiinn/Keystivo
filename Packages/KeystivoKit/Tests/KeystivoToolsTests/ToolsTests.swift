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

@Suite("Menu bar rates")
struct CompactRateTests {
    @Test func neverMoreThanThreeDigits() {
        #expect(SystemMonitor.compactRate(510) == "510 B")
        #expect(SystemMonitor.compactRate(1021) == "1.0 K")
        #expect(SystemMonitor.compactRate(12_800) == "12 K")
        #expect(SystemMonitor.compactRate(1_023_000) == "999 K")
        #expect(SystemMonitor.compactRate(1_048_000) == "1.0 M")
        #expect(SystemMonitor.compactRate(4_200_000) == "4.0 M")
        #expect(SystemMonitor.compactRate(-5) == "0 B")
        for value in stride(from: 0.0, through: 5e9, by: 7_777_777.0) {
            let digits = SystemMonitor.compactRate(value).filter(\.isNumber).count
            #expect(digits <= 3, "\(value)")
        }
    }
}

@Suite("Hardware sensors")
struct HardwareSensorTests {
    @Test func decodesSMCTypes() {
        let flt = HardwareSensors.decode([0x00, 0x00, 0xC8, 0x42], type: 0x666C7420) // "flt " 100.0
        #expect(flt == 100)
        #expect(HardwareSensors.decode([0x1F, 0x40], type: 0x66706532) == 2000) // "fpe2"
        #expect(HardwareSensors.decode([0x2D, 0x80], type: 0x73703738) == 45.5) // "sp78"
        #expect(HardwareSensors.decode([7], type: 0x75693820) == 7) // "ui8 "
    }

    @Test func cpuTemperaturePicksTheHottestCPUSensor() {
        let sensors = [SensorReading(name: "PMU tdie1", value: 48), SensorReading(name: "PMU tdie3", value: 55),
                       SensorReading(name: "NAND CH0 temp", value: 60), SensorReading(name: "gas gauge battery", value: 31)]
        #expect(HardwareSensors.cpuTemperature(from: sensors) == 55)
    }

    @Test func readsThisMacWithoutCrashing() {
        let sensors = HardwareSensors.shared.temperatures()
        let gpu = HardwareSensors.shared.gpuUsage()
        let fans = HardwareSensors.shared.fans()
        let power = HardwareSensors.shared.systemPower()
        print("SENSORS", sensors.count, sensors.prefix(6).map { "\($0.name)=\(Int($0.value))" }, "CPU", HardwareSensors.cpuTemperature(from: sensors) ?? -1,
              "GPU", gpu ?? -1, "FANS", fans.map { Int($0.rpm) }, "POWER", power ?? -1)
    }
}
