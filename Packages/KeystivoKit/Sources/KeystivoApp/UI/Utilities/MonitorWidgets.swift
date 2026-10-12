import AppKit
import KeystivoCore
import KeystivoTools
import SwiftUI

/// What one metric currently reads, in the forms the widget styles need.
struct MonitorReading {
    var symbol: String
    var caption: String
    /// 0…1 for charts and gauges (nil: no reading yet).
    var fraction: Double?
    var value: String
    /// Two stacked values for the two-line style.
    var lines: (top: String, bottom: String)
    var history: [Double]
    var perCore: [Double] = []
    /// Fractions where the utilization color turns orange, then red.
    var thresholds: (warning: Double, critical: Double) = (0.6, 0.8)
    /// Widest value it can show, so the widget keeps a steady width.
    var widestValue: String = "100%"
    var widestLines: [String] = ["100%"]

    static func make(_ metric: MonitorMetric, snapshot: SystemSnapshot, monitor: SystemMonitor, diskValue: DiskValueMode) -> MonitorReading {
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        let bytes = { (value: Int64) in ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
        let memory = { (value: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) }
        switch metric {
        case .cpu:
            return MonitorReading(symbol: "cpu", caption: L("monitor.short.cpu"), fraction: snapshot.cpuUsage, value: percent(snapshot.cpuUsage),
                                  lines: (percent(snapshot.cpuUsage), ""), history: monitor.cpuHistory, perCore: snapshot.perCoreUsage)
        case .memory:
            return MonitorReading(symbol: "memorychip", caption: L("monitor.short.memory"), fraction: snapshot.memoryPressure, value: percent(snapshot.memoryPressure),
                                  lines: (memory(snapshot.memoryUsed), memory(snapshot.memoryTotal)), history: monitor.memoryHistory,
                                  thresholds: (0.75, 0.9), widestLines: ["999,99 GB"])
        case .disk:
            let used = max(snapshot.diskTotal - snapshot.diskFree, 0)
            let value: String = switch diskValue {
            case .freeSpace: bytes(snapshot.diskFree)
            case .usedSpace: bytes(used)
            case .usedPercent: percent(snapshot.diskUsedFraction)
            case .freePercent: percent(1 - snapshot.diskUsedFraction)
            }
            let isPercent = diskValue == .usedPercent || diskValue == .freePercent
            return MonitorReading(symbol: "internaldrive", caption: L("monitor.short.disk"), fraction: snapshot.diskTotal > 0 ? snapshot.diskUsedFraction : nil,
                                  value: value, lines: (bytes(used), bytes(snapshot.diskTotal)), history: [],
                                  thresholds: (0.8, 0.92), widestValue: isPercent ? "100%" : "999,99 GB", widestLines: ["999,99 GB"])
        case .gpu:
            return MonitorReading(symbol: "square.stack.3d.up", caption: L("monitor.short.gpu"), fraction: snapshot.gpuUsage,
                                  value: snapshot.gpuUsage.map(percent) ?? "—", lines: (snapshot.gpuUsage.map(percent) ?? "—", ""), history: monitor.gpuHistory)
        case .network:
            let peak = max((monitor.networkHistory + monitor.uploadHistory).max() ?? 0, 1)
            return MonitorReading(symbol: "network", caption: L("monitor.short.network"), fraction: snapshot.networkDown / peak,
                                  value: "↓ " + SystemMonitor.compactRate(snapshot.networkDown),
                                  lines: ("↑ " + SystemMonitor.compactRate(snapshot.networkUp), "↓ " + SystemMonitor.compactRate(snapshot.networkDown)),
                                  history: monitor.networkHistory.map { $0 / peak }, widestValue: "↓ 999 M", widestLines: ["↓ 999 B", "↓ 999 K", "↓ 9.9 M", "↓ 999 M"])
        case .sensors:
            let temperature = snapshot.cpuTemperature
            let degrees = temperature.map { "\(Int($0.rounded()))°" } ?? "—"
            let second = snapshot.fans.first.map { "\(Int($0.rpm)) rpm" } ?? snapshot.systemPower.map { String(format: "%.0f W", $0) } ?? ""
            return MonitorReading(symbol: "thermometer.medium", caption: L("monitor.short.sensors"), fraction: temperature.map { min($0 / 100, 1) },
                                  value: degrees, lines: (degrees, second), history: monitor.temperatureHistory.map { min($0 / 100, 1) },
                                  thresholds: (0.7, 0.85), widestValue: "100°", widestLines: ["9999 rpm"])
        }
    }
}

/// One metric in the menu bar, in the chosen style (compact, mini, charts, gauge…).
struct MonitorWidget: View {
    let reading: MonitorReading
    let settings: MonitorWidgetSettings

