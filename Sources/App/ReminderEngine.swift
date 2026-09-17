import Foundation
import FoundationModels

@Generable(description: "The final useful event-specific reminders from a complete voice memo and any corrections")
private struct GeneratedReminderBatch {
	@Guide(description: "Every distinct useful reminder after applying all corrections, including zero")
	var reminders: [GeneratedReminderDraft]
}

@Generable(description: "One complete event-reminder action grounded in the supplied memo")
struct GeneratedReminderDraft {
	@Guide(description: "A short imperative checklist item")
	var text: String

	@Guide(description: "Why this reminder will be useful at the matching event, addressing the note owner as you and never as user or speaker")
	var motivation: String

	@Guide(description: "A brief exact contiguous excerpt from the memo or later correction that supports the reminder")
	var evidence: String
}

@Generable(description: "The grounded calendar-event target for one reminder")
struct GeneratedReminderSchedule {
	@Guide(description: "A short exact contiguous excerpt establishing the target event, frequency, or duration; use the action evidence when it contains this context")
	var scheduleContext: String

	@Guide(description: "Preserve every specific event name or stable event class stated for this action")
	var eventDescription: String

	@Guide(description: "A required location you stated, or none when there is no location constraint")
	var locationDescription: String
}

private struct GeneratedReminder: Sendable {
	var text: String
	var motivation: String
	var evidence: String
	var scheduleContext: String
	var attachesToSource: Bool
	var eventDescription: String
	var locationDescription: String
	var occurrencePolicy: EventReminderOccurrencePolicy
	var validity: ReminderRelativeValidity?

	init(
		draft: GeneratedReminderDraft,
		schedule: GeneratedReminderSchedule,
		attachesToSource: Bool,
		occurrencePolicy: EventReminderOccurrencePolicy,
		validity: ReminderRelativeValidity?
	) {
		text = draft.text
		motivation = draft.motivation
		evidence = draft.evidence
		scheduleContext = schedule.scheduleContext
		self.attachesToSource = attachesToSource
		eventDescription = schedule.eventDescription
		locationDescription = schedule.locationDescription
		self.occurrencePolicy = occurrencePolicy
		self.validity = validity
	}
}

struct GroundedReminderSchedule: Sendable {
	var context: String
	var eventDescription: String
	var occurrencePolicy: EventReminderOccurrencePolicy
	var validity: ReminderRelativeValidity?
}

struct ReminderRelativeValidity: Sendable {
	var value: Int
	var component: Calendar.Component
}

@Generable(description: "A conservative decision about one candidate calendar event")
struct GeneratedEventMatch {
	@Guide(description: "Whether the candidate clearly matches every stated selector constraint")
	var matches: Bool

	@Guide(description: "A short explanation grounded in the candidate and selector")
	var reason: String
}

struct ReminderParsingResult: Sendable {
	var reminders: [EventReminderRule]
	var modelName: String?
	var outcome: ModelProcessingOutcome = .complete
}

struct ReminderResolutionUpdate: Sendable {
	var reminderID: UUID
	var occurrence: JournalCalendarEvent?
	var examples: [ReminderMatchExample]?
}

struct ReminderResolutionResult: Sendable {
	var occurrences: [EventReminderOccurrence]
	var examplesByReminderID: [UUID: [ReminderMatchExample]]
	var resolvedOccurrencesByReminderID: [UUID: JournalCalendarEvent]
	var incompleteReminderIDs: Set<UUID> = []
	var outcome: ModelProcessingOutcome = .complete
}

private struct ReminderResponseIncomplete: Error {}

struct ReminderModelServices: Sendable {
	var budget: @Sendable (String, GenerationSchema, Int) async throws -> ModelContextBudget
	var drafts: @Sendable (String, String, Int) async throws -> [GeneratedReminderDraft]
	var schedule: @Sendable (String, String, Int) async throws -> GeneratedReminderSchedule
	var match: @Sendable (String, String, Int) async throws -> GeneratedEventMatch

	static let live = Self(budget: { try await ModelContextBudget.make(instructions: $0, schema: $1, outputTokens: $2) },
		drafts: { instructions, prompt, _ in
			let response = try await LanguageModelSession(instructions: instructions).respond(to: prompt,
				generating: GeneratedReminderBatch.self)
			guard response.rawContent.isComplete else { throw ReminderResponseIncomplete() }
			return response.content.reminders
		}, schedule: { instructions, prompt, _ in
			let response = try await LanguageModelSession(instructions: instructions).respond(to: prompt,
				generating: GeneratedReminderSchedule.self)
			guard response.rawContent.isComplete else { throw ReminderResponseIncomplete() }
			return response.content
		}, match: { instructions, prompt, _ in
			let response = try await LanguageModelSession(instructions: instructions).respond(to: prompt,
				generating: GeneratedEventMatch.self)
			guard response.rawContent.isComplete else { throw ReminderResponseIncomplete() }
			return response.content
		})
}

enum ReminderEngine {
	private static let draftInstructions = """
		Read the complete event-attached memo before extracting anything. Return the final useful reminders after applying every correction in order. A reminder is an action you gave your future self for immediately before or during a calendar event.

		Use context across sentences. Resolve "this event," "the game," "same thing," "today and tomorrow," and similar references before deciding whether an action is useful. If the same action applies to multiple events, create one reminder for that action rather than duplicate phrasings.

		Evidence must be exact contiguous text copied from the original memo or a correction. Preserve every stated name, color, condition, and correction in the action.

		Hard exclusions:
		- Past observations without a future action.
		- Negated, canceled, superseded, hypothetical, or rejected ideas.
		- Another person's intention or obligation.
		- General errands, habits, or appointments to schedule.
		- Vague advice that would waste attention.

		Keep related people facts together. Keep distinct actions separate. Do not create duplicate phrasings of the same action. Existing reminders are context, not evidence. Corrections are authoritative: add what was missed, replace what changed, and omit anything removed. Return any useful number of reminders, including zero. Address the note owner as "you," never as user or speaker.
		"""

