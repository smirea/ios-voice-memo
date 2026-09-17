#if DEBUG
import Foundation

@MainActor
enum ReminderBenchmarkContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-benchmark-contract-tests") else { return }
		do {
			try await emptyAndUnavailable()
			try await typedStopsAndPartialMetrics()
			try await canceledCaseAndReplacement()
			try await productionReconciliation()
			print("REMINDER BENCHMARK CONTRACT: owned cancellation, obsolete progress rejection, typed execution outcomes, assessed-only metrics, deterministic-only runs, and production reconciliation passed")
			fflush(stdout)
		} catch { fatalError("REMINDER BENCHMARK CONTRACT: \(error)") }
	}

	static var previewGroups: [ReminderBenchmarkGroup] {
		[.init(id: ReminderBenchmarkCorpus.groups[0].id, title: "Synthetic preview", level: 1, detail: "Synthetic execution preview",
			cases: [fixture("Synthetic completed case"), fixture("Synthetic interrupted case"), fixture("Synthetic unattempted case")])]
	}

	static func previewServices(status: ReminderBenchmarkStatus) -> ReminderBenchmarkServices {
		var count = 0
		return .init(isAvailable: { status != .unavailable }, parse: { _ in
			count += 1
			if count == 1 { return parsed([]) }
			return parsed([], outcome: status == .cancelled ? .cancelled : .failed("Synthetic preview: the model could not finish this case."))
		}, resolve: { _, _ in fatalError("Unexpected preview resolution") })
	}

	private static func emptyAndUnavailable() async throws {
		var calls = 0
		let services = ReminderBenchmarkServices(isAvailable: { false }, parse: { _ in calls += 1; return parsed([]) },
			resolve: { _, _ in fatalError("Unexpected model resolution") })
		let empty = await ReminderBenchmark.run(groups: [], services: services)
		try expect(empty.status == .complete && empty.attempted == 0 && empty.assessed == 0 && calls == 0
			&& empty.checks.count == 12 && empty.checks.allSatisfy(\.passed),
			"Deterministic-only runs must remain independently complete with all 12 production checks and no model calls")
		try expect(empty.summary.cuePrecision == nil && empty.summary.cueRecall == nil
			&& empty.summary.fieldAccuracy == nil && empty.summary.evidenceGrounding == nil
			&& !empty.summary.consoleReport.contains("100.0%"),
			"A zero-case run must never manufacture perfect semantic percentages")
		let unavailable = await ReminderBenchmark.run(groups: previewGroups, services: services)
		try expect(unavailable.status == .unavailable && unavailable.total == 3 && unavailable.attempted == 0
			&& unavailable.assessed == 0 && calls == 0 && unavailable.summary.cases == 0,
			"An unavailable model must stop before semantic assessment instead of producing accuracy failures")
	}

	private static func typedStopsAndPartialMetrics() async throws {
		for outcome in [ModelProcessingOutcome.cancelled, .unavailable, .failed("Synthetic response failure")] {
			var calls = 0
			let services = ReminderBenchmarkServices(isAvailable: { true }, parse: { _ in
				calls += 1
				return parsed([], outcome: outcome)
			}, resolve: { _, _ in fatalError("Unexpected resolution") })
			let result = await ReminderBenchmark.run(groups: previewGroups, services: services)
			let expected: ReminderBenchmarkStatus = outcome == .cancelled ? .cancelled : (outcome == .unavailable ? .unavailable : .failed)
			try expect(result.status == expected && result.attempted == 1 && result.assessed == 0 && calls == 1
				&& result.results[0].consoleReport.hasPrefix("NOT ASSESSED") && result.summary.cases == 0,
				"Typed execution stops, including gate cancellation without Task cancellation, must not run later cases or become semantic failures")
		}
		let resolution = ReminderResolutionBenchmarkCase(name: "Unavailable empty resolution", sourceEvent: event,
			rule: rule(event), events: [], expectedEventIDs: [])
		let unresolved = await ReminderBenchmark.run(groups: [.init(id: "resolution", title: "Fixture", level: 1, detail: "", cases: [.resolution(resolution)])],
			services: .init(isAvailable: { true }, parse: { _ in fatalError("Unexpected parse") }, resolve: { _, _ in
				.init(occurrences: [], examplesByReminderID: [:], resolvedOccurrencesByReminderID: [:], outcome: .unavailable)
			}))
		try expect(unresolved.status == .unavailable && unresolved.assessed == 0 && unresolved.summary.resolutionCases == 0,
			"An unavailable resolver returning no occurrences must not pass an expected-empty semantic case")
		var calls = 0
		let partial = await ReminderBenchmark.run(groups: [.init(id: "fixture", title: "Fixture", level: 1, detail: "",
			cases: [fixture("Completed wrong answer", expected: [.init("notebook", ["notebook"], .series, .nextMatch)]), fixture("Unavailable")])],
			services: .init(isAvailable: { true }, parse: { _ in
				calls += 1
				return parsed([], outcome: calls == 1 ? .complete : .unavailable)
			}, resolve: { _, _ in fatalError("Unexpected resolution") }))
		try expect(partial.status == .unavailable && partial.assessed == 1 && partial.attempted == 2
			&& partial.summary.cases == 1 && partial.summary.casePasses == 0 && partial.summary.cueRecall == 0,
			"Earlier completed wrong answers remain real accuracy failures while execution failure is excluded from partial denominators")
		let falsePositive = await ReminderBenchmark.run(groups: [.init(id: "fixture", title: "Fixture", level: 1, detail: "",
			cases: [fixture("Unexpected cue")])], services: .init(isAvailable: { true }, parse: { entry in
				parsed([rule(entry.calendarEvent!)])
			}, resolve: { _, _ in fatalError("Unexpected resolution") }))
		try expect(falsePositive.status == .complete && falsePositive.summary.actualCues == 1
			&& falsePositive.summary.casePasses == 0 && falsePositive.summary.cuePrecision == 0,
			"A completed negative case that emits a false positive must show 0% precision, not Not assessed or 100%")
	}

	private static func canceledCaseAndReplacement() async throws {
		let old = HeldCase()
		let owner = ReminderBenchmarkSession()
		owner.start(groups: previewGroups, services: .init(isAvailable: { true }, parse: { _ in await old.hold() },
			resolve: { _, _ in fatalError("Unexpected resolution") }))
		try await wait { old.calls == 1 }
		owner.cancel()
		try expect(!owner.isRunning && owner.run?.status == .cancelled && owner.run?.attempted == 1 && owner.run?.assessed == 0,
			"Cancel must immediately publish an honest partial snapshot without waiting for an uncooperative model")
		owner.start(groups: [], services: .init(isAvailable: { false }, parse: { _ in fatalError("Unexpected model") },
			resolve: { _, _ in fatalError("Unexpected resolution") }))
		try await wait { !owner.isRunning }
		let newRun = owner.run
		old.release()
		try await wait { old.exited }
		for _ in 0..<10 { await Task.yield() }
		try expect(owner.run?.status == .complete && owner.run?.total == 0 && owner.run?.checks.count == newRun?.checks.count
			&& old.calls == 1, "Late old-case completion/progress cannot overwrite a new run or start another old case")
		let held = HeldCase()
		let task = Task { await ReminderBenchmark.run(groups: previewGroups, services: .init(isAvailable: { true },
			parse: { _ in await held.hold() }, resolve: { _, _ in fatalError("Unexpected resolution") })) }
		try await wait { held.calls == 1 }
		task.cancel()
		held.release()
		let result = await task.value
		try expect(result.status == .cancelled && result.assessed == 0 && result.attempted == 1 && held.calls == 1,
			"The benchmark loop must discard a completed response returned after caller cancellation and stop all later cases")
	}

	private static func productionReconciliation() async throws {
		let source = event
		let old = rule(source)
		let feedback = ReminderFeedback(kind: .manualRemoval, text: "Remove this reminder", focusedReminderID: old.id)
		let entry = ReminderFeedbackBenchmarkCase(name: "Preserved manual removal", sourceEvent: source,
			transcript: "Bring a notebook next time.", current: [old], feedback: [feedback], expected: [])
		let result = await ReminderBenchmark.run(groups: [.init(id: "feedback", title: "Fixture", level: 1, detail: "", cases: [.feedback(entry)])],
			services: .init(isAvailable: { true }, parse: { _ in parsed([old]) }, resolve: { _, _ in fatalError("Unexpected resolution") }))
		try expect(result.status == .complete && result.summary.casePasses == 1 && result.summary.actualCues == 0,
			"Benchmark assessment must use production identity/manual-removal reconciliation instead of raw generated rules")
	}

	private static func fixture(_ name: String, expected: [ExpectedReminderCue] = []) -> ReminderBenchmarkCase {
		.parsing(.init(name: name, sourceEvent: event, transcript: "Bring a notebook next time.", expected: expected))
	}
	private static var event: JournalCalendarEvent {
		.init(id: "benchmark-fixture", calendarIdentifier: "benchmark-fixture", calendarTitle: "Fixture", title: "Workshop",
			startDate: ReminderBenchmarkCorpus.createdAt.addingTimeInterval(3_600),
			endDate: ReminderBenchmarkCorpus.createdAt.addingTimeInterval(7_200), isAllDay: false)
	}
	private static func rule(_ event: JournalCalendarEvent) -> EventReminderRule {
		.init(text: "Bring a notebook", motivation: "Be prepared", evidence: "Bring a notebook next time.", selector: .series(.init(event: event)),
			occurrencePolicy: .nextMatch, createdAt: ReminderBenchmarkCorpus.createdAt)
	}
	private static func parsed(_ rules: [EventReminderRule], outcome: ModelProcessingOutcome = .complete) -> ReminderParsingResult {
		.init(reminders: rules, modelName: "Synthetic fixture", outcome: outcome)
	}
	private static func wait(_ condition: () -> Bool) async throws {
		let deadline = Date.now.addingTimeInterval(3)
		while !condition() {
			guard Date.now < deadline else { throw Failure(message: "Held benchmark fixture timed out") }
			await Task.yield()
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
	private struct Failure: Error { var message: String }
	@MainActor
	private final class HeldCase {
		var calls = 0
		var exited = false
		var continuation: CheckedContinuation<ReminderParsingResult, Never>?
		func hold() async -> ReminderParsingResult {
			calls += 1
			let result = await withCheckedContinuation { continuation = $0 }
			exited = true
			return result
		}
		func release() { continuation?.resume(returning: parsed([])); continuation = nil }
	}
}
#endif
