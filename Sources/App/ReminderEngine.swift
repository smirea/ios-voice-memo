import Foundation
import FoundationModels

@Generable(description: "The final useful event-specific reminders from a complete voice memo and any corrections")
private struct GeneratedReminderBatch {
	@Guide(description: "Every distinct useful reminder after applying all corrections, including zero")
	var reminders: [GeneratedReminderDraft]
}

@Generable(description: "One complete event-reminder action grounded in the supplied memo")
private struct GeneratedReminderDraft {
	@Guide(description: "A short imperative checklist item")
	var text: String

	@Guide(description: "Why this reminder will be useful at the matching event, addressing the note owner as you and never as user or speaker")
	var motivation: String

	@Guide(description: "A brief exact contiguous excerpt from the memo or later correction that supports the reminder")
	var evidence: String
}

@Generable(description: "The grounded calendar-event target for one reminder")
private struct GeneratedReminderSchedule {
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
private struct GeneratedEventMatch {
	@Guide(description: "Whether the candidate clearly matches every stated selector constraint")
	var matches: Bool

	@Guide(description: "A short explanation grounded in the candidate and selector")
	var reason: String
}

struct ReminderParsingResult: Sendable {
	var reminders: [EventReminderRule]
	var modelName: String?
}

struct ReminderResolutionResult: Sendable {
	var occurrences: [EventReminderOccurrence]
	var examplesByReminderID: [UUID: [ReminderMatchExample]]
	var resolvedOccurrencesByReminderID: [UUID: JournalCalendarEvent]
}

enum ReminderEngine {
	static func parse(
		transcript: String,
		sourceEvent: JournalCalendarEvent?,
		createdAt: Date,
		currentReminders: [EventReminderRule] = [],
		feedback: [ReminderFeedback] = []
	) async -> ReminderParsingResult {
		guard let sourceEvent else {
			return ReminderParsingResult(reminders: [], modelName: nil)
		}

		do {
			guard let generated = try await generatedReminders(
				transcript: transcript,
				sourceEvent: sourceEvent,
				currentReminders: currentReminders,
				feedback: feedback
			) else {
				return ReminderParsingResult(reminders: currentReminders, modelName: nil)
			}
			let evidenceCorpus = ([transcript] + feedback.map(\.text))
				.joined(separator: "\n")
				.reminderNormalized
			let rules = generated.compactMap {
				rule(
					from: $0,
					sourceEvent: sourceEvent,
					createdAt: createdAt,
					evidenceCorpus: evidenceCorpus
				)
			}
			return ReminderParsingResult(
				reminders: applyingManualRemovals(
					to: deduplicated(rules),
					feedback: feedback
				),
				modelName: "SystemLanguageModel.default · guided reminders"
			)
		} catch {
			if ProcessInfo.processInfo.arguments.contains("-reminder-benchmark") {
				print("REMINDER_GENERATION_ERROR \(error)")
			}
		}

		return ReminderParsingResult(
			reminders: currentReminders,
			modelName: nil
		)
	}

