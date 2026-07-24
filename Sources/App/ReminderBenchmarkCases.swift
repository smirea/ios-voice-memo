import Foundation

struct ReminderBenchmarkGroup: Identifiable {
	var id: String
	var title: String
	var level: Int
	var detail: String
	var cases: [ReminderBenchmarkCase]
}

enum ReminderBenchmarkCase {
	case parsing(ReminderParsingBenchmarkCase)
	case feedback(ReminderFeedbackBenchmarkCase)
	case resolution(ReminderResolutionBenchmarkCase)

	var name: String {
		switch self {
		case let .parsing(test): test.name
		case let .feedback(test): test.name
		case let .resolution(test): test.name
		}
	}
}

struct ReminderParsingBenchmarkCase {
	var name: String
	var sourceEvent: JournalCalendarEvent?
	var transcript: String
	var expected: [ExpectedReminderCue]
}

struct ReminderFeedbackBenchmarkCase {
	var name: String
	var sourceEvent: JournalCalendarEvent
	var transcript: String
	var current: [EventReminderRule]
	var feedback: [ReminderFeedback]
	var expected: [ExpectedReminderCue]
}

struct ReminderResolutionBenchmarkCase {
	var name: String
	var sourceEvent: JournalCalendarEvent
	var rule: EventReminderRule
	var events: [JournalCalendarEvent]
	var expectedEventIDs: Set<String>
}

enum ExpectedReminderSelectorKind: String {
	case occurrence
	case series
	case fuzzy
}

struct ExpectedReminderCue {
	var key: String
	var actionTerms: [String]
	var selectorKind: ExpectedReminderSelectorKind
	var policy: EventReminderOccurrencePolicy
	var timeBucket: EventReminderTimeBucket?
	var expiryDays: ClosedRange<Int>?
	var eventTerms: [String]
	var locationTerms: [String]

	init(
		_ key: String,
		_ actionTerms: [String],
		_ selectorKind: ExpectedReminderSelectorKind,
		_ policy: EventReminderOccurrencePolicy,
		_ timeBucket: EventReminderTimeBucket? = nil,
		_ expiryDays: ClosedRange<Int>? = nil,
		eventTerms: [String] = [],
		locationTerms: [String] = []
	) {
		self.key = key
		self.actionTerms = actionTerms
		self.selectorKind = selectorKind
		self.policy = policy
		self.timeBucket = timeBucket
		self.expiryDays = expiryDays
		self.eventTerms = eventTerms
		self.locationTerms = locationTerms
	}
}

enum ReminderBenchmarkCorpus {
	static let createdAt = Date(timeIntervalSince1970: 1_769_976_000)

	static var groups: [ReminderBenchmarkGroup] {
		[
			directCues,
			precisionBoundaries,
			schedulingAndTargeting,
			naturalSpeech,
			denseAndAdversarial,
			feedbackReprocessing,
			fuzzyResolution
		]
	}

	static var caseCount: Int {
		groups.reduce(0) { $0 + $1.cases.count }
	}

	private static var directCues: ReminderBenchmarkGroup {
		ReminderBenchmarkGroup(
			id: "direct",
			title: "Direct cues",
			level: 1,
			detail: "Clear, explicit reminders with simple event targets.",
			cases: [
				parse("Next gym hydration", .gym, "At the next gym session, bring electrolytes.", [
					cue("electrolytes", ["bring", "electrolytes"], .series, .nextMatch)
				]),
				parse("Recurring gym towel", .gym, "Bring a clean towel to every gym session from now on.", [
					cue("towel", ["clean", "towel"], .series, .everyMatch)
				]),
				parse("Next improv pause", .improv, "Next improv class, pause for one beat before answering.", [
					cue("pause", ["pause", "beat"], .series, .nextMatch)
				]),
				parse("Recurring standup metric", .standup, "For every team standup, bring the latest activation metric.", [
					cue("metric", ["activation", "metric"], .series, .everyMatch)
				]),
				parse("Remember group details", .meetup, "Next time I see this group, remember Alice plays green and Ben is the host.", [
					cue("people", ["alice", "ben"], .series, .nextMatch)
				]),
				parse("Every work meeting", .standup, "Before every work meeting, take one breath and look at the agenda.", [
					cue("breath", ["breath", "agenda"], .fuzzy, .everyMatch, eventTerms: ["work", "meeting"])
				]),
				parse("Morning gaming month", .meetup, "For the next month, wear red pants at every morning gaming event.", [
					cue("red", ["red", "pants"], .fuzzy, .everyMatch, .morning, 27...32, eventTerms: ["gaming"])
				]),
				parse("Two distinct next actions", .gym, "At the next gym session, bring water and ask Maya about the stretching class.", [
					cue("water", ["bring", "water"], .series, .nextMatch),
					cue("Maya", ["ask", "maya", "stretching"], .series, .nextMatch)
				])
			]
		)
	}

