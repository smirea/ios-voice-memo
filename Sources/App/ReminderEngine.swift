import Foundation
import FoundationModels

@Generable(description: "All event-specific actions in an excerpt already confirmed to contain at least one reminder")
private struct GeneratedRequiredReminderBatch {
	@Guide(description: "Every distinct reminder action in the eligible excerpt.", .minimumCount(1))
	var reminders: [GeneratedReminderDraft]
}

@Generable(description: "Whether one memo excerpt contains an eligible event reminder")
private struct GeneratedCueEligibility {
	@Guide(description: "eligible only for an affirmative instruction the speaker gives their future self for a future event; otherwise exclude", .anyOf(["eligible", "exclude"]))
	var classification: String
}

@Generable(description: "One event-reminder action grounded in a memo excerpt")
private struct GeneratedReminderDraft {
	@Guide(description: "A short imperative checklist item")
	var text: String

	@Guide(description: "Why this reminder will be useful at the matching event")
	var motivation: String

	@Guide(description: "A brief exact contiguous excerpt from the memo or later correction that supports the reminder")
	var evidence: String
}

@Generable(description: "The semantic calendar-event target for one reminder")
private struct GeneratedReminderSchedule {
	@Guide(description: "Describe only the event class stated in the evidence, without adding the attached event")
	var eventDescription: String

	@Guide(description: "A required location stated by the speaker, or none when there is no location constraint")
	var locationDescription: String
}

private struct GeneratedReminder {
	var text: String
	var motivation: String
	var evidence: String
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
		self.attachesToSource = attachesToSource
		eventDescription = schedule.eventDescription
		locationDescription = schedule.locationDescription
		self.occurrencePolicy = occurrencePolicy
		self.validity = validity
	}
}

private struct ReminderRelativeValidity {
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

		if !feedback.isEmpty {
			let reminders = await reprocess(
				sourceEvent: sourceEvent,
				createdAt: createdAt,
				currentReminders: currentReminders,
				feedback: feedback
			)
			return ReminderParsingResult(
				reminders: reminders,
				modelName: "SystemLanguageModel.default · guided reminders"
			)
		}

		if let generated = try? await generatedReminders(
			transcript: transcript,
			sourceEvent: sourceEvent
		) {
			let evidenceCorpus = transcript.reminderNormalized
			let rules = generated.compactMap {
				rule(
					from: $0,
					sourceEvent: sourceEvent,
					createdAt: createdAt,
					evidenceCorpus: evidenceCorpus
				)
			}
			return ReminderParsingResult(
				reminders: deduplicated(rules),
				modelName: "SystemLanguageModel.default · guided reminders"
			)
		}

