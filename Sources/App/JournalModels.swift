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
	var id: String
	var calendarIdentifier: String
	var calendarTitle: String
	var title: String
	var startDate: Date
	var endDate: Date
	var isAllDay: Bool
}

struct JournalEntry: Identifiable, Codable, Hashable, Sendable {
	let id: UUID
	var createdAt: Date
	var duration: TimeInterval
	var transcript: String
	var headline: String
	var observations: [String]
	var audioFilename: String?
	var location: JournalLocation?
	var calendarEvent: JournalCalendarEvent?
	var summaryModel: String?
	var transcriptModel: String?

	init(
		id: UUID = UUID(),
		createdAt: Date = .now,
		duration: TimeInterval,
		transcript: String,
		headline: String,
		observations: [String],
		audioFilename: String? = nil,
		location: JournalLocation? = nil,
		calendarEvent: JournalCalendarEvent? = nil,
		summaryModel: String? = nil,
		transcriptModel: String? = nil
	) {
		self.id = id
		self.createdAt = createdAt
		self.duration = duration
		self.transcript = transcript
		self.headline = headline
		self.observations = observations
		self.audioFilename = audioFilename
		self.location = location
		self.calendarEvent = calendarEvent
		self.summaryModel = summaryModel
		self.transcriptModel = transcriptModel
	}
}

struct WeeklyReview: Sendable {
	var weekStart: Date
	var title: String
	var body: String
	var trend: [Double]
}

struct ReflectionResult: Sendable {
	var headline: String
	var observations: [String]
	var modelName: String
}

enum EntryProcessingPhase: Equatable, Sendable {
	case transcribing
	case reflecting
	case complete

	var title: String {
		switch self {
		case .transcribing: "Transcribing"
		case .reflecting: "Creating title"
		case .complete: "Ready"
		}
	}

	var compactTitle: String {
		switch self {
		case .transcribing: "Transcribing"
		case .reflecting: "Creating title"
		case .complete: "Ready"
		}
	}
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

		return [
			JournalEntry(
				createdAt: date(2026, 7, 12, 8, 47),
				duration: 94,
				transcript: "The morning run felt good. I keep wondering if coming back to it means I am finally feeling like myself again.",
				headline: "You’re letting one good run stand in for feeling like yourself again.",
				observations: [
					"The morning run felt good, and you gave it more meaning than the run itself.",
					"You sounded relieved to recognize a familiar part of yourself again.",
					"One good morning became evidence that something larger may be shifting."
				],
				location: JournalLocation(latitude: 41.8781, longitude: -87.6298, city: "Chicago"),
				calendarEvent: JournalCalendarEvent(
					id: "demo-morning-run",
					calendarIdentifier: "demo-personal",
					calendarTitle: "Personal",
					title: "Morning run",
					startDate: date(2026, 7, 12, 8, 0),
					endDate: date(2026, 7, 12, 9, 0),
					isAllDay: false
				),
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			),
			JournalEntry(
				createdAt: date(2026, 7, 12, 7, 21),
				duration: 58,
				transcript: "I need to plan the day before it gets away from me. The review is first, then lunch, then I can finish the draft.",
				headline: "Planning the day",
				observations: ["You were trying to give the day a shape before other people did."],
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			),
			JournalEntry(
				createdAt: date(2026, 7, 11, 22, 25),
				duration: 312,
				transcript: "The Figma review went long again and I spent the afternoon redoing the deck instead of the work that’s due Friday. I keep saying yes to everything and then it’s six p.m.",
				headline: "You keep calling everyone else’s work urgent and your own the thing that can wait.",
				observations: [
					"You keep calling everyone else’s work urgent and your own the thing that can wait.",
					"Six p.m. arrives in your telling like weather, not like a series of yeses.",
					"The deck got redone; the work that’s due Friday got talked about."
				],
				location: JournalLocation(latitude: 41.8781, longitude: -87.6298, city: "Chicago"),
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			),
			JournalEntry(
				createdAt: date(2026, 7, 10, 21, 42),
				duration: 187,
				transcript: "The apartment stopped being the moment it became a choice you were making together.",
				headline: "The apartment stopped being the moment it became a choice you were making together.",
				observations: ["You sounded less interested in the place than in what choosing it would mean."],
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