	static func parse(
		transcript: String,
		sourceEvent: JournalCalendarEvent?,
		createdAt: Date,
		currentReminders: [EventReminderRule] = [],
		feedback: [ReminderFeedback] = [],
		modelIsAvailable: @Sendable () -> Bool = { SystemLanguageModel.default.availability == .available },
		services: ReminderModelServices = .live
	) async -> ReminderParsingResult {
		guard !Task.isCancelled else {
			return ReminderParsingResult(reminders: currentReminders, modelName: nil, outcome: .cancelled)
		}
		guard let sourceEvent else {
			return ReminderParsingResult(reminders: [], modelName: nil, outcome: .skipped)
		}
		let corpus = ([transcript] + feedback.map(\.text)).joined(separator: "\n")
		guard !corpus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return ReminderParsingResult(reminders: [], modelName: nil, outcome: .skipped)
		}
		return await parse(currentReminders: currentReminders) {
			let generated = try await generatedReminders(
				transcript: transcript,
				sourceEvent: sourceEvent,
				currentReminders: currentReminders,
				feedback: feedback,
				modelIsAvailable: modelIsAvailable, services: services
			)
			let rules = generated.reminders.compactMap {
				rule(
					from: $0,
					sourceEvent: sourceEvent,
					createdAt: createdAt,
					evidenceCorpus: corpus.reminderNormalized
				)
			}
			return ReminderParsingResult(
				reminders: applyingManualRemovals(
					to: deduplicated(rules),
					feedback: feedback
				),
				modelName: generated.usedModel ? "SystemLanguageModel.default · guided reminders" : nil
			)
		}
	}

	static func parse(
		currentReminders: [EventReminderRule],
		generation: @Sendable () async throws -> ReminderParsingResult
	) async -> ReminderParsingResult {
		do {
			try Task.checkCancellation()
			let result = try await generation()
			try Task.checkCancellation()
			return result
		} catch {
			let outcome = ModelProcessingOutcome.failure(error,
				message: "The on-device model could not finish finding reminders. Try again.")
			if outcome != .cancelled, ProcessInfo.processInfo.arguments.contains("-reminder-benchmark") {
				print("REMINDER_GENERATION_ERROR \(outcome)")
			}
			return ReminderParsingResult(reminders: currentReminders, modelName: nil, outcome: outcome)
		}
	}

	static func resolve(
		entries: [JournalEntry],
		events: [JournalCalendarEvent],
		now: Date = .now,
		modelIsAvailable: @Sendable () -> Bool = { SystemLanguageModel.default.availability == .available },
		services: ReminderModelServices = .live
	) async -> ReminderResolutionResult {
		do {
			return try await resolvedReminders(entries: entries, events: events, now: now, modelIsAvailable: modelIsAvailable, services: services)
		} catch {
			return ReminderResolutionResult(occurrences: [], examplesByReminderID: [:],
				resolvedOccurrencesByReminderID: [:], outcome: .failure(error,
					message: "The on-device model could not finish matching reminders. Try again."))
		}
	}

	private static func resolvedReminders(
		entries: [JournalEntry],
		events: [JournalCalendarEvent],
		now: Date,
		modelIsAvailable: @Sendable () -> Bool,
		services: ReminderModelServices
	) async throws -> ReminderResolutionResult {
		try Task.checkCancellation()
		var occurrences: [EventReminderOccurrence] = []
		var examplesByReminderID: [UUID: [ReminderMatchExample]] = [:]
		var resolvedOccurrencesByReminderID: [UUID: JournalCalendarEvent] = [:]
		var incompleteReminderIDs: Set<UUID> = []
		var outcome: ModelProcessingOutcome = .complete
		let orderedEvents = events.sorted { $0.startDate < $1.startDate }

		for entry in entries {
			for reminder in entry.reminders where reminder.isActive(at: now) {
				try Task.checkCancellation()
				let candidatesAfterCreation = orderedEvents.filter {
					$0.startDate > reminder.createdAt
				}
				let matchedEvents: [JournalCalendarEvent]

				switch reminder.selector {
				case let .series(series):
					matchedEvents = candidatesAfterCreation.filter { series.matches($0) }
				case let .fuzzy(selector):
					let result = try await match(selector: selector, candidates: orderedEvents, modelIsAvailable: modelIsAvailable, services: services)
					let decisions = result.decisions
					if !result.outcome.isComplete {
						incompleteReminderIDs.insert(reminder.id)
						outcome = result.outcome
					}
					matchedEvents = candidatesAfterCreation.filter {
						decisions[$0.focusKey]?.matches == true
					}
					examplesByReminderID[reminder.id] = matchExamples(
						from: events,
						selector: selector,
						decisions: decisions
					)
				}

				let selected: [JournalCalendarEvent]
				if reminder.occurrencePolicy == .nextMatch {
					if let resolved = reminder.resolvedOccurrence, resolved.endDate < now {
						selected = []
					} else if let resolved = reminder.resolvedOccurrence,
						let current = orderedEvents.first(where: { $0.focusKey == resolved.focusKey }) {
						selected = current.endDate >= now ? [current] : []
					} else if !incompleteReminderIDs.contains(reminder.id),
						let next = matchedEvents.first(where: { $0.endDate >= now }) {
						selected = [next]
						resolvedOccurrencesByReminderID[reminder.id] = next
					} else {
						selected = []
					}
				} else {
					selected = matchedEvents.filter { $0.endDate >= now }
				}
				occurrences.append(contentsOf: selected.map {
					EventReminderOccurrence(sourceEntryID: entry.id, reminder: reminder, event: $0)
				})
			}
		}

		try Task.checkCancellation()
		return ReminderResolutionResult(
			occurrences: occurrences.sorted { $0.event.startDate < $1.event.startDate },
			examplesByReminderID: examplesByReminderID,
			resolvedOccurrencesByReminderID: resolvedOccurrencesByReminderID,
			incompleteReminderIDs: incompleteReminderIDs,
			outcome: outcome
		)
	}

	private static func generatedReminders(
		transcript: String,
		sourceEvent: JournalCalendarEvent,
		currentReminders: [EventReminderRule],
		feedback: [ReminderFeedback],
		modelIsAvailable: @Sendable () -> Bool,
		services: ReminderModelServices
	) async throws -> (reminders: [GeneratedReminder], usedModel: Bool) {
		try Task.checkCancellation()
		let evidenceCorpus = ([transcript] + feedback.map(\.text)).joined(separator: "\n")
		guard sentenceExcerpts(evidenceCorpus).contains(where: hasFutureCueSignal) else {
			return ([], false)
		}
		guard modelIsAvailable() else { throw ModelProcessingError.unavailable }

		let existing = currentReminders.isEmpty
			? "None"
			: currentReminders.map {
				"- \($0.text) — \($0.occurrencePolicy.rawValue) \($0.selector.title)"
			}.joined(separator: "\n")
		let corrections = feedback.isEmpty
			? "None"
			: feedback.enumerated().map { index, correction in
				"\(index + 1). \(correction.kind.rawValue): \(correction.text)"
			}.joined(separator: "\n")
		let instructions = draftInstructions
		let prompt = """
		Attached event:
		Title: \(sourceEvent.title)
		Location: \(sourceEvent.location ?? "None")
		Recurring: \(sourceEvent.isRecurring)

		Original memo:
		\(transcript)

		Existing reminders:
		\(existing)

		Corrections, oldest to newest:
		\(corrections)
		"""
		let budget = try await services.budget(instructions, GeneratedReminderBatch.generationSchema, 1536)
		let drafts: [GeneratedReminderDraft]
		if try await budget.fits(prompt) {
			do { drafts = try await requestDrafts(instructions: instructions, prompt: prompt, budget: budget, services: services) }
			catch {
				guard isRetryableContext(error) else { throw error }
				drafts = try await boundedDrafts(transcript: transcript, sourceEvent: sourceEvent,
					feedback: feedback, corpus: evidenceCorpus, budget: budget, services: services)
			}
		} else {
			drafts = try await boundedDrafts(transcript: transcript, sourceEvent: sourceEvent,
				feedback: feedback, corpus: evidenceCorpus, budget: budget, services: services)
		}
		var reminders: [GeneratedReminder] = []
		for draft in uniqueGroundedDrafts(drafts, corpus: evidenceCorpus) {
			try Task.checkCancellation()
			reminders.append(try await generatedReminder(from: draft, sourceEvent: sourceEvent, evidenceCorpus: evidenceCorpus, services: services))
		}
		return (reminders, true)
	}

	private static func requestDrafts(instructions: String, prompt: String, budget: ModelContextBudget,
		services: ReminderModelServices) async throws -> [GeneratedReminderDraft] {
		try await budget.requireFits(prompt)
		return try await ServiceAdmission.model.run(timeout: .seconds(45)) {
			try await budget.requireFits(prompt)
			return try await services.drafts(instructions, prompt, budget.outputTokens)
		}
	}

	private static func boundedDrafts(transcript: String, sourceEvent: JournalCalendarEvent,
		feedback: [ReminderFeedback], corpus: String,
		budget: ModelContextBudget, services: ReminderModelServices) async throws -> [GeneratedReminderDraft] {
		let references = namedReferences(in: corpus)
		var drafts: [GeneratedReminderDraft] = []
		var sourceOffset = 0
		let sources = [transcript] + feedback.map(\.text)
		for (sourceIndex, source) in sources.enumerated() {
			let offset = sourceOffset
			sourceOffset += source.utf16.count + 1
			guard !source.isEmpty else { continue }
			let chunks = try await budget.chunks(source) { chunk in
				try passagePrompt(chunk, sourceIndex: sourceIndex, event: sourceEvent,
					references: referenceContext(references, before: offset + chunk.range.lowerBound, query: chunk.text, budget: budget),
					existing: [], revising: false)
			}
			for chunk in chunks {
				drafts = try await applyPassage(chunk, sourceIndex: sourceIndex, event: sourceEvent,
					references: references, sourceOffset: offset, drafts: drafts, corpus: corpus, budget: budget, services: services, retries: 3)
			}
		}
		return drafts
	}

	private static func applyPassage(_ chunk: ModelContextChunk, sourceIndex: Int, event: JournalCalendarEvent,
		references: [ReminderReferent], sourceOffset: Int, drafts: [GeneratedReminderDraft], corpus: String, budget: ModelContextBudget,
		services: ReminderModelServices, retries: Int) async throws -> [GeneratedReminderDraft] {
		try Task.checkCancellation()
		let context = try referenceContext(references, before: sourceOffset + chunk.range.lowerBound, query: chunk.text, budget: budget)
		do {
			var updated: [GeneratedReminderDraft] = []
			var shard: [GeneratedReminderDraft] = []
			for draft in drafts {
				let proposed = shard + [draft]
				let prompt = passagePrompt(chunk, sourceIndex: sourceIndex, event: event, references: context,
					existing: proposed, revising: true)
				if !(try await budget.fits(prompt)), !shard.isEmpty {
					updated += try await requestDrafts(instructions: draftInstructions,
						prompt: passagePrompt(chunk, sourceIndex: sourceIndex, event: event, references: context,
							existing: shard, revising: true), budget: budget, services: services)
					shard = []
				}
				shard.append(draft)
				try await budget.requireFits(passagePrompt(chunk, sourceIndex: sourceIndex, event: event,
					references: context, existing: shard, revising: true))
			}
			if !shard.isEmpty {
				updated += try await requestDrafts(instructions: draftInstructions,
					prompt: passagePrompt(chunk, sourceIndex: sourceIndex, event: event, references: context,
						existing: shard, revising: true), budget: budget, services: services)
			}
			updated += try await requestDrafts(instructions: draftInstructions,
				prompt: passagePrompt(chunk, sourceIndex: sourceIndex, event: event, references: context,
					existing: [], revising: false), budget: budget, services: services)
			return uniqueGroundedDrafts(updated, corpus: corpus)
		} catch {
			guard retries > 0, isRetryableContext(error) else { throw error }
			let halves = try ModelContextBudget.bisect(chunk)
			var updated = drafts
			for half in halves {
				updated = try await applyPassage(half, sourceIndex: sourceIndex, event: event, references: references, sourceOffset: sourceOffset,
					drafts: updated, corpus: corpus, budget: budget, services: services, retries: retries - 1)
			}
			return updated
		}
	}

	private static func passagePrompt(_ chunk: ModelContextChunk, sourceIndex: Int, event: JournalCalendarEvent,
		references: String, existing: [GeneratedReminderDraft], revising: Bool) -> String {
		let task = revising
			? "Revise only the supplied candidate shard using this later passage. Return every unchanged candidate, replace corrected candidates, and omit canceled candidates. Do not add unrelated actions. Earlier evidence remains valid."
			: "Extract additions explicitly supported by this passage. Exclude canceled or negated actions. Candidate revision is handled separately. Use named references only to resolve the event target, never as action evidence."
		return """
		Task: \(task)
		Attached event: \(event.title)
		Preceding named event references (context only):
		\(references)
		Source: \(sourceIndex == 0 ? "original memo" : "correction \(sourceIndex)"); UTF16 range: \(chunk.range.lowerBound)..<\(chunk.range.upperBound)
		Passage:
		\(chunk.text)
		End passage.
		Candidate shard:
		\(existing.map { "Action: \($0.text)\nWhy: \($0.motivation)\nEvidence: \($0.evidence)" }.joined(separator: "\n\n"))
		"""
	}

	private static func uniqueGroundedDrafts(_ drafts: [GeneratedReminderDraft], corpus: String) -> [GeneratedReminderDraft] {
		var keys = Set<String>()
		return drafts.filter { draft in
			guard groundedExcerpt(draft.evidence, in: corpus) != nil else { return false }
			return keys.insert(draft.text.reminderNormalized + "\n" + draft.evidence.reminderNormalized).inserted
		}
	}

	private struct ReminderReferent: Sendable {
		var text: String
		var range: Range<Int>
		var group: Range<Int>
	}

	private static func namedReferences(in corpus: String) -> [ReminderReferent] {
		var references: [ReminderReferent] = []
		let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)
		corpus.enumerateSubstrings(in: corpus.startIndex..<corpus.endIndex, options: [.bySentences]) { sentence, range, _, _ in
			guard let sentence else { return }
			let ranges = expression.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence))
				.compactMap { Range($0.range, in: sentence) }
			let words = ranges.map { String(sentence[$0]).reminderNormalized }
			for name in explicitEventDescriptions(in: sentence) {
				let target = name.split(separator: " ").map(String.init)
				guard !target.isEmpty, target.count <= words.count,
					let start = (0...(words.count - target.count)).first(where: { Array(words[$0..<($0 + target.count)]) == target })
				else { continue }
				let local = ranges[start].lowerBound..<ranges[start + target.count - 1].upperBound
				let lower = range.lowerBound.utf16Offset(in: corpus) + local.lowerBound.utf16Offset(in: sentence)
				let text = String(sentence[local])
				references.append(ReminderReferent(text: text, range: lower..<(lower + text.utf16.count),
					group: range.lowerBound.utf16Offset(in: corpus)..<range.upperBound.utf16Offset(in: corpus)))
			}
		}
		return references
	}

	private static func referenceContext(_ references: [ReminderReferent], before offset: Int,
		query: String, budget: ModelContextBudget) throws -> String {
		var names = Set<String>()
		let preceding = references.reversed().filter {
			$0.range.upperBound <= offset && names.insert($0.text.reminderNormalized).inserted
		}
		let grouped = Dictionary(grouping: preceding, by: \.group)
		let normalized = query.reminderNormalized
		let classes = ["game", "call", "class", "gym", "meeting", "meetup", "practice", "session", "standup", "workshop"]
		let targets = classes.filter { normalized.split(separator: " ").contains(Substring($0)) }
		let matching = preceding.filter { reference in targets.contains { reference.text.reminderNormalized.contains($0) } }
		let shared = ["as well", "same thing", "same goal", "same for", "today and tomorrow", "today or tomorrow"]
			.contains(where: normalized.contains)
		var requiredGroups = Set<Range<Int>>()
		if let nearest = matching.first {
			requiredGroups.insert(nearest.group)
			if shared, matching.filter({ $0.group == nearest.group }).count < 2,
				let previous = matching.first(where: { $0.group != nearest.group }) {
				requiredGroups.insert(previous.group)
			}
		}
		var selected = preceding.filter { requiredGroups.contains($0.group) }
		var groups = requiredGroups
		let limit = max(128, min(1_024, budget.contextSize / 4))
		var bytes = selected.reduce(0) { $0 + $1.text.utf8.count + 40 }
		guard bytes <= limit else { throw ModelContextError.fixedOverheadTooLarge }
		for reference in preceding where !groups.contains(reference.group) {
			let group = grouped[reference.group, default: []]
			let size = group.reduce(0) { $0 + $1.text.utf8.count + 40 }
			groups.insert(reference.group)
			guard bytes + size <= limit else { continue }
			selected.append(contentsOf: group)
			bytes += size
		}
		return selected.sorted { $0.range.lowerBound < $1.range.lowerBound }.map {
			"Original UTF16 \($0.range.lowerBound)..<\($0.range.upperBound): \($0.text)"
		}.joined(separator: "\n")
	}

	private static func isRetryableContext(_ error: any Error) -> Bool {
		ModelContextBudget.isContextError(error) || error is ReminderResponseIncomplete
	}

	private static func generatedReminder(
		from draft: GeneratedReminderDraft,
		sourceEvent: JournalCalendarEvent,
		evidenceCorpus: String,
		services: ReminderModelServices
	) async throws -> GeneratedReminder {
		try Task.checkCancellation()
		let fallback = groundedSchedule(
			for: draft.evidence,
			in: evidenceCorpus
		)
		let fallbackDescriptions = explicitEventDescriptions(in: fallback.context)
		let sharedTargetSignals = [
			"as well", "same thing", "same goal", "same for",
			"today and tomorrow", "today or tomorrow"
		]
		let needsModel = fallback.eventDescription.isEmpty
			|| mayContainLocationConstraint(fallback.context)
			|| (fallbackDescriptions.count > 1
				&& !sharedTargetSignals.contains(where: fallback.context.reminderNormalized.contains))
		let generated: GeneratedReminderSchedule?
		if needsModel {
			let instructions = """
			Determine the calendar-event target for one already-extracted action. Read the complete memo context and resolve pronouns or generic references such as "the game" from earlier specific names.

			Schedule context must be exact contiguous text copied from the supplied memo context and retain the target, frequency, and duration. For a cue applying to multiple explicitly named events, preserve every name in eventDescription; never reduce names such as "Ultimate Werewolf" and "Blood on the Clocktower" to "game" or "event." Use only the stable event name or class, without time of day or duration. Use none for location unless the memo explicitly requires a venue. Do not invent details from the attached event.
			"""
			let prompt = """
			Attached event: \(sourceEvent.title)
			Action: \(draft.text)
			Action evidence: \(draft.evidence)

			Complete memo and corrections:
			\(evidenceCorpus)
			"""
			let budget = try await services.budget(instructions, GeneratedReminderSchedule.generationSchema, 512)
			let localPrompt = """
			Attached event: \(sourceEvent.title)
			Action: \(draft.text)
			Action evidence: \(draft.evidence)
			Local original context:
			\(fallback.context)
			Preceding named event references (context only):
			\(try referenceContext(namedReferences(in: evidenceCorpus),
				before: evidenceCorpus.range(of: draft.evidence)?.lowerBound.utf16Offset(in: evidenceCorpus) ?? 0,
				query: draft.evidence, budget: budget))
			"""
			let chosen = try await budget.fits(prompt) ? prompt : localPrompt
			do { generated = try await requestSchedule(instructions: instructions, prompt: chosen, budget: budget, services: services) }
			catch {
				guard chosen != localPrompt, isRetryableContext(error) else { throw error }
				generated = try await requestSchedule(instructions: instructions, prompt: localPrompt, budget: budget, services: services)
			}
		} else {
			generated = nil
		}
		try Task.checkCancellation()
		let scheduleContext = generated.flatMap {
			groundedExcerpt($0.scheduleContext, in: evidenceCorpus)
		} ?? fallback.context
		let description = refinedEventDescription(
			generated?.eventDescription ?? fallback.eventDescription,
			scheduleContext: scheduleContext
		)
		let attachesToSource = shouldAttachToSource(
			eventDescription: description,
			scheduleContext: scheduleContext,
			sourceEvent: sourceEvent
		)
		let schedule = GeneratedReminderSchedule(
			scheduleContext: scheduleContext,
			eventDescription: attachesToSource ? sourceEvent.title : description,
			locationDescription: generated?.locationDescription ?? "none"
		)
		return GeneratedReminder(
			draft: draft,
			schedule: schedule,
			attachesToSource: attachesToSource,
			occurrencePolicy: generated == nil
				? fallback.occurrencePolicy
				: occurrencePolicy(in: scheduleContext),
			validity: generated == nil
				? fallback.validity
				: relativeValidity(in: scheduleContext)
		)
	}

	private static func requestSchedule(instructions: String, prompt: String, budget: ModelContextBudget,
		services: ReminderModelServices) async throws -> GeneratedReminderSchedule {
		try await budget.requireFits(prompt)
		return try await ServiceAdmission.model.run(timeout: .seconds(45)) {
			try await budget.requireFits(prompt)
			return try await services.schedule(instructions, prompt, budget.outputTokens)
		}
	}

	static func groundedSchedule(
		for evidence: String,
		in corpus: String
	) -> GroundedReminderSchedule {
		let context = contextualScheduleText(for: evidence, in: corpus)
		return GroundedReminderSchedule(
			context: context,
			eventDescription: explicitEventDescriptions(in: context)
				.joined(separator: " or "),
			occurrencePolicy: occurrencePolicy(in: context),
			validity: relativeValidity(in: context)
		)
	}

	private static func mayContainLocationConstraint(_ text: String) -> Bool {
		let normalized = " " + text.reminderNormalized
		let targetPrefixes = Set([
			"a", "an", "every", "future", "morning", "afternoon", "evening",
			"next", "the", "this", "call", "class", "event", "game", "gaming",
			"gym", "meeting", "meetup", "practice", "session", "standup", "workshop"
		])
		var searchStart = normalized.startIndex
		while let range = normalized.range(
			of: " at ",
			range: searchStart..<normalized.endIndex
		) {
			let suffix = normalized[range.upperBound...]
			let next = suffix.split(separator: " ").first.map(String.init) ?? ""
			if !targetPrefixes.contains(next) {
				return true
			}
			searchStart = range.upperBound
		}
		return false
	}

	private static func contextualScheduleText(
		for evidence: String,
		in corpus: String
	) -> String {
		let excerpts = sentenceExcerpts(corpus)
		let normalizedEvidence = evidence.reminderNormalized
		guard let index = excerpts.firstIndex(where: {
			let normalized = $0.reminderNormalized
			return normalized.contains(normalizedEvidence)
				|| normalizedEvidence.contains(normalized)
		}) else {
			return evidence
		}
		var context = excerpts[index]
		let hasOwnTarget = !explicitEventDescriptions(in: context).isEmpty
			|| ["this event", "this group", "these sessions", "these classes"]
				.contains(where: context.reminderNormalized.contains)
		if !hasOwnTarget {
			for previousIndex in stride(from: index - 1, through: max(0, index - 10), by: -1) {
				context = excerpts[previousIndex] + " " + context
				let explicit = explicitEventDescriptions(in: context)
				let seeksMultipleNames = [
					"as well", "same thing", "same goal", "same for",
					"today and tomorrow", "today or tomorrow"
				].contains(where: context.reminderNormalized.contains)
				if !explicit.isEmpty, !seeksMultipleNames || explicit.count >= 2 {
					break
				}
			}
		}
		let extensionSignals = ["as well", "same thing", "same goal", "same for"]
		let following = (index + 1)..<min(excerpts.endIndex, index + 7)
		if let extensionIndex = following.first(where: { nextIndex in
			extensionSignals.contains {
				excerpts[nextIndex].reminderNormalized.contains($0)
			}
		}) {
			context += " " + excerpts[(index + 1)...extensionIndex].joined(separator: " ")
		}
		return context
	}

	private static func shouldAttachToSource(
		eventDescription: String,
		scheduleContext: String,
		sourceEvent: JournalCalendarEvent
	) -> Bool {
		let explicitDescriptions = explicitEventDescriptions(in: scheduleContext)
		if explicitDescriptions.count > 1 {
			return false
		}

		let normalizedContext = scheduleContext.reminderNormalized
		let deicticTargets = [
			"this event", "this group", "these sessions", "these classes",
			"next time", "same event", "future me"
		]
		if deicticTargets.contains(where: normalizedContext.contains),
			explicitDescriptions.isEmpty {
			return true
		}

		let ignored = Set([
			"a", "an", "and", "at", "every", "for", "in", "my", "next",
			"of", "on", "or", "the", "this"
		])
		let described = Set(eventDescription.reminderNormalized.split(separator: " ").map(String.init))
			.subtracting(ignored)
		let source = Set(sourceEvent.title.reminderNormalized.split(separator: " ").map(String.init))
			.subtracting(ignored)
		guard !described.isEmpty, !source.isEmpty else { return false }
		let overlap = described.intersection(source)
		return !overlap.isEmpty
			&& (overlap.count >= 2 || overlap == described || overlap == source)
	}

	private static func occurrencePolicy(
		in scheduleContext: String
	) -> EventReminderOccurrencePolicy {
		let normalized = scheduleContext.reminderNormalized
		if normalized.contains("today and tomorrow")
			|| normalized.contains("today or tomorrow") {
			return .everyMatch
		}
		let standingSignals = [
			"every", "always", "each ", "from now on", "going forward",
			"same deal", "these sessions", "these classes"
		]
		if standingSignals.contains(where: normalized.contains) {
			return .everyMatch
		}
		if relativeValidity(in: scheduleContext) != nil {
			return .everyMatch
		}
		let pluralEventTerms = [
			"calls", "classes", "events", "games", "meetings", "meetups",
			"practices", "sessions", "standups", "workshops"
		]
		if pluralEventTerms.contains(where: {
			normalized.split(separator: " ").contains(Substring($0))
		}), !normalized.contains("next ") {
			return .everyMatch
		}
		return .nextMatch
	}

	private static func sentenceExcerpts(_ transcript: String) -> [String] {
		var excerpts: [String] = []
		transcript.enumerateSubstrings(
			in: transcript.startIndex..<transcript.endIndex,
			options: [.bySentences, .substringNotRequired]
		) { _, range, _, _ in
			let excerpt = transcript[range].trimmingCharacters(in: .whitespacesAndNewlines)
			if !excerpt.isEmpty {
				excerpts.append(excerpt)
			}
		}
		if excerpts.isEmpty {
			let excerpt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
			if !excerpt.isEmpty { excerpts.append(excerpt) }
		}
		return excerpts
	}

	private static func groundedExcerpt(_ value: String, in corpus: String) -> String? {
		let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty, corpus.range(of: value) != nil else { return nil }
		return value
	}

	private static func hasFutureCueSignal(_ excerpt: String) -> Bool {
		let normalized = excerpt.reminderNormalized
		let phrases = [
			"next",
			"future",
			"every",
			"always",
			"going forward",
			"from now on",
			"note to self",
			"can t forget",
			"cannot forget",
			"future me",
			"save this",
			"would help",
			"actually want",
			"i should",
			"i want",
			"i need to",
			"i plan to",
			"remember",
			"make sure"
		]
		if phrases.contains(where: normalized.contains) { return true }
		let actionWords = [
			"ask", "bring", "focus", "keep", "learn", "look", "make", "pause",
			"practice", "take", "use", "wear"
		]
		let words = Set(normalized.split(separator: " ").map(String.init))
		return !words.isDisjoint(with: actionWords)
	}

	private static func actionIsGrounded(_ text: String, in evidence: String) -> Bool {
		let ignored = Set([
			"a", "an", "and", "at", "before", "during", "every", "for", "i",
			"class", "event", "game", "gym", "in", "me", "meeting", "meetup",
			"my", "next", "of", "on", "or", "practice", "session", "standup",
			"the", "this", "to", "workshop"
		])
		let actionWords = Array(Set(text.reminderNormalized.split(separator: " ").map(String.init))
			.subtracting(ignored)
		)
		let evidenceWords = Set(evidence.reminderNormalized.split(separator: " ").map(String.init))
			.subtracting(ignored)
		guard !actionWords.isEmpty else { return false }
		let matched = actionWords.filter { actionWord in
			evidenceWords.contains { evidenceWord in
				let prefixLength = min(4, min(actionWord.count, evidenceWord.count))
				guard prefixLength >= 3 else { return actionWord == evidenceWord }
				return actionWord.prefix(prefixLength) == evidenceWord.prefix(prefixLength)
			}
		}.count
		return Double(matched) / Double(actionWords.count) >= 0.5
	}

	private static func explicitTimeBucket(in evidence: String) -> EventReminderTimeBucket {
		affirmativeTimeBucket(in: evidence) ?? .any
	}

	private static func affirmativeTimeBucket(
		in evidence: String
	) -> EventReminderTimeBucket? {
		let normalized = evidence.reminderNormalized
		let candidates: [(EventReminderTimeBucket, String)] = [
			(.morning, "morning"),
			(.afternoon, "afternoon"),
			(.evening, "evening")
		]
		return candidates.compactMap { bucket, word -> (EventReminderTimeBucket, Int)? in
			guard let range = normalized.range(of: word, options: .backwards) else { return nil }
			let prefix = normalized[..<range.lowerBound]
			if prefix.hasSuffix("not ") { return nil }
			return (
				bucket,
				normalized.distance(from: normalized.startIndex, to: range.lowerBound)
			)
		}
		.max { $0.1 < $1.1 }?.0
	}

	private static func refinedEventDescription(
		_ generated: String,
		scheduleContext: String
	) -> String {
		let generated = clean(generated)
		let explicit = explicitEventDescriptions(in: scheduleContext)
		if explicit.count > 1 {
			return explicit.joined(separator: " or ")
		}
		let generic = Set([
			"event", "events", "game", "games", "game event", "gaming event",
			"session", "sessions"
		])
		if generic.contains(generated.reminderNormalized),
			let specific = explicit.first {
			return specific
		}
		return generated
	}

	private static func explicitEventDescriptions(in text: String) -> [String] {
		let words = text.reminderNormalized.split(separator: " ").map(String.init)
		let anchorPrefixes = [
			"call", "class", "event", "game", "gaming", "gym", "meeting",
			"meetup", "practice", "session", "standup", "workshop"
		]
		let genericWords = Set([
			"call", "class", "event", "events", "game", "games", "gaming", "gym",
			"meeting", "meetup", "meetups", "practice", "session", "sessions",
			"standup", "workshop"
		])
		let connectors = Set(["of", "on", "or", "the"])
		let boundaries = Set([
			"a", "actually", "also", "an", "and", "ask", "at", "before", "bring",
			"during", "every", "focus", "for", "future", "have", "i", "in",
			"keep", "learn", "look", "make", "morning", "afternoon", "evening",
			"my", "next", "play", "read", "remember", "same", "take", "this",
			"to", "today", "tomorrow", "try", "use", "wear"
		])
		var descriptions: [String] = []
		for index in words.indices {
			guard anchorPrefixes.contains(where: words[index].hasPrefix) else { continue }
			var start = index
			var cursor = index - 1
			while cursor >= words.startIndex, index - cursor <= 6 {
				if boundaries.contains(words[cursor]) { break }
				start = cursor
				cursor -= 1
			}
			let end = words.indices.contains(index + 1)
				&& words[index].hasPrefix("game")
				&& ["night", "meetup", "meetups"].contains(words[index + 1])
				? index + 1
				: index
			var phrase = Array(words[start...end])
			while phrase.first.map(connectors.contains) == true {
				phrase.removeFirst()
			}
			let meaningful = Set(phrase).subtracting(genericWords).subtracting([
				"a", "an", "and", "of", "on", "or", "the"
			])
			let genericOnlyAllowed = phrase.contains {
				["gaming", "gym", "meetup", "meetups", "practice", "standup", "workshop"]
					.contains($0)
			} || Set(phrase).intersection(genericWords).count >= 2
			guard !meaningful.isEmpty || genericOnlyAllowed else { continue }
			let description = phrase.joined(separator: " ")
			if !descriptions.contains(where: {
				$0.reminderNormalized == description.reminderNormalized
			}) {
				descriptions.append(description)
			}
		}
		return descriptions.filter { description in
			let terms = Set(description.reminderNormalized.split(separator: " ").map(String.init))
				.subtracting(["a", "an", "and", "of", "on", "or", "the"])
			return !descriptions.contains { other in
				guard other != description else { return false }
				let otherTerms = Set(other.reminderNormalized.split(separator: " ").map(String.init))
					.subtracting(["a", "an", "and", "of", "on", "or", "the"])
				return terms.isSubset(of: otherTerms) && otherTerms.count > terms.count
			}
		}
	}

	private static func relativeValidity(in text: String) -> ReminderRelativeValidity? {
		let normalized = text.reminderNormalized
		if normalized.contains("today and tomorrow")
			|| normalized.contains("today or tomorrow") {
			return ReminderRelativeValidity(value: 2, component: .day)
		}
		if normalized.contains("today"),
			normalized.contains("tomorrow"),
			["as well", "same thing", "same goal", "same for"]
				.contains(where: normalized.contains) {
			return ReminderRelativeValidity(value: 2, component: .day)
		}
		let pattern = #"\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|a|next|this)\s+(day|days|week|weeks|month|months)\b"#
		guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
		let range = NSRange(normalized.startIndex..., in: normalized)
		var latest: (location: Int, validity: ReminderRelativeValidity)?
		for match in expression.matches(in: normalized, range: range) {
			guard let valueRange = Range(match.range(at: 1), in: normalized),
				let unitRange = Range(match.range(at: 2), in: normalized)
			else { continue }
			let prefixRange = normalized.startIndex..<valueRange.lowerBound
			let prefix = String(normalized[prefixRange].suffix(5))
			if prefix.hasSuffix("not ") { continue }
			let valueText = String(normalized[valueRange])
			let matchEnd = match.range.location + match.range.length
			if valueText == "next",
				matchEnd < (normalized as NSString).length,
				(normalized as NSString).substring(from: matchEnd).hasPrefix(" s") {
				continue
			}
			let value = Int(valueText) ?? [
				"a": 1,
				"next": 1,
				"this": 1,
				"one": 1,
				"two": 2,
				"three": 3,
				"four": 4,
				"five": 5,
				"six": 6,
				"seven": 7,
				"eight": 8,
				"nine": 9,
				"ten": 10
			][valueText]
			guard let value, value > 0 else { continue }
			let component: Calendar.Component = String(normalized[unitRange]).hasPrefix("day")
				? .day
				: String(normalized[unitRange]).hasPrefix("week") ? .weekOfYear : .month
			latest = (match.range.location, ReminderRelativeValidity(
				value: value,
				component: component
			))
		}
		return latest?.validity
	}

	private static func rule(
		from generated: GeneratedReminder,
		sourceEvent: JournalCalendarEvent,
		createdAt: Date,
		evidenceCorpus: String
	) -> EventReminderRule? {
		let text = clean(generated.text)
		let motivation = sentenceCase(generated.motivation)
		let evidence = clean(generated.evidence)
		guard !text.isEmpty,
			!motivation.isEmpty,
			!evidence.isEmpty,
			evidenceCorpus.contains(evidence.reminderNormalized),
			actionIsGrounded(text, in: evidence)
		else { return nil }

		let selector: EventReminderSelector
		if generated.attachesToSource {
			selector = .series(EventSeriesReference(event: sourceEvent))
		} else {
			let description = clean(generated.eventDescription)
			guard !description.isEmpty else { return nil }
			selector = .fuzzy(FuzzyEventSelector(
				semanticDescription: description,
				timeBucket: explicitTimeBucket(in: generated.scheduleContext),
				locationDescription: groundedOptionalConstraint(
					generated.locationDescription,
					in: evidenceCorpus
				),
				examples: []
			))
		}

		return EventReminderRule(
			text: text,
			motivation: motivation,
			evidence: evidence,
			selector: selector,
			occurrencePolicy: generated.occurrencePolicy,
			createdAt: createdAt,
			expiresAt: generated.validity.flatMap {
				Calendar.current.date(
					byAdding: $0.component,
					value: $0.value,
					to: createdAt
				)
			}
		)
	}

	private static func match(
		selector: FuzzyEventSelector,
		candidates: [JournalCalendarEvent],
		modelIsAvailable: @Sendable () -> Bool,
		services: ReminderModelServices
	) async throws -> (decisions: [String: EventMatchAssessment], outcome: ModelProcessingOutcome) {
		try Task.checkCancellation()
		guard !candidates.isEmpty else { return ([:], .complete) }
		var decisions = Dictionary(uniqueKeysWithValues: candidates.map {
			(
				$0.focusKey,
				EventMatchAssessment(
					matches: false,
					reason: selector.timeBucket.contains($0.startDate)
						? "The event was not clearly matched."
						: "The event is outside the selected time of day."
				)
			)
		})
		let eligibleCandidates = candidates.filter {
			guard selector.timeBucket.contains($0.startDate) else { return false }
			guard let requiredLocation = selector.locationDescription else { return true }
			return $0.location?.reminderNormalized.contains(requiredLocation.reminderNormalized) == true
		}
		let exactMatches = eligibleCandidates.filter {
			exactNamedTargetMatch(selector: selector, event: $0)
		}
		for event in exactMatches {
			decisions[event.focusKey] = EventMatchAssessment(
				matches: true,
				reason: "The event title matches a named target."
			)
		}

		let exactMatchKeys = Set(exactMatches.map(\.focusKey))
		let modelCandidates = eligibleCandidates
			.filter { !exactMatchKeys.contains($0.focusKey) }
			.filter { hasSemanticAnchor(selector: selector, event: $0) }
		guard modelCandidates.isEmpty || modelIsAvailable() else {
			for event in modelCandidates { decisions.removeValue(forKey: event.focusKey) }
			return (decisions, .unavailable)
		}
		for (index, event) in modelCandidates.enumerated() {
			try Task.checkCancellation()
			let instructions = """
			Classify one calendar event against the supplied semantic selector. A match must clearly satisfy the event type and every stated constraint. Prefer false when uncertain. Title, notes, location, and time are evidence; do not invent missing facts. A shared venue or one related word is not enough to establish the event type.

			Canonical negatives:
			- Online video gaming is not a tabletop role-playing campaign session.
			- A fantasy book club mentioning characters or campaign themes is not a role-playing session.
			- An internal quarterly review is not a client call unless the title or notes identify a client.
			- A vague social event at a tabletop venue is not a tabletop gaming meetup without title or notes evidence.
			"""
			let prompt = """
			Selector: \(selector.semanticDescription)
			Time constraint: \(selector.timeBucket.rawValue)
			Location constraint: \(selector.locationDescription ?? "None")

			Candidate:
			Title: \(event.title)
			Calendar: \(event.calendarTitle)
			Start: \(event.startDate.formatted(date: .abbreviated, time: .shortened))
			End: \(event.endDate.formatted(date: .abbreviated, time: .shortened))
			Location: \(event.location ?? "None")
			Notes: \(event.notes ?? "None")
			"""
			do {
				let budget = try await services.budget(instructions, GeneratedEventMatch.generationSchema, 256)
				try await budget.requireFits(prompt)
				let generated = try await ServiceAdmission.model.run(timeout: .seconds(45)) {
					try await budget.requireFits(prompt)
					return try await services.match(instructions, prompt, budget.outputTokens)
				}
				decisions[event.focusKey] = EventMatchAssessment(
					matches: generated.matches,
					reason: clean(generated.reason)
				)
			} catch {
				let outcome = ModelProcessingOutcome.failure(error,
					message: "The on-device model could not finish matching reminders. Try again.")
				if outcome == .cancelled { throw CancellationError() }
				for pending in modelCandidates[index...] { decisions.removeValue(forKey: pending.focusKey) }
				return (decisions, outcome)
			}
		}
		return (decisions, .complete)
	}

	private static func exactNamedTargetMatch(
		selector: FuzzyEventSelector,
		event: JournalCalendarEvent
	) -> Bool {
		let ignored = Set([
			"a", "an", "and", "at", "call", "class", "event", "events", "for",
			"game", "games", "gaming", "in", "meeting", "meetup", "meetups",
			"of", "on", "or", "practice", "session", "sessions", "standup",
			"the", "workshop"
		])
		let titleWords = Set(event.title.reminderNormalized.split(separator: " ").map(String.init))
		return selector.semanticDescription.reminderNormalized
			.components(separatedBy: " or ")
			.contains { alternative in
				let targetWords = Set(alternative.split(separator: " ").map(String.init))
					.subtracting(ignored)
				guard targetWords.count >= 2 else { return false }
				return targetWords.allSatisfy { targetWord in
					titleWords.contains { titleWord in
						let length = min(4, min(targetWord.count, titleWord.count))
						return length >= 3
							? targetWord.prefix(length) == titleWord.prefix(length)
								|| (targetWord.count >= 4 && titleWord.contains(targetWord))
							: targetWord == titleWord
					}
				}
			}
	}

	private static func hasSemanticAnchor(
		selector: FuzzyEventSelector,
		event: JournalCalendarEvent
	) -> Bool {
		let normalizedSelector = selector.semanticDescription.reminderNormalized
		let normalizedEvent = ([event.title, event.notes ?? ""])
			.joined(separator: " ")
			.reminderNormalized
		if normalizedEvent.contains("book club"),
			!normalizedSelector.contains("book club") {
			return false
		}
		let ignored = Set([
			"a", "an", "at", "calendar", "class", "event", "for", "meeting",
			"meetup", "of", "session", "the"
		])
		let selectorWords = Set(
			normalizedSelector
				.split(separator: " ")
				.map(String.init)
		).subtracting(ignored)
		let eventWords = Set(
			normalizedEvent
				.split(separator: " ")
				.map(String.init)
		).subtracting(ignored)
		return selectorWords.contains { selectorWord in
			eventWords.contains { eventWord in
				let prefixLength = min(3, min(selectorWord.count, eventWord.count))
				guard prefixLength >= 3 else { return selectorWord == eventWord }
				return selectorWord.prefix(prefixLength) == eventWord.prefix(prefixLength)
			}
		}
	}
	private static func matchExamples(
		from events: [JournalCalendarEvent],
		selector: FuzzyEventSelector,
		decisions: [String: EventMatchAssessment]
	) -> [ReminderMatchExample] {
		let relevant = events.sorted {
			abs($0.startDate.timeIntervalSinceNow) < abs($1.startDate.timeIntervalSinceNow)
		}
		let matches = relevant.compactMap { event -> ReminderMatchExample? in
			guard let decision = decisions[event.focusKey], decision.matches else { return nil }
			return ReminderMatchExample(event: event, matches: true, reason: decision.reason)
		}
		let nonmatches = relevant.compactMap { event -> ReminderMatchExample? in
			guard let decision = decisions[event.focusKey], !decision.matches else { return nil }
			return ReminderMatchExample(event: event, matches: false, reason: decision.reason)
		}
		return Array(matches.prefix(3)) + Array(nonmatches.prefix(3))
	}

	private static func deduplicated(_ reminders: [EventReminderRule]) -> [EventReminderRule] {
		var kept: [EventReminderRule] = []
		for reminder in reminders {
			let words = meaningfulActionWords(reminder.text)
			let duplicate = kept.contains { existing in
				guard existing.selector.title.reminderNormalized
					== reminder.selector.title.reminderNormalized,
					existing.occurrencePolicy == reminder.occurrencePolicy
				else { return false }
				let existingWords = meaningfulActionWords(existing.text)
				guard !words.isEmpty, !existingWords.isEmpty else { return false }
				let overlap = words.intersection(existingWords).count
				return overlap == min(words.count, existingWords.count)
			}
			if !duplicate { kept.append(reminder) }
		}
		return kept
	}

	private static func applyingManualRemovals(
		to reminders: [EventReminderRule],
		feedback: [ReminderFeedback]
	) -> [EventReminderRule] {
		let removed = feedback
			.filter { $0.kind == .manualRemoval }
			.map { meaningfulActionWords($0.text.replacingOccurrences(
				of: "Keep removed:",
				with: "",
				options: [.caseInsensitive, .anchored]
			)) }
			.filter { !$0.isEmpty }
		return reminders.filter { reminder in
			let words = meaningfulActionWords(reminder.text)
			return !removed.contains { removedWords in
				!words.isEmpty
					&& words.intersection(removedWords).count
						== min(words.count, removedWords.count)
			}
		}
	}

	private static func meaningfulActionWords(_ text: String) -> Set<String> {
		let ignored = Set([
			"a", "an", "and", "at", "before", "bring", "during", "every", "for",
			"i", "in", "just", "me", "my", "next", "of", "on", "or", "remember",
			"session", "the", "this", "time", "to"
		])
		return Set(text.reminderNormalized.split(separator: " ").map(String.init))
			.subtracting(ignored)
	}

	private static func clean(_ value: String) -> String {
		value
			.replacingOccurrences(of: "\n", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func sentenceCase(_ value: String) -> String {
		let value = clean(value)
		guard let first = value.first else { return "" }
		return first.uppercased() + value.dropFirst()
	}

	private static func optionalConstraint(_ value: String) -> String? {
		let value = clean(value)
		return value.isEmpty || value.reminderNormalized == "none" ? nil : value
	}

	private static func groundedOptionalConstraint(
		_ value: String,
		in evidenceCorpus: String
	) -> String? {
		guard let value = optionalConstraint(value),
			evidenceCorpus.reminderNormalized.contains(value.reminderNormalized)
		else { return nil }
		return value
	}
}

private struct EventMatchAssessment {
	var matches: Bool
	var reason: String
}
