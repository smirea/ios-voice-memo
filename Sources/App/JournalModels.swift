import Foundation

struct JournalLocation: Codable, Hashable, Sendable {
	var latitude: Double
	var longitude: Double
	var city: String?

	var displayName: String {
		city ?? "Recorded location"
	}
}

struct JournalCalendarEvent: Codable, Hashable, Identifiable, Sendable {
	private enum CodingKeys: String, CodingKey {
		case id
		case localIdentifier
		case externalIdentifier
		case providerURL
		case calendarIdentifier
		case calendarTitle
		case title
		case startDate
		case endDate
		case isAllDay
		case location
		case notes
		case isRecurring
	}

	var id: String
	var localIdentifier: String?
	var externalIdentifier: String?
	var providerURL: URL?
	var calendarIdentifier: String
	var calendarTitle: String
	var title: String
	var startDate: Date
	var endDate: Date
	var isAllDay: Bool
	var location: String?
	var notes: String?
	var isRecurring: Bool

	init(
		id: String,
		localIdentifier: String? = nil,
		externalIdentifier: String? = nil,
		providerURL: URL? = nil,
		calendarIdentifier: String,
		calendarTitle: String,
		title: String,
		startDate: Date,
		endDate: Date,
		isAllDay: Bool,
		location: String? = nil,
		notes: String? = nil,
		isRecurring: Bool = false
	) {
		self.id = id
		self.localIdentifier = localIdentifier
		self.externalIdentifier = externalIdentifier
		self.providerURL = providerURL
		self.calendarIdentifier = calendarIdentifier
		self.calendarTitle = calendarTitle
		self.title = title
		self.startDate = startDate
		self.endDate = endDate
		self.isAllDay = isAllDay
		self.location = location
		self.notes = notes
		self.isRecurring = isRecurring
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		localIdentifier = try container.decodeIfPresent(String.self, forKey: .localIdentifier)
		externalIdentifier = try container.decodeIfPresent(String.self, forKey: .externalIdentifier)
		providerURL = try container.decodeIfPresent(URL.self, forKey: .providerURL)
		calendarIdentifier = try container.decode(String.self, forKey: .calendarIdentifier)
		calendarTitle = try container.decode(String.self, forKey: .calendarTitle)
		title = try container.decode(String.self, forKey: .title)
		startDate = try container.decode(Date.self, forKey: .startDate)
		endDate = try container.decode(Date.self, forKey: .endDate)
		isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
		location = try container.decodeIfPresent(String.self, forKey: .location)
		notes = try container.decodeIfPresent(String.self, forKey: .notes)
		isRecurring = try container.decodeIfPresent(Bool.self, forKey: .isRecurring) ?? false
	}
}

struct JournalEntry: Identifiable, Codable, Hashable, Sendable {
	private enum CodingKeys: String, CodingKey {
		case id
		case createdAt
		case duration
		case transcript
		case summary
		case headline
		case audioFilename
		case location
		case calendarEvent
		case summaryModel
		case transcriptModel
		case reminders
		case reminderFeedback
		case reminderModel
	}

	let id: UUID
	var createdAt: Date
	var duration: TimeInterval
	var transcript: String
	var summary: String?
	var headline: String
	var audioFilename: String?
	var location: JournalLocation?
	var calendarEvent: JournalCalendarEvent?
	var summaryModel: String?
	var transcriptModel: String?
	var reminders: [EventReminderRule]
	var reminderFeedback: [ReminderFeedback]
	var reminderModel: String?