	private static var precisionBoundaries: ReminderBenchmarkGroup {
		ReminderBenchmarkGroup(
			id: "boundaries",
			title: "Precision boundaries",
			level: 2,
			detail: "Material that should not consume attention as an event reminder.",
			cases: [
				parse("General tasks only", .gym, "I need to schedule a dentist appointment, buy groceries, renew my passport, and call Mom sometime.", []),
				parse("Retrospective observations", .improv, "The warmup was long. Dana was funny. I felt nervous at first and relaxed near the end.", []),
				parse("Explicit negation", .gym, "Do not remind me about electrolytes next time, and I do not need a packing cue.", []),
				parse("Another person’s intention", .gym, "Rob said he needs to bring electrolytes and call his dentist before next week. I do not have anything to remember.", []),
				parse("Hypothetical without commitment", .gym, "If I ever joined the morning class I would probably bring coffee, but I am not planning to.", []),
				parse("Advice given to someone else", .improv, "I told Mia she should pause before answering at her next improv class.", []),
				parse("Quoted coach instruction", .improv, "The coach said, remember to make eye contact next time. That was advice for the beginners, not me.", []),
				parse("Canceled idea", .gym, "I should bring a towel next time—actually no, the gym supplies towels, so forget that.", []),
				parse("Event-free habit", .gym, "I should drink more water every day and sleep eight hours.", []),
				parse("Too vague to focus", .improv, "I should just do better next time, somehow.", []),
				parse("Suggestion about event organizer", .meetup, "Maybe they should start every meetup earlier because the room gets crowded.", []),
				parse("Explicit empty intent", .standup, "Nothing to remember for the next standup. The meeting was fine.", [])
			]
		)
	}

	private static var schedulingAndTargeting: ReminderBenchmarkGroup {
		ReminderBenchmarkGroup(
			id: "schedule",
			title: "Scheduling and targeting",
			level: 3,
			detail: "One-time versus standing policy, fuzzy targets, time, venue, and expiry.",
			cases: [
				parse("Recurring source does not imply repetition", .gym, "At the next gym session, bring the lifting straps.", [
					cue("straps", ["lifting", "straps"], .series, .nextMatch)
				]),
				parse("Explicit standing series", .gym, "Going forward, bring the lifting straps to gym sessions.", [
					cue("straps", ["lifting", "straps"], .series, .everyMatch)
				]),
				parse("Six-week validity", .standup, "For the next six weeks, bring the activation metric to every team standup.", [
					cue("metric", ["activation", "metric"], .series, .everyMatch, nil, 41...43)
				]),
				parse("Forty-five-day validity", .gym, "For 45 days, use the blue locker at every gym session.", [
					cue("locker", ["blue", "locker"], .series, .everyMatch, nil, 44...46)
				]),
				parse("Afternoon workshop rule", .improv, "For the next month, bring the notebook to afternoon acting workshops.", [
					cue("notebook", ["bring", "notebook"], .fuzzy, .everyMatch, .afternoon, 27...32, eventTerms: ["acting", "workshop"])
				]),
				parse("Required venue", .meetup, "At tabletop meetups at Dice Dojo this month, wear the orange name tag.", [
					cue("tag", ["orange", "name", "tag"], .fuzzy, .everyMatch, .any, 27...32, eventTerms: ["tabletop", "meetup"], locationTerms: ["dice", "dojo"])
				]),
				parse("Changing imported titles", .meetup, "For Sunday tabletop meetups at Dice Dojo this month, wear the orange name tag even if Meetup changes the event title.", [
					cue("tag", ["orange", "name", "tag"], .fuzzy, .everyMatch, .any, 27...32, eventTerms: ["tabletop", "meetup"], locationTerms: ["dice", "dojo"])
				]),
				parse("Broader client calls", .standup, "Before every client call, open the account notes.", [
					cue("account", ["account", "notes"], .fuzzy, .everyMatch, eventTerms: ["client", "call"])
				]),
				parse("Different event class once", .gym, "At the next yoga class, bring the green mat.", [
					cue("mat", ["green", "mat"], .fuzzy, .nextMatch, eventTerms: ["yoga", "class"])
				]),
				parse("Named fuzzy event once", .meetup, "For the next board game meetup, bring card sleeves.", [
					cue("sleeves", ["card", "sleeves"], .fuzzy, .nextMatch, eventTerms: ["board", "game", "meetup"])
				]),
				parse("Indefinite attached standing cue", .improv, "From now on at improv class, learn everyone’s name before scenes start.", [
					cue("names", ["learn", "name"], .series, .everyMatch)
				]),
				parse("Evening campaign month", .meetup, "During the next month of evening role-playing sessions, bring the character binder.", [
					cue("binder", ["character", "binder"], .fuzzy, .everyMatch, .evening, 27...32, eventTerms: ["role", "playing", "session"])
				])
			]
		)
	}

