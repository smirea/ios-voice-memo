import Foundation
import FoundationModels
import Darwin

struct ReminderBenchmarkProgress {
	var completed: Int
	var total: Int
	var group: ReminderBenchmarkGroup
	var result: ReminderBenchmarkCaseResult?
}

struct ReminderBenchmarkCaseResult: Identifiable {
	var groupID: String
	var name: String
	var passed: Bool
	var expectedCount: Int
	var actualCount: Int
	var matchedCount: Int
	var fieldChecks: Int
	var fieldPasses: Int
	var groundedCount: Int
	var generated: [String]
	var issues: [String]
	var duration: TimeInterval
	var id: String { "\(groupID)|\(name)" }

	var consoleReport: String {
		let output = generated.isEmpty ? "none" : generated.joined(separator: " | ")
		let issueText = issues.isEmpty ? "none" : issues.joined(separator: "; ")
		return """
		\(passed ? "PASS" : "FAIL") \(name) (\(duration.formatted(.number.precision(.fractionLength(1))))s)
		  generated: \(output)
		  expected/matched/actual: \(expectedCount)/\(matchedCount)/\(actualCount)
		  field accuracy: \(fieldPasses)/\(fieldChecks), grounded evidence: \(groundedCount)/\(actualCount)
		  issues: \(issueText)
		"""
	}
}

struct ReminderBenchmarkCheckResult: Identifiable {
	var id: String { name }
	var name: String
	var passed: Bool
}

struct ReminderBenchmarkRun {
	var results: [ReminderBenchmarkCaseResult]
	var checks: [ReminderBenchmarkCheckResult]

	var summary: ReminderBenchmarkSummary {
		ReminderBenchmarkSummary(results: results, checks: checks)
	}
}

struct ReminderBenchmarkSummary {
	var casePasses: Int
	var cases: Int
	var expectedCues: Int
	var actualCues: Int
	var matchedCues: Int
	var fieldPasses: Int
	var fieldChecks: Int
	var groundedCues: Int
	var resolutionPasses: Int
	var resolutionCases: Int
	var checkPasses: Int
	var checks: Int

	init(results: [ReminderBenchmarkCaseResult], checks: [ReminderBenchmarkCheckResult]) {
		let parsingResults = results.filter { $0.groupID != "resolution" }
		casePasses = results.filter(\.passed).count
		cases = results.count
		expectedCues = parsingResults.reduce(0) { $0 + $1.expectedCount }
		actualCues = parsingResults.reduce(0) { $0 + $1.actualCount }
		matchedCues = parsingResults.reduce(0) { $0 + $1.matchedCount }
		fieldPasses = parsingResults.reduce(0) { $0 + $1.fieldPasses }
		fieldChecks = parsingResults.reduce(0) { $0 + $1.fieldChecks }
		groundedCues = parsingResults.reduce(0) { $0 + $1.groundedCount }
		resolutionPasses = results.filter { $0.groupID == "resolution" && $0.passed }.count
		resolutionCases = results.filter { $0.groupID == "resolution" }.count
		checkPasses = checks.filter(\.passed).count
		self.checks = checks.count
	}

	var cuePrecision: Double {
		actualCues == 0 ? 1 : Double(matchedCues) / Double(actualCues)
	}

	var cueRecall: Double {
		expectedCues == 0 ? 1 : Double(matchedCues) / Double(expectedCues)
	}

	var fieldAccuracy: Double {
		fieldChecks == 0 ? 1 : Double(fieldPasses) / Double(fieldChecks)
	}

	var evidenceGrounding: Double {
		actualCues == 0 ? 1 : Double(groundedCues) / Double(actualCues)
	}

	var consoleReport: String {
		"""
		SUMMARY
		  exact cases: \(casePasses)/\(cases)
		  cue precision: \(cuePrecision.formatted(.percent.precision(.fractionLength(1))))
		  cue recall: \(cueRecall.formatted(.percent.precision(.fractionLength(1))))
		  schema field accuracy: \(fieldAccuracy.formatted(.percent.precision(.fractionLength(1))))
		  exact evidence grounding: \(evidenceGrounding.formatted(.percent.precision(.fractionLength(1))))
		  fuzzy resolution: \(resolutionPasses)/\(resolutionCases)
		  deterministic checks: \(checkPasses)/\(checks)
		"""
	}
}

