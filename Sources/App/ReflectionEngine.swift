import Foundation
import FoundationModels

@Generable(description: "A concise title for a private voice memo")
private struct GeneratedReflection {
	@Guide(description: "A sentence-case title of 4 to 12 words naming your central theme, realization, decision, or next step; use you rather than user or speaker")
	var title: String
}

@Generable(description: "A concise title and short summary for a private voice memo")
private struct GeneratedSummarizedReflection {
	@Guide(description: "A sentence-case title of 4 to 12 words naming your central theme, realization, decision, or next step; use you rather than user or speaker")
	var title: String

	@Guide(description: "A factual summary of 1 or 2 sentences and no more than 60 words, covering the whole memo and addressing its owner as you")
	var summary: String
}

@Generable(description: "A concise weekly reflection based on private voice memos")
private struct GeneratedWeeklyReview {
	@Guide(description: "A sentence-case title under 12 words naming the week's central pattern")
	var title: String

	@Guide(description: "One restrained paragraph of 90 to 140 words describing your repetition and change, addressing you directly")
	var body: String
}

enum ReflectionEngine {
	static func reflect(on transcript: String, includeSummary: Bool) async -> ReflectionResult {
		if let generated = try? await withGenerationTimeout({
			try await modelReflection(
				on: transcript,
				includeSummary: includeSummary
			)
		}) {
			return generated
		}
		return fallbackReflection(on: transcript, includeSummary: includeSummary)
	}

	static func weeklyReview(entries: [JournalEntry], weekStart: Date) async -> WeeklyReview {
		let sorted = entries.sorted { $0.createdAt < $1.createdAt }
		let joined = sorted.map { $0.transcript }.joined(separator: "\n\n")

		if let generated = try? await withGenerationTimeout({
			try await modelWeeklyReview(
				transcript: joined,
				entries: sorted,
				weekStart: weekStart
			)
		}) {
			return generated
		}

		let title = sorted.last?.headline ?? "No entries this week"
		let body = sorted.isEmpty
			? "There are no entries for this week yet."
			: sorted.map(\.transcript).joined(separator: " ")
		let trend = sorted.enumerated().map { index, entry in
			min(0.9, max(0.15, Double(entry.transcript.count % 80) / 100 + Double(index) * 0.08))
		}
		return WeeklyReview(weekStart: weekStart, title: title, body: body, trend: trend)
	}

	private static func fallbackReflection(
		on transcript: String,
		includeSummary: Bool
	) -> ReflectionResult {
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

		return ReflectionResult(
			headline: headline,
			summary: includeSummary
				? sentences.prefix(2).map(cleanSentence).joined(separator: ". ").nonempty
				: nil,
			modelName: "MyVoiceMemo local parser"
		)
	}

	private static func modelReflection(
		on transcript: String,
		includeSummary: Bool
	) async throws -> ReflectionResult? {
		guard SystemLanguageModel.default.availability == .available else { return nil }
		let session = LanguageModelSession(instructions: """
		Read the entire private voice memo before responding. Identify its most meaningful theme, realization, decision, or next step. Ignore false starts, filler, transcription repetitions, and comments about making the recording. Never use the opening phrase as a title merely because it appears first. Keep the title natural, specific, sentence case, and free of ending punctuation. Summaries must cover the whole memo without interpretation or advice. Address the memo owner directly as "you"; never call them "the user," "user," or "the speaker." Never output filenames, logs, metadata, identifiers, or other tokens absent from the memo. Never give advice, diagnose, ask a question, or chat.
		""")
		if includeSummary {
			let response = try await session.respond(
				to: transcript,
				generating: GeneratedSummarizedReflection.self
			)
			guard !containsUngroundedArtifact(response.content.title, transcript: transcript),
				!containsUngroundedArtifact(response.content.summary, transcript: transcript)
			else { return nil }
			return ReflectionResult(
				headline: cleanTitle(response.content.title),
				summary: cleanSentence(response.content.summary).nonempty,
				modelName: "SystemLanguageModel.default · guided"
			)
		}
		let response = try await session.respond(
			to: transcript,
			generating: GeneratedReflection.self
		)
		guard !containsUngroundedArtifact(response.content.title, transcript: transcript) else {
			return nil
		}
		return ReflectionResult(
			headline: cleanTitle(response.content.title),
			summary: nil,
			modelName: "SystemLanguageModel.default · guided"
		)
	}

	private static func modelWeeklyReview(transcript: String, entries: [JournalEntry], weekStart: Date) async throws -> WeeklyReview? {
		guard !entries.isEmpty, SystemLanguageModel.default.availability == .available else { return nil }
		let session = LanguageModelSession(instructions: """
		Read all entries before writing a weekly reflection. Use only these entries, notice repetition and change, and ignore transcription artifacts. Address their owner directly as "you"; never call them "the user," "user," or "the speaker." Keep the title natural, specific, sentence case, and free of ending punctuation. Never give advice, diagnose, ask questions, or chat.
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

	private static func cleanTitle(_ title: String) -> String {
		let cleaned = title
			.replacingOccurrences(of: "\n", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"“”"))
		guard let first = cleaned.first else { return "Voice memo" }
		return first.uppercased() + cleaned.dropFirst()
	}

	private static func cleanSentence(_ sentence: String) -> String {
		let cleaned = sentence
			.replacingOccurrences(of: "\n", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let first = cleaned.first else { return "" }
		return first.uppercased() + cleaned.dropFirst()
	}

	static func containsUngroundedArtifact(
		_ generated: String,
		transcript: String
	) -> Bool {
		if (generated.contains("{") || generated.contains("}")),
			!transcript.contains("{"),
			!transcript.contains("}") {
			return true
		}
		let pattern = #"(?i)\b[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*\.(?:log|json|txt|csv|md)\b"#
		guard let expression = try? NSRegularExpression(pattern: pattern) else {
			return false
		}
		let range = NSRange(generated.startIndex..., in: generated)
		return expression.matches(in: generated, range: range).contains { match in
			guard let matchRange = Range(match.range, in: generated) else { return false }
			return !transcript.reminderNormalized.contains(
				String(generated[matchRange]).reminderNormalized
			)
		}
	}

	private static func withGenerationTimeout<T: Sendable>(
		_ operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask { try await operation() }
			group.addTask {
				try await Task.sleep(for: .seconds(45))
				throw ReflectionGenerationError.timedOut
			}
			guard let result = try await group.next() else {
				throw ReflectionGenerationError.timedOut
			}
			group.cancelAll()
			return result
		}
	}
}

private enum ReflectionGenerationError: Error {
	case timedOut
}

private extension String {
	var nonempty: String? {
		isEmpty ? nil : self
	}
}
