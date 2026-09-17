#if DEBUG
import Foundation

@MainActor
enum ModelOutcomeContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-model-outcome-contract-tests") else { return }
		do {
			try await reflectionChecks()
			try await reminderChecks()
			try await weeklyChecks()
			try await resolutionChecks()
			print("MODEL OUTCOME CONTRACT: completion, skip, unavailable, failure, cancellation, weekly review, and partial reminder resolution checks passed")
			fflush(nil)
		} catch { fatalError("MODEL OUTCOME CONTRACT: \(error)") }
	}

	private static func reflectionChecks() async throws {
		let transcript = "I want to make more room for focused work. The next step is to protect an hour."
		let generated = ReflectionResult(headline: "You made room to focus", summary: "You protected an hour.", modelName: "fixture")
		let success = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { generated }
		try expect(success.outcome == .complete && success.headline == generated.headline, "Successful reflection must remain complete")
		let unavailable = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw ModelProcessingError.unavailable }
		try expect(unavailable.outcome == .unavailable && !unavailable.outcome.isComplete && !unavailable.headline.isEmpty,
			"Unavailable reflection must keep only an explicitly incomplete fallback")
		let failed = await ReflectionEngine.reflect(on: transcript, includeSummary: false) {
			throw NSError(domain: "PRIVATE_MODEL_PAYLOAD", code: 1)
		}
		if case let .failed(message) = failed.outcome {
			try expect(!message.contains("PRIVATE_MODEL_PAYLOAD") && !failed.headline.isEmpty && failed.summary == nil,
				"Reflection failure must have a safe status and preserve the short-note fallback")
		} else { throw Failure(message: "Reflection failure was treated as success") }
		let timeout = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw ModelProcessingError.timedOut }
		try expect(!timeout.outcome.isComplete, "Timeout must not complete reflection")
		let invalid = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw ModelProcessingError.invalidOutput }
		try expect(!invalid.outcome.isComplete, "Invalid model output must not complete reflection")
		let silence = await ReflectionEngine.reflect(on: " \n", includeSummary: true) { throw Failure(message: "Silence invoked the model") }
		try expect(silence.outcome == .skipped && silence.summary == nil, "Silence must skip analysis explicitly")
		let thrownCancellation = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw CancellationError() }
		try expect(thrownCancellation.outcome == .cancelled && thrownCancellation.headline.isEmpty && thrownCancellation.summary == nil,
			"Reflection cancellation must not generate fallback")

		let started = ModelOutcomeSignal()
		let task = Task {
			await ReflectionEngine.reflect(on: transcript, includeSummary: true) {
				await started.send()
				try await Task.sleep(for: .seconds(5))
				return generated
			}
		}
		defer { task.cancel() }
		try await started.wait()
		task.cancel()
		let canceled = await task.value
		try expect(canceled.outcome == .cancelled && canceled.headline.isEmpty, "In-flight reflection child cancellation must be retained")
	}

	private static func reminderChecks() async throws {
		let event = JournalCalendarEvent(id: "fixture", calendarIdentifier: "calendar", calendarTitle: "Calendar",
			title: "Project review", startDate: Date(timeIntervalSince1970: 1_800_000_000),
			endDate: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false)
		let rule = EventReminderRule(text: "Bring the notes", motivation: "You want them available.", evidence: "Bring the notes.",
			selector: .series(EventSeriesReference(event: event)), occurrencePolicy: .nextMatch)
		let noEvent = await ReminderEngine.parse(transcript: "The project review was useful.", sourceEvent: nil, createdAt: event.startDate)
		try expect(noEvent.outcome == .skipped && noEvent.reminders.isEmpty, "A missing attached event must be an explicit skip")
		let emptySpeech = await ReminderEngine.parse(transcript: "\n ", sourceEvent: event, createdAt: event.startDate)
		try expect(emptySpeech.outcome == .skipped, "Empty speech must skip reminder extraction")
		let noFutureCue = await ReminderEngine.parse(transcript: "The project review was useful.", sourceEvent: event,
			createdAt: event.startDate, currentReminders: [rule], modelIsAvailable: { false })
		try expect(noFutureCue.outcome == .complete && noFutureCue.reminders.isEmpty && noFutureCue.modelName == nil,
			"A note with no future cue must complete without an available model")
		let requestedUnavailable = await ReminderEngine.parse(transcript: "I should bring notes to the next project review.",
			sourceEvent: event, createdAt: event.startDate, currentReminders: [rule], modelIsAvailable: { false })
		try expect(requestedUnavailable.outcome == .unavailable && requestedUnavailable.reminders == [rule],
			"A reminder model request must report unavailable and preserve rules")
		let noReminders = await ReminderEngine.parse(currentReminders: [rule]) {
			ReminderParsingResult(reminders: [], modelName: "fixture")
		}
		try expect(noReminders.outcome == .complete && noReminders.reminders.isEmpty, "Successful zero reminders must be authoritative completion")
		let missingModel = await ReminderEngine.parse(currentReminders: [rule]) { throw ModelProcessingError.unavailable }
		try expect(missingModel.outcome == .unavailable && missingModel.reminders == [rule], "An unavailable reminder model must preserve existing rules")
		let failed = await ReminderEngine.parse(currentReminders: [rule]) { throw NSError(domain: "PRIVATE_MODEL_PAYLOAD", code: 1) }
		if case let .failed(message) = failed.outcome {
			try expect(!message.contains("PRIVATE_MODEL_PAYLOAD") && failed.reminders == [rule], "Reminder failure must preserve existing rules and hide the payload")
		} else { throw Failure(message: "Reminder failure was treated as completion") }
		let canceled = await ReminderEngine.parse(currentReminders: [rule]) { throw CancellationError() }
		try expect(canceled.outcome == .cancelled && canceled.reminders == [rule], "Reminder cancellation must preserve existing rules")
		let started = ModelOutcomeSignal()
		let task = Task {
			await ReminderEngine.parse(currentReminders: [rule]) {
				await started.send()
				try? await Task.sleep(for: .seconds(5))
				return ReminderParsingResult(reminders: [], modelName: "late fixture")
			}
		}
		defer { task.cancel() }
		try await started.wait()
		task.cancel()
		let late = await task.value
		try expect(late.outcome == .cancelled && late.reminders == [rule], "A late reminder success after cancellation must be discarded")
	}

	private static func weeklyChecks() async throws {
		let start = Date(timeIntervalSince1970: 1_800_000_000)
		let entry = JournalEntry(createdAt: start, duration: 10, transcript: "You planned a focused week.", headline: "Your plans")
		let complete = WeeklyReview(weekStart: start, title: "Your week", body: "You planned ahead.", recordingMinutes: [])
		let success = await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) { complete }
		try expect(success.outcome == .complete && success.title == complete.title, "A completed weekly review must remain complete")
		let empty = await ReflectionEngine.weeklyReview(entries: [], weekStart: start) {
			throw Failure(message: "Empty week invoked generation")
		}
		try expect(empty.outcome == .skipped, "An empty week must skip generation")
		let unavailable = await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) { throw ModelProcessingError.unavailable }
		try expect(unavailable.outcome == .unavailable && !unavailable.body.isEmpty, "Weekly fallback must remain explicitly incomplete")
		let canceled = await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) { throw CancellationError() }
		try expect(canceled.outcome == .cancelled && canceled.title.isEmpty && canceled.body.isEmpty,
			"Canceled review must not manufacture fallback text")
		let started = ModelOutcomeSignal()
		let task = Task {
			await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) {
				await started.send()
				try? await Task.sleep(for: .seconds(5))
				return complete
			}
		}
		defer { task.cancel() }
		try await started.wait()
		task.cancel()
		let late = await task.value
		try expect(late.outcome == .cancelled && late.body.isEmpty, "Late weekly generation must not publish after cancellation")
	}

	private static func resolutionChecks() async throws {
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		let seriesEvent = JournalCalendarEvent(id: "series", calendarIdentifier: "calendar", calendarTitle: "Calendar",
			title: "Project review", startDate: now.addingTimeInterval(3_600), endDate: now.addingTimeInterval(5_400), isAllDay: false)
		let exactEvent = JournalCalendarEvent(id: "exact", calendarIdentifier: "calendar", calendarTitle: "Calendar",
			title: "Tabletop campaign", startDate: now.addingTimeInterval(7_200), endDate: now.addingTimeInterval(9_000), isAllDay: false)
		let unknownEvent = JournalCalendarEvent(id: "unknown", calendarIdentifier: "calendar", calendarTitle: "Calendar",
			title: "Campaign planning", startDate: now.addingTimeInterval(1_800), endDate: now.addingTimeInterval(3_600), isAllDay: false)
		let series = EventReminderRule(text: "Bring notes", motivation: "You need them.", evidence: "Bring notes",
			selector: .series(EventSeriesReference(event: seriesEvent)), occurrencePolicy: .everyMatch, createdAt: now)
		let fuzzy = EventReminderRule(text: "Bring dice", motivation: "You need them.", evidence: "Bring dice",
			selector: .fuzzy(FuzzyEventSelector(semanticDescription: "Tabletop campaign", timeBucket: .any, examples: [])),
			occurrencePolicy: .everyMatch, createdAt: now)
		var entry = JournalEntry(createdAt: now, duration: 10, transcript: "Bring notes and dice.", headline: "Your plan", reminders: [series, fuzzy])
		let events = [seriesEvent, exactEvent, unknownEvent]
		let partial = await ReminderEngine.resolve(entries: [entry], events: events, now: now, modelIsAvailable: { false })
		try expect(partial.outcome == .unavailable && partial.incompleteReminderIDs == [fuzzy.id],
			"Unavailable fuzzy matching must identify its affected rule")
		try expect(Set(partial.occurrences.map(\.eventKey)) == [seriesEvent.focusKey, exactEvent.focusKey],
			"Unavailable fuzzy matching must retain unrelated series and exact matches")
		try expect(partial.examplesByReminderID[fuzzy.id]?.contains(where: { $0.event.focusKey == unknownEvent.focusKey }) == false,
			"An unclassified event must not become a confident negative example")
		entry.reminders[1].occurrencePolicy = .nextMatch
		let next = await ReminderEngine.resolve(entries: [entry], events: events, now: now, modelIsAvailable: { false })
		try expect(next.resolvedOccurrencesByReminderID[fuzzy.id] == nil && next.occurrences.count == 1,
			"Incomplete classification must not pin a later occurrence past an unknown earlier candidate")
		let deterministic = await ReminderEngine.resolve(entries: [entry], events: [seriesEvent, exactEvent], now: now, modelIsAvailable: { false })
		try expect(deterministic.outcome == .complete && deterministic.occurrences.count == 2,
			"Deterministic matching must complete without a model")
		let task = Task {
			try? await Task.sleep(for: .seconds(5))
			return await ReminderEngine.resolve(entries: [entry], events: events, now: now, modelIsAvailable: { false })
		}
		task.cancel()
		let canceled = await task.value
		try expect(canceled.outcome == .cancelled && canceled.occurrences.isEmpty,
			"Canceled resolution must not publish a partial schedule")
	}

	private static func expect(_ condition: Bool, _ message: String) throws {
		guard condition else { throw Failure(message: message) }
	}

	private struct Failure: Error { let message: String }
}

private actor ModelOutcomeSignal {
	private var started = false
	func send() { started = true }
	func wait() async throws {
		for _ in 0..<200 {
			if started { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		throw Timeout()
	}
	private struct Timeout: Error {}
}
#endif
