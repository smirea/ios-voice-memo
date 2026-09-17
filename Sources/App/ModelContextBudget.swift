import Foundation
import FoundationModels
import NaturalLanguage

struct ModelContextChunk: Equatable, Sendable {
	let text: String
	// UTF-16 offsets into the original source, always on grapheme boundaries.
	let range: Range<Int>
}

enum ModelContextError: Error { case fixedOverheadTooLarge, promptTooLarge, unsplittable }

struct ModelContextBudget: Sendable {
	let contextSize: Int
	let outputTokens: Int
	private let availableInputTokens: Int
	private let count: @Sendable (String) async throws -> Int

	init(contextSize: Int, instructionTokens: Int, schemaTokens: Int, outputTokens: Int,
		safetyTokens: Int = 256, count: @escaping @Sendable (String) async throws -> Int) throws {
		var available = contextSize
		for overhead in [instructionTokens, schemaTokens, outputTokens, safetyTokens] {
			guard overhead >= 0, overhead <= available else { throw ModelContextError.fixedOverheadTooLarge }
			available -= overhead
		}
		guard contextSize > 0 else { throw ModelContextError.fixedOverheadTooLarge }
		self.contextSize = contextSize
		self.outputTokens = outputTokens
		self.availableInputTokens = available
		self.count = count
	}

	static func make(instructions: String, schema: GenerationSchema, outputTokens: Int,
		safetyTokens: Int = 256, model: SystemLanguageModel = .default) async throws -> Self {
		try Task.checkCancellation()
		if #available(iOS 26.4, macOS 26.4, *) {
			let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
			try Task.checkCancellation()
			let schemaTokens = try await model.tokenCount(for: schema)
			try Task.checkCancellation()
			return try Self(contextSize: model.contextSize, instructionTokens: instructionTokens, schemaTokens: schemaTokens,
				outputTokens: outputTokens, safetyTokens: safetyTokens, count: { try await model.tokenCount(for: Prompt($0)) })
		}
		return try Self(contextSize: model.contextSize, instructionTokens: instructions.utf8.count,
			schemaTokens: JSONEncoder().encode(schema).count, outputTokens: outputTokens, safetyTokens: safetyTokens,
			count: { $0.utf8.count })
	}

	func fits(_ prompt: String) async throws -> Bool {
		try Task.checkCancellation()
		let tokens = try await count(prompt)
		try Task.checkCancellation()
		guard tokens >= 0 else { throw ModelContextError.promptTooLarge }
		return tokens <= availableInputTokens
	}

	func requireFits(_ prompt: String) async throws {
		guard try await fits(prompt) else { throw ModelContextError.promptTooLarge }
	}

	func chunks(_ source: String, prompt: @escaping @Sendable (ModelContextChunk) throws -> String = { $0.text }) async throws -> [ModelContextChunk] {
		guard try await fits(prompt(ModelContextChunk(text: "", range: 0..<0))) else {
			throw ModelContextError.fixedOverheadTooLarge
		}
		guard !source.isEmpty else { return [] }
		let entire = ModelContextChunk(text: source, range: 0..<source.utf16.count)
		if try await fits(prompt(entire)) { return [entire] }
		let indexed = try IndexedSource(source)
		var result: [ModelContextChunk] = []
		var start = 0
		while start < indexed.count {
			try Task.checkCancellation()
			var lower = start
			var upper = start + min(indexed.count - start, max(16, availableInputTokens))
			while try await fits(prompt(indexed.chunk(start..<upper))) {
				lower = upper
				if upper == indexed.count { break }
				upper += min(indexed.count - upper, upper - start)
			}
			while lower + 1 < upper {
				let middle = lower + (upper - lower) / 2
				if try await fits(prompt(indexed.chunk(start..<middle))) { lower = middle }
				else { upper = middle }
			}
			guard lower > start else { throw ModelContextError.unsplittable }
			var end = lower
			if lower < indexed.count, let preferred = indexed.preferredBoundary(in: (start + 1)...lower) {
				if try await fits(prompt(indexed.chunk(start..<preferred))) { end = preferred }
			}
			result.append(indexed.chunk(start..<end))
			start = end
		}
		return result
	}

	static func bisect(_ chunk: ModelContextChunk) throws -> [ModelContextChunk] {
		let indexed = try IndexedSource(chunk.text)
		guard indexed.count > 1, chunk.range.lowerBound >= 0, chunk.range.count == chunk.text.utf16.count else {
			throw ModelContextError.unsplittable
		}
		let middle = indexed.preferredBoundary(in: max(1, indexed.count / 4)...min(indexed.count - 1, indexed.count * 3 / 4))
			?? indexed.count / 2
		return [indexed.chunk(0..<middle, offset: chunk.range.lowerBound),
			indexed.chunk(middle..<indexed.count, offset: chunk.range.lowerBound)]
	}

	static func isContextError(_ error: any Error) -> Bool {
		if case ModelContextError.promptTooLarge = error { return true }
		if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
		return false
	}

	private struct IndexedSource {
		let text: String
		let indices: [String.Index]
		let offsets: [Int]
		let paragraphs: [Int]
		let sentences: [Int]
		var count: Int { indices.count - 1 }

		init(_ text: String) throws {
			try Task.checkCancellation()
			self.text = text
			var indices = [text.startIndex]
			var offsets = [0]
			var current = text.startIndex
			while current < text.endIndex {
				if indices.count.isMultiple(of: 1_024) { try Task.checkCancellation() }
				let next = text.index(after: current)
				indices.append(next)
				offsets.append(offsets.last! + text[current..<next].utf16.count)
				current = next
			}
			self.indices = indices
			self.offsets = offsets
			let positions = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
			var paragraphs: [Int] = []
			text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byParagraphs, .substringNotRequired]) { _, _, range, stop in
				if let position = positions[range.upperBound] { paragraphs.append(position) }
				stop = Task.isCancelled
			}
			self.paragraphs = paragraphs
			var sentences: [Int] = []
			let tokenizer = NLTokenizer(unit: .sentence)
			tokenizer.string = text
			tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
				if let position = positions[range.upperBound] { sentences.append(position) }
				return !Task.isCancelled
			}
			self.sentences = sentences
			try Task.checkCancellation()
		}

		func chunk(_ range: Range<Int>, offset: Int = 0) -> ModelContextChunk {
			ModelContextChunk(text: String(text[indices[range.lowerBound]..<indices[range.upperBound]]),
				range: (offset + offsets[range.lowerBound])..<(offset + offsets[range.upperBound]))
		}

		func preferredBoundary(in range: ClosedRange<Int>) -> Int? {
			lastBoundary(paragraphs, in: range) ?? lastBoundary(sentences, in: range)
		}

		private func lastBoundary(_ boundaries: [Int], in range: ClosedRange<Int>) -> Int? {
			var lower = 0
			var upper = boundaries.count
			while lower < upper {
				let middle = lower + (upper - lower) / 2
				if boundaries[middle] <= range.upperBound { lower = middle + 1 }
				else { upper = middle }
			}
			guard lower > 0, boundaries[lower - 1] >= range.lowerBound else { return nil }
			return boundaries[lower - 1]
		}
	}
}
