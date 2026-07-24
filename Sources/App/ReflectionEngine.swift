import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable(description: "A concise title and three grounded observations about a private voice memo")
private struct GeneratedReflection {
	@Guide(description: "A sentence-case title of 4 to 12 words naming the memo's central theme, realization, decision, or next step")
	var title: String

	@Guide(description: "Three concise observations grounded in the speaker's words", .count(3))
	var observations: [String]
}

@available(iOS 26.0, *)
@Generable(description: "A concise weekly reflection based on private voice memos")
private struct GeneratedWeeklyReview {
	@Guide(description: "A sentence-case title under 12 words naming the week's central pattern")
	var title: String

	@Guide(description: "One restrained paragraph of 90 to 140 words describing repetition and change")
	var body: String
}
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

		let title = sorted.last?.headline ?? "No entries this week"
		let body = sorted.isEmpty
			? "There are no entries for this week yet."
			: sorted.map(\.transcript).joined(separator: " ")
		let trend = sorted.enumerated().map { index, entry in
			min(0.9, max(0.15, Double(entry.transcript.count % 80) / 100 + Double(index) * 0.08))
		}
		return WeeklyReview(weekStart: weekStart, title: title, body: body, trend: trend)
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
			modelName: "MyVoiceMemo local parser"
		)
	}

	#if canImport(FoundationModels)
	@available(iOS 26.0, *)
	private static func modelReflection(on transcript: String) async throws -> ReflectionResult? {
		guard SystemLanguageModel.default.availability == .available else { return nil }
		let session = LanguageModelSession(instructions: """
		Read the entire private voice memo before responding. Identify its most meaningful theme, realization, decision, or next step. Ignore false starts, filler, transcription repetitions, and comments about making the recording. Never use the opening phrase as a title merely because it appears first. Keep the title natural, specific, sentence case, and free of ending punctuation. Make each observation specific, restrained, kind, and supported by the speaker's own words. Never give advice, diagnose, ask a question, or chat.
		""")
		let response = try await session.respond(
			to: transcript,
			generating: GeneratedReflection.self
		)
		return ReflectionResult(
			headline: cleanTitle(response.content.title),
			observations: response.content.observations.map(cleanSentence),
			modelName: "SystemLanguageModel.default · guided"
		)
	}

	@available(iOS 26.0, *)
	private static func modelWeeklyReview(transcript: String, entries: [JournalEntry], weekStart: Date) async throws -> WeeklyReview? {
		guard !entries.isEmpty, SystemLanguageModel.default.availability == .available else { return nil }
		let session = LanguageModelSession(instructions: """
		Read all entries before writing a weekly reflection. Use only the speaker's entries, notice repetition and change, and ignore transcription artifacts. Keep the title natural, specific, sentence case, and free of ending punctuation. Never give advice, diagnose, ask questions, or chat.
		""")
		let response = try await session.respond(
			to: transcript,
			generating: GeneratedWeeklyReview.self
		)
		let trend = entries.enumerated().map { index, entry in
			min(0.9, max(0.15, Double(entry.transcript.count % 80) / 100 + Double(index) * 0.08))
		}
		return WeeklyReview(
			weekStart: weekStart,
			title: cleanTitle(response.content.title),
			body: response.content.body.trimmingCharacters(in: .whitespacesAndNewlines),
			trend: trend
		)
	}
	#endif

	private static func cleanTitle(_ title: String) -> String {
		let cleaned = title
			.replacingOccurrences(of: "\n", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"“”"))
		guard let first = cleaned.first else { return "Voice memo" }
		return first.uppercased() + cleaned.dropFirst()
	}

	private static func cleanSentence(_ sentence: String) -> String {
		sentence
			.replacingOccurrences(of: "\n", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
