#if DEBUG
import Foundation

@MainActor
enum ModelOutcomeContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-model-outcome-contract-tests") else { return }
		do {
			try await reflectionChecks()
			try await reminderChecks()
			print("MODEL OUTCOME CONTRACT: 17 completion, skip, unavailable, failure, and cancellation checks passed")
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
