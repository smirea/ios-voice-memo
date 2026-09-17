#if DEBUG
import Foundation

@MainActor
enum ReflectionContextContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reflection-context-contract-tests") else { return }
		do {
			try await fittingAndReductionChecks()
			try await failureAndCancellationChecks()
			try await weeklyChecks()
			try analysisRoundTripChecks()
			print("REFLECTION CONTEXT CONTRACT: unchanged fitting input, all-range recursive reduction, bounded overflow retry, failure/cancellation, dated weekly coverage, and source-checked notes passed")
			fflush(nil)
		} catch { fatalError("REFLECTION CONTEXT CONTRACT: \(error)") }
	}

	private static func fittingAndReductionChecks() async throws {
		let final = try budget(260)
		let notes = try budget(700)
		let text = "You decided to protect an hour for focused work."
		let fitted = try await ReflectionEngine.boundedReflection(on: text, budget: final, notesBudget: notes,
			summarize: { _ in throw Failure("Fitting input was unnecessarily reduced") }) { prompt in
			try expect(prompt == text, "The fitting path must retain its original complete prompt")
			return ReflectionResult(headline: "Your focused hour", summary: "You protected an hour.", modelName: "Fixture")
		}
		try expect(fitted.analysisContext == fitted.summary, "Completed short analysis should be reusable as internal notes")
		let source = (1...200).map { "[\($0)] " + String(repeating: "originalword ", count: 20) + "\n" }.joined()
		let probe = Probe()
		let result = try await ReflectionEngine.boundedReflection(on: source, budget: final, notesBudget: notes,
			summarize: { try await probe.summarize($0) }) { prompt in
			try await final.requireFits(prompt)
			try expect(ids(prompt) == Array(1...200), "The final reduced context must represent every ordered child, including the tail")
			return ReflectionResult(headline: "All source passages", summary: "Completed", modelName: "Fixture")
		}
		let inputs = await probe.inputs
		try expect(inputs.filter { $0.contains("originalword") }.joined() == source,
			"The first reduction pass must cover the original text exactly once in order")
		try expect(inputs.contains { !$0.contains("originalword") }, "Long derived notes must pass through recursive reduction")
		try expect(result.analysisContext.map(ids) == Array(1...200), "Saved analysis context must cover the same complete reduction")
		let overflow = Probe(contextFailure: true)
		let divided = try await ReflectionEngine.reduceContext(source, budget: final, notesBudget: notes,
			summarize: { try await overflow.summarize($0) })
		let overflowFailures = await overflow.failures
		try expect(ids(divided) == Array(1...200) && overflowFailures == 1,
			"A native context error must split and retry the affected chunk without losing another range")
	}

	private static func failureAndCancellationChecks() async throws {
		let final = try budget(260), notes = try budget(700)
		let source = (1...20).map { "[\($0)] " + String(repeating: "originalword ", count: 20) + "\n" }.joined()
		let failed = Probe(failAt: 3)
		let result = await ReflectionEngine.reflect(on: source, includeSummary: true) {
			try await ReflectionEngine.boundedReflection(on: source, budget: final, notesBudget: notes,
				summarize: { try await failed.summarize($0) }) { _ in throw Failure("A failed chunk reached final generation") }
		}
		try expect(!result.outcome.isComplete && result.analysisContext == nil,
			"A failed middle chunk must remain incomplete and cannot publish derived notes")
		var stopped = false
		do {
			_ = try await ReflectionEngine.reduceContext(source, budget: final, notesBudget: notes, summarize: { $0 })
		} catch ReflectionContextError.noProgress { stopped = true }
		try expect(stopped, "An unexpectedly long model response must stop reduction instead of looping or dropping text")
		let attempts = Probe(alwaysOverflow: true)
		var exhausted = false
		do {
			_ = try await ReflectionEngine.reduceContext(source, budget: final, notesBudget: notes,
				summarize: { try await attempts.summarize($0) })
		} catch { exhausted = true }
		let attemptedInputs = await attempts.inputs.count
		try expect(exhausted && attemptedInputs <= 5, "Context split retries must have a finite depth")
		let held = Probe(hold: true)
		let task = Task {
			await ReflectionEngine.reflect(on: source, includeSummary: true) {
				try await ReflectionEngine.boundedReflection(on: source, budget: final, notesBudget: notes,
					summarize: { try await held.summarize($0) }) { _ in throw Failure("Canceled reduction reached final generation") }
			}
		}
		try await wait { await held.inputs.count == 1 }
		task.cancel()
		let canceled = await task.value
		try expect(canceled.outcome == .cancelled && canceled.analysisContext == nil, "Cancellation must stop all later chunks and preserve the canceled outcome")
	}

	private static func weeklyChecks() async throws {
		let final = try budget(360), notes = try budget(700)
		let start = Date(timeIntervalSince1970: 1_800_000_000)
		let entries = (1...30).map { index -> JournalEntry in
			let transcript = "[\(index)] " + String(repeating: "originalword ", count: 25)
			return JournalEntry(createdAt: start.addingTimeInterval(Double(index) * 60), duration: 10,
				transcript: transcript, headline: "Short note", analysis: index == 1 ? MemoAnalysis(transcript: transcript, notes: "<1:1>") : nil)
		}
		let probe = Probe()
		let context = try await ReflectionEngine.weeklyContext(entries: entries.reversed(), budget: final, notesBudget: notes,
			summarize: { try await probe.summarize($0) })
		try expect(ids(context) == Array(1...30), "The week must retain every note in order, including short notes with no visible summary")
		let inputs = await probe.inputs
		try expect(!inputs.contains(entries[0].transcript) && inputs.contains(entries[1].transcript),
			"A matching completed analysis is reused while a missing analysis is derived from its full memo")
		try expect(inputs.contains { $0.contains(start.addingTimeInterval(60).formatted(.iso8601)) },
			"Weekly reduction must receive dated records")
		var changed = entries[0]
		changed.transcript = "[99] A new short memo."
		let fresh = Probe()
		_ = try await ReflectionEngine.weeklyContext(entries: [changed], budget: final, notesBudget: notes,
			summarize: { try await fresh.summarize($0) })
		try expect(await fresh.inputs.contains(changed.transcript), "A stale fingerprint must never stand in for a changed transcript")
	}

	private static func analysisRoundTripChecks() throws {
		let original = JournalEntry(duration: 15, transcript: "Complete original words", headline: "A note",
			analysis: MemoAnalysis(transcript: "Complete original words", notes: "Completed notes"))
		let reloaded = try JSONDecoder().decode(JournalEntry.self, from: JSONEncoder().encode(original))
		try expect(reloaded.analysis?.matches(original.transcript) == true && reloaded.summary == nil,
			"Internal completed notes must survive persistence without adding a visible short-note summary")
		var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
		object.removeValue(forKey: "analysis")
		let legacy = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: object))
		try expect(legacy.analysis == nil && legacy.transcript == original.transcript, "Older saved notes must decode without derived analysis")
	}

	private actor Probe {
		private(set) var inputs: [String] = []
		private(set) var failures = 0
		let contextFailure: Bool
		let failAt: Int?
		let alwaysOverflow: Bool
		let hold: Bool
		init(contextFailure: Bool = false, failAt: Int? = nil, alwaysOverflow: Bool = false, hold: Bool = false) {
			self.contextFailure = contextFailure; self.failAt = failAt; self.alwaysOverflow = alwaysOverflow; self.hold = hold
		}
		func summarize(_ source: String) async throws -> String {
			inputs.append(source)
			if hold { try await Task.sleep(for: .seconds(5)) }
			if alwaysOverflow || (contextFailure && failures == 0) { failures += 1; throw ModelContextError.promptTooLarge }
			if inputs.count == failAt { throw Failure("Fixture chunk unavailable") }
			let represented = ReflectionContextContractChecks.ids(source)
			guard let first = represented.first, let last = represented.last else { throw Failure("A fixture fact was split unexpectedly") }
			return "<\(first):\(last)>"
		}
	}

	nonisolated private static func ids(_ text: String) -> [Int] {
		let expression = try! NSRegularExpression(pattern: #"\[(\d+)\]|<(\d+):(\d+)>"#)
		return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match -> [Int] in
			if let range = Range(match.range(at: 1), in: text), let value = Int(text[range]) { return [value] }
			guard let start = Range(match.range(at: 2), in: text), let end = Range(match.range(at: 3), in: text),
				let lower = Int(text[start]), let upper = Int(text[end]), lower <= upper else { return [] }
			return Array(lower...upper)
		}
	}
	nonisolated private static func budget(_ size: Int) throws -> ModelContextBudget {
		try ModelContextBudget(contextSize: size, instructionTokens: 20, schemaTokens: 20, outputTokens: 40, safetyTokens: 20,
			count: { $0.utf8.count })
	}
	private static func wait(_ condition: () async -> Bool) async throws {
		for _ in 0..<200 {
			if await condition() { return }
			try await Task.sleep(for: .milliseconds(5))
		}
		throw Failure("Timed out waiting for reduction")
	}
	nonisolated private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
