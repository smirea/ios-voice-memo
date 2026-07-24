import Foundation

enum EventReminderOccurrencePolicy: String, Codable, Hashable, Sendable {
	case nextMatch
	case everyMatch

	var title: String {
		switch self {
		case .nextMatch: "Next match"
		case .everyMatch: "Every match"
		}
	}
}

enum EventReminderTimeBucket: String, Codable, CaseIterable, Hashable, Sendable {
	case any
	case morning
	case afternoon
	case evening

	var title: String {
		switch self {
		case .any: "Any time"
		case .morning: "Morning"
		case .afternoon: "Afternoon"
		case .evening: "Evening"
		}
	}

	func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
		let hour = calendar.component(.hour, from: date)
		return switch self {
		case .any:
			true
		case .morning:
			(4..<12).contains(hour)
		case .afternoon:
			(12..<17).contains(hour)
		case .evening:
			(17..<24).contains(hour)
		}
	}
}

struct EventSeriesReference: Codable, Hashable, Sendable {
	var externalIdentifier: String?
	var calendarIdentifier: String
	var calendarTitle: String
	var eventTitle: String
	var startMinuteOfDay: Int

	init(event: JournalCalendarEvent, calendar: Calendar = .current) {
		externalIdentifier = event.externalIdentifier
		calendarIdentifier = event.calendarIdentifier
		calendarTitle = event.calendarTitle
		eventTitle = event.title
		let components = calendar.dateComponents([.hour, .minute], from: event.startDate)
		startMinuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
	}

	func matches(_ event: JournalCalendarEvent, calendar: Calendar = .current) -> Bool {
		if let externalIdentifier,
			!externalIdentifier.isEmpty,
			event.externalIdentifier == externalIdentifier {
			return true
		}

		guard event.title.reminderNormalized == eventTitle.reminderNormalized else { return false }
		let sameCalendar = event.calendarIdentifier == calendarIdentifier
			|| event.calendarTitle.reminderNormalized == calendarTitle.reminderNormalized
		guard sameCalendar else { return false }

		let components = calendar.dateComponents([.hour, .minute], from: event.startDate)
		let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
		let timeDistance = min(abs(minute - startMinuteOfDay), 1_440 - abs(minute - startMinuteOfDay))
		return event.isAllDay || timeDistance <= 120
	}
}

struct ReminderMatchExample: Codable, Hashable, Identifiable, Sendable {
	var event: JournalCalendarEvent
	var matches: Bool
	var reason: String

	var id: String { event.focusKey }
}

struct FuzzyEventSelector: Codable, Hashable, Sendable {
	var semanticDescription: String
	var timeBucket: EventReminderTimeBucket
	var locationDescription: String?
	var examples: [ReminderMatchExample]
}

enum EventReminderSelector: Codable, Hashable, Sendable {
	case series(EventSeriesReference)
	case fuzzy(FuzzyEventSelector)

	var title: String {
		switch self {
		case let .series(series):
			series.eventTitle
		case let .fuzzy(selector):
			selector.timeBucket == .any
				? selector.semanticDescription
				: "\(selector.timeBucket.title) \(selector.semanticDescription)"
		}
	}

	var examples: [ReminderMatchExample] {
		guard case let .fuzzy(selector) = self else { return [] }
		return selector.examples
	}
}

struct EventReminderRule: Codable, Hashable, Identifiable, Sendable {
	var id: UUID
	var text: String
	var motivation: String
	var evidence: String
	var selector: EventReminderSelector
	var occurrencePolicy: EventReminderOccurrencePolicy
	var createdAt: Date
	var expiresAt: Date?
	var leadTimeOverrideMinutes: Int?
	var resolvedOccurrence: JournalCalendarEvent?

	init(
		id: UUID = UUID(),
		text: String,
		motivation: String,
		evidence: String,
		selector: EventReminderSelector,
		occurrencePolicy: EventReminderOccurrencePolicy,
		createdAt: Date = .now,
		expiresAt: Date? = nil,
		leadTimeOverrideMinutes: Int? = nil,
		resolvedOccurrence: JournalCalendarEvent? = nil
	) {
		self.id = id
		self.text = text
		self.motivation = motivation
		self.evidence = evidence
		self.selector = selector
		self.occurrencePolicy = occurrencePolicy
		self.createdAt = createdAt
		self.expiresAt = expiresAt
		self.leadTimeOverrideMinutes = leadTimeOverrideMinutes
		self.resolvedOccurrence = resolvedOccurrence
	}

	func isActive(at date: Date) -> Bool {
		expiresAt.map { $0 >= date } ?? true
	}
}

enum ReminderFeedbackKind: String, Codable, Hashable, Sendable {
	case voice
	case manualRemoval
}

struct ReminderFeedback: Codable, Hashable, Sendable {
	var kind: ReminderFeedbackKind
	var text: String
	var focusedReminderID: UUID?

	init(
		kind: ReminderFeedbackKind,
		text: String,
		focusedReminderID: UUID? = nil
	) {
		self.kind = kind
		self.text = text
		self.focusedReminderID = focusedReminderID
	}
}

struct EventReminderOccurrence: Identifiable, Hashable, Sendable {
	var sourceEntryID: UUID
	var reminder: EventReminderRule
	var event: JournalCalendarEvent

	var id: String {
		"\(sourceEntryID.uuidString)::\(reminder.id.uuidString)::\(event.focusKey)"
	}

	var eventKey: String { event.focusKey }
}

extension JournalCalendarEvent {
	var focusKey: String {
		"\(id)::\(Int(startDate.timeIntervalSince1970))"
	}
}

extension String {
	var reminderNormalized: String {
		folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.unicodeScalars
			.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
			.joined()
			.split(whereSeparator: \.isWhitespace)
			.joined(separator: " ")
	}
}
