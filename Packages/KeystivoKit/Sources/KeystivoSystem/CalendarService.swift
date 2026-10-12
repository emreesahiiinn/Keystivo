import AppKit
import EventKit
import KeystivoCore

/// One calendar event, reduced to what the launcher and menu bar show.
nonisolated public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarName: String
    public let colorHex: String
    public let location: String?
    /// Video call link found in the event (Zoom, Meet, Teams, Webex, FaceTime…).
    public let meetingURL: URL?

    public func isHappening(at date: Date = .now) -> Bool { start <= date && date < end }
}

/// Calendar events through EventKit ("My Schedule", joining meetings). Access is
/// requested only the first time the schedule is opened.
public final class CalendarService {
    public static let shared = CalendarService()

    private let store = EKEventStore()

    public init() {}

    public var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    public var accessDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    /// Asks for calendar access if it hasn't been decided yet.
    public func requestAccess() async -> Bool {
        if hasAccess { return true }
        guard !accessDenied else { return false }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Events from now (including ones in progress) until `days` days later, soonest first.
    public func upcoming(days: Int = 2, from now: Date = .now) -> [CalendarEvent] {
        guard hasAccess else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map(Self.event)
    }

    /// The soonest timed event with a video link that hasn't ended yet.
    public func nextMeeting(from now: Date = .now) -> CalendarEvent? {
        upcoming(days: 1, from: now).first { !$0.isAllDay && $0.meetingURL != nil }
    }

    public func open(_ event: CalendarEvent) {
        let encoded = event.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.id
        if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func event(_ event: EKEvent) -> CalendarEvent {
        let color = event.calendar?.color.usingColorSpace(.sRGB)
        let hex = color.map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#8E8E93"
        let link = MeetingLinks.find(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
        return CalendarEvent(
            id: event.calendarItemIdentifier, title: event.title ?? "", start: event.startDate, end: event.endDate,
            isAllDay: event.isAllDay, calendarName: event.calendar?.title ?? "", colorHex: hex,
            location: event.location.flatMap { $0.isEmpty ? nil : $0 }, meetingURL: link
        )
    }
}

/// Finds video-call links in event fields. Pure, unit-tested.
nonisolated public enum MeetingLinks {
    static let hosts = [
        "zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "facetime.apple.com", "whereby.com", "meet.jit.si", "gotomeeting.com", "app.slack.com/huddle", "chime.aws", "around.co", "discord.gg",
    ]

    public static func find(in texts: [String]) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let host = url.host()?.lowercased() else { continue }
                let full = host + url.path
                if hosts.contains(where: { full.contains($0) }) { return url }
            }
        }
        return nil
    }
}