	private static var naturalSpeech: ReminderBenchmarkGroup {
		ReminderBenchmarkGroup(
			id: "speech",
			title: "Natural speech",
			level: 4,
			detail: "Fillers, repairs, pronouns, indirect intent, repetition, and weak punctuation.",
			cases: [
				parse("Filler and self-correction", .improv, "Um, so next time I should, no, not speak louder. What I actually want is to make eye contact before starting the scene.", [
					cue("eye contact", ["eye", "contact"], .series, .nextMatch)
				]),
				parse("Duplicate phrasing", .gym, "Bring electrolytes next time. I mean, next gym session remember electrolytes. Yes, just one reminder to bring electrolytes.", [
					cue("electrolytes", ["electrolytes"], .series, .nextMatch)
				]),
				parse("Punctuationless transcription", .gym, "okay next gym i guess bring the small towel and uh leave the big bottle at home", [
					cue("towel", ["small", "towel"], .series, .nextMatch),
					cue("bottle", ["leave", "bottle", "home"], .series, .nextMatch)
				]),
				parse("Pronoun carries event class", .meetup, "For the next month of gaming, wear red pants in the morning. If it starts in the evening, wear the blue shirt.", [
					cue("red", ["red", "pants"], .fuzzy, .everyMatch, .morning, 27...32, eventTerms: ["gaming"]),
					cue("blue", ["blue", "shirt"], .fuzzy, .everyMatch, .evening, 27...32, eventTerms: ["gaming"])
				]),
				parse("Elliptical second condition", .meetup, "At morning gaming events this month, wear red pants. Same deal in the evening, except use the blue shirt.", [
					cue("red", ["red", "pants"], .fuzzy, .everyMatch, .morning, 27...32, eventTerms: ["gaming"]),
					cue("blue", ["blue", "shirt"], .fuzzy, .everyMatch, .evening, 27...32, eventTerms: ["gaming"])
				]),
				parse("Three people in one memory cue", .meetup, "Next time with this group, keep in mind Alice plays green, Ben hosts, and Priya likes cooperative games.", [
					cue("people", ["alice", "ben", "priya"], .series, .nextMatch)
				]),
				parse("Hedged but affirmative", .improv, "I think maybe next class I should try pausing before I answer.", [
					cue("pause", ["pausing", "answer"], .series, .nextMatch)
				]),
				parse("Note to self idiom", .gym, "Note to self for Thursday gym: pack the wrist wraps.", [
					cue("wraps", ["wrist", "wraps"], .series, .nextMatch)
				]),
				parse("Cannot forget idiom", .standup, "I can’t forget the churn chart at next week’s standup.", [
					cue("chart", ["churn", "chart"], .series, .nextMatch)
				]),
				parse("Future-me phrasing", .improv, "Future me will have a better class if I look at my scene partner before speaking.", [
					cue("look", ["look", "partner"], .series, .nextMatch)
				]),
				parse("Save this thought", .meetup, "Save this for the next game night: ask Noor which expansion she mentioned.", [
					cue("Noor", ["ask", "noor", "expansion"], .fuzzy, .nextMatch, eventTerms: ["game", "night"])
				]),
				parse("Detour before the cue", .gym, "The music was too loud and Rob changed jobs. Anyway, from now on bring earplugs to these gym sessions.", [
					cue("earplugs", ["bring", "earplugs"], .series, .everyMatch)
				])
			]
		)
	}

