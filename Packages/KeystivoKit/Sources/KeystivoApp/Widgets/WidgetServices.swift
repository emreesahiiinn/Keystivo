import AppKit
import IOKit
import KeystivoCore
import Observation

// MARK: - Weather

/// Current weather and the next hours from Open-Meteo (free, no account or key).
@Observable
final class WeatherService {
    static let shared = WeatherService()

    nonisolated struct Place: Hashable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
    }

    nonisolated struct Report: Sendable {
        var temperature: Double
        var code: Int
        var isDay: Bool
        var high: Double
        var low: Double
        var hours: [(date: Date, temperature: Double, code: Int)]
        var fetchedAt: Date
    }

    private(set) var reports: [String: Report] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var places: [String: Place] = [:]

    nonisolated static var usesFahrenheit: Bool { Locale.current.measurementSystem == .us }

    /// The city of the Mac's time zone ("Europe/Istanbul" → "Istanbul").
    static var defaultCity: String {
        TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
    }

    func report(for city: String) -> Report? { reports[city] }

    /// Loads (or refreshes after 30 minutes) the weather of `city`.
    func refresh(city: String) {
        let city = city.isEmpty ? Self.defaultCity : city
        if let report = reports[city], Date.now.timeIntervalSince(report.fetchedAt) < 30 * 60 { return }
        guard !city.isEmpty, loading.insert(city).inserted else { return }
        Task {
            defer { loading.remove(city) }
            guard let place = await place(for: city), let report = await Self.forecast(place) else { return }
            reports[city] = report
        }
    }

    func place(for city: String) async -> Place? {
        if let place = places[city] { return place }
        guard let place = await Self.geocode(city) else { return nil }
        places[city] = place
        return place
    }

    nonisolated private static func geocode(_ city: String) async -> Place? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double else { return nil }
        return Place(name: first["name"] as? String ?? city, latitude: latitude, longitude: longitude)
    }

    nonisolated private static func forecast(_ place: Place) async -> Report? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "temperature_unit", value: usesFahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int else { return nil }
        let daily = json["daily"] as? [String: Any]
        let hourly = json["hourly"] as? [String: Any]
        let times = (hourly?["time"] as? [Double]) ?? []
        let temperatures = (hourly?["temperature_2m"] as? [Double]) ?? []
        let codes = (hourly?["weather_code"] as? [Int]) ?? []
        let now = Date.now.timeIntervalSince1970 - 3600
        let hours = zip(times, zip(temperatures, codes))
            .filter { $0.0 >= now }
            .prefix(6)
            .map { (date: Date(timeIntervalSince1970: $0.0), temperature: $0.1.0, code: $0.1.1) }
        return Report(
            temperature: temperature, code: code, isDay: (current["is_day"] as? Int ?? 1) == 1,
            high: (daily?["temperature_2m_max"] as? [Double])?.first ?? temperature,
            low: (daily?["temperature_2m_min"] as? [Double])?.first ?? temperature,
            hours: Array(hours), fetchedAt: .now
        )
    }

    /// SF Symbol for a WMO weather code.
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    /// Localization key of the condition for a WMO weather code.
    static func conditionKey(_ code: Int) -> String {
        switch code {
        case 0: "weather.clear"
        case 1, 2: "weather.partlyCloudy"
        case 3: "weather.cloudy"
        case 45, 48: "weather.fog"
        case 51...57: "weather.drizzle"
        case 61...67, 80...82: "weather.rain"
        case 71...77, 85, 86: "weather.snow"
        case 95...99: "weather.thunderstorm"
        default: "weather.cloudy"
        }
    }
}

// MARK: - Timers

/// A countdown that keeps running while its widget is closed.
@Observable
final class WidgetTimer {
    private(set) var duration: TimeInterval
    private(set) var endsAt: Date?
    private(set) var pausedRemaining: TimeInterval?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onFinish: (() -> Void)?

    init(minutes: Int) { duration = TimeInterval(minutes * 60) }

    var isRunning: Bool { endsAt != nil }

    func remaining(at date: Date = .now) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(date)) }
        return pausedRemaining ?? duration
    }

    func progress(at date: Date = .now) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 0
    }

    func start() {
        guard endsAt == nil else { return }
        let left = pausedRemaining ?? duration
        endsAt = Date.now.addingTimeInterval(left)
        pausedRemaining = nil
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled, let self else { return }
            self.endsAt = nil
            self.pausedRemaining = nil
            self.onFinish?()
        }
    }

    func pause() {
        guard let endsAt else { return }
        pausedRemaining = max(0, endsAt.timeIntervalSinceNow)
        self.endsAt = nil
        task?.cancel()
    }

    func reset(minutes: Int? = nil) {
        task?.cancel()
        endsAt = nil
        pausedRemaining = nil
        if let minutes { duration = TimeInterval(minutes * 60) }
    }
}

/// One timer per timer widget, alive for the whole session.
final class WidgetTimers {
    static let shared = WidgetTimers()
    private var timers: [UUID: WidgetTimer] = [:]

    func timer(for instance: WidgetInstance) -> WidgetTimer {
        if let timer = timers[instance.id] { return timer }
        let timer = WidgetTimer(minutes: instance.timerMinutes)
        timer.onFinish = {
            NSSound(named: "Glass")?.play()
            KeystivoRuntime.shared.hud.show(symbol: "timer", text: L("widget.timer.done"))
        }
        timers[instance.id] = timer
        return timer
    }
}

// MARK: - Device batteries

/// Battery levels of connected Apple keyboards, mice and trackpads.
nonisolated enum DeviceBatteries {
    struct Device: Hashable, Sendable {
        var name: String
        var level: Int
        var isCharging: Bool
    }

    static func connected() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func value(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let level = value("BatteryPercent") as? Int, let name = value("Product") as? String else { continue }
            let status = value("BatteryStatusFlags") as? Int ?? 0
            if !devices.contains(where: { $0.name == name }) {
                devices.append(Device(name: name, level: level, isCharging: status & 0x3 == 0x3))
            }
        }
        return devices
    }
}

// MARK: - Notes

/// Note widget text, one plain-text file per widget (not in the settings file).
final class WidgetNotes {
    static let shared = WidgetNotes()
    private var cache: [UUID: String] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    private var folder: URL { AppPaths.applicationSupport.appending(path: "Widgets", directoryHint: .isDirectory) }

    func text(for id: UUID) -> String {
        if let text = cache[id] { return text }
        let text = (try? String(contentsOf: folder.appending(path: "\(id.uuidString).txt"), encoding: .utf8)) ?? ""
        cache[id] = text
        return text
    }

    /// Saves shortly after typing stops.
    func setText(_ text: String, for id: UUID) {
        cache[id] = text
        saveTasks[id]?.cancel()
        let url = folder.appending(path: "\(id.uuidString).txt")
        let folder = folder
        saveTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func remove(_ id: UUID) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: folder.appending(path: "\(id.uuidString).txt"))
    }
}
