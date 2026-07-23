import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ReflectionEngine {
	static func reflect(on transcript: String) async -> ReflectionResult {
		#if canImport(FoundationModels)
		if #available(iOS 26.0, *), let generated = try? await modelReflection(on: transcript) {
			return generated
		}
		#endif
		return fallbackReflection(on: transcript)
	}

	static func weeklyReview(entries: [JournalEntry], weekStart: Date) async -> WeeklyReview {
		let sorted = entries.sorted { $0.createdAt < $1.createdAt }
		let joined = sorted.map { $0.transcript }.joined(separator: "\n\n")

		#if canImport(FoundationModels)
		if #available(iOS 26.0, *), let generated = try? await modelWeeklyReview(transcript: joined, entries: sorted, weekStart: weekStart) {
			return generated
		}
		#endif

		let topics = Array(sorted.flatMap(\.tags).uniqued().prefix(3))
		let title = sorted.last?.headline ?? "No entries this week"
		let body = sorted.isEmpty
			? "There are no entries for this week yet."
			: sorted.map(\.transcript).joined(separator: " ")
		let trend = sorted.enumerated().map { index, entry in
			min(0.9, max(0.15, Double(entry.transcript.count % 80) / 100 + Double(index) * 0.08))
		}
		return WeeklyReview(weekStart: weekStart, title: title, body: body, tags: topics, trend: trend)
	}

	private static func fallbackReflection(on transcript: String) -> ReflectionResult {
		let sentences = transcript
			.split(whereSeparator: { ".!?".contains($0) })
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }

		let first = sentences.first ?? transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		let headline: String
		if first.isEmpty {
			headline = "No summary available"
		} else if first.count <= 100 {
			headline = first.hasSuffix(".") ? first : first + "."
		} else {
			headline = String(first.prefix(97)).trimmingCharacters(in: .whitespaces) + "…"
		}

		let observations = Array(sentences.prefix(3)).map { sentence in
			sentence.hasSuffix(".") ? sentence : sentence + "."
		}
		return ReflectionResult(
			headline: headline,
			observations: observations,
			tags: extractTags(from: transcript),
			modelName: "MyVoiceMemo local parser"
		)
	}

	private static func extractTags(from text: String) -> [String] {
		let stopWords: Set<String> = ["about", "after", "again", "also", "because", "been", "before", "could", "from", "have", "into", "just", "like", "really", "that", "their", "there", "they", "this", "today", "want", "were", "what", "when", "with", "would", "your", "youre"]
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.letters.inverted)
			.filter { $0.count > 3 && !stopWords.contains($0) }
		let counts = Dictionary(grouping: words, by: { $0 }).mapValues(\.count)
		return counts.sorted { left, right in
			left.value == right.value ? left.key < right.key : left.value > right.value
		}.prefix(3).map { $0.key.capitalized }
	}

	#if canImport(FoundationModels)
	@available(iOS 26.0, *)
	private static func modelReflection(on transcript: String) async throws -> ReflectionResult? {
		guard SystemLanguageModel.default.availability == .available else { return nil }
		let session = LanguageModelSession(instructions: """
		You reflect a private voice journal. Notice themes and tensions in the speaker's own words. Never give advice, diagnose, ask a question, or chat. Be specific, restrained, and kind. Return plain text in exactly this shape:
		TITLE: one second-person observation under 18 words
		OBSERVATIONS:
		- observation
		- observation
		- observation
		TAGS: short tag | short tag | short tag
		""")
		let response = try await session.respond(to: transcript)
		return parseReflection(response.content, modelName: "SystemLanguageModel.default")
	}

	@available(iOS 26.0, *)
	private static func modelWeeklyReview(transcript: String, entries: [JournalEntry], weekStart: Date) async throws -> WeeklyReview? {
		guard !entries.isEmpty, SystemLanguageModel.default.availability == .available else { return nil }
		let session = LanguageModelSession(instructions: """
		Write a weekly reflection for a private voice journal using only the speaker's entries. Notice repetition and change. Never give advice, diagnose, ask questions, or chat. Return plain text in exactly this shape:
		TITLE: one observation under 12 words
		BODY: one paragraph, 90 to 140 words
		TAGS: short tag | short tag | short tag
		""")
		let response = try await session.respond(to: transcript)
		let lines = response.content.components(separatedBy: .newlines)
		let title = value(after: "TITLE:", in: lines) ?? entries.last!.headline
		let body = value(after: "BODY:", in: lines) ?? transcript
		let tags = value(after: "TAGS:", in: lines)?.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
		let trend = entries.enumerated().map { index, entry in
			min(0.9, max(0.15, Double(entry.transcript.count % 80) / 100 + Double(index) * 0.08))
		}
		return WeeklyReview(weekStart: weekStart, title: title, body: body, tags: tags, trend: trend)
	}
	#endif

	private static func parseReflection(_ text: String, modelName: String) -> ReflectionResult? {
		let lines = text.components(separatedBy: .newlines)
		guard let title = value(after: "TITLE:", in: lines) else { return nil }
		let observations = lines
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { $0.hasPrefix("-") }
			.map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
		let tags = value(after: "TAGS:", in: lines)?.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
		return ReflectionResult(headline: title, observations: observations, tags: tags, modelName: modelName)
	}

	private static func value(after prefix: String, in lines: [String]) -> String? {
		lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
			.map { String($0.dropFirst($0.range(of: prefix)!.upperBound.utf16Offset(in: $0))).trimmingCharacters(in: .whitespaces) }
	}
}

private extension Sequence where Element: Hashable {
	func uniqued() -> [Element] {
		var seen = Set<Element>()
		return filter { seen.insert($0).inserted }
	}
}