		return ReminderParsingResult(
			reminders: currentReminders,
			modelName: nil
		)
	}

	private static func reprocess(
		sourceEvent: JournalCalendarEvent,
		createdAt: Date,
		currentReminders: [EventReminderRule],
		feedback: [ReminderFeedback]
	) async -> [EventReminderRule] {
		var reminders = currentReminders

		for correction in feedback {
			let normalized = correction.text.reminderNormalized
			if correction.kind == .manualRemoval {
				if let focusedID = correction.focusedReminderID {
					reminders.removeAll {
						$0.id == focusedID || feedbackText(normalized, references: $0)
					}
				} else {
					reminders.removeAll { feedbackText(normalized, references: $0) }
				}
				continue
			}

			if normalized.contains("remove all")
				|| normalized.contains("delete all")
				|| normalized.contains("no event cues") {
				reminders = []
				continue
			}

			if normalized.contains("remove") || normalized.contains("delete") {
				let removalScope = normalized.components(separatedBy: " keep ").first ?? normalized
				reminders.removeAll { feedbackText(removalScope, references: $0) }
				continue
			}

			if normalized.contains("replace") {
				reminders.removeAll { feedbackText(normalized, references: $0) }
				let parsed = await parse(
					transcript: correction.text,
					sourceEvent: sourceEvent,
					createdAt: createdAt
				)
				reminders.append(contentsOf: parsed.reminders)
				continue
			}

			let referencedIndices = reminders.indices.filter {
				feedbackText(normalized, references: reminders[$0])
			}
			let correctionSignals = [
				"actually",
				"are for",
				"is for",
				"make the",
				"only remind",
				"last ",
				"not "
			]
			if !referencedIndices.isEmpty,
				correctionSignals.contains(where: normalized.contains) {
				for index in referencedIndices {
					reminders[index].evidence = correction.text
					if case var .fuzzy(selector) = reminders[index].selector,
						let timeBucket = affirmativeTimeBucket(in: correction.text) {
						selector.timeBucket = timeBucket
						reminders[index].selector = .fuzzy(selector)
					}
					if let policy = explicitOccurrencePolicy(in: correction.text) {
						reminders[index].occurrencePolicy = policy
						if policy == .everyMatch {
							reminders[index].resolvedOccurrence = nil
						}
					}
					if let validity = relativeValidity(in: correction.text) {
						reminders[index].expiresAt = Calendar.current.date(
							byAdding: validity.component,
							value: validity.value,
							to: createdAt
						)
					}
				}
				continue
			}

			if normalized.contains("missed")
				|| normalized.hasPrefix("add ")
				|| normalized.contains("also remind") {
				let parsed = await parse(
					transcript: correction.text,
					sourceEvent: sourceEvent,
					createdAt: createdAt
				)
				reminders.append(contentsOf: parsed.reminders)
			}
		}

		return deduplicated(reminders)
	}

	private static func feedbackText(
		_ normalizedFeedback: String,
		references reminder: EventReminderRule
	) -> Bool {
		let ignored = Set([
			"a", "an", "and", "at", "bring", "every", "for", "keep", "reminder",
			"remove", "the", "to"
		])
		let words = Set(reminder.text.reminderNormalized.split(separator: " ").map(String.init))
			.subtracting(ignored)
			.filter { $0.count >= 4 }
		return words.contains(where: normalizedFeedback.contains)
	}

	private static func explicitOccurrencePolicy(
		in text: String
	) -> EventReminderOccurrencePolicy? {
		let normalized = text.reminderNormalized
		if normalized.contains("only")
			&& [
				"next time", "next class", "next session", "next meeting",
				"next standup", "next gym", "next game", "next meetup"
			].contains(where: normalized.contains) {
			return .nextMatch
		}
		if normalized.contains("every")
			|| normalized.contains("from now on")
			|| normalized.contains("going forward") {
			return .everyMatch
		}
		return nil
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
						&& $0.focusKey != entry.calendarEvent?.focusKey
				}
				let matchedEvents: [JournalCalendarEvent]

				switch reminder.selector {
				case let .series(series):
					matchedEvents = candidatesAfterCreation.filter { series.matches($0) }
				case let .fuzzy(selector):
					let candidates = orderedEvents.filter {
						$0.focusKey != entry.calendarEvent?.focusKey
					}
					let decisions = await match(selector: selector, candidates: candidates)
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
		sourceEvent: JournalCalendarEvent
	) async throws -> [GeneratedReminder]? {
		guard SystemLanguageModel.default.availability == .available else { return nil }
		let eligibleExcerpts = try await eligibleCueExcerpts(transcript: transcript)
		guard !eligibleExcerpts.isEmpty else { return [] }

		let draftInstructions = """
		This excerpt has already been confirmed to contain at least one event reminder. Extract every action the speaker gives their future self for immediately before or during that event. Do not reclassify the excerpt. Include actions conditional on the event's time or other stated traits.

		Hard exclusions:
		- Never turn a past observation into a reminder.
		- Never extract a negated, canceled, or rejected idea.
		- Never assign another person's intention or obligation to the speaker.
		- Never invent an action, object, name, event constraint, repetition, or duration.
		- Never extract general tasks, errands, or appointments to schedule.

		Copy a short exact contiguous evidence excerpt. Preserve every stated action, name, and color. Return every useful cue, including zero; never fill a quota. Prefer omission when uncertain. A later pass assigns event matching, repetition, time, location, and duration.

		"""
		var drafts: [GeneratedReminderDraft] = []
		for excerpt in eligibleExcerpts {
			for focusExcerpt in actionFocusExcerpts(excerpt) {
				let prompt = """
				Attached event: \(sourceEvent.title)

				Focus excerpt:
				\(focusExcerpt)
				"""
				var excerptDrafts: [GeneratedReminderDraft]?
				for _ in 0..<2 where excerptDrafts == nil {
					let session = LanguageModelSession(instructions: """
					\(draftInstructions)
					Extract actions stated in the focus excerpt only.

					A self-correction such as "bring the red notebook—sorry, not red, bring the blue notebook" produces only "Bring the blue notebook."
					The action is the speaker's imperative verb phrase, never attendance at the event. "Next class ask Dana about the showcase" produces "Ask Dana about the showcase," never "Go to class."
					A time branch such as "If it starts in the evening, wear the blue shirt" is an affirmative instruction and produces "Wear the blue shirt."
					Keep related people facts in one compact reminder. "Remember Alice plays green, Ben hosts, and Priya likes cooperative games" is one reminder containing all three facts, not three reminders. A negative preference such as "Noor does not want cooperative games" is a fact to preserve, not a canceled instruction.
					""")
					excerptDrafts = try? await withGenerationTimeout {
						let response = try await session.respond(
							to: prompt,
							generating: GeneratedRequiredReminderBatch.self
						)
						return response.content.reminders
					}
				}
				drafts.append(contentsOf: compactRelatedFacts(
					excerptDrafts ?? [],
					in: focusExcerpt
				).map {
					var draft = $0
					draft.evidence = focusExcerpt
					return draft
				})
			}
		}
		var reminders: [GeneratedReminder] = []
		for draft in drafts {
			let scheduleText = relevantScheduleText(
				for: draft.evidence,
				in: eligibleExcerpts
			)
			let attachesToSource = shouldAttachToSource(
				evidence: scheduleText,
				sourceEvent: sourceEvent
			)
			let schedule = await generatedSchedule(
				for: draft,
				sourceEvent: sourceEvent,
				context: scheduleText,
				attachesToSource: attachesToSource
			)
			let reminder = GeneratedReminder(
				draft: draft,
				schedule: schedule,
				attachesToSource: attachesToSource,
				occurrencePolicy: occurrencePolicy(in: scheduleText),
				validity: relativeValidity(in: scheduleText)
			)
			reminders.append(reminder)
		}
		return reminders
	}

	private static func generatedSchedule(
		for draft: GeneratedReminderDraft,
		sourceEvent: JournalCalendarEvent,
		context: String,
		attachesToSource: Bool
	) async -> GeneratedReminderSchedule {
		if attachesToSource {
			return GeneratedReminderSchedule(
				eventDescription: sourceEvent.title,
				locationDescription: "none"
			)
		}
		let fallback = GeneratedReminderSchedule(
			eventDescription: explicitEventDescription(in: context) ?? context,
			locationDescription: sourceEvent.location.flatMap {
				context.reminderNormalized.contains($0.reminderNormalized) ? $0 : nil
			} ?? "none"
		)
		let session = LanguageModelSession(instructions: """
		Extract only the semantic calendar-event class and required venue stated in the reminder evidence. Do not infer or mention the memo's attached source event. Keep time of day and duration out of the event description because app code handles them. If titles may vary, describe the stable event type. Use none when no venue is required.

		Examples:
		- "At tabletop meetups at Dice Dojo this month, wear the orange tag." becomes event class "tabletop meetup" at "Dice Dojo".
		- "Before every client call, open the account notes." becomes event class "client call" with no venue.
		- "During evening role-playing sessions, bring the binder." becomes event class "role-playing session" with no venue.
		""")
		let prompt = """
		Reminder action: \(draft.text)
		Evidence: \(draft.evidence)

		Relevant memo context:
		\(context)
		"""
		return (try? await withGenerationTimeout {
			let response = try await session.respond(
				to: prompt,
				generating: GeneratedReminderSchedule.self
			)
			var schedule = response.content
			if let explicitDescription = explicitEventDescription(in: context) {
				schedule.eventDescription = explicitDescription
			}
			return schedule
		}) ?? fallback
	}

	private static func eligibleCueExcerpts(transcript: String) async throws -> [String] {
		let allExcerpts = sentenceExcerpts(transcript)
		let candidates = allExcerpts.enumerated().filter { hasFutureCueSignal($0.element) }
		guard !candidates.isEmpty else { return [] }
		var eligible: [String] = []

		for (index, excerpt) in candidates {
			if isClearlyIneligible(excerpt) {
				continue
			}
			if isClearlyEligible(
				excerpt,
				previousExcerpt: index > 0 ? allExcerpts[index - 1] : nil
			) {
				eligible.append(excerpt)
				continue
			}
			let session = LanguageModelSession(instructions: """
			Classify one memo excerpt conservatively. Mark eligible only when it contains an affirmative instruction the speaker gives their future self for immediately before or during a future calendar event. The named future event may be the attached event, a broader event class, or a completely different event class. Exclude past observations, descriptions without a future instruction, negated or rejected ideas, another person's intentions, and general tasks such as scheduling appointments or errands. If the excerpt contains both excluded material and a valid event cue, mark it eligible; a later pass will extract only the valid cue.

			The previous excerpt may resolve a pronoun, event class, or shared duration, but classify only the current excerpt.

			Canonical boundaries:
			- "I brought too many drinks." is exclude: it is only a past fact.
			- "The warmup was long and I felt nervous." is exclude: it is only reflection.
			- "Do not remind me about electrolytes next time." is exclude: it rejects a cue.
			- "Next gym, do not bring water; bring electrolytes instead." is eligible: the positive replacement is a valid cue.
			- "Rob said he needs to bring electrolytes." is exclude: it belongs to Rob.
			- Current "The coach said remember eye contact next time." followed by "That advice was not for me." is exclude.
			- "I should schedule a dentist appointment." is exclude: it is a general task.
			- "At the next class, pause for one beat." is eligible.
			- "For every morning game, wear red pants." is eligible.
			- "Before every client call, open the account notes." is eligible even when the attached event is a standup.
			- "At the next yoga class, bring the green mat." is eligible even when the attached event is a gym session.
			- "For a month of evening role-playing sessions, bring the binder." is eligible even when the attached event is a board-game meetup.
			- "Next time I see this group, remember Alice plays green and Ben hosts." is eligible: remembering useful people context is a future instruction.
			- "For Sunday tabletop meetups, wear the orange tag even if the title changes." is eligible: "even if" adds matching context and does not reject the instruction.
			- Current "If it starts in the evening, wear the blue shirt." after previous "For the next month of gaming, wear red in the morning." is eligible.
			""")
			let prompt = """
			An event-attached memo exists. The current excerpt may target that event or another event class.

			Previous memo excerpt:
			\(index > 0 ? allExcerpts[index - 1] : "None")

			Current memo excerpt:
			\(excerpt)

			Following memo excerpt:
			\(allExcerpts.indices.contains(index + 1) ? allExcerpts[index + 1] : "None")
			"""
			let decision = try await withGenerationTimeout {
				let response = try await session.respond(
					to: prompt,
					generating: GeneratedCueEligibility.self
				)
				return response.content
			}
			if decision.classification == "eligible" { eligible.append(excerpt) }
		}
		return eligible
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

	private static func actionFocusExcerpts(_ excerpt: String) -> [String] {
		let pattern = #",\s*(?:(?:and\s+)?(?=in\s+(?:the\s+)?(?:morning|afternoon|evening))|and\s+(?=at\s+(?:the\s+)?(?:morning|afternoon|evening|gaming|role)))"#
		guard let expression = try? NSRegularExpression(pattern: pattern) else {
			return [excerpt]
		}
		let fullRange = NSRange(excerpt.startIndex..., in: excerpt)
		let matches = expression.matches(in: excerpt, range: fullRange)
		guard !matches.isEmpty else { return [excerpt] }
		var ranges: [Range<String.Index>] = []
		var start = excerpt.startIndex
		for match in matches {
			guard let range = Range(match.range, in: excerpt) else { continue }
			ranges.append(start..<range.lowerBound)
			start = range.upperBound
		}
		ranges.append(start..<excerpt.endIndex)
		return ranges.compactMap {
			let value = excerpt[$0].trimmingCharacters(in: .whitespacesAndNewlines)
			return value.isEmpty ? nil : value
		}
	}

	private static func compactRelatedFacts(
		_ drafts: [GeneratedReminderDraft],
		in excerpt: String
	) -> [GeneratedReminderDraft] {
		let excerpt = excerpt.reminderNormalized
		guard drafts.count > 1,
			excerpt.contains("remember "),
			!excerpt.contains("remember to "),
			drafts.allSatisfy({
				let text = clean($0.text).lowercased()
				return text.hasPrefix("remember ")
					|| text.hasPrefix("keep in mind ")
			})
		else { return drafts }

		let prefixes = ["Remember that ", "Remember ", "Keep in mind that ", "Keep in mind "]
		let facts = drafts.map { draft in
			let text = clean(draft.text)
			let prefix = prefixes.first {
				text.lowercased().hasPrefix($0.lowercased())
			}
			return prefix.map { String(text.dropFirst($0.count)) } ?? text
		}
		var combined = drafts[0]
		combined.text = "Remember " + facts.joined(separator: "; ")
		return [combined]
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

	private static func isClearlyEligible(
		_ excerpt: String,
		previousExcerpt: String?
	) -> Bool {
		let normalized = excerpt.reminderNormalized
		let exclusionSignals = [
			"do not",
			"don t",
			"forget that",
			"not planning",
			"nothing to remember",
			"advice for",
			"coach said",
			"not me",
			"i told ",
			"said he",
			"said she",
			"he needs",
			"she needs",
			"they should",
			"would probably"
		]
		let hasPositiveReplacement = normalized.contains("instead")
			|| normalized.contains("but bring")
		guard hasPositiveReplacement
			|| !exclusionSignals.contains(where: normalized.contains)
		else { return false }
		let eventSignals = [
			" call", " class", " event", " game", " gym", " meeting", " meetup",
			" practice", " scene", " session", " standup", " workshop",
			"next time", "this group", "these sessions"
		]
		let actionWords = Set([
			"ask", "bring", "focus", "forget", "keep", "learn", "look", "make", "open",
			"pack", "pause", "practice", "remember", "take", "try", "use", "wear"
		])
		let words = Set(normalized.split(separator: " ").map(String.init))
		let hasAction = !words.isDisjoint(with: actionWords)
			|| normalized.contains("can t forget")
			|| normalized.contains("cannot forget")
		if hasAction && eventSignals.contains(where: normalized.contains) {
			return true
		}
		let continuationSignals = [
			"if it",
			"same deal",
			"same for",
			"except"
		]
		return hasAction
			&& continuationSignals.contains(where: normalized.contains)
			&& previousExcerpt.map {
				let previous = $0.reminderNormalized
				return eventSignals.contains(where: previous.contains)
			} == true
	}

	private static func isClearlyIneligible(_ excerpt: String) -> Bool {
		let normalized = excerpt.reminderNormalized
		let speakerCommitmentSignals = [
			"actually want",
			"can t forget",
			"cannot forget",
			"future me",
			"i need",
			"i plan",
			"i should",
			"i want",
			"note to self",
			"save this"
		]
		let anotherPersonSignals = [
			"coach said",
			"he needs",
			"he should",
			"i told ",
			"said he",
			"said she",
			"she needs",
			"she should",
			"they need",
			"they should"
		]
		let belongsOnlyToSomeoneElse = anotherPersonSignals.contains(where: normalized.contains)
			&& !speakerCommitmentSignals.contains(where: normalized.contains)
		return (normalized.contains("schedule") && normalized.contains("appointment"))
			|| normalized.contains("buy groceries")
			|| normalized.contains("renew my passport")
			|| belongsOnlyToSomeoneElse
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

	private static func explicitEventDescription(in text: String) -> String? {
		let words = text.reminderNormalized.split(separator: " ").map(String.init)
		let anchorPrefixes = [
			"call", "class", "event", "game", "gaming", "gym", "meeting",
			"meetup", "practice", "session", "standup", "workshop"
		]
		let ignored = Set([
			"a", "an", "at", "before", "during", "every", "for", "future", "in",
			"morning", "afternoon", "evening", "next", "of", "on", "the", "this", "to"
		])
		for index in words.indices {
			guard anchorPrefixes.contains(where: words[index].hasPrefix) else { continue }
			let lowerBound = max(words.startIndex, index - 3)
			var phrase = words[lowerBound...index].filter { !ignored.contains($0) }
			if words[index].hasPrefix("game"),
				words.indices.contains(index + 1),
				["night", "meetup", "meetups"].contains(words[index + 1]) {
				phrase.append(words[index + 1])
			}
			let actionWords = Set([
				"ask", "bring", "focus", "keep", "learn", "look", "open",
				"pack", "pause", "remember", "take", "try", "use", "wear"
			])
			phrase = phrase.filter { !actionWords.contains($0) }
			if !phrase.isEmpty {
				return phrase.joined(separator: " ")
			}
		}
		return nil
	}

	private static func relevantScheduleText(
		for evidence: String,
		in excerpts: [String]
	) -> String {
		let normalizedEvidence = evidence.reminderNormalized
		guard let index = excerpts.firstIndex(where: {
			$0.reminderNormalized.contains(normalizedEvidence)
				|| normalizedEvidence.contains($0.reminderNormalized)
		}) else {
			return evidence
		}
		var relevant = [evidence]
		let normalizedExcerpt = excerpts[index].reminderNormalized
		if relativeValidity(in: evidence) == nil,
			relativeValidity(in: excerpts[index]) != nil {
			relevant.insert(excerpts[index], at: 0)
		}
		if explicitEventDescription(in: evidence) == nil,
			explicitEventDescription(in: excerpts[index]) != nil {
			relevant.insert(excerpts[index], at: 0)
		}
		let continuationSignals = [
			"if it",
			"same deal",
			"same for",
			"except",
			"that event",
			"those events"
		]
		if index > 0 && continuationSignals.contains(where: normalizedExcerpt.contains) {
			relevant.insert(excerpts[index - 1], at: 0)
		}
		return relevant.joined(separator: " ")
	}

	private static func occurrencePolicy(
		in scheduleText: String
	) -> EventReminderOccurrencePolicy {
		let normalized = scheduleText.reminderNormalized
		let standingSignals = [
			" every ",
			"always",
			"from now on",
			"going forward"
		]
		let padded = " \(normalized) "
		let oneTimeSignals = [
			"next time",
			"next class",
			"next session",
			"next meeting",
			"next standup",
			"next gym",
			"next game",
			"next meetup",
			"next week s"
		]
		let lastStanding = standingSignals.compactMap {
			padded.range(of: $0, options: .backwards).map {
				padded.distance(from: padded.startIndex, to: $0.lowerBound)
			}
		}.max()
		let lastOneTime = oneTimeSignals.compactMap {
			normalized.range(of: $0, options: .backwards).map {
				normalized.distance(from: normalized.startIndex, to: $0.lowerBound)
			}
		}.max()
		if let lastOneTime,
			lastStanding == nil || lastOneTime > lastStanding! {
			return .nextMatch
		}
		if lastStanding != nil || relativeValidity(in: scheduleText) != nil {
			return .everyMatch
		}
		let words = normalized.split(separator: " ").map(String.init)
		if normalized.contains("future"),
			words.contains(where: {
				["calls", "classes", "events", "games", "meetings", "meetups", "sessions", "standups", "workshops"].contains($0)
			}) {
			return .everyMatch
		}
		if words.contains(where: {
			["calls", "classes", "events", "games", "meetings", "meetups", "sessions", "standups", "workshops"].contains($0)
		}), !normalized.contains("next") {
			return .everyMatch
		}
		if lastOneTime != nil {
			return .nextMatch
		}
		return .nextMatch
	}

	private static func relativeValidity(in text: String) -> ReminderRelativeValidity? {
		let normalized = text.reminderNormalized
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

	private static func shouldAttachToSource(
		evidence: String,
		sourceEvent: JournalCalendarEvent
	) -> Bool {
		let normalized = evidence.reminderNormalized
		let deicticSignals = [
			"this group",
			"this event",
			"these people",
			"these sessions",
			"next session",
			"next time i see"
		]
		if deicticSignals.contains(where: normalized.contains) {
			return true
		}
		if normalized.contains("next time"),
			explicitEventDescription(in: evidence) == nil {
			return true
		}
		if !sourceEvent.isRecurring { return false }
		let ignored = Set([
			"team",
			"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
		])
		let sourceWords = Set(
			sourceEvent.title.reminderNormalized.split(separator: " ").map(String.init)
		).subtracting(ignored)
		let evidenceWords = Set(normalized.split(separator: " ").map(String.init))
		if !sourceWords.isEmpty && !sourceWords.isDisjoint(with: evidenceWords) {
			return true
		}
		let eventWordPrefixes = [
			"call", "class", "event", "game", "gym", "meet", "practice",
			"session", "standup", "workshop"
		]
		return !evidenceWords.contains {
			eventWordPrefixes.contains(where: $0.hasPrefix)
		}
	}

	private static func rule(
		from generated: GeneratedReminder,
		sourceEvent: JournalCalendarEvent,
		createdAt: Date,
		evidenceCorpus: String
	) -> EventReminderRule? {
		let text = clean(generated.text)
		let motivation = clean(generated.motivation)
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
				timeBucket: explicitTimeBucket(in: evidence),
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
		guard SystemLanguageModel.default.availability == .available else { return decisions }

		let modelCandidates = candidates.filter {
			guard selector.timeBucket.contains($0.startDate) else { return false }
			guard let requiredLocation = selector.locationDescription else { return true }
			return $0.location?.reminderNormalized.contains(requiredLocation.reminderNormalized) == true
		}.filter { hasSemanticAnchor(selector: selector, event: $0) }
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
