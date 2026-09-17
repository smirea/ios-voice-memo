#if DEBUG
import Foundation
import FoundationModels

@MainActor
enum ModelContextContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-model-context-contract-tests") else { return }
		do {
			try await completePromptBudget()
			try await losslessUnicode()
			try await preferredBoundaries()
			try await impossibleInputs()
			try await cancelledCounting()
			try bisectCoverage()
			try await nativeTokenBudget()
			print("MODEL CONTEXT CONTRACT: complete prompt reserves, lossless UTF16 coverage, preferred boundaries, typed oversized-input failures, cancellation, and strict bisection passed")
			fflush(stdout)
		} catch { fatalError("MODEL CONTEXT CONTRACT: \(error)") }
	}

	private static func nativeTokenBudget() async throws {
		guard #available(iOS 26.4, macOS 26.4, *) else {
			print("MODEL CONTEXT NATIVE: unavailable; this OS does not expose the native tokenizer")
			return
		}
		let model = SystemLanguageModel.default
		try expect(model.contextSize > 0, "The native model must report a positive runtime context size")
		print("MODEL CONTEXT NATIVE: checking runtime context and Unicode prompt counts")
		fflush(stdout)
		do {
			let instructions = "Summarize every supplied fact without adding unsupported information. Preserve facts written in any language."
			let schema = ContextFixtureSummary.generationSchema
			let safety = 256
			let budget = try await ModelContextBudget.make(instructions: instructions, schema: schema,
				outputTokens: 512, safetyTokens: safety, model: model)
			let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
			let schemaTokens = try await model.tokenCount(for: schema)
			try expect(budget.contextSize == model.contextSize, "The helper must use the model's runtime context size")
			let source = "FIRST_SENTINEL\n" + String(repeating: "下次会议请带蓝色文件夹。🎙️🧑🏽‍💻 e\u{301} العربية\n",
				count: max(256, min(4_096, model.contextSize / 12))) + "\nLAST_SENTINEL：海洋。"
			let chunks = try await budget.chunks(source, prompt: renderedPrompt)
			try validateCoverage(source, chunks)
			var maximumTokens = 0
			for chunk in chunks {
				let prompt = renderedPrompt(chunk)
				let promptTokens = try await model.tokenCount(for: Prompt(prompt))
				let total = instructionTokens + schemaTokens + promptTokens + budget.outputTokens + safety
				try expect(total <= model.contextSize,
					"Every complete Unicode prompt plus instructions, schema, output reserve, and safety must fit the native context")
				try await budget.requireFits(prompt)
				maximumTokens = max(maximumTokens, total)
			}
			print("MODEL CONTEXT NATIVE: passed; runtime context=\(model.contextSize), Unicode chunks=\(chunks.count), largest reserved request=\(maximumTokens); no semantic generation tested")
		} catch let error as Failure { throw error }
		catch let error as ModelContextError { throw error }
		catch is CancellationError { throw CancellationError() }
		catch { print("MODEL CONTEXT NATIVE: unavailable; native token counting could not be verified: \(error)") }
	}

	private static func completePromptBudget() async throws {
		let budget = try ModelContextBudget(contextSize: 512, instructionTokens: 31, schemaTokens: 47,
			outputTokens: 63, safetyTokens: 19, count: { $0.utf8.count })
		let available = 512 - 31 - 47 - 63 - 19
		try expect(try await budget.fits(String(repeating: "x", count: available)), "A prompt exactly at the remaining input budget must fit")
		try expect(try await !budget.fits(String(repeating: "x", count: available + 1)), "Instructions, schema, output reserve, and safety margin must all reduce usable input")
		let rejected = await failure { try await budget.requireFits(String(repeating: "x", count: available + 1)) }
		try requireError(rejected, matching: .promptTooLarge, message: "An oversized fully constructed prompt must fail explicitly")
		let source = String(repeating: "unpunctuatedsource", count: 240)
		let chunks = try await budget.chunks(source, prompt: renderedPrompt)
		try validateCoverage(source, chunks)
		try expect(chunks.count > 1, "The fixture must require multiple complete prompts")
		for chunk in chunks {
			let prompt = renderedPrompt(chunk)
			try await budget.requireFits(prompt)
			try expect(prompt.utf8.count + 31 + 47 + budget.outputTokens + 19 <= budget.contextSize,
				"Chunk fitting must include range labels and other prompt-builder overhead")
		}
	}

	private static func losslessUnicode() async throws {
		let sources = [
			"FIRST_SENTINEL\n" + String(repeating: "漢字東京。🙂e\u{301} 👩🏽‍💻 ", count: 120)
				+ "\nMIDDLE_SENTINEL\n" + String(repeating: "العربية हिन्दी Ελληνικά\n", count: 80) + "\nLAST_SENTINEL",
			"FIRST_SENTINEL" + String(repeating: "界👨‍👩‍👧‍👦e\u{301}", count: 180)
				+ "MIDDLE_SENTINEL" + String(repeating: "unpunctuated", count: 180) + "LAST_SENTINEL"
		]
		let budget = try ModelContextBudget(contextSize: 256, instructionTokens: 17, schemaTokens: 23,
			outputTokens: 32, safetyTokens: 8, count: { $0.utf8.count })
		for source in sources {
			let chunks = try await budget.chunks(source, prompt: renderedPrompt)
			try validateCoverage(source, chunks)
			try expect(chunks.count > 3 && chunks.count <= source.count, "Chunking must make nonempty progress through multilingual source text")
			for chunk in chunks { try await budget.requireFits(renderedPrompt(chunk)) }
		}
	}

	private static func preferredBoundaries() async throws {
		let budget = try ModelContextBudget(contextSize: 80, instructionTokens: 8, schemaTokens: 8,
			outputTokens: 8, safetyTokens: 0, count: { $0.utf8.count })
		let firstParagraph = "This paragraph describes the first task."
		let paragraphs = firstParagraph + "\n\n" + String(repeating: "The next paragraph continues with details. ", count: 8)
		let paragraphChunks = try await budget.chunks(paragraphs)
		try validateCoverage(paragraphs, paragraphChunks)
		try expect(paragraphChunks.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == firstParagraph,
			"A nearby complete paragraph boundary should be preferred to cutting into the next paragraph")
		let firstSentence = "The first sentence explains the task."
		let sentences = firstSentence + " " + String(repeating: "The second sentence adds more context. ", count: 8)
		let sentenceChunks = try await budget.chunks(sentences)
		try validateCoverage(sentences, sentenceChunks)
		try expect(sentenceChunks.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == firstSentence,
			"A nearby complete sentence boundary should be preferred to cutting its successor")
	}

	private static func impossibleInputs() async throws {
		for (instructions, schema, output, safety) in [(64, 0, 1, 0), (0, 64, 1, 0), (0, 0, 65, 0), (0, 0, 1, 64)] {
			let error = await failure {
				try ModelContextBudget(contextSize: 64, instructionTokens: instructions, schemaTokens: schema,
					outputTokens: output, safetyTokens: safety, count: { $0.utf8.count })
			}
			try requireError(error, matching: .fixedOverheadTooLarge, message: "Impossible fixed instructions, schema, output, or safety reserves must reject construction")
		}
		let budget = try ModelContextBudget(contextSize: 64, instructionTokens: 8, schemaTokens: 8,
			outputTokens: 8, safetyTokens: 0, count: { $0.utf8.count })
		let overhead = await failure {
			try await budget.chunks("Short source") { "A fixed prompt wrapper that alone exceeds all available input capacity. " + $0.text }
		}
		try requireError(overhead, matching: .fixedOverheadTooLarge, message: "An oversized prompt wrapper must fail before attempting unusable chunks")
		let rejectedReferent = await failure {
			try await budget.chunks("An indivisible source referent") { _ in throw ModelContextError.unsplittable }
		}
		try requireError(rejectedReferent, matching: .unsplittable, message: "A prompt builder must be able to reject required context without losing its error")
		let grapheme = "a" + String(repeating: "\u{301}", count: 200)
		try expect(grapheme.count == 1, "The oversized fixture must be one indivisible grapheme")
		let indivisible = await failure { try await budget.chunks("Before " + grapheme + " after") }
		try requireError(indivisible, matching: .unsplittable, message: "An oversized single grapheme must fail without dropping or splitting source text")
		let failingCounter = try ModelContextBudget(contextSize: 128, instructionTokens: 1, schemaTokens: 1,
			outputTokens: 1, safetyTokens: 0, count: { _ in throw CounterFailure() })
		let countFailure = await failure { try await failingCounter.chunks("Preserve a token counter failure") }
		try expect(countFailure is CounterFailure, "A token-count failure must propagate instead of silently using a different budget")
	}

	private static func cancelledCounting() async throws {
		let gate = CounterGate()
		let budget = try ModelContextBudget(contextSize: 128, instructionTokens: 8, schemaTokens: 8,
			outputTokens: 16, safetyTokens: 8, count: { await gate.count($0) })
		let source = "FIRST " + String(repeating: "漢字👨‍👩‍👧‍👦", count: 1_000) + " LAST"
		let task = Task { try await budget.chunks(source, prompt: renderedPrompt) }
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while await gate.calls == 0 {
			guard ContinuousClock.now < deadline else { throw Failure("Chunking never reached the token counter") }
			await Task.yield()
		}
		task.cancel()
		await gate.release()
		let error = await failure { try await task.value }
		let calls = await gate.calls
		try expect(error is CancellationError && calls == 1, "Cancellation during a token count must stop before further counting or source chunk publication")
	}

	private static func bisectCoverage() throws {
		let source = "FIRST 👩🏽‍💻 e\u{301} 漢字 MIDDLE " + String(repeating: "unpunctuated", count: 8) + " LAST"
		let offset = 37
		let original = ModelContextChunk(text: source, range: offset..<(offset + source.utf16.count))
		var pending = [original]
		var leaves: [ModelContextChunk] = []
		while let chunk = pending.popLast() {
			if chunk.text.count == 1 { leaves.append(chunk); continue }
			let parts = try ModelContextBudget.bisect(chunk)
			try expect(parts.count == 2 && parts.allSatisfy { !$0.text.isEmpty && $0.text.count < chunk.text.count },
				"Context-error bisection must make strict progress with two nonempty grapheme-aligned parts")
			try expect(parts.map(\.text).joined() == chunk.text && parts[0].range.lowerBound == chunk.range.lowerBound
				&& parts[0].range.upperBound == parts[1].range.lowerBound && parts[1].range.upperBound == chunk.range.upperBound,
				"Bisection must preserve text order and absolute UTF16 offsets")
			pending.append(contentsOf: parts.reversed())
		}
		try validateCoverage(source, leaves, offset: offset)
		let single = ModelContextChunk(text: "👨‍👩‍👧‍👦", range: 100..<111)
		do { _ = try ModelContextBudget.bisect(single); throw Failure("A single grapheme was split") }
		catch ModelContextError.unsplittable {}
	}

	private nonisolated static func renderedPrompt(_ chunk: ModelContextChunk) -> String {
		"Source UTF16 \(chunk.range.lowerBound)..<\(chunk.range.upperBound):\n\(chunk.text)\nReturn only grounded results."
	}
	private static func validateCoverage(_ source: String, _ chunks: [ModelContextChunk], offset: Int = 0) throws {
		let boundaries = Set(source.indices.map { $0.utf16Offset(in: source) } + [source.utf16.count])
		var next = offset
		for chunk in chunks {
			try expect(!chunk.text.isEmpty && chunk.range.lowerBound == next && chunk.range.count == chunk.text.utf16.count,
				"Chunks must cover contiguous nonempty UTF16 ranges without overlaps or gaps")
			let start = chunk.range.lowerBound - offset
			let end = chunk.range.upperBound - offset
			try expect(boundaries.contains(start) && boundaries.contains(end), "Every chunk boundary must be a complete extended grapheme boundary")
			try expect((source as NSString).substring(with: NSRange(location: start, length: end - start)) == chunk.text,
				"Each source range must identify exactly its chunk text")
			next = chunk.range.upperBound
		}
		try expect(next == offset + source.utf16.count && chunks.map(\.text).joined() == source,
			"Chunking must preserve all source content, including first, middle, and last sentinels")
	}
	private static func requireError(_ error: (any Error)?, matching expected: ModelContextError, message: String) throws {
		let matches: Bool
		switch (error as? ModelContextError, expected) {
		case (.fixedOverheadTooLarge, .fixedOverheadTooLarge), (.promptTooLarge, .promptTooLarge), (.unsplittable, .unsplittable): matches = true
		default: matches = false
		}
		try expect(matches, message)
	}
	private static func failure<T>(_ operation: () async throws -> T) async -> (any Error)? {
		do { _ = try await operation(); return nil } catch { return error }
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
	private struct CounterFailure: Error {}
	private actor CounterGate {
		private(set) var calls = 0
		private var continuation: CheckedContinuation<Void, Never>?
		func count(_ text: String) async -> Int {
			calls += 1
			if calls == 1 { await withCheckedContinuation { continuation = $0 } }
			return text.utf8.count
		}
		func release() { continuation?.resume(); continuation = nil }
	}
}

@Generable
private struct ContextFixtureSummary {
	var summary: String
}
#endif
