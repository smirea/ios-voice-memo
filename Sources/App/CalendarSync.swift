import EventKit
import Foundation
import Observation

struct CalendarSource: Hashable, Identifiable, Sendable {
	let id: String
	let title: String
	let sourceTitle: String
}

enum PreferredCalendarApp: String, Codable, CaseIterable, Identifiable {
	case google
	case apple

	var id: Self { self }

	var title: String {
		switch self {
		case .google: "Google Calendar"
		case .apple: "Apple Calendar"
		}
	}
}

@MainActor
@Observable
final class CalendarSync {
	private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)
	private(set) var calendars: [CalendarSource] = []
	private(set) var events: [JournalCalendarEvent] = []

	@ObservationIgnored private let eventStore = EKEventStore()
	@ObservationIgnored private let isDemoMode: Bool
	@ObservationIgnored private var refreshID = UUID()

	init(isDemoMode: Bool = false) {
		self.isDemoMode = isDemoMode
		if isDemoMode {
			authorizationStatus = .fullAccess
		}
	}

	var hasAccess: Bool {
		isDemoMode || authorizationStatus == .fullAccess
	}

	func requestAccess() async -> Bool {
		if isDemoMode {
			loadDemoData(on: .now)
			return true
		}
		do {
			let granted = try await eventStore.requestFullAccessToEvents()
			authorizationStatus = EKEventStore.authorizationStatus(for: .event)
			if granted {
				loadCalendars()
			}
			return granted
		} catch {
			authorizationStatus = EKEventStore.authorizationStatus(for: .event)
			return false
		}
	}

	func refresh(
		includedCalendarIdentifiers: Set<String>?,
		on date: Date = .now
	) async {
		let requestID = UUID()
		refreshID = requestID

		if isDemoMode {
			loadDemoData(on: date)
			if let includedCalendarIdentifiers {
				events.removeAll {
					!includedCalendarIdentifiers.contains($0.calendarIdentifier)
				}
			}
			return
		}

		authorizationStatus = EKEventStore.authorizationStatus(for: .event)
		guard authorizationStatus == .fullAccess else {
			calendars = []
			events = []
			return
		}

		loadCalendars()
		let selectedIdentifiers = includedCalendarIdentifiers
		let start = Calendar.current.startOfDay(for: date)
		let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start

		let loadedEvents: [JournalCalendarEvent] = await Task.detached(priority: .utility) {
			let store = EKEventStore()
			let selectedCalendars = store.calendars(for: .event).filter { calendar in
				selectedIdentifiers?.contains(calendar.calendarIdentifier) ?? true
			}
			guard !selectedCalendars.isEmpty else { return [] }
			let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selectedCalendars)
			return store.events(matching: predicate)
				.filter { $0.status != .canceled }
				.sorted { $0.startDate < $1.startDate }
				.map {
					JournalCalendarEvent(
						id: $0.eventIdentifier ?? $0.calendarItemIdentifier,
						localIdentifier: $0.calendarItemIdentifier,
						externalIdentifier: $0.calendarItemExternalIdentifier,
						providerURL: Self.calendarProviderURL(from: $0.url),
						calendarIdentifier: $0.calendar.calendarIdentifier,
						calendarTitle: $0.calendar.title,
						title: $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Untitled event",
						startDate: $0.startDate,
						endDate: $0.endDate,
						isAllDay: $0.isAllDay
					)
				}
		}.value
		guard refreshID == requestID else { return }
		events = loadedEvents
	}

	func resolve(_ storedEvent: JournalCalendarEvent) -> EKEvent? {
		if isDemoMode {
			let event = EKEvent(eventStore: eventStore)
			event.title = storedEvent.title
			event.startDate = storedEvent.startDate
			event.endDate = storedEvent.endDate
			event.isAllDay = storedEvent.isAllDay
			return event
		}

		guard authorizationStatus == .fullAccess else { return nil }

		for identifier in [storedEvent.localIdentifier, storedEvent.id].compactMap({ $0 }) {
			if let event = eventStore.event(withIdentifier: identifier)
				?? eventStore.calendarItem(withIdentifier: identifier) as? EKEvent {
				return event
			}
		}

		if let externalIdentifier = storedEvent.externalIdentifier {
			let matches = eventStore.calendarItems(withExternalIdentifier: externalIdentifier)
				.compactMap { $0 as? EKEvent }
			if let event = bestMatch(for: storedEvent, among: matches) {
				return event
			}
		}

		let start = storedEvent.startDate.addingTimeInterval(-60)
		let end = storedEvent.endDate.addingTimeInterval(60)
		let calendars = eventStore.calendars(for: .event).filter {
			$0.calendarIdentifier == storedEvent.calendarIdentifier
		}
		let predicate = eventStore.predicateForEvents(
			withStart: start,
			end: end,
			calendars: calendars.isEmpty ? nil : calendars
		)
		let matchingEvents = eventStore.events(matching: predicate).filter {
			$0.title == storedEvent.title
		}
		return bestMatch(for: storedEvent, among: matchingEvents)
	}

	func providerURL(for event: EKEvent) -> URL? {
		Self.calendarProviderURL(from: event.url)
	}

	func clear() {
		refreshID = UUID()
		events = []
		calendars = []
		authorizationStatus = EKEventStore.authorizationStatus(for: .event)
	}

	private func loadCalendars() {
		calendars = eventStore.calendars(for: .event)
			.map {
				CalendarSource(
					id: $0.calendarIdentifier,
					title: $0.title,
					sourceTitle: $0.source.title
				)
			}
			.sorted {
				if $0.sourceTitle == $1.sourceTitle {
					return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
				}
				return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
			}
	}

	private func loadDemoData(on date: Date) {
		let calendar = Calendar.current
		let start = calendar.startOfDay(for: date)
		func time(_ hour: Int, _ minute: Int = 0) -> Date {
			calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start) ?? start
		}

		calendars = [
			CalendarSource(id: "demo-work", title: "Work", sourceTitle: "Google"),
			CalendarSource(id: "demo-personal", title: "Personal", sourceTitle: "iCloud")
		]
		events = [
			JournalCalendarEvent(
				id: "demo-standup",
				calendarIdentifier: "demo-work",
				calendarTitle: "Work",
				title: "Team standup",
				startDate: time(9, 30),
				endDate: time(10),
				isAllDay: false
			),
			JournalCalendarEvent(
				id: "demo-design-review",
				calendarIdentifier: "demo-work",
				calendarTitle: "Work",
				title: "Design review",
				startDate: time(13),
				endDate: time(14),
				isAllDay: false
			),
			JournalCalendarEvent(
				id: "demo-dinner",
				calendarIdentifier: "demo-personal",
				calendarTitle: "Personal",
				title: "Dinner",
				startDate: time(19),
				endDate: time(20, 30),
				isAllDay: false
			)
		]
	}

	private func bestMatch(
		for storedEvent: JournalCalendarEvent,
		among events: [EKEvent]
	) -> EKEvent? {
		let event = events.min { lhs, rhs in
			matchScore(lhs, storedEvent: storedEvent) < matchScore(rhs, storedEvent: storedEvent)
		}
		guard let event,
			abs(event.startDate.timeIntervalSince(storedEvent.startDate)) < 300
		else { return nil }
		return event
	}

	private func matchScore(_ event: EKEvent, storedEvent: JournalCalendarEvent) -> TimeInterval {
		let calendarPenalty: TimeInterval = event.calendar.calendarIdentifier == storedEvent.calendarIdentifier ? 0 : 86_400
		let titlePenalty: TimeInterval = event.title == storedEvent.title ? 0 : 43_200
		return calendarPenalty + titlePenalty + abs(event.startDate.timeIntervalSince(storedEvent.startDate))
	}

	nonisolated private static func calendarProviderURL(from url: URL?) -> URL? {
		guard let url, let host = url.host?.lowercased() else { return nil }
		if host == "calendar.google.com" || host.hasSuffix(".calendar.google.com") {
			return url
		}
		if (host == "google.com" || host == "www.google.com"),
			url.path.hasPrefix("/calendar/") {
			return url
		}
		return nil
	}
}

private extension String {
	var nonempty: String? {
		isEmpty ? nil : self
	}
}