	init(
		id: UUID = UUID(),
		createdAt: Date = .now,
		duration: TimeInterval,
		transcript: String,
		summary: String? = nil,
		headline: String,
		audioFilename: String? = nil,
		location: JournalLocation? = nil,
		calendarEvent: JournalCalendarEvent? = nil,
		summaryModel: String? = nil,
		transcriptModel: String? = nil,
		reminders: [EventReminderRule] = [],
		reminderFeedback: [ReminderFeedback] = [],
		reminderModel: String? = nil
	) {
		self.id = id
		self.createdAt = createdAt
		self.duration = duration
		self.transcript = transcript
		self.summary = summary
		self.headline = headline
		self.audioFilename = audioFilename
		self.location = location
		self.calendarEvent = calendarEvent
		self.summaryModel = summaryModel
		self.transcriptModel = transcriptModel
		self.reminders = reminders
		self.reminderFeedback = reminderFeedback
		self.reminderModel = reminderModel
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		createdAt = try container.decode(Date.self, forKey: .createdAt)
		duration = try container.decode(TimeInterval.self, forKey: .duration)
		transcript = try container.decode(String.self, forKey: .transcript)
		summary = try container.decodeIfPresent(String.self, forKey: .summary)
		headline = try container.decode(String.self, forKey: .headline)
		audioFilename = try container.decodeIfPresent(String.self, forKey: .audioFilename)
		location = try container.decodeIfPresent(JournalLocation.self, forKey: .location)
		calendarEvent = try container.decodeIfPresent(JournalCalendarEvent.self, forKey: .calendarEvent)
		summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
		transcriptModel = try container.decodeIfPresent(String.self, forKey: .transcriptModel)
		reminders = try container.decodeIfPresent([EventReminderRule].self, forKey: .reminders) ?? []
		reminderFeedback = try container.decodeIfPresent([ReminderFeedback].self, forKey: .reminderFeedback) ?? []
		reminderModel = try container.decodeIfPresent(String.self, forKey: .reminderModel)
	}
}

extension JournalEntry {
	func jsonData() throws -> Data {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}
}

struct WeeklyReview: Sendable {
	var weekStart: Date
	var title: String
	var body: String
	var trend: [Double]
	var outcome: ModelProcessingOutcome = .complete
}

struct ReflectionResult: Sendable {
	var headline: String
	var summary: String?
	var modelName: String
	var outcome: ModelProcessingOutcome = .complete
}

enum EntryProcessingPhase: Equatable, Sendable {
	case finalizing
	case finalizationFailed
	case partial
	case failed
	case canceled
	case transcribing
	case queued
	case reflecting
	case reminders
	case complete

	var title: String {
		switch self {
		case .finalizing: "Preparing audio"
		case .finalizationFailed: "Audio preparation needs retry"
		case .partial: "Transcript incomplete"
		case .failed: "Processing needs retry"
		case .canceled: "Processing paused"
		case .transcribing: "Transcribing"
		case .queued: "Waiting"
		case .reflecting: "Analyzing"
		case .reminders: "Finding reminders"
		case .complete: "Ready"
		}
	}

	var isActive: Bool { ![.finalizationFailed, .partial, .failed, .canceled, .complete].contains(self) }

}

extension JournalEntry {
	static let demo: [JournalEntry] = {
		let calendar = Calendar(identifier: .gregorian)
		let timeZone = TimeZone(identifier: "America/Chicago")!
		func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
			var components = DateComponents()
			components.calendar = calendar
			components.timeZone = timeZone
			components.year = year
			components.month = month
			components.day = day
			components.hour = hour
			components.minute = minute
			return components.date!
		}
		let morningRun = JournalCalendarEvent(
			id: "demo-morning-run",
			externalIdentifier: "demo-morning-run-series",
			calendarIdentifier: "demo-personal",
			calendarTitle: "Personal",
			title: "Morning run",
			startDate: date(2026, 7, 12, 8, 0),
			endDate: date(2026, 7, 12, 9, 0),
			isAllDay: false,
			location: "Lakefront Trail",
			isRecurring: true
		)
		let nextMorningRun = JournalCalendarEvent(
			id: "demo-morning-run-next",
			externalIdentifier: "demo-morning-run-series",
			calendarIdentifier: "demo-personal",
			calendarTitle: "Personal",
			title: "Morning run",
			startDate: date(2026, 7, 26, 8, 0),
			endDate: date(2026, 7, 26, 9, 0),
			isAllDay: false,
			location: "Lakefront Trail",
			isRecurring: true
		)
		let eveningRun = JournalCalendarEvent(
			id: "demo-evening-run",
			calendarIdentifier: "demo-personal",
			calendarTitle: "Personal",
			title: "Evening run",
			startDate: date(2026, 7, 25, 18, 30),
			endDate: date(2026, 7, 25, 19, 30),
			isAllDay: false,
			location: "Lakefront Trail"
		)
		let runSeries = EventSeriesReference(event: morningRun)

