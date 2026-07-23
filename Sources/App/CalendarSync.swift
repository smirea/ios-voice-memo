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
			loadDemoData()
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

	func refresh(includedCalendarIdentifiers: Set<String>?) async {
		if isDemoMode {
			loadDemoData()
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
		let start = Calendar.current.startOfDay(for: .now)
		let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? .now

		events = await Task.detached(priority: .utility) {
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
						calendarIdentifier: $0.calendar.calendarIdentifier,
						calendarTitle: $0.calendar.title,
						title: $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Untitled event",
						startDate: $0.startDate,
						endDate: $0.endDate,
						isAllDay: $0.isAllDay
					)
				}
		}.value
	}

	func clear() {
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

	private func loadDemoData() {
		let calendar = Calendar.current
		let start = calendar.startOfDay(for: .now)
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
}

private extension String {
	var nonempty: String? {
		isEmpty ? nil : self
	}
}