	private static var denseAndAdversarial: ReminderBenchmarkGroup {
		ReminderBenchmarkGroup(
			id: "dense",
			title: "Dense and adversarial",
			level: 5,
			detail: "Several intents, distractions, ownership changes, and conflicting language.",
			cases: [
				parse(
					"Mixed gym and gaming memo",
					.gym,
					"I went to the gym and was tired. From now on I should bring electrolytes to these gym sessions. I talked to Rob and he is cool. He told me he went to the dentist, which reminds me I should schedule a dentist appointment. At the next gym session I should ask Rob who his dentist is. For the next month, at gaming events in the morning wear red pants, and at gaming events in the evening wear a blue shirt.",
					[
						cue("electrolytes", ["electrolytes"], .series, .everyMatch),
						cue("Rob", ["ask", "rob", "dentist"], .series, .nextMatch),
						cue("red", ["red", "pants"], .fuzzy, .everyMatch, .morning, 27...32, eventTerms: ["gaming"]),
						cue("blue", ["blue", "shirt"], .fuzzy, .everyMatch, .evening, 27...32, eventTerms: ["gaming"])
					]
				),
				parse("Two semantic event classes", .meetup, "At future board game meetups bring the card sleeves. At role-playing campaign sessions bring the character binder.", [
					cue("sleeves", ["card", "sleeves"], .fuzzy, .everyMatch, eventTerms: ["board", "game", "meetup"]),
					cue("binder", ["character", "binder"], .fuzzy, .everyMatch, eventTerms: ["role", "playing", "session"])
				]),
				parse("Three time buckets", .meetup, "For one month of gaming events: in the morning wear red pants, in the afternoon wear the green hat, and in the evening wear the blue shirt.", [
					cue("red", ["red", "pants"], .fuzzy, .everyMatch, .morning, 27...32, eventTerms: ["gaming"]),
					cue("green", ["green", "hat"], .fuzzy, .everyMatch, .afternoon, 27...32, eventTerms: ["gaming"]),
					cue("blue", ["blue", "shirt"], .fuzzy, .everyMatch, .evening, 27...32, eventTerms: ["gaming"])
				]),
				parse("Past present and future collide", .gym, "I brought electrolytes today, I am holding them now, and next time I want to bring the smaller lemon packets instead.", [
					cue("packets", ["smaller", "lemon", "packets"], .series, .nextMatch)
				]),
				parse("Ownership switches", .gym, "Rob wants to bring a towel every week, Maya needs to call her trainer, and I want to bring wrist wraps to the next gym session.", [
					cue("wraps", ["wrist", "wraps"], .series, .nextMatch)
				]),
				parse("Inline correction changes object", .improv, "Next class bring the red notebook—sorry, not the red one, bring the thin blue notebook.", [
					cue("notebook", ["thin", "blue", "notebook"], .series, .nextMatch)
				]),
				parse("Long distraction around one cue", .standup, "The train was late, lunch was good, our conversion chart looked strange, and I forgot Sam’s dog’s name. The only useful cue for next standup is to bring the churn chart.", [
					cue("chart", ["churn", "chart"], .series, .nextMatch)
				]),
				parse("Names colors and preferences", .meetup, "At the next meetup remember Alice uses green, Ben uses yellow, Priya uses blue, and Noor does not want the cooperative game.", [
					cue("Alice", ["alice", "green"], .fuzzy, .nextMatch, eventTerms: ["meetup"]),
					cue("Ben", ["ben", "yellow"], .fuzzy, .nextMatch, eventTerms: ["meetup"]),
					cue("Priya", ["priya", "blue"], .fuzzy, .nextMatch, eventTerms: ["meetup"]),
					cue("Noor", ["noor", "cooperative"], .fuzzy, .nextMatch, eventTerms: ["meetup"])
				]),
				parse("Different policies in one memo", .improv, "Next class ask Dana about the showcase. Going forward, take one breath before every scene.", [
					cue("Dana", ["ask", "dana", "showcase"], .series, .nextMatch),
					cue("breath", ["breath", "scene"], .series, .everyMatch)
				]),
				parse("Negated object with positive replacement", .gym, "Next gym, do not bring plain water; bring electrolytes instead.", [
					cue("electrolytes", ["bring", "electrolytes"], .series, .nextMatch)
				])
			]
		)
	}