	static func resolve(
		entries: [JournalEntry],
		events: [JournalCalendarEvent],
		now: Date = .now
	) async -> ReminderResolutionResult {
		var occurrences: [EventReminderOccurrence] = []
		var examplesByReminderID: [UUID: [ReminderMatchExample]] = [:]
		var resolvedOccurrencesByReminderID: [UUID: JournalCalendarEvent] = [:]
		let orderedEvents = events.sorted { $0.startDate < $1.startDate }

		for entry in entries {
			for reminder in entry.reminders where reminder.isActive(at: now) {
				let candidatesAfterCreation = orderedEvents.filter {
					$0.startDate > reminder.createdAt
				}
				let matchedEvents: [JournalCalendarEvent]

				switch reminder.selector {
				case let .series(series):
					matchedEvents = candidatesAfterCreation.filter { series.matches($0) }
				case let .fuzzy(selector):
					let decisions = await match(selector: selector, candidates: orderedEvents)
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
					} else if let next = matchedEvents.first(where: { $0.endDate >= now }) {
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

		return ReminderResolutionResult(
			occurrences: occurrences.sorted { $0.event.startDate < $1.event.startDate },
			examplesByReminderID: examplesByReminderID,
			resolvedOccurrencesByReminderID: resolvedOccurrencesByReminderID
		)
	}

	private static func generatedReminders(
		transcript: String,
		sourceEvent: JournalCalendarEvent,
		currentReminders: [EventReminderRule],
		feedback: [ReminderFeedback]
	) async throws -> [GeneratedReminder]? {
		guard SystemLanguageModel.default.availability == .available else { return nil }
		let evidenceCorpus = ([transcript] + feedback.map(\.text)).joined(separator: "\n")
		guard sentenceExcerpts(evidenceCorpus).contains(where: hasFutureCueSignal) else {
			return []
		}

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
		let session = LanguageModelSession(instructions: """
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
		""")
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
		let drafts = try await withGenerationTimeout {
			let response = try await session.respond(
				to: prompt,
				generating: GeneratedReminderBatch.self
			)
			return response.content.reminders
		}
		return await withTaskGroup(of: (Int, GeneratedReminder).self) { group in
			for (index, draft) in drafts.enumerated() {
				group.addTask {
					(
						index,
						await generatedReminder(
							from: draft,
							sourceEvent: sourceEvent,
							evidenceCorpus: evidenceCorpus
						)
					)
				}
			}
			var indexed: [(Int, GeneratedReminder)] = []
			for await reminder in group {
				indexed.append(reminder)
			}
			return indexed.sorted { $0.0 < $1.0 }.map(\.1)
		}
	}

	private static func generatedReminder(
		from draft: GeneratedReminderDraft,
		sourceEvent: JournalCalendarEvent,
		evidenceCorpus: String
	) async -> GeneratedReminder {
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
			let session = LanguageModelSession(instructions: """
			Determine the calendar-event target for one already-extracted action. Read the complete memo context and resolve pronouns or generic references such as "the game" from earlier specific names.

			Schedule context must be exact contiguous text copied from the supplied memo context and retain the target, frequency, and duration. For a cue applying to multiple explicitly named events, preserve every name in eventDescription; never reduce names such as "Ultimate Werewolf" and "Blood on the Clocktower" to "game" or "event." Use only the stable event name or class, without time of day or duration. Use none for location unless the memo explicitly requires a venue. Do not invent details from the attached event.
			""")
			let prompt = """
			Attached event: \(sourceEvent.title)
			Action: \(draft.text)
			Action evidence: \(draft.evidence)

			Complete memo and corrections:
			\(evidenceCorpus)
			"""
			generated = try? await withGenerationTimeout {
				let response = try await session.respond(
					to: prompt,
					generating: GeneratedReminderSchedule.self
				)
				return response.content
			}
		} else {
			generated = nil
		}
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
		let value = clean(value)
		guard !value.isEmpty,
			corpus.reminderNormalized.contains(value.reminderNormalized)
		else { return nil }
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
		candidates: [JournalCalendarEvent]
	) async -> [String: EventMatchAssessment] {
		guard !candidates.isEmpty else { return [:] }
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

		guard SystemLanguageModel.default.availability == .available else { return decisions }
		let exactMatchKeys = Set(exactMatches.map(\.focusKey))
		let modelCandidates = eligibleCandidates
			.filter { !exactMatchKeys.contains($0.focusKey) }
			.filter { hasSemanticAnchor(selector: selector, event: $0) }
		for event in modelCandidates {
			let session = LanguageModelSession(instructions: """
			Classify one calendar event against the supplied semantic selector. A match must clearly satisfy the event type and every stated constraint. Prefer false when uncertain. Title, notes, location, and time are evidence; do not invent missing facts. A shared venue or one related word is not enough to establish the event type.

			Canonical negatives:
			- Online video gaming is not a tabletop role-playing campaign session.
			- A fantasy book club mentioning characters or campaign themes is not a role-playing session.
			- An internal quarterly review is not a client call unless the title or notes identify a client.
			- A vague social event at a tabletop venue is not a tabletop gaming meetup without title or notes evidence.
			""")
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
			guard let response = try? await session.respond(
				to: prompt,
				generating: GeneratedEventMatch.self
			) else { continue }
			decisions[event.focusKey] = EventMatchAssessment(
				matches: response.content.matches,
				reason: clean(response.content.reason)
			)
		}
		return decisions
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

	private static func withGenerationTimeout<T: Sendable>(
		_ operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask { try await operation() }
			group.addTask {
				try await Task.sleep(for: .seconds(45))
				throw ReminderGenerationError.timedOut
			}
			guard let result = try await group.next() else {
				throw ReminderGenerationError.timedOut
			}
			group.cancelAll()
			return result
		}
	}
}

private struct EventMatchAssessment {
	var matches: Bool
	var reason: String
}

private enum ReminderGenerationError: Error {
	case timedOut
}
