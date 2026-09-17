#if DEBUG
import Foundation
import FoundationModels

@MainActor
enum ReminderContextContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-context-contract-tests") else { return }
		do {
			try await fittingChecks()
			try await coverageAndCorrectionChecks()
			try await scheduleAndEvidenceChecks()
			try await failureAndRetryChecks()
			try await fuzzyBudgetChecks()
			print("REMINDER CONTEXT CONTRACT: fitting path, original range coverage, all-candidate corrections, exact evidence, named targets, bounded native retry, and fuzzy budget failure passed")
			fflush(stdout)
		} catch { fatalError("REMINDER CONTEXT CONTRACT: \(error)") }
	}

	nonisolated private static let blue = GeneratedReminderDraft(text: "Bring the blue notebook", motivation: "You need your notes.",
		evidence: "Next time, bring the blue notebook to this event.")
	nonisolated private static let red = GeneratedReminderDraft(text: "Bring the red notebook", motivation: "You changed your notebook.",
		evidence: "Bring the red notebook instead of the blue notebook.")
	nonisolated private static let dice = GeneratedReminderDraft(text: "Bring dice", motivation: "You need dice at the game.",
		evidence: "At the game, I should bring dice, and do the same thing tomorrow.")
	nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

	private static func fittingChecks() async throws {
		let probe = Probe()
		let result = await ReminderEngine.parse(transcript: blue.evidence, sourceEvent: event(), createdAt: now,
			modelIsAvailable: { true }, services: services(probe, context: 20_000))
		try expect(result.outcome == .complete && result.reminders.map(\.text) == [blue.text], "The fitting whole-memo path must retain its generated action")
		let calls = await probe.draftCalls
		try expect(calls.count == 1 && calls[0].contains("Original memo:\n" + blue.evidence)
			&& calls[0].contains("Corrections, oldest to newest:"), "A fitting memo must keep the original full-context prompt")
	}

	private static func coverageAndCorrectionChecks() async throws {
		let seeds = (0..<40).map { index in
			GeneratedReminderDraft(text: "Bring item\(index)", motivation: "You need this item.",
				evidence: "Next time, bring item\(index) to this event.")
		}
		let filler = String(repeating: "Ordinary conversation had careful details 漢字 👩🏽‍🔬. ", count: 100)
		let manyNames = (0..<80).map { "We mentioned Cedar\($0) Workshop.\n" }.joined()
		let transcript = manyNames + "The Aurora Workshop is next week.\n" + blue.evidence + "\n"
			+ seeds.map(\.evidence).joined(separator: "\n") + "\n" + filler + "\nThe final sentence has arrived."
		let correction = filler + "\n" + red.evidence
		let finalCorrection = "Do not bring the red notebook."
		let feedback = [ReminderFeedback(kind: .voice, text: correction), ReminderFeedback(kind: .voice, text: finalCorrection)]
		let probe = Probe(additions: [blue] + seeds)
		let prior = seeds.map { rule($0) } + [rule(red)]
		let result = await ReminderEngine.parse(transcript: transcript, sourceEvent: event(), createdAt: now,
			currentReminders: prior, feedback: feedback, modelIsAvailable: { true }, services: services(probe))
		try expect(result.outcome == .complete, "All original ranges and corrections must complete without a global reminder quota")
		try expect(Set(result.reminders.map(\.text)) == Set(seeds.map(\.text)),
			"A final correction must remove the replacement of an earlier action while retaining every unrelated candidate")
		let calls = await probe.draftCalls
		for (index, source) in [transcript, correction, finalCorrection].enumerated() {
			try assertCoverage(source, sourceIndex: index, calls: calls)
		}
		try expect(calls.filter { $0.contains("Source: original memo;") }.allSatisfy { !candidateDrafts($0).contains { $0.evidence == red.evidence } },
			"Current rules grounded in later feedback must not leak into original memo passages")
		let finalShards = calls.filter { $0.hasPrefix("Task: Revise") && $0.contains("correction 2;") }
		let visited = finalShards.flatMap(candidateDrafts).map(\.text)
		try expect(Set(seeds.map(\.text)).isSubset(of: Set(visited)) && visited.contains(red.text),
			"The final correction must visit every candidate shard, including replacements from prior corrections")
		try expect(finalShards.count > 1, "The large candidate set must actually exercise bounded shard revision")
	}

	private static func scheduleAndEvidenceChecks() async throws {
		let filler = String(repeating: "There were ordinary details without a named target. ", count: 100)
		let history = (0..<80).map { "We discussed Historical\($0) game.\n" }.joined()
		let transcript = history + "We discussed the Ultimate Werewolf game and the Café Blood on the Clocktower game.\n" + filler + "\n" + dice.evidence
		let fabricated = GeneratedReminderDraft(text: "Bring a telescope", motivation: "You need it.", evidence: "Bring a telescope to the game.")
		let probe = Probe(additions: [dice, fabricated], alwaysIncludeFabricated: true)
		let result = await ReminderEngine.parse(transcript: transcript, sourceEvent: event(), createdAt: now,
			modelIsAvailable: { true }, services: services(probe))
		try expect(result.outcome == .complete && result.reminders.map(\.text) == [dice.text],
			"Only exact evidence from the complete original corpus may survive extraction")
		let schedules = await probe.scheduleCalls
		try expect(schedules.count == 1 && schedules[0].contains("Ultimate Werewolf game")
			&& schedules[0].contains("Café Blood on the Clocktower game") && !schedules[0].contains("Historical0 game") && schedules[0].contains("Original UTF16")
			&& schedules[0].contains(dice.evidence) && !schedules[0].contains(transcript),
			"A bounded scheduling request must retain the distant verbatim target and original action evidence")
	}

	private static func failureAndRetryChecks() async throws {
		let transcript = blue.evidence + "\n" + String(repeating: "Ordinary detailed conversation. ", count: 200)
		let prior = [rule(blue)]
		let failing = Probe(failPassage: true)
		let failed = await ReminderEngine.parse(transcript: transcript, sourceEvent: event(), createdAt: now,
			currentReminders: prior, modelIsAvailable: { true }, services: services(failing))
		try expect(!failed.outcome.isComplete && failed.reminders == prior, "One failed source passage must preserve all previously completed rules")
		let retrying = Probe(contextFailures: 2)
		let retried = await ReminderEngine.parse(transcript: blue.evidence, sourceEvent: event(), createdAt: now,
			modelIsAvailable: { true }, services: services(retrying, context: 20_000))
		let remainingFailures = await retrying.contextFailures
		try expect(retried.outcome == .complete && remainingFailures == 0,
			"Native context exhaustion must switch to bounded source work and reduce the failing range")
		let impossible = Probe(contextFailures: 100)
		let exhausted = await ReminderEngine.parse(transcript: blue.evidence, sourceEvent: event(), createdAt: now,
			currentReminders: prior, modelIsAvailable: { true }, services: services(impossible, context: 20_000))
		let exhaustedCalls = await impossible.draftCalls.count
		try expect(!exhausted.outcome.isComplete && exhausted.reminders == prior && exhaustedCalls <= 5,
			"Context retries must be bounded and may not publish a partial extraction")
		let crowdedNames = (0..<100).map { "Named\($0) game" }.joined(separator: " and ") + ".\n" + String(repeating: "Ordinary conversation. ", count: 300) + dice.evidence
		let crowded = await ReminderEngine.parse(transcript: crowdedNames, sourceEvent: event(), createdAt: now,
			currentReminders: prior, modelIsAvailable: { true }, services: services(Probe(additions: [dice])))
		try expect(!crowded.outcome.isComplete && crowded.reminders == prior,
			"An indivisible required shared-target group too large for its allowance must fail without silently dropping names")
	}

	private static func fuzzyBudgetChecks() async throws {
		let selector = FuzzyEventSelector(semanticDescription: "tabletop gaming", timeBucket: .any,
			locationDescription: nil, examples: [])
		var reminder = rule(blue)
		reminder.selector = .fuzzy(selector)
		let entry = JournalEntry(createdAt: now, duration: 30, transcript: blue.evidence, headline: "Fixture", reminders: [reminder])
		var candidate = event()
		candidate.title = "Gaming social"
		candidate.notes = String(repeating: "Some tabletop context. ", count: 500)
		let probe = Probe()
		let result = await ReminderEngine.resolve(entries: [entry], events: [candidate], now: now,
			modelIsAvailable: { true }, services: services(probe))
		let matchCalls = await probe.matchCalls
		try expect(!result.outcome.isComplete && result.incompleteReminderIDs.contains(reminder.id)
			&& result.examplesByReminderID[reminder.id, default: []].isEmpty && matchCalls == 0,
			"Oversized fuzzy evidence must remain unknown without an overflowing native call or a false negative example")
	}

	private static func services(_ probe: Probe, context: Int = 5_000) -> ReminderModelServices {
		ReminderModelServices(budget: { instructions, _, reserve in
			try ModelContextBudget(contextSize: context, instructionTokens: instructions.utf8.count,
				schemaTokens: 64, outputTokens: min(reserve, 200), safetyTokens: 32, count: { $0.utf8.count })
		}, drafts: { instructions, prompt, reserve in
			try checkBudget(instructions, prompt, reserve, context)
			return try await probe.drafts(prompt)
		}, schedule: { instructions, prompt, reserve in
			try checkBudget(instructions, prompt, reserve, context)
			await probe.recordSchedule(prompt)
			return GeneratedReminderSchedule(scheduleContext: dice.evidence, eventDescription: "Ultimate Werewolf game", locationDescription: "none")
		}, match: { instructions, prompt, reserve in
			try checkBudget(instructions, prompt, reserve, context)
			await probe.recordMatch()
			return GeneratedEventMatch(matches: false, reason: "Fixture decision")
		})
	}

	nonisolated private static func checkBudget(_ instructions: String, _ prompt: String, _ reserve: Int, _ context: Int) throws {
		try expect(instructions.utf8.count + prompt.utf8.count + reserve + 96 <= context,
			"Every admitted request must include instructions, schema, full prompt, output reserve, and safety margin")
	}

	private actor Probe {
		var additions: [GeneratedReminderDraft]
		var alwaysIncludeFabricated: Bool
		var failPassage: Bool
		var contextFailures: Int
		var draftCalls: [String] = []
		var scheduleCalls: [String] = []
		var matchCalls = 0
		init(additions: [GeneratedReminderDraft] = [blue], alwaysIncludeFabricated: Bool = false,
			failPassage: Bool = false, contextFailures: Int = 0) {
			self.additions = additions
			self.alwaysIncludeFabricated = alwaysIncludeFabricated
			self.failPassage = failPassage
			self.contextFailures = contextFailures
		}
		func drafts(_ prompt: String) throws -> [GeneratedReminderDraft] {
			draftCalls.append(prompt)
			if contextFailures > 0 { contextFailures -= 1; throw ModelContextError.promptTooLarge }
			if failPassage && prompt.contains("Passage:") { throw Failure("Injected passage failure") }
			let passage = ReminderContextContractChecks.passage(prompt) ?? prompt
			if prompt.hasPrefix("Task: Revise") {
				return candidateDrafts(prompt).compactMap { draft in
					if passage.contains("Do not bring the red notebook"), draft.text == red.text { return nil }
					if passage.contains(red.evidence), draft.text == blue.text { return red }
					return draft
				}
			}
			var result = additions.filter { passage.contains($0.evidence) }
			if passage.contains(red.evidence) { result.append(red) }
			if alwaysIncludeFabricated, let last = additions.last { result.append(last) }
			return result
		}
		func recordSchedule(_ prompt: String) { scheduleCalls.append(prompt) }
		func recordMatch() { matchCalls += 1 }
	}

	nonisolated private static func passage(_ prompt: String) -> String? {
		guard let start = prompt.range(of: "Passage:\n")?.upperBound,
			let end = prompt.range(of: "\nEnd passage.", range: start..<prompt.endIndex)?.lowerBound else { return nil }
		return String(prompt[start..<end])
	}

	nonisolated private static func candidateDrafts(_ prompt: String) -> [GeneratedReminderDraft] {
		guard let start = prompt.range(of: "Candidate shard:\n")?.upperBound else { return [] }
		return prompt[start...].components(separatedBy: "\n\n").compactMap { item in
			let lines = item.components(separatedBy: "\n")
			guard lines.count == 3, lines[0].hasPrefix("Action: "), lines[1].hasPrefix("Why: "), lines[2].hasPrefix("Evidence: ") else { return nil }
			return GeneratedReminderDraft(text: String(lines[0].dropFirst(8)), motivation: String(lines[1].dropFirst(5)), evidence: String(lines[2].dropFirst(10)))
		}
	}

	private static func assertCoverage(_ source: String, sourceIndex: Int, calls: [String]) throws {
		var covered = Array(repeating: false, count: source.utf16.count)
		let label = sourceIndex == 0 ? "original memo" : "correction \(sourceIndex)"
		for prompt in calls where prompt.hasPrefix("Task: Extract") && prompt.contains("Source: \(label);") {
			guard let text = passage(prompt), let raw = prompt.components(separatedBy: "UTF16 range: ").last?.components(separatedBy: "\n").first else { throw Failure("Missing source range") }
			let bounds = raw.components(separatedBy: "..<").compactMap(Int.init)
			guard bounds.count == 2, bounds[0] >= 0, bounds[1] <= covered.count,
				let range = Range(NSRange(location: bounds[0], length: bounds[1] - bounds[0]), in: source) else { throw Failure("Invalid source range") }
			try expect(String(source[range]) == text, "Prompt source offsets must reconstruct exact original text, including Unicode")
			for index in bounds[0]..<bounds[1] { covered[index] = true }
		}
		try expect(covered.allSatisfy { $0 }, "Every UTF16 source unit, including the tail, must reach extraction")
	}

	private static func event() -> JournalCalendarEvent {
		JournalCalendarEvent(id: "context-event", calendarIdentifier: "calendar", calendarTitle: "Calendar", title: "Aurora Workshop",
			startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(7200), isAllDay: false)
	}
	private static func rule(_ draft: GeneratedReminderDraft) -> EventReminderRule {
		EventReminderRule(text: draft.text, motivation: draft.motivation, evidence: draft.evidence,
			selector: .series(EventSeriesReference(event: event())), occurrencePolicy: .nextMatch, createdAt: now)
	}
	nonisolated private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
}
#endif