    var body: some View {
        switch settings.style {
        case .compact:
            HStack(spacing: 3) {
                if settings.showsIcon { Image(systemName: reading.symbol).font(.system(size: 10)) }
                fixedText(reading.value, size: 11, widest: reading.widestValue)
                    .foregroundStyle(tint)
            }
        case .mini:
            VStack(spacing: -1) {
                if settings.showsLabel { caption }
                fixedText(reading.value, size: settings.showsLabel ? 10 : 12, widest: reading.widestValue, alignment: .center)
                    .foregroundStyle(tint)
            }
        case .text:
            fixedText(reading.value, size: 11.5, widest: reading.widestValue).foregroundStyle(tint)
        case .twoLine:
            VStack(alignment: .trailing, spacing: -1) {
                Text(reading.lines.top).lineLimit(1)
                Text(reading.lines.bottom).lineLimit(1)
            }
            .font(.system(size: 8.5, weight: .medium).monospacedDigit())
            .foregroundStyle(tint)
            .frame(width: Self.width(of: reading.widestLines, size: 8.5), alignment: .trailing)
        case .lineChart:
            HStack(spacing: 3) {
                if settings.showsLabel { stackedCaption }
                MiniLineChart(values: reading.history, color: chartColor)
                    .frame(width: 32, height: 15)
                    .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.75))
            }
        case .barChart:
            HStack(spacing: 3) {
                if settings.showsLabel { stackedCaption }
                if reading.perCore.count > 1 {
                    CoreBarChart(values: reading.perCore, color: barColor)
                } else {
                    LevelBar(value: reading.fraction ?? 0, color: chartColor)
                }
            }
        case .pie:
            HStack(spacing: 3) {
                PieGauge(value: reading.fraction ?? 0, color: chartColor).frame(width: 15, height: 15)
                if settings.showsLabel { fixedText(reading.value, size: 10, widest: reading.widestValue).foregroundStyle(tint) }
            }
        case .gauge:
            VStack(spacing: 0) {
                NeedleGauge(value: reading.fraction ?? 0, color: chartColor).frame(width: 24, height: 12)
                Text(settings.showsLabel ? reading.value : reading.caption)
                    .font(.system(size: 7, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
            }
            .frame(minWidth: 26)
        }
    }

    // MARK: Pieces

    private var caption: some View {
        Text(reading.caption)
            .font(.system(size: 7, weight: .semibold))
            .opacity(0.75)
            .lineLimit(1)
    }

    /// "CPU" written as a tiny column next to charts, like a label on a gauge.
    private var stackedCaption: some View {
        VStack(spacing: -2) {
            ForEach(Array(reading.caption.prefix(4).uppercased().enumerated()), id: \.offset) { _, letter in
                Text(String(letter)).font(.system(size: 6, weight: .bold))
            }
        }
        .opacity(0.75)
        .frame(width: 6)
    }

    private func fixedText(_ text: String, size: CGFloat, widest: String, alignment: Alignment = .trailing) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .frame(minWidth: Self.width(of: [widest], size: size), alignment: alignment)
    }

    static func width(of samples: [String], size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        return ceil(samples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 20) + 1
    }

    // MARK: Colors

    /// Text color: the menu bar's own unless a color mode says otherwise.
    private var tint: Color {
        settings.color == .monochrome ? .primary : color(for: reading.fraction)
    }

    /// Charts are always colored; monochrome charts use the text color.
    private var chartColor: Color { color(for: reading.fraction) }

    private func barColor(_ value: Double) -> Color { color(for: value) }

    private func color(for value: Double?) -> Color {
        switch settings.color {
        case .monochrome: return Color.primary
        case .utilization:
            guard let value else { return Color.primary }
            return value >= reading.thresholds.critical ? Color.red : value >= reading.thresholds.warning ? Color.orange : Color.green
        case .accent: return Color.accentColor
        case .blue: return Color.blue
        case .green: return Color.green
        case .orange: return Color.orange
        case .red: return Color.red
        case .purple: return Color.purple
        case .pink: return Color.pink
        case .teal: return Color.teal
        }
    }
}

// MARK: - Chart shapes

private struct MiniLineChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let points = values.suffix(30)
            guard points.count > 1 else { return }
            let step = size.width / CGFloat(points.count - 1)
            var line = Path()
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(min(max(value, 0), 1)) * (size.height - 2))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.3)))
            context.stroke(line, with: .color(color), lineWidth: 1)
        }
        .padding(1)
    }
}

/// One thin bar per core (pairs averaged on Macs with many cores).
private struct CoreBarChart: View {
    let values: [Double]
    let color: (Double) -> Color

    var body: some View {
        let bars = Self.reduce(values, to: 12)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 0.5).fill(Color.primary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 0.5).fill(color(value))
                        .frame(height: max(1, 15 * CGFloat(min(max(value, 0), 1))))
                }
                .frame(width: 2.5, height: 15)
            }
        }
    }

    static func reduce(_ values: [Double], to count: Int) -> [Double] {
        guard values.count > count else { return values }
        let group = Int((Double(values.count) / Double(count)).rounded(.up))
        return stride(from: 0, to: values.count, by: group).map { start in
            let slice = values[start..<min(start + group, values.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

private struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.primary.opacity(0.4), lineWidth: 0.75)
            RoundedRectangle(cornerRadius: 1).fill(color)
                .frame(height: max(1, 13 * CGFloat(min(max(value, 0), 1))))
                .padding(1)
        }
        .frame(width: 7, height: 15)
    }
}

private struct PieGauge: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
    }
}

/// Half-circle dial with a needle (tachometer).
private struct NeedleGauge: View {
    let value: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            let fraction = CGFloat(min(max(value, 0), 1))
            let center = CGPoint(x: size.width / 2, y: size.height)
            let radius = min(size.width / 2, size.height) - 1.5
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .color(.primary.opacity(0.2)), style: StrokeStyle(lineWidth: 2.5))
            var filled = Path()
            filled.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * Double(fraction)), clockwise: false)
            context.stroke(filled, with: .color(color), style: StrokeStyle(lineWidth: 2.5))
            let angle = Double.pi * (1 + Double(fraction))
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * (radius - 2), y: center.y + CGFloat(sin(angle)) * (radius - 2)))
            context.stroke(needle, with: .color(.primary), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }
}
