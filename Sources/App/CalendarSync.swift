import EventKit
import Foundation
import Observation

struct CalendarSource: Codable, Hashable, Identifiable, Sendable {
	let id: String
	let title: String
	let sourceTitle: String
}

private struct CalendarEventCache: Codable {
	let refreshedAt: Date
	let includedCalendarIdentifiers: Set<String>?
	let calendars: [CalendarSource]
	let events: [JournalCalendarEvent]
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
	private(set) var calendars: [CalendarSource] = []
	private(set) var events: [JournalCalendarEvent] = []

	@ObservationIgnored private let eventStore = EKEventStore()
	@ObservationIgnored private let isDemoMode: Bool
	@ObservationIgnored private let cacheURL: URL
	@ObservationIgnored private var refreshID = UUID()
	@ObservationIgnored private var refreshedAt: Date?
	@ObservationIgnored private var cachedCalendarIdentifiers: Set<String>?
	@ObservationIgnored private var refreshStartedAt: Date?
	@ObservationIgnored private var refreshingCalendarIdentifiers: Set<String>?

	init(isDemoMode: Bool = false, cacheURL: URL) {
		self.isDemoMode = isDemoMode
		self.cacheURL = cacheURL
		guard !isDemoMode,
			EKEventStore.authorizationStatus(for: .event) == .fullAccess,
			let cache = Self.loadCache(from: cacheURL)
		else { return }
		calendars = cache.calendars
		events = cache.events
		refreshedAt = cache.refreshedAt
		cachedCalendarIdentifiers = cache.includedCalendarIdentifiers
	}

	func requestAccess() async -> Bool {
		if isDemoMode {
			loadDemoData(on: .now)
			return true
		}
		do {
			let granted = try await eventStore.requestFullAccessToEvents()
			if granted {
				loadCalendars()
			}
			return granted
		} catch {
			return false
		}
	}

	func refresh(
		includedCalendarIdentifiers: Set<String>?,
		now: Date = .now,
		force: Bool = false
	) async {
		if !force, cacheIsFresh(
			at: now,
			includedCalendarIdentifiers: includedCalendarIdentifiers
		) {
			return
		}
		if !force,
			refreshingCalendarIdentifiers == includedCalendarIdentifiers,
			let refreshStartedAt,
			now.timeIntervalSince(refreshStartedAt) < 300 {
			return
		}

		let requestID = UUID()
		refreshID = requestID
		refreshStartedAt = now
		refreshingCalendarIdentifiers = includedCalendarIdentifiers
		let range = Self.eventRange(around: now)

		if isDemoMode {
			loadDemoCalendars()
			let loadedEvents = await loadEvents(
				from: range.lowerBound,
				to: range.upperBound,
				includedCalendarIdentifiers: includedCalendarIdentifiers
			)
			guard refreshID == requestID else { return }
			events = loadedEvents
			await finishRefresh(
				at: now,
				includedCalendarIdentifiers: includedCalendarIdentifiers
			)
			return
		}

		guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
			clear()
			return
		}