	private static var feedbackReprocessing: ReminderBenchmarkGroup {
		let gym = event(.gym)
		let series = EventSeriesReference(event: gym)
		let electrolytes = rule(
			"Bring electrolytes",
			.series(series),
			.everyMatch,
			evidence: "Bring electrolytes to gym sessions."
		)
		let dentist = rule(
			"Ask Rob who his dentist is",
			.series(series),
			.nextMatch,
			evidence: "At the next gym session ask Rob who his dentist is."
		)
		let towel = rule(
			"Bring a clean towel",
			.series(series),
			.everyMatch,
			evidence: "Bring a clean towel to every gym session."
		)
		let redMorning = rule(
			"Wear red pants",
			.fuzzy(FuzzyEventSelector(
				semanticDescription: "gaming event",
				timeBucket: .morning,
				locationDescription: nil,
				examples: []
			)),
			.everyMatch,
			evidence: "Wear red pants at morning gaming events."
		)
		let transcript = "Bring electrolytes to gym sessions. At the next gym session ask Rob who his dentist is. Wear red pants at morning gaming events."

		return ReminderBenchmarkGroup(
			id: "feedback",
			title: "Feedback reprocessing",
			level: 6,
			detail: "Voice corrections and manual removals must replace the prior reminder set.",
			cases: [
				feedback("Remove one and keep one", gym, transcript, [electrolytes, dentist], [
					ReminderFeedback(kind: .voice, text: "Remove the dentist reminder, but keep the electrolytes reminder.")
				], [
					cue("electrolytes", ["electrolytes"], .series, .everyMatch)
				]),
				feedback("Add a missed cue", gym, "Bring electrolytes to gym sessions.", [electrolytes], [
					ReminderFeedback(kind: .voice, text: "You missed that I want to ask Rob about his dentist next time.")
				], [
					cue("electrolytes", ["electrolytes"], .series, .everyMatch),
					cue("Rob", ["ask", "rob", "dentist"], .series, .nextMatch)
				]),
				feedback("Correct fuzzy time", gym, transcript, [redMorning], [
					ReminderFeedback(kind: .voice, text: "The red pants are for evening gaming events, not morning events.")
				], [
					cue("red", ["red", "pants"], .fuzzy, .everyMatch, .evening, eventTerms: ["gaming"])
				]),
				feedback("Manual removal remains removed", gym, transcript, [dentist, redMorning], [
					ReminderFeedback(kind: .manualRemoval, text: "Keep removed: Bring electrolytes")
				], [
					cue("Rob", ["ask", "rob", "dentist"], .series, .nextMatch),
					cue("red", ["red", "pants"], .fuzzy, .everyMatch, .morning, eventTerms: ["gaming"])
				]),
				feedback("Change standing cue to once", gym, "Bring a clean towel to every gym session.", [towel], [
					ReminderFeedback(kind: .voice, text: "Actually, only remind me to bring the towel at the next gym session.")
				], [
					cue("towel", ["towel"], .series, .nextMatch)
				]),
				feedback("Change expiry", gym, "For the next month, wear red pants at morning gaming events.", [redMorning], [
					ReminderFeedback(kind: .voice, text: "Make the red pants reminder last two weeks, not one month.")
				], [
					cue("red", ["red", "pants"], .fuzzy, .everyMatch, .morning, 13...15, eventTerms: ["gaming"])
				]),
				feedback("Replace an action", gym, "Bring a clean towel to every gym session.", [towel], [
					ReminderFeedback(kind: .voice, text: "Replace the towel reminder with: bring the gray sweatband to every gym session.")
				], [
					cue("sweatband", ["gray", "sweatband"], .series, .everyMatch)
				]),
				feedback("Remove all cues", gym, transcript, [electrolytes, dentist, redMorning], [
					ReminderFeedback(kind: .voice, text: "Remove all three reminders. I do not want any event cues from this memo.")
				], [])
			]
		)
	}

