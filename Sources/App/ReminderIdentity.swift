import Foundation

struct ReminderReconciliation: Sendable {
	var reminders: [EventReminderRule]
	var history: [EventReminderRule]
	var processedFeedbackIDs: Set<UUID>
}

enum ReminderIdentity {
	static func reconcile(generated: [EventReminderRule], entry: JournalEntry) -> ReminderReconciliation {
		var priorByID = Dictionary(entry.reminderHistory.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
		for rule in entry.reminders { priorByID[rule.id] = rule }
		let prior = priorByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
		let knownSources = Set(prior.compactMap(\.sourceFeedbackID))
		let newFeedback = Set(entry.reminderFeedback.filter { $0.kind == .voice }.map(\.id))
			.subtracting(entry.reminderProcessedFeedbackIDs).subtracting(knownSources)
		let proposed = generated.map { candidate in
			Candidate(rule: candidate, source: feedbackSource(for: candidate.evidence, entry: entry))
		}
		var candidates: [Candidate] = []
		for candidate in proposed {
			if let index = candidates.firstIndex(where: { semanticKey($0.rule) == semanticKey(candidate.rule) }) {
				if candidate.source.map(newFeedback.contains) == true { candidates[index] = candidate }
			} else { candidates.append(candidate) }
		}
		let fresh = Set(candidates.indices.filter { candidates[$0].source.map(newFeedback.contains) == true })
		var matches: [Int: EventReminderRule] = [:]
		var used = Set<UUID>()
		for index in candidates.indices where !fresh.contains(index) {
			let candidate = candidates[index]
			let available = prior.filter { !used.contains($0.id) }
			let sameAction = available.filter {
				canonical($0.text) == canonical(candidate.rule.text) && selectorKey($0.selector) == selectorKey(candidate.rule.selector)
			}
			let sameSource = sameAction.filter { candidate.source != nil && $0.sourceFeedbackID == candidate.source }
			let exact = sameAction.filter { $0.occurrencePolicy == candidate.rule.occurrencePolicy }
			if let matched = unique(sameSource) ?? unique(exact) ?? unique(sameAction) {
				matches[index] = matched
				used.insert(matched.id)
			}
		}
		let corpus = ([entry.transcript] + entry.reminderFeedback.map(\.text)).joined(separator: "\n")
		let sentences = sourceSentences(corpus)
		for index in candidates.indices where !fresh.contains(index) && matches[index] == nil {
			let candidate = candidates[index].rule
			let compatible = prior.filter {
				!used.contains($0.id) && selectorKey($0.selector) == selectorKey(candidate.selector)
					&& plausiblySameAction($0.text, candidate.text)
					&& sharesSource($0.evidence, candidate.evidence, sentences: sentences)
			}
			let sameWords = compatible.filter { actionWords($0.text) == actionWords(candidate.text) }
			let possible = sameWords.isEmpty ? compatible : sameWords
			guard let matched = unique(possible) else { continue }
			let competing = candidates.indices.filter { other in
				!fresh.contains(other) && matches[other] == nil
					&& selectorKey(candidates[other].rule.selector) == selectorKey(matched.selector)
					&& plausiblySameAction(candidates[other].rule.text, matched.text)
					&& sharesSource(candidates[other].rule.evidence, matched.evidence, sentences: sentences)
					&& (sameWords.isEmpty || actionWords(candidates[other].rule.text) == actionWords(matched.text))
			}
			guard competing == [index] else { continue }
			matches[index] = matched
			used.insert(matched.id)
		}

		let removed = Set(entry.reminderFeedback.filter { $0.kind == .manualRemoval }.compactMap(\.focusedReminderID))
		let legacyRemovals = entry.reminderFeedback.filter {
			$0.kind == .manualRemoval && ($0.focusedReminderID == nil || priorByID[$0.focusedReminderID!] == nil)
		}.map { actionWords($0.text.replacingOccurrences(of: "Keep removed:", with: "", options: [.anchored, .caseInsensitive])) }
		var reminders: [EventReminderRule] = []
		for index in candidates.indices {
			let candidate = candidates[index]
			var rule = candidate.rule
			if let old = matches[index] {
				guard !removed.contains(old.id) else { continue }
				rule.id = old.id
				rule.createdAt = old.createdAt
				rule.resolvedOccurrence = old.resolvedOccurrence
				rule.consumedAt = old.consumedAt
				if old.occurrencePolicy == .nextMatch, old.resolvedOccurrence != nil { rule.occurrencePolicy = .nextMatch }
				rule.leadTimeOverrideMinutes = old.leadTimeOverrideMinutes
				rule.sourceFeedbackID = old.sourceFeedbackID ?? candidate.source
			} else {
				if !fresh.contains(index), prior.contains(where: {
					($0.consumedAt != nil || $0.resolvedOccurrence != nil || removed.contains($0.id))
						&& mayBeRetiredAction($0.text, rule.text, evidence: rule.evidence)
						&& sharesSource($0.evidence, rule.evidence, sentences: sentences)
				}) { continue }
				rule.id = UUID()
				rule.createdAt = entry.createdAt
				rule.resolvedOccurrence = nil
				rule.consumedAt = nil
				rule.leadTimeOverrideMinutes = nil
				rule.sourceFeedbackID = candidate.source
			}
			if !fresh.contains(index), legacyRemovals.contains(actionWords(rule.text)) { continue }
			reminders.append(rule)
		}
		let activeIDs = Set(reminders.map(\.id))
		return ReminderReconciliation(reminders: reminders, history: prior.filter { !activeIDs.contains($0.id) },
			processedFeedbackIDs: entry.reminderProcessedFeedbackIDs.union(entry.reminderFeedback.map(\.id)))
	}

	static func canonical(_ value: String) -> String {
		value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
			.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
			.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	private struct Candidate {
		var rule: EventReminderRule
		var source: UUID?
	}

	private static func semanticKey(_ rule: EventReminderRule) -> [String] {
		[canonical(rule.text), rule.occurrencePolicy.rawValue] + selectorKey(rule.selector)
	}

	private static func selectorKey(_ selector: EventReminderSelector) -> [String] {
		switch selector {
		case .series(let series):
			if let external = series.externalIdentifier, !external.isEmpty {
				return ["series", series.calendarIdentifier, external]
			}
			return ["series", series.calendarIdentifier, canonical(series.eventTitle), String(series.startMinuteOfDay)]
		case .fuzzy(let fuzzy):
			return ["fuzzy", canonical(fuzzy.semanticDescription), fuzzy.timeBucket.rawValue, canonical(fuzzy.locationDescription ?? "")]
		}
	}

	private static func feedbackSource(for evidence: String, entry: JournalEntry) -> UUID? {
		let evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !evidence.isEmpty, !entry.transcript.contains(evidence) else { return nil }
		let matches = entry.reminderFeedback.filter { $0.text.contains(evidence) }
		guard matches.count == 1, matches[0].kind == .voice else { return nil }
		return matches[0].id
	}

	private static func actionWords(_ text: String) -> Set<String> {
		Set(canonical(text).split(separator: " ").map(String.init))
			.subtracting(actionFillers)
	}

	private static let actionFillers: Set<String> = ["a", "an", "the", "please", "remember", "to", "my", "your", "you", "with", "about"]

	private static func plausiblySameAction(_ lhs: String, _ rhs: String) -> Bool {
		let lhs = canonical(lhs).split(separator: " ").map(String.init).filter { !actionFillers.contains($0) }
		let rhs = canonical(rhs).split(separator: " ").map(String.init).filter { !actionFillers.contains($0) }
		guard let leftVerb = lhs.first, let rightVerb = rhs.first else { return false }
		let carryVerbs: Set<String> = ["bring", "pack", "carry"]
		guard leftVerb == rightVerb || (carryVerbs.contains(leftVerb) && carryVerbs.contains(rightVerb)) else { return false }
		let left = Set(lhs.dropFirst()), right = Set(rhs.dropFirst())
		guard !left.isEmpty, !right.isEmpty else { return lhs == rhs }
		if left == right { return true }
		let overlap = left.intersection(right).count
		return overlap >= 2 && Double(overlap) / Double(max(left.count, right.count)) >= 0.75
	}

	private static func mayBeRetiredAction(_ lhs: String, _ rhs: String, evidence: String) -> Bool {
		let lhs = canonical(lhs).split(separator: " ").map(String.init).filter { !actionFillers.contains($0) }
		let rhs = canonical(rhs).split(separator: " ").map(String.init).filter { !actionFillers.contains($0) }
		guard let leftVerb = lhs.first, let rightVerb = rhs.first else { return false }
		let carryVerbs: Set<String> = ["bring", "pack", "carry", "take"]
		guard leftVerb == rightVerb || (carryVerbs.contains(leftVerb) && carryVerbs.contains(rightVerb)) else { return false }
		let modifiers: Set<String> = ["blue", "red", "green", "black", "white", "yellow", "small", "large", "new", "old",
			"extra", "same", "different", "other", "next", "event", "meeting", "today", "tomorrow", "for", "and", "on", "at",
			"before", "during", "in", "of", "this", "that", "session", "group"]
		let left = Set(lhs.dropFirst()).subtracting(modifiers), right = Set(rhs.dropFirst()).subtracting(modifiers)
		if !left.intersection(right).isEmpty { return true }
		return right.isDisjoint(with: canonical(evidence).split(separator: " ").map(String.init))
	}

	private static func sharesSource(_ lhs: String, _ rhs: String, sentences: [String]) -> Bool {
		let lhs = canonical(lhs), rhs = canonical(rhs)
		guard !lhs.isEmpty, !rhs.isEmpty else { return false }
		if (" " + lhs + " ").contains(" " + rhs + " ") || (" " + rhs + " ").contains(" " + lhs + " ") { return true }
		return sentences.contains { (" " + $0 + " ").contains(" " + lhs + " ") && (" " + $0 + " ").contains(" " + rhs + " ") }
	}

	private static func sourceSentences(_ corpus: String) -> [String] {
		var sentences: [String] = []
		corpus.enumerateSubstrings(in: corpus.startIndex..<corpus.endIndex, options: [.bySentences]) { sentence, _, _, _ in
			if let sentence { sentences.append(canonical(sentence)) }
		}
		return sentences
	}

	private static func unique(_ rules: [EventReminderRule]) -> EventReminderRule? {
		rules.count == 1 ? rules[0] : nil
	}
}
