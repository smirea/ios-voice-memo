import Foundation

struct JournalEntry: Identifiable, Codable, Hashable, Sendable {
	let id: UUID
	var createdAt: Date
	var duration: TimeInterval
	var transcript: String
	var headline: String
	var observations: [String]
	var tags: [String]
	var audioFilename: String?
	var context: String?

	init(
		id: UUID = UUID(),
		createdAt: Date = .now,
		duration: TimeInterval,
		transcript: String,
		headline: String,
		observations: [String],
		tags: [String],
		audioFilename: String? = nil,
		context: String? = nil
	) {
		self.id = id
		self.createdAt = createdAt
		self.duration = duration
		self.transcript = transcript
		self.headline = headline
		self.observations = observations
		self.tags = tags
		self.audioFilename = audioFilename
		self.context = context
	}
}

struct WeeklyReview: Sendable {
	var weekStart: Date
	var title: String
	var body: String
	var tags: [String]
	var trend: [Double]
}

struct ReflectionResult: Sendable {
	var headline: String
	var observations: [String]
	var tags: [String]
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
				tags: ["The Morning Run", "Coming Back To A Habit"]
			),
			JournalEntry(
				createdAt: date(2026, 7, 12, 7, 21),
				duration: 58,
				transcript: "I need to plan the day before it gets away from me. The review is first, then lunch, then I can finish the draft.",
				headline: "Planning the day",
				observations: ["You were trying to give the day a shape before other people did."],
				tags: []
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
				tags: ["The Figma Review", "Saying Yes Too Much", "Friday Deadline"]
			),
			JournalEntry(
				createdAt: date(2026, 7, 10, 21, 42),
				duration: 187,
				transcript: "The apartment stopped being the moment it became a choice you were making together.",
				headline: "The apartment stopped being the moment it became a choice you were making together.",
				observations: ["You sounded less interested in the place than in what choosing it would mean."],
				tags: ["The Apartment", "Choosing Together"]
			)
		]
	}()
}

extension WeeklyReview {
	static let demo = WeeklyReview(
		weekStart: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 29))!,
		title: "The week kept disappearing into other people’s asks",
		body: "You started the week behind and mostly talked about time. Who took it, where it went. The Figma review on Tuesday and the deck revisions on Wednesday were the same story told twice: you said yes, the afternoon vanished, and the work you cared about moved to tomorrow. But Thursday morning sounded different. The run came back, and with it a sentence you haven’t said in a while. Feeling like a person again. The contrast is worth noticing: the days you resented were the ones structured around other people’s requests, and the day you liked started with twenty minutes that were only yours.",
		tags: ["Time given away, rising through the week", "The run came back, and it mattered", "Friday’s deadline, still circling"],
		trend: [0.55, 0.38, 0.31, 0.43, 0.68]
	)
}

extension Date {
	func startOfWeek(using calendar: Calendar = .current) -> Date {
		let start = calendar.dateInterval(of: .weekOfYear, for: self)?.start ?? self
		return calendar.startOfDay(for: start)
	}
}