		return [
			JournalEntry(
				createdAt: date(2026, 7, 12, 8, 47),
				duration: 94,
				transcript: "The morning run felt good, but I faded early. Next time I should bring electrolytes. I should also ask Maya which dentist she recommended. For morning group runs this month I want to wear the red shorts so they are easy to spot.",
				summary: "The run felt encouraging, with a few concrete preparations you want to carry into the next one.",
				headline: "The run felt good enough to plan for the next one.",
				location: JournalLocation(latitude: 41.8781, longitude: -87.6298, city: "Chicago"),
				calendarEvent: morningRun,
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US",
				reminders: [
					EventReminderRule(
						text: "Bring electrolytes",
						motivation: "You faded early during the last run.",
						evidence: "Next time I should bring electrolytes.",
						selector: .series(runSeries),
						occurrencePolicy: .everyMatch,
						createdAt: date(2026, 7, 12, 8, 47)
					),
					EventReminderRule(
						text: "Ask Maya which dentist she recommended",
						motivation: "You wanted to follow up with Maya at the next run.",
						evidence: "I should also ask Maya which dentist she recommended.",
						selector: .series(runSeries),
						occurrencePolicy: .nextMatch,
						createdAt: date(2026, 7, 12, 8, 47)
					),
					EventReminderRule(
						text: "Wear the red shorts",
						motivation: "You want them to be easy to spot at morning group runs.",
						evidence: "For morning group runs this month I want to wear the red shorts.",
						selector: .fuzzy(FuzzyEventSelector(
							semanticDescription: "group run",
							timeBucket: .morning,
							locationDescription: nil,
							examples: [
								ReminderMatchExample(
									event: nextMorningRun,
									matches: true,
									reason: "A morning group run."
								),
								ReminderMatchExample(
									event: eveningRun,
									matches: false,
									reason: "The event is in the evening."
								)
							]
						)),
						occurrencePolicy: .everyMatch,
						createdAt: date(2026, 7, 12, 8, 47),
						expiresAt: date(2026, 8, 12, 8, 47)
					)
				],
				reminderModel: "SystemLanguageModel.default · guided"
			),
			JournalEntry(
				createdAt: date(2026, 7, 12, 7, 21),
				duration: 58,
				transcript: "I need to plan the day before it gets away from me. The review is first, then lunch, then I can finish the draft.",
				summary: "You mapped out the review, lunch, and draft so the day would not get away from you.",
				headline: "Planning the day",
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			),
			JournalEntry(
				createdAt: date(2026, 7, 11, 22, 25),
				duration: 312,
				transcript: "The Figma review went long again and I spent the afternoon redoing the deck instead of the work that’s due Friday. I keep saying yes to everything and then it’s six p.m.",
				summary: "The review and deck revisions consumed the afternoon while your own Friday work kept moving later.",
				headline: "You keep calling everyone else’s work urgent and your own the thing that can wait.",
				location: JournalLocation(latitude: 41.8781, longitude: -87.6298, city: "Chicago"),
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			),
			JournalEntry(
				createdAt: date(2026, 7, 10, 21, 42),
				duration: 187,
				transcript: "The apartment stopped being the moment it became a choice you were making together.",
				summary: "The apartment mattered less as a place than as a decision you were making together.",
				headline: "The apartment stopped being the moment it became a choice you were making together.",
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			)
		]
	}()
}

extension WeeklyReview {
	static let demo = WeeklyReview(
		weekStart: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 29))!,
		title: "The week kept disappearing into other people’s asks",
		body: "You started the week behind and mostly talked about time. Who took it, where it went. The Figma review on Tuesday and the deck revisions on Wednesday were the same story told twice: you said yes, the afternoon vanished, and the work you cared about moved to tomorrow. But Thursday morning sounded different. The run came back, and with it a sentence you haven’t said in a while. Feeling like a person again. The contrast is worth noticing: the days you resented were the ones structured around other people’s requests, and the day you liked started with twenty minutes that were only yours.",
		trend: [0.55, 0.38, 0.31, 0.43, 0.68]
	)
}

extension Date {
	func startOfWeek(using calendar: Calendar = .current) -> Date {
		let start = calendar.dateInterval(of: .weekOfYear, for: self)?.start ?? self
		return calendar.startOfDay(for: start)
	}
}
