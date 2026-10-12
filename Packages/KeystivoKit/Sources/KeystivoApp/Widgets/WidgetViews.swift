import AppKit
import KeystivoClipboard
import KeystivoCore
import KeystivoSystem
import KeystivoTools
import SwiftUI

/// One widget's content, laid out for its size. The surface around it (desktop
/// glass or a menu bar panel card) is drawn by the host.
struct WidgetView: View {
    let runtime: KeystivoRuntime
    let instance: WidgetInstance

    var body: some View {
        Group {
            switch instance.kind {
            case .clock: ClockWidget(instance: instance)
            case .worldClock: WorldClockWidget(instance: instance)
            case .calendar: CalendarWidget(instance: instance)
            case .timer: TimerWidget(runtime: runtime, instance: instance)
            case .system: SystemWidget(instance: instance)
            case .battery: BatteryWidget(instance: instance)
            case .weather: WeatherWidget(instance: instance)
            case .notes: NotesWidget(instance: instance)
            case .shortcuts: ShortcutsWidget(instance: instance)
            case .clipboard: ClipboardWidget(runtime: runtime, instance: instance)
            case .countdown: CountdownWidget(instance: instance)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Formatting in the interface language.
enum WidgetFormat {
    static var locale: Locale { Localizer.shared.locale }

    static func time(_ date: Date, seconds: Bool = false, zone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone)
        if seconds { style = Date.FormatStyle(locale: locale, timeZone: zone).hour().minute().second() }
        return date.formatted(style)
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.wide))
    }

    static func dayMonth(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).day().month(.wide))
    }

    static func temperature(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}

/// Small caption at the top of a widget.
private struct WidgetCaption: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

// MARK: - Clock

private struct ClockWidget: View {
    let instance: WidgetInstance