	private static var fuzzyResolution: ReminderBenchmarkGroup {
		let source = event(.meetup)
		let morningGaming = rule(
			"Wear red pants",
			.fuzzy(FuzzyEventSelector(
				semanticDescription: "gaming event",
				timeBucket: .morning,
				locationDescription: nil,
				examples: []
			)),
			.everyMatch
		)
		let diceMeetup = rule(
			"Wear the orange name tag",
			.fuzzy(FuzzyEventSelector(
				semanticDescription: "tabletop gaming meetup",
				timeBucket: .any,
				locationDescription: "Dice Dojo",
				examples: []
			)),
			.everyMatch
		)
		let improv = rule(
			"Pause before answering",
			.fuzzy(FuzzyEventSelector(
				semanticDescription: "improv practice or class",
				timeBucket: .any,
				locationDescription: nil,
				examples: []
			)),
			.everyMatch
		)
		let rolePlaying = rule(
			"Bring the character binder",
			.fuzzy(FuzzyEventSelector(
				semanticDescription: "tabletop role-playing campaign session",
				timeBucket: .any,
				locationDescription: nil,
				examples: []
			)),
			.everyMatch
		)
		let clientCall = rule(
			"Open account notes",
			.fuzzy(FuzzyEventSelector(
				semanticDescription: "client call",
				timeBucket: .any,
				locationDescription: nil,
				examples: []
			)),
			.everyMatch
		)

		let morningGame = candidate("morning-game", "Board Games Brunch", 2, 10, "Cafe", "Open gaming")
		let eveningGame = candidate("evening-game", "Board Games Night", 2, 19, "Cafe", "Open gaming")
		let morningPlanning = candidate("morning-planning", "Quarterly planning", 2, 9, "Office", nil)
		let diceBoardGames = candidate("dice-board-games", "Sunday Social #42", 3, 13, "Dice Dojo", "Tabletop games via Meetup")
		let diceChess = candidate("dice-chess", "Chess study", 3, 15, "Dice Dojo", "Tournament preparation")
		let libraryTabletop = candidate("library-tabletop", "Tabletop Meetup", 3, 13, "Public Library", "Board games")
		let sceneLab = candidate("scene-lab", "Scene work lab", 4, 18, "Theater", "Improv practice")
		let comedyShow = candidate("comedy-show", "Friday comedy show", 4, 20, "Theater", "Audience tickets")
		let improvClass = candidate("improv-class", "Improv 201", 5, 19, "Theater", "Class")
		let ttrpg = candidate("ttrpg", "Thursday TTRPG", 6, 19, "Home", "Continue the campaign")
		let videoGame = candidate("video-game", "Online gaming", 6, 19, nil, "Co-op video games")
		let accountReview = candidate("account-review", "Acme quarterly review", 7, 14, nil, "Video call with client")
		let internalReview = candidate("internal-review", "Quarterly review", 7, 15, nil, "Internal planning")
		let vagueSocial = candidate("vague-social", "Sunday Social", 8, 13, "Dice Dojo", nil)

		return ReminderBenchmarkGroup(
			id: "resolution",
			title: "Fuzzy event resolution",
			level: 7,
			detail: "Candidate titles, notes, venues, abbreviations, near misses, and time filters.",
			cases: [
				resolution("Time bucket plus semantic type", source, morningGaming, [morningGame, eveningGame, morningPlanning], ["morning-game"]),
				resolution("Variable title and required venue", source, diceMeetup, [diceBoardGames, diceChess, libraryTabletop], ["dice-board-games"]),
				resolution("Notes reveal improv", source, improv, [sceneLab, comedyShow, improvClass], ["scene-lab", "improv-class"]),
				resolution("Abbreviation and campaign context", source, rolePlaying, [ttrpg, videoGame], ["ttrpg"]),
				resolution("Deterministic evening exclusion", source, morningGaming, [eveningGame], []),
				resolution("Client type appears in notes", source, clientCall, [accountReview, internalReview], ["account-review"]),
				resolution("Venue alone is insufficient", source, diceMeetup, [diceChess, vagueSocial], []),
				resolution("Matching type at wrong venue", source, diceMeetup, [libraryTabletop], []),
				resolution("Multiple clear morning games", source, morningGaming, [
					morningGame,
					candidate("morning-chess", "Casual Chess Morning", 9, 9, "Cafe", "Open tabletop gaming")
				], ["morning-game", "morning-chess"]),
				resolution("Semantic near miss stays excluded", source, rolePlaying, [
					videoGame,
					candidate("book-club", "Fantasy Book Club", 9, 19, "Library", "Discuss characters and campaign themes")
				], [])
			]
		)
	}

	private enum FixtureEvent {
		case gym
		case improv
		case meetup
		case standup
	}