@MainActor
enum ReminderBenchmark {
	static var modelStatus: String {
		switch SystemLanguageModel.default.availability {
		case .available:
			return "SystemLanguageModel.default is available"
		case let .unavailable(reason):
			return "SystemLanguageModel.default is unavailable: \(reason)"
		}
	}

	static var canRun: Bool {
		SystemLanguageModel.default.availability == .available
	}

	static func run(
		groups: [ReminderBenchmarkGroup] = ReminderBenchmarkCorpus.groups,
		progress: (ReminderBenchmarkProgress) -> Void = { _ in }
	) async -> ReminderBenchmarkRun {
		let total = groups.reduce(0) { $0 + $1.cases.count }
		var completed = 0
		var results: [ReminderBenchmarkCaseResult] = []
		let checks = await deterministicChecks()

		for group in groups {
			progress(ReminderBenchmarkProgress(
				completed: completed,
				total: total,
				group: group,
				result: nil
			))
			for test in group.cases {
				let result = await run(test, groupID: group.id)
				results.append(result)
				completed += 1
				progress(ReminderBenchmarkProgress(
					completed: completed,
					total: total,
					group: group,
					result: result
				))
			}
		}

		return ReminderBenchmarkRun(
			results: results,
			checks: checks
		)
	}

	static func runFromLaunchArguments() async {
		let arguments = ProcessInfo.processInfo.arguments
		guard arguments.contains("-reminder-benchmark") else { return }
		let requestedGroup = argument(after: "-reminder-benchmark-group", in: arguments)
		let requestedCase = argument(after: "-reminder-benchmark-case", in: arguments)
		var groups = arguments.contains("-reminder-benchmark-deterministic-only")
			? []
			: requestedGroup.map { groupID in
				ReminderBenchmarkCorpus.groups.filter { $0.id == groupID }
			} ?? ReminderBenchmarkCorpus.groups
		if let requestedCase {
			groups = groups.compactMap { group in
				var group = group
				group.cases = group.cases.filter {
					$0.name.localizedCaseInsensitiveContains(requestedCase)
				}
				return group.cases.isEmpty ? nil : group
			}
		}

		print("REMINDER_BENCHMARK_BEGIN")
		print(modelStatus)
		print("\(groups.reduce(0) { $0 + $1.cases.count }) model-backed cases in \(groups.count) groups")
		let run = await run(groups: groups) { progress in
			if let result = progress.result {
				print(result.consoleReport)
			} else {
				print("\nLEVEL \(progress.group.level) · \(progress.group.title)")
			}
		}
		for check in run.checks {
			print("\(check.passed ? "PASS" : "FAIL") Contract · \(check.name)")
		}
		print(run.summary.consoleReport)
		print("REMINDER_BENCHMARK_END")
		fflush(stdout)
	}