    var body: some View {
        TimelineView(.periodic(from: .now, by: instance.showsSeconds ? 1 : 10)) { context in
            let date = context.date
            switch instance.size {
            case .small:
                digital(date, timeSize: 40)
            case .medium:
                HStack(spacing: 16) {
                    digital(date, timeSize: 48)
                    AnalogDial(date: date, showsSeconds: instance.showsSeconds).frame(width: 124, height: 124)
                }
            case .large:
                VStack(spacing: 14) {
                    AnalogDial(date: date, showsSeconds: instance.showsSeconds).frame(width: 220, height: 220)
                    Text(WidgetFormat.time(date, seconds: instance.showsSeconds))
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text("\(WidgetFormat.weekday(date)), \(WidgetFormat.dayMonth(date))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func digital(_ date: Date, timeSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(WidgetFormat.weekday(date).uppercased(with: WidgetFormat.locale))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 0)
            Text(WidgetFormat.time(date, seconds: instance.showsSeconds))
                .font(.system(size: timeSize, weight: .light, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(WidgetFormat.dayMonth(date)).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A quiet analog face: hour ticks, rounded hands, accent second hand.
struct AnalogDial: View {
    let date: Date
    var showsSeconds = false

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(.primary.opacity(0.07)))
            for hour in 0..<12 {
                let angle = Double(hour) / 12 * 2 * .pi
                let outer = point(center, angle, radius * 0.9)
                let inner = point(center, angle, radius * (hour % 3 == 0 ? 0.74 : 0.8))
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: outer)
                context.stroke(tick, with: .color(.primary.opacity(hour % 3 == 0 ? 0.75 : 0.35)), style: StrokeStyle(lineWidth: hour % 3 == 0 ? 2.2 : 1.2, lineCap: .round))
            }
            let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
            let seconds = Double(components.second ?? 0)
            let minutes = Double(components.minute ?? 0) + seconds / 60
            let hours = Double((components.hour ?? 0) % 12) + minutes / 60
            hand(&context, center, hours / 12, radius * 0.5, width: radius * 0.07, color: .primary)
            hand(&context, center, minutes / 60, radius * 0.75, width: radius * 0.05, color: .primary)
            if showsSeconds {
                hand(&context, center, seconds / 60, radius * 0.82, width: max(1, radius * 0.018), color: .orange)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius * 0.05, y: center.y - radius * 0.05, width: radius * 0.1, height: radius * 0.1)),
                         with: .color(showsSeconds ? .orange : .primary))
        }
    }

    private func point(_ center: CGPoint, _ angle: Double, _ length: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(sin(angle)) * length, y: center.y - CGFloat(cos(angle)) * length)
    }

    private func hand(_ context: inout GraphicsContext, _ center: CGPoint, _ fraction: Double, _ length: CGFloat, width: CGFloat, color: Color) {
        var path = Path()
        path.move(to: center)
        path.addLine(to: point(center, fraction * 2 * .pi, length))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

// MARK: - World clocks

private struct WorldClockWidget: View {
    let instance: WidgetInstance

    private var limit: Int {
        switch instance.size {
        case .small: 2
        case .medium: 3
        case .large: 7
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let zones = instance.timeZones.compactMap(TimeZone.init(identifier:)).prefix(limit)
            VStack(alignment: .leading, spacing: instance.size == .small ? 10 : 8) {
                if zones.isEmpty {
                    Text(L("widget.world.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(Array(zones), id: \.identifier) { zone in
                    row(zone, at: context.date)
                    if zone != zones.last { Divider().opacity(0.5) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ zone: TimeZone, at date: Date) -> some View {
        let hour = Calendar.current.dateComponents(in: zone, from: date).hour ?? 12
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: (6..<19).contains(hour) ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 11))
                .foregroundStyle((6..<19).contains(hour) ? Color.yellow : Color.indigo)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.city(zone)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if instance.size != .small {
                    Text(Self.relative(zone, at: date)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(WidgetFormat.time(date, zone: zone))
                .font(.system(size: instance.size == .small ? 17 : 21, weight: .light, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    static func city(_ zone: TimeZone) -> String {
        zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
    }

    /// "Tomorrow, +9 h".
    static func relative(_ zone: TimeZone, at date: Date) -> String {
        var remote = Calendar.current
        remote.timeZone = zone
        let here = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let there = remote.dateComponents([.year, .month, .day], from: date)
        let localDay = (here.year ?? 0, here.month ?? 0, here.day ?? 0)
        let remoteDay = (there.year ?? 0, there.month ?? 0, there.day ?? 0)
        let day = remoteDay > localDay ? L("widget.world.tomorrow") : remoteDay < localDay ? L("widget.world.yesterday") : L("widget.world.today")
        let hours = Double(zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)) / 3600
        let offset = hours == 0 ? "" : ", " + L("widget.world.hours", (hours > 0 ? "+" : "") + hours.formatted(.number.precision(.fractionLength(0...1)).locale(WidgetFormat.locale)))
        return day + offset
    }
}

// MARK: - Calendar

private struct CalendarWidget: View {
    let instance: WidgetInstance
    @State private var hasAccess = CalendarService.shared.hasAccess

    var body: some View {
        if !hasAccess {
            VStack(alignment: .leading, spacing: 8) {
                WidgetCaption(symbol: "calendar", title: L("widget.kind.calendar"))
                Spacer(minLength: 0)
                Text(L("widget.calendar.noAccess")).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("widget.calendar.allow")) {
                    Task { hasAccess = await CalendarService.shared.requestAccess() }
                }
                .controlSize(.small)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let events = CalendarService.shared.upcoming(days: 7, from: context.date)
                switch instance.size {
                case .small: small(context.date, events)
                case .medium:
                    HStack(alignment: .top, spacing: 14) {
                        MonthGrid(date: context.date).frame(width: 140)
                        EventList(events: events, limit: 3, now: context.date)
                    }
                case .large:
                    VStack(alignment: .leading, spacing: 12) {
                        MonthGrid(date: context.date)
                        Divider().opacity(0.5)
                        EventList(events: events, limit: 5, now: context.date)
                    }
                }
            }
        }
    }

    private func small(_ date: Date, _ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WidgetFormat.weekday(date).uppercased(with: WidgetFormat.locale))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 38, weight: .regular, design: .rounded))
            Spacer(minLength: 0)
            if let next = events.first(where: { !$0.isAllDay }) ?? events.first {
                Text(next.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(next.isAllDay ? L("widget.calendar.allDay") : WidgetFormat.time(next.start)).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(L("widget.calendar.noEvents")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct MonthGrid: View {
    let date: Date

    var body: some View {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        let today = calendar.component(.day, from: date)
        let symbols = Array(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1)...] + calendar.veryShortStandaloneWeekdaySymbols[..<(calendar.firstWeekday - 1)])
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        VStack(alignment: .leading, spacing: 5) {
            Text(date.formatted(Date.FormatStyle(locale: WidgetFormat.locale).month(.wide)).uppercased(with: WidgetFormat.locale))
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.red)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 15) }
                ForEach(1...days, id: \.self) { day in
                    Text("\(day)")
                        .font(.system(size: 10, weight: day == today ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(day == today ? Color.white : Color.primary.opacity(0.85))
                        .frame(width: 17, height: 15)
                        .background(Circle().fill(day == today ? Color.red : .clear).frame(width: 17, height: 17))
                }
            }
        }
    }
}

private struct EventList: View {
    let events: [CalendarEvent]
    let limit: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if events.isEmpty {
                Text(L("widget.calendar.noEvents")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(events.prefix(limit)) { event in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: event.colorHex) ?? .accentColor).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(timeText(event)).font(.system(size: 10.5)).foregroundStyle(event.isHappening(at: now) ? Color.accentColor : .secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if let link = event.meetingURL {
                        Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "video.fill").font(.system(size: 10)) }
                            .buttonStyle(.borderless)
                            .help(L("widget.calendar.join"))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { CalendarService.shared.open(event) }
            }
            Spacer(minLength: 0)
        }
    }

    private func timeText(_ event: CalendarEvent) -> String {
        if event.isAllDay { return L("widget.calendar.allDay") }
        let day = Calendar.current.isDate(event.start, inSameDayAs: now) ? "" : event.start.formatted(Date.FormatStyle(locale: WidgetFormat.locale).weekday(.abbreviated)) + " "
        return day + WidgetFormat.time(event.start) + "–" + WidgetFormat.time(event.end)
    }
}

// MARK: - Timer

private struct TimerWidget: View {
    let runtime: KeystivoRuntime
    let instance: WidgetInstance

    var body: some View {
        let timer = WidgetTimers.shared.timer(for: instance)
        TimelineView(.periodic(from: .now, by: timer.isRunning ? 0.5 : 60)) { context in
            switch instance.size {
            case .small, .large:
                VStack(spacing: 10) {
                    ring(timer, context.date, size: 96)
                    controls(timer)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .medium:
                HStack(spacing: 18) {
                    ring(timer, context.date, size: 118)
                    VStack(alignment: .leading, spacing: 10) {
                        WidgetCaption(symbol: "timer", title: L("widget.kind.timer"))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                            ForEach([5, 10, 15, 25, 45, 60], id: \.self) { minutes in
                                Button { setMinutes(minutes, timer) } label: {
                                    Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes, .hours], width: .narrow)))
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity, minHeight: 22)
                                        .background(Capsule().fill(Int(timer.duration / 60) == minutes ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        controls(timer)
                    }
                }
            }
        }
    }

    private func ring(_ timer: WidgetTimer, _ date: Date, size: CGFloat) -> some View {
        let remaining = timer.remaining(at: date)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: size * 0.07)
            Circle()
                .trim(from: 0, to: max(0.001, 1 - timer.progress(at: date)))
                .stroke(Color.orange, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: remaining)
            Text(Duration.seconds(Int(remaining.rounded(.up))).formatted(.time(pattern: remaining >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                .font(.system(size: size * 0.24, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }

    private func controls(_ timer: WidgetTimer) -> some View {
        HStack(spacing: 8) {
            Button { timer.isRunning ? timer.pause() : timer.start() } label: {
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.orange))
            }
            .buttonStyle(.plain)
            .help(timer.isRunning ? L("widget.timer.pause") : L("widget.timer.start"))
            Button { timer.reset() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(L("widget.timer.reset"))
        }
    }

    private func setMinutes(_ minutes: Int, _ timer: WidgetTimer) {
        timer.reset(minutes: minutes)
        runtime.updateWidget(instance.id) { $0.timerMinutes = minutes }
    }
}

// MARK: - System

private struct SystemWidget: View {
    let instance: WidgetInstance

    var body: some View {
        let monitor = SystemMonitor.shared
        let snapshot = monitor.snapshot
        let gauges: [(String, String, Double, Color)] = [
            ("cpu", "CPU", snapshot.cpuUsage, .blue),
            ("memorychip", "RAM", snapshot.memoryPressure, .purple),
            ("internaldrive", L("monitor.metric.disk"), snapshot.diskUsedFraction, .orange),
        ]
        Group {
            switch instance.size {
            case .small:
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(gauges, id: \.0) { symbol, title, value, color in
                        bar(symbol, title, value, color)
                    }
                    network(snapshot, compact: true)
                }
            case .medium:
                HStack(spacing: 12) {
                    ForEach(gauges, id: \.0) { _, title, value, color in
                        GaugeRing(value: value, color: color, label: title)
                    }
                    network(snapshot, compact: false)
                }
                .frame(maxHeight: .infinity)
            case .large:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ForEach(gauges, id: \.0) { _, title, value, color in
                            GaugeRing(value: value, color: color, label: title)
                        }
                    }
                    WidgetCaption(symbol: "cpu", title: L("monitor.metric.cpu"))
                    Sparkline(values: monitor.cpuHistory, color: .blue).frame(height: 44)
                    network(snapshot, compact: false)
                    ZStack {
                        Sparkline(values: monitor.networkHistory, color: .green)
                        Sparkline(values: monitor.uploadHistory, color: .orange)
                    }
                    .frame(height: 44)
                }
            }
        }
        .onAppear { SystemMonitor.shared.acquire("widget.\(instance.id)") }
        .onDisappear { SystemMonitor.shared.release("widget.\(instance.id)") }
    }

    private func bar(_ symbol: String, _ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(title).font(.system(size: 11, weight: .medium)).frame(width: 34, alignment: .leading).lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color).frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
            Text("\(Int(value * 100))%").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func network(_ snapshot: SystemSnapshot, compact: Bool) -> some View {
        let down = Label(SystemMonitor.rate(snapshot.networkDown), systemImage: "arrow.down").foregroundStyle(.green)
        let up = Label(SystemMonitor.rate(snapshot.networkUp), systemImage: "arrow.up").foregroundStyle(.orange)
        if compact {
            HStack(spacing: 10) { down; up }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                WidgetCaption(symbol: "network", title: L("monitor.metric.network"))
                down
                up
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A ring gauge with the percentage inside and a caption below.
struct GaugeRing: View {
    let value: Double
    let color: Color
    let label: String
    var size: CGFloat = 54

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: size * 0.11)
                Circle()
                    .trim(from: 0, to: min(max(value, 0.001), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value * 100))")
                    .font(.system(size: size * 0.28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Battery

private struct BatteryWidget: View {
    let instance: WidgetInstance

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let items = Self.items()
            let shown = Array(items.prefix(instance.size == .small ? 2 : 4))
            if shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetCaption(symbol: "battery.100percent", title: L("widget.kind.battery"))
                    Spacer(minLength: 0)
                    Label(L("cc.onPower"), systemImage: "powerplug.fill").font(.system(size: 12))
                    Text(L("widget.battery.none")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if instance.size == .small {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(shown, id: \.name) { item in
                        HStack(spacing: 10) {
                            BatteryRing(item: item, size: 46)
                            Text(item.name).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(shown, id: \.name) { item in
                        VStack(spacing: 8) {
                            BatteryRing(item: item, size: 58)
                            Text(item.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    struct Item {
        var name: String
        var level: Int
        var isCharging: Bool
        var symbol: String
    }

    static func items() -> [Item] {
        var items: [Item] = []
        let power = PowerMonitor.shared
        if power.hasBattery, let level = power.batteryLevel {
            items.append(Item(name: Host.current().localizedName ?? "Mac", level: level, isCharging: power.isCharging, symbol: "laptopcomputer"))
        }
        for device in DeviceBatteries.connected() {
            let lower = device.name.lowercased()
            let symbol = lower.contains("mouse") ? "magicmouse.fill" : lower.contains("trackpad") ? "rectangle.and.hand.point.up.left.filled" : "keyboard.fill"
            items.append(Item(name: device.name, level: device.level, isCharging: device.isCharging, symbol: symbol))
        }
        return items
    }
}

private struct BatteryRing: View {
    let item: BatteryWidget.Item
    let size: CGFloat

    var body: some View {
        let color: Color = item.level <= 10 ? .red : item.level <= 20 ? .orange : .green
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: CGFloat(item.level) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Image(systemName: item.isCharging ? "bolt.fill" : item.symbol)
                    .font(.system(size: size * 0.24))
                    .foregroundStyle(item.isCharging ? color : .primary)
                Text("\(item.level)%").font(.system(size: size * 0.2, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Weather

private struct WeatherWidget: View {
    let instance: WidgetInstance

    private var city: String { instance.city.isEmpty ? WeatherService.defaultCity : instance.city }

    var body: some View {
        let service = WeatherService.shared
        TimelineView(.periodic(from: .now, by: 600)) { context in
            let report = service.report(for: city)
            Group {
                if let report {
                    switch instance.size {
                    case .small: current(report)
                    case .medium:
                        HStack(alignment: .top, spacing: 12) {
                            current(report).frame(width: 128)
                            hours(report, count: 5).frame(maxHeight: .infinity)
                        }
                    case .large:
                        VStack(alignment: .leading, spacing: 16) {
                            current(report).frame(height: 150)
                            Divider().opacity(0.4)
                            hours(report, count: 6)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(city).font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                        ProgressView().controlSize(.small)
                        Text(L("widget.weather.loading")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { service.refresh(city: city) }
            .onChange(of: context.date) { service.refresh(city: city) }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background { sky(service.report(for: city)) }
        .padding(-14)
    }

    private func sky(_ report: WeatherService.Report?) -> some View {
        let day = report?.isDay ?? true
        let clear = (report?.code ?? 0) <= 2
        let colors: [Color] = day
            ? (clear ? [Color(red: 0.24, green: 0.52, blue: 0.9), Color(red: 0.42, green: 0.7, blue: 0.96)] : [Color(red: 0.36, green: 0.45, blue: 0.58), Color(red: 0.55, green: 0.63, blue: 0.72)])
            : [Color(red: 0.06, green: 0.08, blue: 0.2), Color(red: 0.16, green: 0.2, blue: 0.38)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom).opacity(0.85)
    }

    private func current(_ report: WeatherService.Report) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(city).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(WidgetFormat.temperature(report.temperature))
                .font(.system(size: 42, weight: .light, design: .rounded))
            Spacer(minLength: 0)
            Image(systemName: WeatherService.symbol(report.code, isDay: report.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 16))
            Text(L(WeatherService.conditionKey(report.code))).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(L("widget.weather.highLow", WidgetFormat.temperature(report.high), WidgetFormat.temperature(report.low)))
                .font(.system(size: 11)).opacity(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func hours(_ report: WeatherService.Report, count: Int) -> some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(report.hours.prefix(count).enumerated()), id: \.offset) { _, hour in
                VStack(spacing: 8) {
                    Text(hour.date.formatted(Date.FormatStyle(locale: WidgetFormat.locale, timeZone: report.timeZone).hour()))
                        .font(.system(size: 11, weight: .medium)).opacity(0.85)
                    Image(systemName: WeatherService.symbol(hour.code, isDay: hour.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 16))
                        .frame(height: 20)
                    Text(WidgetFormat.temperature(hour.temperature)).font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Notes

private struct NotesWidget: View {
    let instance: WidgetInstance
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetCaption(symbol: "note.text", title: L("widget.kind.notes"), tint: .yellow)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, -5)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L("widget.notes.placeholder")).font(.system(size: 13)).foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
        }
        .onAppear { text = WidgetNotes.shared.text(for: instance.id) }
        .onChange(of: text) { WidgetNotes.shared.setText(text, for: instance.id) }
    }
}

// MARK: - Shortcuts

private struct ShortcutsWidget: View {
    let instance: WidgetInstance

    private var layout: (columns: Int, rows: Int) {
        switch instance.size {
        case .small: (2, 2)
        case .medium: (4, 2)
        case .large: (4, 4)
        }
    }

    var body: some View {
        let descriptors = instance.actions.compactMap { ActionRegistry.shared.descriptors[$0] }.prefix(layout.columns * layout.rows)
        if descriptors.isEmpty {
            Text(L("widget.shortcuts.empty")).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: layout.columns), spacing: 8) {
                ForEach(Array(descriptors)) { descriptor in
                    ShortcutButton(descriptor: descriptor)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct ShortcutButton: View {
    let descriptor: ActionDescriptor
    @State private var hovering = false

    var body: some View {
        Button {
            ActionRegistry.shared.run(ActionInvocation(descriptor.id), source: .menuBar)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: descriptor.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.16 : 0.09)))
                Text(L(descriptor.titleKey))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 24, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L(descriptor.titleKey))
    }
}

// MARK: - Clipboard

private struct ClipboardWidget: View {
    let runtime: KeystivoRuntime
    let instance: WidgetInstance
    @State private var items: [ClipboardItem] = []

    private var limit: Int { instance.size == .large ? 8 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                WidgetCaption(symbol: "list.clipboard.fill", title: L("widget.kind.clipboard"), tint: .orange)
                Spacer()
                Button { runtime.launcher.show(mode: .clipboard) } label: { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .help(L("action.clipboard.history"))
            }
            if items.isEmpty {
                Text(L("widget.clipboard.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                ClipRow(item: item) {
                    ClipboardMonitor.shared.copy(item)
                    runtime.hud.show(symbol: "doc.on.doc", text: L("widget.clipboard.copied"))
                }
            }
            Spacer(minLength: 0)
        }
        .task(id: ClipboardMonitor.shared.revision) {
            items = await ClipboardMonitor.shared.items(matching: "", limit: limit)
        }
    }
}

private struct ClipRow: View {
    let item: ClipboardItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if item.kind == .image, let data = item.data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 22)
                }
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow).locale(WidgetFormat.locale)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var symbol: String { item.kind.symbolName }
}

// MARK: - Countdown

private struct CountdownWidget: View {
    let instance: WidgetInstance

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let target = instance.targetDate ?? context.date
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: context.date), to: calendar.startOfDay(for: target)).day ?? 0
            let title = instance.title.isEmpty ? L("widget.kind.countdown") : instance.title
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(days > 0 ? "\(days)" : days == 0 ? L("widget.countdown.today") : "\(-days)")
                        .font(.system(size: days == 0 ? 30 : 46, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if days != 0 {
                        Text(L(days > 0 ? "widget.countdown.daysLeft" : "widget.countdown.daysAgo")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(target.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: WidgetFormat.locale)))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                if instance.size == .medium, days > 0 {
                    let parts = calendar.dateComponents([.day, .hour, .minute], from: context.date, to: target)
                    HStack(spacing: 8) {
                        unit(max(parts.day ?? 0, 0), L("widget.countdown.days"))
                        unit(max(parts.hour ?? 0, 0), L("widget.countdown.hours"))
                        unit(max(parts.minute ?? 0, 0), L("widget.countdown.minutes"))
                    }
                }
            }
        }
    }

    private func unit(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 52, height: 48)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