	private static func parse(
		_ name: String,
		_ fixture: FixtureEvent?,
		_ transcript: String,
		_ expected: [ExpectedReminderCue]
	) -> ReminderBenchmarkCase {
		.parsing(ReminderParsingBenchmarkCase(
			name: name,
			sourceEvent: fixture.map(event),
			transcript: transcript,
			expected: expected
		))
	}

	private static func feedback(
		_ name: String,
		_ sourceEvent: JournalCalendarEvent,
		_ transcript: String,
		_ current: [EventReminderRule],
		_ feedback: [ReminderFeedback],
		_ expected: [ExpectedReminderCue]
	) -> ReminderBenchmarkCase {
		.feedback(ReminderFeedbackBenchmarkCase(
			name: name,
			sourceEvent: sourceEvent,
			transcript: transcript,
			current: current,
			feedback: feedback,
			expected: expected
		))
	}

	private static func resolution(
		_ name: String,
		_ sourceEvent: JournalCalendarEvent,
		_ rule: EventReminderRule,
		_ events: [JournalCalendarEvent],
		_ expectedEventIDs: Set<String>
	) -> ReminderBenchmarkCase {
		.resolution(ReminderResolutionBenchmarkCase(
			name: name,
			sourceEvent: sourceEvent,
			rule: rule,
			events: events,
			expectedEventIDs: expectedEventIDs
		))
	}

	private static func cue(
		_ key: String,
		_ actionTerms: [String],
		_ selectorKind: ExpectedReminderSelectorKind,
		_ policy: EventReminderOccurrencePolicy,
		_ timeBucket: EventReminderTimeBucket? = nil,
		_ expiryDays: ClosedRange<Int>? = nil,
		eventTerms: [String] = [],
		locationTerms: [String] = []
	) -> ExpectedReminderCue {
		ExpectedReminderCue(
			key,
			actionTerms,
			selectorKind,
			policy,
			timeBucket,
			expiryDays,
			eventTerms: eventTerms,
			locationTerms: locationTerms
		)
	}

	private static func event(_ fixture: FixtureEvent) -> JournalCalendarEvent {
		switch fixture {
		case .gym:
			sourceEvent("gym-source", "Thursday gym", 18, "West Loop Fitness", true)
		case .improv:
			sourceEvent("improv-source", "Improv class", 19, "Theater", true)
		case .meetup:
			sourceEvent("meetup-source", "Sunday Board Games", 10, "Dice Dojo", false)
		case .standup:
			sourceEvent("standup-source", "Team standup", 9, nil, true)
		}
	}

	private static func sourceEvent(
		_ id: String,
		_ title: String,
		_ hour: Int,
		_ location: String?,
		_ isRecurring: Bool
	) -> JournalCalendarEvent {
		JournalCalendarEvent(
			id: id,
			externalIdentifier: isRecurring ? "\(id)-series" : nil,
			calendarIdentifier: "benchmark",
			calendarTitle: "Benchmark",
			title: title,
			startDate: date(0, hour),
			endDate: date(0, hour + 1),
			isAllDay: false,
			location: location,
			isRecurring: isRecurring
		)
	}

	private static func candidate(
		_ id: String,
		_ title: String,
		_ day: Int,
		_ hour: Int,
		_ location: String?,
		_ notes: String?
	) -> JournalCalendarEvent {
		JournalCalendarEvent(
			id: id,
			calendarIdentifier: "benchmark",
			calendarTitle: "Benchmark",
			title: title,
			startDate: date(day, hour),
			endDate: date(day, hour + 1),
			isAllDay: false,
			location: location,
			notes: notes
		)
	}

	private static func rule(
		_ text: String,
		_ selector: EventReminderSelector,
		_ policy: EventReminderOccurrencePolicy,
		evidence: String = "Benchmark fixture"
	) -> EventReminderRule {
		EventReminderRule(
			text: text,
			motivation: "Benchmark fixture",
			evidence: evidence,
			selector: selector,
			occurrencePolicy: policy,
			createdAt: createdAt
		)
	}

	private static func date(_ day: Int, _ hour: Int) -> Date {
		let calendar = Calendar(identifier: .gregorian)
		return calendar.date(
			byAdding: .hour,
			value: day * 24 + hour,
			to: calendar.startOfDay(for: createdAt)
		) ?? createdAt
	}
}