	private static func argument(after flag: String, in arguments: [String]) -> String? {
		guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
			return nil
		}
		return arguments[index + 1]
	}

	private static func run(
		_ test: ReminderBenchmarkCase,
		groupID: String
	) async -> ReminderBenchmarkCaseResult {
		let startedAt = Date()
		switch test {
		case let .parsing(test):
			let parsed = await ReminderEngine.parse(
				transcript: test.transcript,
				sourceEvent: test.sourceEvent,
				createdAt: ReminderBenchmarkCorpus.createdAt
			)
			return assess(
				groupID: groupID,
				name: test.name,
				evidenceCorpus: test.transcript,
				expected: test.expected,
				actual: parsed.reminders,
				duration: Date().timeIntervalSince(startedAt)
			)
		case let .feedback(test):
			let parsed = await ReminderEngine.parse(
				transcript: test.transcript,
				sourceEvent: test.sourceEvent,
				createdAt: ReminderBenchmarkCorpus.createdAt,
				currentReminders: test.current,
				feedback: test.feedback
			)
			let evidenceCorpus = ([test.transcript] + test.feedback.map(\.text))
				.joined(separator: "\n")
			return assess(
				groupID: groupID,
				name: test.name,
				evidenceCorpus: evidenceCorpus,
				expected: test.expected,
				actual: parsed.reminders,
				duration: Date().timeIntervalSince(startedAt)
			)
		case let .resolution(test):
			let entry = JournalEntry(
				createdAt: ReminderBenchmarkCorpus.createdAt,
				duration: 60,
				transcript: "Benchmark fixture",
				headline: "Benchmark",
				calendarEvent: test.sourceEvent,
				reminders: [test.rule]
			)
			let resolved = await ReminderEngine.resolve(
				entries: [entry],
				events: test.events,
				now: ReminderBenchmarkCorpus.createdAt.addingTimeInterval(60)
			)
			let actual = Set(resolved.occurrences.map(\.event.id))
			let passed = actual == test.expectedEventIDs
			let issues = passed
				? []
				: [
					"expected \(test.expectedEventIDs.sorted().joined(separator: ", ")); matched \(actual.sorted().joined(separator: ", "))"
				]
			return ReminderBenchmarkCaseResult(
				groupID: groupID,
				name: test.name,
				passed: passed,
				expectedCount: test.expectedEventIDs.count,
				actualCount: actual.count,
				matchedCount: actual.intersection(test.expectedEventIDs).count,
				fieldChecks: 0,
				fieldPasses: 0,
				groundedCount: 0,
				generated: actual.sorted(),
				issues: issues,
				duration: Date().timeIntervalSince(startedAt)
			)
		}
	}

	private static func assess(
		groupID: String,
		name: String,
		evidenceCorpus: String,
		expected: [ExpectedReminderCue],
		actual: [EventReminderRule],
		duration: TimeInterval
	) -> ReminderBenchmarkCaseResult {
		var remaining = Set(actual.indices)
		var issues: [String] = []
		var matched = 0
		var fieldChecks = 0
		var fieldPasses = 0

		for cue in expected {
			guard let index = remaining.max(by: {
				matchScore(actual[$0], cue) < matchScore(actual[$1], cue)
			}), matchScore(actual[index], cue) == cue.actionTerms.count else {
				issues.append("missing \(cue.key)")
				continue
			}
			remaining.remove(index)
			matched += 1
			let rule = actual[index]

			fieldChecks += 2
			if selectorKind(rule.selector) == cue.selectorKind {
				fieldPasses += 1
			} else {
				issues.append("\(cue.key): selector \(selectorKind(rule.selector).rawValue)")
			}
			if rule.occurrencePolicy == cue.policy {
				fieldPasses += 1
			} else {
				issues.append("\(cue.key): policy \(rule.occurrencePolicy.rawValue)")
			}

			if let expectedBucket = cue.timeBucket {
				fieldChecks += 1
				if case let .fuzzy(selector) = rule.selector,
					selector.timeBucket == expectedBucket {
					fieldPasses += 1
				} else {
					issues.append("\(cue.key): wrong time bucket")
				}
			}

			if let expectedDays = cue.expiryDays {
				fieldChecks += 1
				let days = rule.expiresAt.map {
					Int(($0.timeIntervalSince(ReminderBenchmarkCorpus.createdAt) / 86_400).rounded())
				}
				if let days, expectedDays.contains(days) {
					fieldPasses += 1
				} else {
					issues.append("\(cue.key): expiry \(days.map(String.init) ?? "none") days")
				}
			}

			if !cue.eventTerms.isEmpty {
				fieldChecks += 1
				if case let .fuzzy(selector) = rule.selector,
					cue.eventTerms.allSatisfy({
						selector.semanticDescription.reminderNormalized.contains($0.reminderNormalized)
					}) {
					fieldPasses += 1
				} else {
					issues.append("\(cue.key): wrong semantic event")
				}
			}

			if !cue.locationTerms.isEmpty {
				fieldChecks += 1
				if case let .fuzzy(selector) = rule.selector,
					let location = selector.locationDescription,
					cue.locationTerms.allSatisfy({
						location.reminderNormalized.contains($0.reminderNormalized)
					}) {
					fieldPasses += 1
				} else {
					issues.append("\(cue.key): wrong venue")
				}
			}
		}

		if !remaining.isEmpty {
			issues.append("unexpected: \(remaining.sorted().map { actual[$0].text }.joined(separator: " | "))")
		}
		let grounded = actual.filter {
			!$0.evidence.reminderNormalized.isEmpty
				&& evidenceCorpus.reminderNormalized.contains($0.evidence.reminderNormalized)
		}.count
		if grounded != actual.count {
			issues.append("grounded evidence \(grounded)/\(actual.count)")
		}
		let passed = matched == expected.count
			&& remaining.isEmpty
			&& fieldPasses == fieldChecks
			&& grounded == actual.count

		return ReminderBenchmarkCaseResult(
			groupID: groupID,
			name: name,
			passed: passed,
			expectedCount: expected.count,
			actualCount: actual.count,
			matchedCount: matched,
			fieldChecks: fieldChecks,
			fieldPasses: fieldPasses,
			groundedCount: grounded,
			generated: actual.map {
				"\($0.text) [\($0.selector.title), \($0.occurrencePolicy.rawValue), evidence: \($0.evidence)]"
			},
			issues: issues,
			duration: duration
		)
	}

	private static func matchScore(
		_ rule: EventReminderRule,
		_ cue: ExpectedReminderCue
	) -> Int {
		let words = rule.text.reminderNormalized.split(separator: " ").map(String.init)
		return cue.actionTerms.filter { term in
			let normalizedTerm = term.reminderNormalized
			return words.contains { word in
				let prefixLength = min(4, min(word.count, normalizedTerm.count))
				guard prefixLength >= 3 else { return word == normalizedTerm }
				return word.prefix(prefixLength) == normalizedTerm.prefix(prefixLength)
			}
		}.count
	}

	private static func selectorKind(
		_ selector: EventReminderSelector
	) -> ExpectedReminderSelectorKind {
		switch selector {
		case .series: .series
		case .fuzzy: .fuzzy
		}
	}

	private static func deterministicChecks() async -> [ReminderBenchmarkCheckResult] {
		let source = JournalCalendarEvent(
			id: "contract-source",
			externalIdentifier: "contract-series",
			calendarIdentifier: "benchmark",
			calendarTitle: "Benchmark",
			title: "Thursday gym",
			startDate: benchmarkDate(0, 18),
			endDate: benchmarkDate(0, 19),
			isAllDay: false,
			location: "West Loop Fitness",
			isRecurring: true
		)
		let series = EventSeriesReference(event: source)
		let first = contractEvent(
			"contract-first",
			source.externalIdentifier,
			source.title,
			7,
			18,
			source.location
		)
		let second = contractEvent(
			"contract-second",
			source.externalIdentifier,
			source.title,
			14,
			18,
			source.location
		)
		var checks = [
			ReminderBenchmarkCheckResult(
				name: "series external identifier",
				passed: series.matches(first)
			),
			ReminderBenchmarkCheckResult(
				name: "series rejects another title and identifier",
				passed: !series.matches(contractEvent(
					"unrelated",
					nil,
					"Team dinner",
					7,
					18,
					source.location
				))
			),
			ReminderBenchmarkCheckResult(
				name: "time bucket boundaries",
				passed: timeBucketBoundariesPass()
			),
			ReminderBenchmarkCheckResult(
				name: "old entry JSON remains decodable",
				passed: oldEntryDecodingPasses()
			),
			ReminderBenchmarkCheckResult(
				name: "unpinned reminder JSON remains decodable",
				passed: unpinnedReminderDecodingPasses(series)
			),
			ReminderBenchmarkCheckResult(
				name: "summary rejects ungrounded file artifacts",
				passed: ReflectionEngine.containsUngroundedArtifact(
					"You will stay engaged.} Nehuan.S.20240514.1732.v1.20240514.1732.log",
					transcript: "I want to stay engaged during the game."
				)
			),
			ReminderBenchmarkCheckResult(
				name: "distant named events ground a shared cue",
				passed: namedEventSchedulePasses()
			)
		]

		let once = contractRule("Bring electrolytes", .series(series), .nextMatch)
		let entry = contractEntry(source, once)
		let initial = await ReminderEngine.resolve(
			entries: [entry],
			events: [first, second],
			now: ReminderBenchmarkCorpus.createdAt.addingTimeInterval(60)
		)
		checks.append(ReminderBenchmarkCheckResult(
			name: "next match pins first occurrence",
			passed: initial.occurrences.map(\.event.id) == [first.id]
				&& initial.resolvedOccurrencesByReminderID[once.id]?.id == first.id
		))

		var consumed = once
		consumed.resolvedOccurrence = first
		let retired = await ReminderEngine.resolve(
			entries: [contractEntry(source, consumed)],
			events: [first, second],
			now: first.endDate.addingTimeInterval(1)
		)
		checks.append(ReminderBenchmarkCheckResult(
			name: "next match retires instead of drifting",
			passed: retired.occurrences.isEmpty
		))

		let every = contractRule("Bring electrolytes", .series(series), .everyMatch)
		let repeated = await ReminderEngine.resolve(
			entries: [contractEntry(source, every)],
			events: [first, second],
			now: ReminderBenchmarkCorpus.createdAt.addingTimeInterval(60)
		)
		checks.append(ReminderBenchmarkCheckResult(
			name: "every match materializes all occurrences",
			passed: repeated.occurrences.map(\.event.id) == [first.id, second.id]
		))

		let upcomingSource = await ReminderEngine.resolve(
			entries: [contractEntry(source, once)],
			events: [source, first],
			now: ReminderBenchmarkCorpus.createdAt.addingTimeInterval(60)
		)
		checks.append(ReminderBenchmarkCheckResult(
			name: "upcoming source occurrence remains eligible",
			passed: upcomingSource.occurrences.map(\.event.id) == [source.id]
		))

		let werewolf = contractEvent(
			"named-werewolf",
			nil,
			"Ultimate Werewolf",
			0,
			19,
			"The Brewtorium"
		)
		let clocktower = contractEvent(
			"named-clocktower",
			nil,
			"Blood on the Clocktower",
			1,
			19,
			"The Brewtorium"
		)
		let namedGames = contractRule(
			"Focus on the game",
			.fuzzy(FuzzyEventSelector(
				semanticDescription: "ultimate werewolf event or blood on the clock tower event",
				timeBucket: .any,
				locationDescription: nil,
				examples: []
			)),
			.everyMatch
		)
		let namedResolution = await ReminderEngine.resolve(
			entries: [contractEntry(werewolf, namedGames)],
			events: [werewolf, clocktower],
			now: ReminderBenchmarkCorpus.createdAt.addingTimeInterval(60)
		)
		checks.append(ReminderBenchmarkCheckResult(
			name: "named fuzzy targets resolve without a model call",
			passed: namedResolution.occurrences.map(\.event.id)
				== [werewolf.id, clocktower.id]
		))
		return checks
	}

	private static func namedEventSchedulePasses() -> Bool {
		let transcript = """
		Today I have this Ultimate Werewolf event. My goal is to play while being charming and easygoing. And actually for tomorrow's Blood on the Clocktower event as well, let's do the same thing. Let's have a reminder for today and tomorrow to focus on the game and read the text. Just read one or two things and then jump in.
		"""
		let schedule = ReminderEngine.groundedSchedule(
			for: "Let's have a reminder for today and tomorrow to focus on the game and read the text.",
			in: transcript
		)
		let charmingSchedule = ReminderEngine.groundedSchedule(
			for: "My goal is to play while being charming and easygoing.",
			in: transcript
		)
		return [schedule, charmingSchedule].allSatisfy { schedule in
			let normalized = schedule.eventDescription.reminderNormalized
			return ["ultimate", "werewolf", "blood", "clocktower"].allSatisfy {
				normalized.contains($0)
			}
				&& schedule.occurrencePolicy == .everyMatch
				&& schedule.validity?.value == 2
				&& schedule.validity?.component == .day
		}
	}

	private static func contractEvent(
		_ id: String,
		_ externalIdentifier: String?,
		_ title: String,
		_ day: Int,
		_ hour: Int,
		_ location: String?
	) -> JournalCalendarEvent {
		JournalCalendarEvent(
			id: id,
			externalIdentifier: externalIdentifier,
			calendarIdentifier: "benchmark",
			calendarTitle: "Benchmark",
			title: title,
			startDate: benchmarkDate(day, hour),
			endDate: benchmarkDate(day, hour + 1),
			isAllDay: false,
			location: location,
			isRecurring: externalIdentifier != nil
		)
	}

	private static func contractRule(
		_ text: String,
		_ selector: EventReminderSelector,
		_ policy: EventReminderOccurrencePolicy
	) -> EventReminderRule {
		EventReminderRule(
			text: text,
			motivation: "Benchmark",
			evidence: "Benchmark",
			selector: selector,
			occurrencePolicy: policy,
			createdAt: ReminderBenchmarkCorpus.createdAt
		)
	}

	private static func contractEntry(
		_ event: JournalCalendarEvent,
		_ rule: EventReminderRule
	) -> JournalEntry {
		JournalEntry(
			createdAt: ReminderBenchmarkCorpus.createdAt,
			duration: 30,
			transcript: "Benchmark",
			headline: "Benchmark",
			calendarEvent: event,
			reminders: [rule]
		)
	}

	private static func benchmarkDate(_ day: Int, _ hour: Int) -> Date {
		let calendar = Calendar(identifier: .gregorian)
		return calendar.date(
			byAdding: .hour,
			value: day * 24 + hour,
			to: calendar.startOfDay(for: ReminderBenchmarkCorpus.createdAt)
		) ?? ReminderBenchmarkCorpus.createdAt
	}

	private static func timeBucketBoundariesPass() -> Bool {
		EventReminderTimeBucket.morning.contains(benchmarkDate(1, 4))
			&& EventReminderTimeBucket.morning.contains(benchmarkDate(1, 11))
			&& !EventReminderTimeBucket.morning.contains(benchmarkDate(1, 12))
			&& EventReminderTimeBucket.afternoon.contains(benchmarkDate(1, 12))
			&& EventReminderTimeBucket.afternoon.contains(benchmarkDate(1, 16))
			&& EventReminderTimeBucket.evening.contains(benchmarkDate(1, 17))
			&& !EventReminderTimeBucket.evening.contains(benchmarkDate(1, 3))
	}

	private static func oldEntryDecodingPasses() -> Bool {
		let entry = JournalEntry(
			createdAt: ReminderBenchmarkCorpus.createdAt,
			duration: 30,
			transcript: "Old entry",
			headline: "Old entry"
		)
		guard let data = try? JSONEncoder().encode(entry),
			var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return false }
		object["observations"] = ["Legacy observation"]
		object.removeValue(forKey: "reminders")
		object.removeValue(forKey: "reminderFeedback")
		object.removeValue(forKey: "reminderModel")
		guard let oldData = try? JSONSerialization.data(withJSONObject: object),
			let decoded = try? JSONDecoder().decode(JournalEntry.self, from: oldData)
		else { return false }
		return decoded.reminders.isEmpty
			&& decoded.reminderFeedback.isEmpty
			&& decoded.reminderModel == nil
	}

	private static func unpinnedReminderDecodingPasses(
		_ series: EventSeriesReference
	) -> Bool {
		let reminder = contractRule(
			"Bring electrolytes",
			.series(series),
			.nextMatch
		)
		let entry = JournalEntry(
			createdAt: ReminderBenchmarkCorpus.createdAt,
			duration: 30,
			transcript: "Bring electrolytes",
			headline: "Benchmark",
			reminders: [reminder]
		)
		guard let data = try? JSONEncoder().encode(entry),
			var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			var reminders = object["reminders"] as? [[String: Any]],
			!reminders.isEmpty
		else { return false }
		reminders[0]["isEnabled"] = true
		reminders[0]["modelName"] = "Legacy reminder model"
		object["reminders"] = reminders
		guard let legacyData = try? JSONSerialization.data(withJSONObject: object),
			let decoded = try? JSONDecoder().decode(JournalEntry.self, from: legacyData)
		else { return false }
		return decoded.reminders.count == 1
			&& decoded.reminders[0].resolvedOccurrence == nil
	}
}
