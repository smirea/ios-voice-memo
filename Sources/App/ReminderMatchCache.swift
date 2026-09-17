import Foundation

struct ReminderMatchContext: Hashable, Sendable {
	var version = "event-match-v2"
	var model = "SystemLanguageModel.default/general"
	var locale = Locale.current.identifier
	var timeZone = TimeZone.current.identifier
	var calendar = String(describing: Calendar.current.identifier)
	var firstWeekday = Calendar.current.firstWeekday
	var minimumDaysInFirstWeek = Calendar.current.minimumDaysInFirstWeek
}

struct ReminderMatchSelector: Hashable, Sendable {
	let text: String
	let time: EventReminderTimeBucket
	let location: String?
	init(_ selector: FuzzyEventSelector) {
		text = selector.semanticDescription
		time = selector.timeBucket
		location = selector.locationDescription
	}
}

struct ReminderMatchKey: Hashable, Sendable {
	let selector: ReminderMatchSelector
	let event: JournalCalendarEvent
	let context: ReminderMatchContext
	init(selector: FuzzyEventSelector, event: JournalCalendarEvent, context: ReminderMatchContext) {
		self.selector = ReminderMatchSelector(selector)
		self.event = event
		self.context = context
	}
}

actor ReminderMatchCache {
	private struct Cached {
		var assessment: EventMatchAssessment
		var used: UInt64
	}
	private var values: [ReminderMatchKey: Cached] = [:]
	private var selectors = Set<ReminderMatchSelector>()
	private var events = Set<JournalCalendarEvent>()
	private var context = ReminderMatchContext()
	private var clock: UInt64 = 0
	private let capacity: Int

	init(capacity: Int = 512) { self.capacity = min(512, max(1, capacity)) }
	var count: Int { values.count }

	func retain(entries: [JournalEntry], events: [JournalCalendarEvent], now: Date, context: ReminderMatchContext) {
		guard !Task.isCancelled else { return }
		selectors = Set(entries.flatMap(\.reminders).compactMap { reminder in
			guard reminder.isActive(at: now), case let .fuzzy(selector) = reminder.selector else { return nil }
			return ReminderMatchSelector(selector)
		})
		self.events = Set(events)
		self.context = context
		values = values.filter { accepts($0.key) }
	}

	func value(for key: ReminderMatchKey) -> EventMatchAssessment? {
		guard var cached = values[key], accepts(key) else { return nil }
		clock += 1
		cached.used = clock
		values[key] = cached
		return cached.assessment
	}

	func insert(_ assessment: EventMatchAssessment, for key: ReminderMatchKey) {
		guard !Task.isCancelled, accepts(key) else { return }
		clock += 1
		values[key] = Cached(assessment: assessment, used: clock)
		if values.count > capacity, let oldest = values.min(by: { $0.value.used < $1.value.used })?.key {
			values[oldest] = nil
		}
	}

	private func accepts(_ key: ReminderMatchKey) -> Bool {
		key.context == context && selectors.contains(key.selector) && events.contains(key.event)
	}
}