		loadCalendars()
		let loadedEvents = await loadEvents(
			from: range.lowerBound,
			to: range.upperBound,
			includedCalendarIdentifiers: includedCalendarIdentifiers
		)
		guard refreshID == requestID else { return }
		events = loadedEvents
		await finishRefresh(
			at: now,
			includedCalendarIdentifiers: includedCalendarIdentifiers
		)
	}

	func events(on date: Date) -> [JournalCalendarEvent] {
		let start = Calendar.current.startOfDay(for: date)
		let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
		return events.filter { $0.startDate < end && $0.endDate > start }
	}

	var selectableDateRange: ClosedRange<Date> {
		let range = Self.eventRange(around: .now)
		return range.lowerBound...range.upperBound.addingTimeInterval(-1)
	}

	func loadEvents(
		from start: Date,
		to end: Date,
		includedCalendarIdentifiers: Set<String>?
	) async -> [JournalCalendarEvent] {
		if isDemoMode {
			return demoEvents(from: start, to: end).filter {
				includedCalendarIdentifiers?.contains($0.calendarIdentifier) ?? true
			}
		}

		guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
		let selectedIdentifiers = includedCalendarIdentifiers
		return await Task.detached(priority: .utility) {
			let store = EKEventStore()
			let selectedCalendars = store.calendars(for: .event).filter { calendar in
				selectedIdentifiers?.contains(calendar.calendarIdentifier) ?? true
			}
			guard !selectedCalendars.isEmpty else { return [] }
			let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selectedCalendars)
			return store.events(matching: predicate)
				.filter { $0.status != .canceled }
				.sorted { $0.startDate < $1.startDate }
				.map(Self.journalEvent)
		}.value
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

		guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }

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
		refreshedAt = nil
		cachedCalendarIdentifiers = nil
		refreshStartedAt = nil
		refreshingCalendarIdentifiers = nil
		try? FileManager.default.removeItem(at: cacheURL)
	}

	private func cacheIsFresh(
		at now: Date,
		includedCalendarIdentifiers: Set<String>?
	) -> Bool {
		guard cachedCalendarIdentifiers == includedCalendarIdentifiers,
			let refreshedAt
		else { return false }
		let age = now.timeIntervalSince(refreshedAt)
		return age >= 0 && age < 86_400
	}

	private func finishRefresh(
		at date: Date,
		includedCalendarIdentifiers: Set<String>?
	) async {
		refreshedAt = date
		cachedCalendarIdentifiers = includedCalendarIdentifiers
		refreshStartedAt = nil
		refreshingCalendarIdentifiers = nil
		guard !isDemoMode else { return }
		await Self.save(CalendarEventCache(
			refreshedAt: date,
			includedCalendarIdentifiers: includedCalendarIdentifiers,
			calendars: calendars,
			events: events
		), to: cacheURL)
	}

	nonisolated private static func save(_ cache: CalendarEventCache, to cacheURL: URL) async {
		guard let data = try? JSONEncoder().encode(cache) else { return }
		await Task.detached(priority: .utility) {
			do {
				try FileManager.default.createDirectory(
					at: cacheURL.deletingLastPathComponent(),
					withIntermediateDirectories: true
				)
				try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
				var values = URLResourceValues()
				values.isExcludedFromBackup = true
				var savedURL = cacheURL
				try savedURL.setResourceValues(values)
			} catch {
				assertionFailure("Could not save the calendar cache: \(error)")
			}
		}.value
	}

	nonisolated private static func loadCache(from url: URL) -> CalendarEventCache? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? JSONDecoder().decode(CalendarEventCache.self, from: data)
	}

	nonisolated private static func eventRange(around date: Date) -> Range<Date> {
		let calendar = Calendar.current
		let day = calendar.startOfDay(for: date)
		let start = calendar.date(byAdding: .month, value: -1, to: day) ?? day
		let future = calendar.date(byAdding: .month, value: 3, to: day) ?? day
		let end = calendar.date(byAdding: .day, value: 1, to: future) ?? future
		return start..<end
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

	private func loadDemoCalendars() {
		calendars = [
			CalendarSource(id: "demo-work", title: "Work", sourceTitle: "Google"),
			CalendarSource(id: "demo-personal", title: "Personal", sourceTitle: "iCloud")
		]
	}

	private func loadDemoData(on date: Date) {
		loadDemoCalendars()
		let calendar = Calendar.current
		let start = calendar.startOfDay(for: date)
		let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
		events = demoEvents(from: start, to: end)
	}

	private func demoEvents(from start: Date, to end: Date) -> [JournalCalendarEvent] {
		let calendar = Calendar.current
		var day = calendar.startOfDay(for: start)
		var events: [JournalCalendarEvent] = []
		while day < end {
			func time(_ hour: Int, _ minute: Int = 0) -> Date {
				calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day) ?? day
			}
			let dayKey = day.formatted(.iso8601.year().month().day())
			events.append(contentsOf: [
			JournalCalendarEvent(
				id: "demo-standup-\(dayKey)",
				calendarIdentifier: "demo-work",
				calendarTitle: "Work",
				title: "Team standup",
				startDate: time(9, 30),
				endDate: time(10),
				isAllDay: false
			),
			JournalCalendarEvent(
				id: "demo-design-review-\(dayKey)",
				calendarIdentifier: "demo-work",
				calendarTitle: "Work",
				title: "Design review",
				startDate: time(13),
				endDate: time(14),
				isAllDay: false
			),
			JournalCalendarEvent(
				id: "demo-dinner-\(dayKey)",
				calendarIdentifier: "demo-personal",
				calendarTitle: "Personal",
				title: "Dinner",
				startDate: time(19),
				endDate: time(20, 30),
				isAllDay: false
			)
			])

			let weekday = calendar.component(.weekday, from: day)
			if weekday == 1 {
				events.append(contentsOf: [
					JournalCalendarEvent(
						id: "demo-morning-run-\(dayKey)",
						externalIdentifier: "demo-morning-run-series",
						calendarIdentifier: "demo-personal",
						calendarTitle: "Personal",
						title: "Morning run",
						startDate: time(8),
						endDate: time(9),
						isAllDay: false,
						location: "Lakefront Trail",
						notes: "Weekly group run",
						isRecurring: true
					),
					JournalCalendarEvent(
						id: "demo-board-games-\(dayKey)",
						calendarIdentifier: "demo-personal",
						calendarTitle: "Personal",
						title: "Sunday board games",
						startDate: time(10),
						endDate: time(13),
						isAllDay: false,
						location: "Dice Dojo",
						notes: "Meetup event"
					)
				])
			}
			if weekday == 5 {
				events.append(JournalCalendarEvent(
					id: "demo-improv-\(dayKey)",
					externalIdentifier: "demo-improv-series",
					calendarIdentifier: "demo-personal",
					calendarTitle: "Personal",
					title: "Improv class",
					startDate: time(19),
					endDate: time(21),
					isAllDay: false,
					location: "Theater",
					isRecurring: true
				))
			}
			day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
		}
		return events.sorted { $0.startDate < $1.startDate }
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

	nonisolated private static func journalEvent(_ event: EKEvent) -> JournalCalendarEvent {
		JournalCalendarEvent(
			id: event.eventIdentifier ?? event.calendarItemIdentifier,
			localIdentifier: event.calendarItemIdentifier,
			externalIdentifier: event.calendarItemExternalIdentifier,
			providerURL: calendarProviderURL(from: event.url),
			calendarIdentifier: event.calendar.calendarIdentifier,
			calendarTitle: event.calendar.title,
			title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Untitled event",
			startDate: event.startDate,
			endDate: event.endDate,
			isAllDay: event.isAllDay,
			location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty,
			notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty,
			isRecurring: event.hasRecurrenceRules || event.occurrenceDate != nil
		)
	}
}

private extension String {
	var nonempty: String? {
		isEmpty ? nil : self
	}
}
