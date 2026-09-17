#if DEBUG
import Foundation

@MainActor
enum ReminderIdentityContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-identity-contract-tests") else { return }
		do {
			try await durableLifecycleChecks()
			try await feedbackChecks()
			try await multilineFeedbackChecks()
			try await removalChecks()
			try await pinnedSnapshotChecks()
			try await consumptionWriteFailureChecks()
			try await sharedEvidenceChecks()
			try await omittedDistinctActionChecks()
			try await omittedDistinctObjectChecks()
			try await legacyChecks()
			print("REMINDER IDENTITY CONTRACT: durable identity, consumption, archive recovery, feedback generations, removal, pinned refresh, write faults, and legacy metadata passed")
			fflush(stdout)
		} catch { fatalError("REMINDER IDENTITY CONTRACT: \(error)") }
	}

	private static let now = Date(timeIntervalSince1970: 1_900_000_000)
	private static let evidence = "Next time, bring the blue notebook to this event."

	private static func durableLifecycleChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var original = rule()
		original.leadTimeOverrideMinutes = 37
		let (repository, entry) = try await seed(root, reminders: [original])
		let first = event("A", offset: 3_600), second = event("B", offset: 7_200)
		let pinned = try await resolveAndCommit(repository, entry.id, events: [second, first], at: now)
		try expect(pinned.entry?.reminders.first?.resolvedOccurrence == first, "An unresolved next cue must durably pin the first occurrence")
		var proposed = rule()
		proposed.motivation = "A newly generated explanation"
		proposed.createdAt = now.addingTimeInterval(100)
		proposed.leadTimeOverrideMinutes = 2
		let reparsed = try await commit(repository, entry.id, generated: [proposed])
		let retained = try reminder(reparsed)
		try expect(retained.id == original.id && retained.createdAt == original.createdAt
			&& retained.leadTimeOverrideMinutes == 37 && retained.resolvedOccurrence == first
			&& retained.motivation == proposed.motivation,
			"Generated content may update explanation but must preserve app-owned identity, creation, override and pin")
		let consumed = try await resolveAndCommit(repository, entry.id, events: [first, second], at: first.endDate.addingTimeInterval(1))
		try expect(try reminder(consumed).consumedAt != nil, "An ended pin must durably consume a next cue")
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		var wording = rule()
		wording.text = "Remember to bring the blue notebook"
		let recovered = try await commit(restarted, entry.id, generated: [wording])
		try expect(try reminder(recovered).id == original.id && reminder(recovered).consumedAt != nil,
			"Rephrasing from the same grounded source after restart must not re-arm a consumed cue")
		let noSecond = await ReminderEngine.resolve(entries: [try savedEntry(recovered)], events: [second], now: first.endDate.addingTimeInterval(2), modelIsAvailable: { false })
		try expect(noSecond.occurrences.isEmpty, "A regenerated consumed cue must never emit future occurrence B")
		var expanded = rule()
		expanded.text = "Bring the blue meeting notebook"
		let ambiguous = try await commit(restarted, entry.id, generated: [expanded])
		let noExpandedSecond = await ReminderEngine.resolve(entries: [try savedEntry(ambiguous)], events: [second], now: first.endDate.addingTimeInterval(3), modelIsAvailable: { false })
		try expect(noExpandedSecond.occurrences.isEmpty && ambiguous.entry?.reminders.allSatisfy({ $0.consumedAt != nil }) == true,
			"A modifier added to the same grounded consumed action must preserve retirement or be withheld, never create a fresh future cue")
		var paraphrased = rule()
		paraphrased.text = "Take the blue notebook"
		let paraphrase = try await commit(restarted, entry.id, generated: [paraphrased])
		let noParaphrasedSecond = await ReminderEngine.resolve(entries: [try savedEntry(paraphrase)], events: [second], now: first.endDate.addingTimeInterval(4), modelIsAvailable: { false })
		try expect(noParaphrasedSecond.occurrences.isEmpty && paraphrase.entry?.reminders.allSatisfy({ $0.consumedAt != nil }) == true,
			"A transport-verb paraphrase from consumed evidence must not create a fresh cue")
		var pluralized = rule()
		pluralized.text = "Bring the blue notebooks"
		let plural = try await commit(restarted, entry.id, generated: [pluralized])
		let noPluralSecond = await ReminderEngine.resolve(entries: [try savedEntry(plural)], events: [second], now: first.endDate.addingTimeInterval(5), modelIsAvailable: { false })
		try expect(noPluralSecond.occurrences.isEmpty && plural.entry?.reminders.allSatisfy({ $0.consumedAt != nil }) == true,
			"An ungrounded pluralized object must not turn the same consumed evidence into a fresh cue")
		let omitted = try await commit(restarted, entry.id, generated: [])
		try expect(omitted.entry?.reminders.isEmpty == true && omitted.entry?.reminderHistory.contains(where: { $0.id == original.id && $0.consumedAt != nil }) == true,
			"An omitted consumed identity must remain in the durable archive")
		let again = JournalRepository(rootURL: root)
		_ = try await again.load()
		let restored = try await commit(again, entry.id, generated: [rule()])
		try expect(try reminder(restored).id == original.id && reminder(restored).consumedAt != nil,
			"Reappearance after omission and relaunch must recover the same consumed identity")
		let exported = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try savedEntry(omitted))) as? [String: Any]
		let history = exported?["reminderHistory"] as? [[String: Any]]
		try expect(history?.first?["consumedAt"] != nil, "Complete metadata export must retain archived consumption")
	}

	private static func feedbackChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var original = rule()
		original.resolvedOccurrence = event("past", offset: -3_600)
		original.consumedAt = now.addingTimeInterval(-1_000)
		let (repository, entry) = try await seed(root, reminders: [original])
		let unrelated = ReminderFeedback(kind: .voice, text: "Next time, bring water to this event.")
		_ = try await repository.apply(.feedback(unrelated), to: entry.id)
		var water = rule()
		water.text = "Bring water"
		water.evidence = unrelated.text
		let augmented = try await commit(repository, entry.id, generated: [rule(), water])
		try expect(augmented.entry?.reminders.first(where: { $0.id == original.id })?.consumedAt == original.consumedAt,
			"Unrelated voice feedback must not reset another cue's consumed identity")
		let newInstruction = ReminderFeedback(kind: .voice, text: "At the next event, bring the blue notebook again.")
		_ = try await repository.apply(.feedback(newInstruction), to: entry.id)
		var fresh = rule()
		fresh.evidence = newInstruction.text
		let renewed = try await commit(repository, entry.id, generated: [fresh, water])
		guard let renewedRule = renewed.entry?.reminders.first(where: { $0.evidence == newInstruction.text }) else { throw Failure("Missing explicitly renewed cue") }
		try expect(renewedRule.id != original.id && renewedRule.consumedAt == nil && renewedRule.resolvedOccurrence == nil
			&& renewedRule.sourceFeedbackID == newInstruction.id,
			"An unambiguous new voice instruction must receive a new unconsumed identity with durable provenance")
		try expect(renewed.entry?.reminderProcessedFeedbackIDs.contains(newInstruction.id) == true,
			"The atomic parser commit must mark the voice correction processed")
		_ = try await repository.commitReminderResolution([
			ReminderResolutionUpdate(reminderID: renewedRule.id, occurrence: nil, examples: nil, consumedAt: now)
		], source: renewed)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let repeated = try await commit(restarted, entry.id, generated: [fresh, water])
		let repeatedRule = repeated.entry?.reminders.first(where: { $0.evidence == newInstruction.text })
		try expect(repeatedRule?.id == renewedRule.id && repeatedRule?.consumedAt == now,
			"Reprocessing the same saved correction after restart must not create another cue generation")
	}

	private static func removalChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let shared = "Next time, bring the blue notebook and label the blue notebook for this event."
		var bring = rule(), label = rule()
		bring.evidence = shared
		label.text = "Label the blue notebook"
		label.evidence = shared
		let (repository, entry) = try await seed(root, reminders: [bring, label], transcript: shared)
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reminders)
		let lease = try await claim(repository)
		let correction = ReminderFeedback(kind: .manualRemoval, text: bring.text, focusedReminderID: bring.id)
		let removed = try await repository.apply(.removeReminder(bring.id, correction), to: entry.id)
		try expect(removed.entry?.reminderHistory.contains(where: { $0.id == bring.id }) == true,
			"Manual removal must archive the exact rule before deleting visible content")
		var staleRejected = false
		do { _ = try await repository.commitReminders(.init(reminders: [bring, label], modelName: "Late fixture"), lease: lease) }
		catch RepositoryError.staleProcessing { staleRejected = true }
		try expect(staleRejected, "A parser lease issued before manual removal must not restore the removed cue")
		var changed = bring
		changed.id = UUID()
		changed.text = "Remember to bring the blue notebook"
		var changedLabel = label
		changedLabel.id = UUID()
		let revised = try await commit(repository, entry.id, generated: [changed, changedLabel])
		try expect(revised.entry?.reminders.map(\.id) == [label.id],
			"Changed wording of a removed identity must stay removed while a different action sharing its evidence and noun survives")
	}

	private static func multilineFeedbackChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var old = rule()
		old.consumedAt = now.addingTimeInterval(-100)
		let (repository, entry) = try await seed(root, reminders: [old])
		let feedback = ReminderFeedback(kind: .voice, text: "At the next event,\nbring the blue notebook again.")
		_ = try await repository.apply(.feedback(feedback), to: entry.id)
		let services = ReminderModelServices(budget: { _, _, _ in
			try ModelContextBudget(contextSize: 20_000, instructionTokens: 0, schemaTokens: 0, outputTokens: 500, safetyTokens: 0, count: { $0.utf8.count })
		}, drafts: { _, _, _ in
			[GeneratedReminderDraft(text: "Bring the blue notebook", motivation: "You requested another reminder", evidence: feedback.text)]
		}, schedule: { _, _, _ in
			GeneratedReminderSchedule(scheduleContext: feedback.text, eventDescription: "Notebook workshop", locationDescription: "none")
		}, match: { _, _, _ in throw Failure("Extraction should not classify events") })
		let parsed = await ReminderEngine.parse(transcript: entry.transcript, sourceEvent: entry.calendarEvent, createdAt: entry.createdAt,
			currentReminders: [old], feedback: [feedback], modelIsAvailable: { true }, services: services)
		try expect(parsed.outcome.isComplete && parsed.reminders.first?.evidence == feedback.text,
			"Production parsing must preserve exact multiline evidence used to prove a new correction's source")
		let saved = try await commit(repository, entry.id, generated: parsed.reminders)
		let fresh = try reminder(saved)
		try expect(fresh.id != old.id && fresh.sourceFeedbackID == feedback.id && fresh.consumedAt == nil,
			"A uniquely grounded new multiline correction must create exactly one fresh cue generation")
	}

	private static func pinnedSnapshotChecks() async throws {
		var pinned = rule()
		let original = event("A", offset: 3_600), other = event("B", offset: 7_200)
		pinned.resolvedOccurrence = original
		let entry = makeEntry(reminders: [pinned])
		let missing = await ReminderEngine.resolve(entries: [entry], events: [other], now: now, modelIsAvailable: { false })
		try expect(missing.occurrences.isEmpty && missing.resolvedOccurrencesByReminderID[pinned.id] == nil
			&& missing.consumedAtByReminderID[pinned.id] == nil, "A missing future pin must neither drift to B nor be consumed early")
		let restored = await ReminderEngine.resolve(entries: [entry], events: [other, original], now: now, modelIsAvailable: { false })
		try expect(restored.occurrences.map(\.event) == [original], "Restoring A must restore the original pinned occurrence")
		var rewritten = pinned
		rewritten.id = UUID()
		rewritten.occurrencePolicy = .everyMatch
		let reconciled = ReminderIdentity.reconcile(generated: [rewritten], entry: entry)
		try expect(reconciled.reminders.first?.occurrencePolicy == .nextMatch,
			"A legacy pin without consumedAt must retain next-only delivery when model output proposes every-match")
		let retired = await ReminderEngine.resolve(entries: [makeEntry(reminders: reconciled.reminders)], events: [other],
			now: original.endDate.addingTimeInterval(1), modelIsAvailable: { false })
		try expect(retired.occurrences.isEmpty && retired.consumedAtByReminderID[pinned.id] != nil,
			"An ended legacy pin must be consumed before a policy rewrite can deliver a later event")
		var extended = original
		extended.endDate = original.endDate.addingTimeInterval(3_600)
		extended.title = "Updated event title"
		let refreshed = await ReminderEngine.resolve(entries: [entry], events: [extended, other], now: original.endDate.addingTimeInterval(1), modelIsAvailable: { false })
		try expect(refreshed.occurrences.map(\.event) == [extended] && refreshed.resolvedOccurrencesByReminderID[pinned.id] == extended
			&& refreshed.consumedAtByReminderID[pinned.id] == nil,
			"A provably identical pin's refreshed end must be applied before deciding consumption")
		pinned.consumedAt = now
		pinned.occurrencePolicy = .everyMatch
		let consumed = await ReminderEngine.resolve(entries: [makeEntry(reminders: [pinned])], events: [other], now: now, modelIsAvailable: { false })
		try expect(consumed.occurrences.isEmpty, "A policy rewrite must not bypass already-consumed app state")
	}

	private static func consumptionWriteFailureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var pinned = rule()
		pinned.resolvedOccurrence = event("A", offset: 3_600)
		let (repository, entry) = try await seed(root, reminders: [pinned])
		let source = try await record(repository, entry.id)
		let path = root.appendingPathComponent("Records/\(entry.id.uuidString).json")
		let held = root.appendingPathComponent("held.json")
		try FileManager.default.moveItem(at: path, to: held)
		try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
		let update = ReminderResolutionUpdate(reminderID: pinned.id, occurrence: nil, examples: nil, consumedAt: now)
		var failed = false
		do { _ = try await repository.commitReminderResolution([update], source: source) } catch { failed = true }
		let unchanged = try await record(repository, entry.id)
		try expect(failed && unchanged.entry?.reminders.first?.consumedAt == nil,
			"A failed consumption write must preserve prior repository memory and acknowledgment")
		try FileManager.default.removeItem(at: path)
		try FileManager.default.moveItem(at: held, to: path)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let prior = try await record(restarted, entry.id)
		try expect(prior.entry?.reminders.first?.consumedAt == nil, "A failed write must not falsely appear durable after restart")
		let saved = try await restarted.commitReminderResolution([update], source: prior)
		try expect(saved.entry?.reminders.first?.consumedAt == now, "The unchanged consumption update must remain retryable")
	}

	private static func sharedEvidenceChecks() async throws {
		let shared = "Next time, bring the notebook and label the notebook for this event."
		let services = ReminderModelServices(budget: { _, _, _ in
			try ModelContextBudget(contextSize: 20_000, instructionTokens: 0, schemaTokens: 0, outputTokens: 500, safetyTokens: 0, count: { $0.utf8.count })
		}, drafts: { _, _, _ in
			[GeneratedReminderDraft(text: "Bring the notebook", motivation: "You need it", evidence: shared),
			 GeneratedReminderDraft(text: "Label the notebook", motivation: "You can identify it", evidence: shared)]
		}, schedule: { _, _, _ in
			GeneratedReminderSchedule(scheduleContext: shared, eventDescription: "Notebook workshop", locationDescription: "none")
		},
		match: { _, _, _ in throw Failure("Extraction should not classify events") })
		let parsed = await ReminderEngine.parse(transcript: shared, sourceEvent: event("source", offset: -3_600), createdAt: now,
			modelIsAvailable: { true }, services: services)
		try expect(parsed.outcome.isComplete && parsed.reminders.count == 2,
			"Production parsing must keep distinct actions that share their supporting source sentence")
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root, reminders: [], transcript: shared)
		let saved = try await commit(repository, entry.id, generated: parsed.reminders)
		let ids = saved.entry?.reminders.map(\.id) ?? []
		var regenerated = parsed.reminders
		for index in regenerated.indices { regenerated[index].id = UUID() }
		let again = try await commit(repository, entry.id, generated: regenerated)
		try expect(Set(ids).count == 2 && again.entry?.reminders.map(\.id) == ids,
			"One shared excerpt must neither collapse two actions nor let them claim one previous UUID")
	}

	private static func legacyChecks() async throws {
		let feedback = ReminderFeedback(kind: .voice, text: "At the next event, bring the blue notebook again.")
		var consumed = rule()
		consumed.evidence = feedback.text
		consumed.consumedAt = now
		var entry = makeEntry(reminders: [consumed])
		entry.reminderFeedback = [feedback]
		var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
		json.removeValue(forKey: "reminderProcessedFeedbackIDs")
		json.removeValue(forKey: "reminderHistory")
		let decoded = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: json))
		try expect(decoded.reminderHistory.isEmpty && decoded.reminderProcessedFeedbackIDs == [feedback.id],
			"Legacy metadata must treat already-saved voice feedback as processed")
		var regenerated = consumed
		regenerated.id = UUID()
		regenerated.consumedAt = nil
		let reconciled = ReminderIdentity.reconcile(generated: [regenerated], entry: decoded)
		try expect(reconciled.reminders.first?.id == consumed.id && reconciled.reminders.first?.consumedAt == now,
			"Legacy feedback must not become a new command when identity support is first loaded")
		var rules = json["reminders"] as! [[String: Any]]
		rules[0].removeValue(forKey: "consumedAt")
		rules[0].removeValue(forKey: "sourceFeedbackID")
		json["reminders"] = rules
		var oldFeedback = json["reminderFeedback"] as! [[String: Any]]
		oldFeedback[0].removeValue(forKey: "id")
		json["reminderFeedback"] = oldFeedback
		let legacy = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: json))
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		try await repository.save([legacy])
		let reopened = try await JournalRepository(rootURL: root).load()
		guard let roundTrip = reopened.entries.first else { throw Failure("Missing reloaded legacy reminder fixture") }
		try expect(roundTrip.reminders.first?.consumedAt == nil && roundTrip.reminders.first?.sourceFeedbackID == nil
			&& roundTrip.reminderProcessedFeedbackIDs == Set(roundTrip.reminderFeedback.map(\.id))
			&& roundTrip.reminderFeedback.map(\.id) == legacy.reminderFeedback.map(\.id),
			"Legacy optional rule fields must default safely and generated feedback IDs must stabilize after save")
	}

	private static func omittedDistinctActionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let shared = "Next time, bring the notebook and ask about the budget at this event."
		var bring = rule()
		bring.text = "Bring the notebook"
		bring.evidence = shared
		bring.resolvedOccurrence = event("A", offset: 3_600)
		let (repository, entry) = try await seed(root, reminders: [bring], transcript: shared)
		var ask = rule()
		ask.text = "Ask about the budget"
		ask.evidence = shared
		let recovered = try await commit(repository, entry.id, generated: [ask])
		let newAction = try reminder(recovered)
		try expect(newAction.id != bring.id && newAction.resolvedOccurrence == nil
			&& recovered.entry?.reminderHistory.contains(where: { $0.id == bring.id }) == true,
			"A previously omitted distinct action must neither be vetoed nor inherit a pinned action's identity from shared evidence")
		let future = event("B", offset: 7_200)
		let withPin = try await resolveAndCommit(repository, entry.id, events: [future], at: now.addingTimeInterval(5_401))
		try expect(try reminder(withPin).resolvedOccurrence == future,
			"The newly recovered independent action may select its own future occurrence")
		let both = try await commit(repository, entry.id, generated: [bring, ask])
		try expect(Set(both.entry?.reminders.map(\.id) ?? []) == [bring.id, newAction.id],
			"Reappearance of both actions must retain two independent durable identities")
		let resolution = await ReminderEngine.resolve(entries: [try savedEntry(both)], events: [future], now: now.addingTimeInterval(5_402), modelIsAvailable: { false })
		try expect(resolution.occurrences.map(\.reminder.id) == [newAction.id] && resolution.consumedAtByReminderID[bring.id] != nil,
			"Only the independent new cue may emit B; the original ended pin must consume separately")
	}

	private static func omittedDistinctObjectChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let shared = "Next time, bring the notebook and bring water to this event."
		var notebook = rule()
		notebook.text = "Bring the notebook"
		notebook.evidence = shared
		notebook.resolvedOccurrence = event("A", offset: 3_600)
		let (repository, entry) = try await seed(root, reminders: [notebook], transcript: shared)
		var water = rule()
		water.text = "Bring water"
		water.evidence = shared
		let recovered = try await commit(repository, entry.id, generated: [water])
		let independent = try reminder(recovered)
		try expect(independent.id != notebook.id && independent.resolvedOccurrence == nil
			&& recovered.entry?.reminderHistory.contains(where: { $0.id == notebook.id }) == true,
			"A different fully grounded object must keep a same-verb action independent from the old pinned cue")
		let future = event("B", offset: 7_200)
		let resolution = await ReminderEngine.resolve(entries: [try savedEntry(recovered)], events: [future], now: now.addingTimeInterval(5_401), modelIsAvailable: { false })
		try expect(resolution.occurrences.map(\.reminder.id) == [independent.id],
			"The independently grounded water action may select B without borrowing the notebook's identity")
	}

	private static func resolveAndCommit(_ repository: JournalRepository, _ id: UUID, events: [JournalCalendarEvent], at date: Date) async throws -> JournalRecord {
		let source = try await record(repository, id)
		let result = await ReminderEngine.resolve(entries: [try savedEntry(source)], events: events, now: date, modelIsAvailable: { false })
		try expect(result.outcome.isComplete, "Deterministic series resolution must not require an available model")
		let ids = Set(result.resolvedOccurrencesByReminderID.keys).union(result.consumedAtByReminderID.keys)
		let updates = ids.map { ReminderResolutionUpdate(reminderID: $0, occurrence: result.resolvedOccurrencesByReminderID[$0],
			examples: nil, consumedAt: result.consumedAtByReminderID[$0]) }
		return try await repository.commitReminderResolution(updates, source: source)
	}
	private static func commit(_ repository: JournalRepository, _ id: UUID, generated: [EventReminderRule]) async throws -> JournalRecord {
		_ = try await repository.requestProcessing(id: id, startAt: .reminders)
		let lease = try await claim(repository)
		return try await repository.commitReminders(.init(reminders: generated, modelName: "Fixture"), lease: lease)
	}
	private static func claim(_ repository: JournalRepository) async throws -> ProcessingLease {
		guard let work = try await repository.claimProcessing(), work.lease.stage == .reminders else { throw Failure("Expected a reminder stage lease") }
		return work.lease
	}
	private static func seed(_ root: URL, reminders: [EventReminderRule], transcript: String = evidence) async throws -> (JournalRepository, JournalEntry) {
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = makeEntry(reminders: reminders, transcript: transcript)
		try await repository.save([entry])
		return (repository, entry)
	}
	private static func makeEntry(reminders: [EventReminderRule], transcript: String = evidence) -> JournalEntry {
		let id = UUID()
		return JournalEntry(id: id, createdAt: now, duration: 30, transcript: transcript, headline: "Saved reminder fixture",
			audioFilename: "\(id.uuidString).m4a", calendarEvent: event("source", offset: -3_600), reminders: reminders)
	}
	private static func rule() -> EventReminderRule {
		EventReminderRule(text: "Bring the blue notebook", motivation: "You need your notes", evidence: evidence,
			selector: .series(EventSeriesReference(event: event("source", offset: -3_600))), occurrencePolicy: .nextMatch, createdAt: now)
	}
	private static func event(_ id: String, offset: TimeInterval) -> JournalCalendarEvent {
		let start = now.addingTimeInterval(offset)
		return JournalCalendarEvent(id: id, externalIdentifier: "fixture-series", calendarIdentifier: "fixture-calendar", calendarTitle: "Fixture",
			title: "Notebook workshop", startDate: start, endDate: start.addingTimeInterval(1_800), isAllDay: false, isRecurring: true)
	}
	private static func record(_ repository: JournalRepository, _ id: UUID) async throws -> JournalRecord {
		guard let record = await repository.record(id: id) else { throw Failure("Expected a saved manifest") }
		return record
	}
	private static func savedEntry(_ record: JournalRecord) throws -> JournalEntry {
		guard let entry = record.entry else { throw Failure("Expected a saved entry") }
		return entry
	}
	private static func reminder(_ record: JournalRecord) throws -> EventReminderRule {
		guard let reminder = record.entry?.reminders.first else { throw Failure("Expected a saved reminder") }
		return reminder
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-identity-\(UUID())")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
