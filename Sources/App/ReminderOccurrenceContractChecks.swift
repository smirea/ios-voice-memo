#if DEBUG
import Foundation
#if os(iOS)
import ActivityKit
#endif

@MainActor
enum ReminderOccurrenceContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-occurrence-contract-tests") else { return }
		do {
			try await movedPinLifecycle()
			try await legacyPinRestart()
			try await rejectedCandidates()
			try await ambiguousEndedPin()
			try await unpinnedAmbiguity()
			try await fuzzyAmbiguity()
			try await movedValidity()
			#if os(iOS)
			try await activityCompatibility()
			print("REMINDER OCCURRENCE CONTRACT: moved pin refresh, legacy restart, calendar and ambiguity fences, expiry, monotonic consumption, and activity identity passed")
			#else
			print("REMINDER OCCURRENCE CONTRACT: repository and pin checks passed; activity identity checks require iOS")
			#endif
			fflush(stdout)
		} catch { fatalError("REMINDER OCCURRENCE CONTRACT: \(error)") }
	}

	private static let now = Date(timeIntervalSince1970: 2_000_000_000)

	private static func movedPinLifecycle() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let original = event(start: 3_600)
		let (repository, entry) = try await seed(root, pin: original)
		var moved = original
		moved.id = "detached-id"
		moved.localIdentifier = "detached-local-id"
		moved.title = "Renamed workshop"
		moved.startDate = now.addingTimeInterval(10_800)
		moved.endDate = now.addingTimeInterval(12_600)
		let later = event(start: 86_400)
		let afterOldEnd = original.endDate.addingTimeInterval(1)
		let resolved = await resolve(entry, events: [later, moved], at: afterOldEnd)
		try expect(resolved.occurrences.map(\.event) == [moved] && resolved.consumedAtByReminderID.isEmpty,
			"Current original-date identity must refresh a moved/renamed pin before its old end could consume it")
		let saved = try await commit(resolved, repository: repository, entryID: entry.id)
		try expect(saved.entry?.reminders[0].resolvedOccurrence == moved && saved.entry?.reminders[0].id == entry.reminders[0].id,
			"Refresh must persist the current occurrence without replacing the reminder identity")
		let restarted = JournalRepository(rootURL: root)
		let loaded = try await restarted.load()
		let restored = try onlyEntry(loaded.entries)
		try expect(restored.reminders[0].resolvedOccurrence == moved, "Moved original occurrence metadata must survive repository restart")
		let consumed = await resolve(restored, events: [moved, later], at: moved.endDate.addingTimeInterval(1))
		let retired = try await commit(consumed, repository: restarted, entryID: restored.id)
		try expect(retired.entry?.reminders[0].consumedAt == moved.endDate, "Consumption must use the refreshed actual end")
		var extended = moved
		extended.endDate = later.endDate
		let afterRetirement = await resolve(try savedEntry(retired), events: [extended, later], at: moved.endDate.addingTimeInterval(2))
		try expect(afterRetirement.occurrences.isEmpty && afterRetirement.resolvedOccurrencesByReminderID.isEmpty,
			"Later occurrence edits must never revive already-consumed app state")
	}

	private static func legacyPinRestart() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var legacy = event(start: 3_600)
		legacy.occurrenceDate = nil
		let encoded = try JSONEncoder().encode(legacy)
		let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
		try expect(object["occurrenceDate"] == nil, "Legacy snapshots must not invent an original occurrence date")
		let decoded = try JSONDecoder().decode(JournalCalendarEvent.self, from: encoded)
		let (repository, entry) = try await seed(root, pin: decoded)
		let before = try await record(repository, entry.id)
		var current = event(start: 3_600)
		current.id = "new-event-id"
		current.localIdentifier = "new-item-id"
		current.startDate.addTimeInterval(900)
		current.endDate.addTimeInterval(900)
		let result = await resolve(entry, events: [event(start: 86_400), current])
		try expect(result.occurrences.map(\.event) == [current], "A legacy pin may adopt a unique original-date match without drifting to the series head")
		let updated = try await commit(result, repository: repository, entryID: entry.id)
		try expect(updated.inputRevision == before.inputRevision && updated.revision > before.revision,
			"Occurrence refresh must preserve source leases while durably updating derived metadata")
		let restarted = JournalRepository(rootURL: root)
		let loaded = try await restarted.load()
		let restored = try onlyEntry(loaded.entries)
		try expect(restored.id == entry.id && restored.reminders[0].id == entry.reminders[0].id
			&& restored.reminders[0].resolvedOccurrence?.occurrenceDate == legacy.startDate,
			"Legacy pin identity and adopted original date must survive restart")
		let missing = await resolve(restored, events: [event(start: 86_400)])
		try expect(missing.occurrences.isEmpty && missing.resolvedOccurrencesByReminderID.isEmpty,
			"A missing refreshed legacy pin must not retarget a later recurrence")
	}

	private static func rejectedCandidates() async throws {
		let original = event(start: 3_600)
		var wrongCalendar = original
		wrongCalendar.calendarIdentifier = "another-account-calendar"
		var wrongOccurrence = original
		wrongOccurrence.occurrenceDate = now.addingTimeInterval(86_400)
		var unprovenMove = original
		unprovenMove.occurrenceDate = nil
		unprovenMove.startDate.addTimeInterval(300)
		unprovenMove.endDate.addTimeInterval(300)
		var copyA = original, copyB = original
		copyA.id = "copy-A"; copyA.localIdentifier = "copy-A-local"
		copyB.id = "copy-B"; copyB.localIdentifier = "copy-B-local"
		copyB.startDate.addTimeInterval(60); copyB.endDate.addTimeInterval(60)
		let entry = makeEntry(pin: original)
		for candidates in [[wrongCalendar], [wrongOccurrence], [unprovenMove], [copyA, copyB], []] {
			let result = await resolve(entry, events: candidates + [event(start: 86_400)])
			try expect(result.occurrences.isEmpty && result.resolvedOccurrencesByReminderID.isEmpty
				&& result.consumedAtByReminderID.isEmpty,
				"Wrong-calendar, wrong-original-date, unproven moved, ambiguous, and missing future pins must remain unavailable without drift")
		}
		var every = entry
		every.reminders[0].occurrencePolicy = .everyMatch
		every.reminders[0].resolvedOccurrence = nil
		let wrongAccount = await resolve(every, events: [wrongCalendar])
		try expect(wrongAccount.occurrences.isEmpty, "Shared external IDs or calendar titles must not cross known calendar IDs for unpinned series matching")
	}

	private static func movedValidity() async throws {
		let original = event(start: 3_600)
		var entry = makeEntry(pin: original)
		let expiry = now.addingTimeInterval(7_200)
		entry.reminders[0].expiresAt = expiry
		for offset in [7_200.0, 7_201.0] {
			var moved = original
			moved.startDate = now.addingTimeInterval(offset)
			moved.endDate = moved.startDate.addingTimeInterval(1_800)
			let result = await resolve(entry, events: [moved, event(start: 5_400)])
			try expect(result.resolvedOccurrencesByReminderID[entry.reminders[0].id] == moved,
				"The current pinned snapshot must refresh even when its new start is outside validity")
			try expect(result.occurrences.map(\.event) == (offset == 7_200 ? [moved] : []) && result.consumedAtByReminderID.isEmpty,
				"Moved occurrences must honor inclusive expiry and never substitute another in-window event")
		}
	}

	private static func ambiguousEndedPin() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let original = event(start: -3_600)
		let (repository, entry) = try await seed(root, pin: original)
		var ended = original, moved = original
		ended.id = "ambiguous-old"; ended.localIdentifier = "ambiguous-old-item"
		moved.id = "ambiguous-moved"; moved.localIdentifier = "ambiguous-moved-item"
		moved.startDate = now.addingTimeInterval(3_600)
		moved.endDate = now.addingTimeInterval(5_400)
		let result = await resolve(entry, events: [ended, moved, event(start: 86_400)])
		try expect(result.occurrences.isEmpty && result.resolvedOccurrencesByReminderID.isEmpty && result.consumedAtByReminderID.isEmpty
			&& result.incompleteReminderIDs == [entry.reminders[0].id] && !result.outcome.isComplete,
			"An ambiguous original occurrence must not consume the old pin: one credible current candidate may have moved into the future")
		_ = try await commit(result, repository: repository, entryID: entry.id)
		let loaded = try await JournalRepository(rootURL: root).load()
		let restored = try onlyEntry(loaded.entries)
		try expect(restored.reminders[0].consumedAt == nil && restored.reminders[0].resolvedOccurrence == original,
			"An ambiguous ended pin must stay saved and unconsumed across restart")
		let missing = await resolve(restored, events: [event(start: 86_400)])
		try expect(missing.consumedAtByReminderID[entry.reminders[0].id] == original.endDate,
			"Ordinary absence must retain the established ended-pin consumption policy without selecting another recurrence")
	}

	private static func unpinnedAmbiguity() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let original = event(start: 3_600), later = event(start: 86_400)
		var duplicate = original
		duplicate.id = "different-native-item"; duplicate.localIdentifier = "different-local-item"
		duplicate.startDate.addTimeInterval(60); duplicate.endDate.addTimeInterval(60)
		var entry = makeEntry(pin: original)
		entry.reminders[0].resolvedOccurrence = nil
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		try await repository.save([entry])
		let ambiguous = await resolve(entry, events: [later, duplicate, original, original])
		try expect(ambiguous.occurrences.isEmpty && ambiguous.resolvedOccurrencesByReminderID.isEmpty
			&& ambiguous.incompleteReminderIDs == [entry.reminders[0].id] && !ambiguous.outcome.isComplete,
			"An unpinned next reminder must neither choose an ambiguous item nor skip it for a later recurrence")
		_ = try await commit(ambiguous, repository: repository, entryID: entry.id)
		let restarted = JournalRepository(rootURL: root)
		let loaded = try await restarted.load()
		let restored = try onlyEntry(loaded.entries)
		try expect(restored.reminders[0].resolvedOccurrence == nil && restored.reminders[0].consumedAt == nil,
			"Ambiguous initial matching must not persist an arbitrary pin across restart")
		let repaired = await resolve(restored, events: [original, original, later])
		try expect(repaired.outcome.isComplete && repaired.occurrences.map(\.event) == [original],
			"Repeated identical snapshots must collapse to one proven occurrence")
		let saved = try await commit(repaired, repository: restarted, entryID: entry.id)
		try expect(saved.entry?.reminders[0].resolvedOccurrence == original,
			"Removing the conflicting native item must allow the original first occurrence to pin durably")

		var every = entry
		every.reminders[0].occurrencePolicy = .everyMatch
		let mixed = await resolve(every, events: [original, duplicate, later, later])
		try expect(mixed.occurrences.map(\.event) == [later] && !mixed.outcome.isComplete
			&& mixed.incompleteReminderIDs == [entry.reminders[0].id],
			"Every-match must retain independent unique occurrences while reporting excluded ambiguous groups")
		let earlier = event(start: 1_800)
		let firstProven = await resolve(entry, events: [original, duplicate, earlier])
		try expect(firstProven.occurrences.map(\.event) == [earlier] && firstProven.outcome.isComplete,
			"Ambiguity strictly after the proven next event must not prevent that event from pinning")
		var simultaneous = later
		simultaneous.startDate = original.startDate; simultaneous.endDate = original.endDate
		let stableFirst = [original, simultaneous].min { $0.focusKey < $1.focusKey }!
		for order in [[original, simultaneous], [simultaneous, original]] {
			let tied = await resolve(entry, events: order)
			try expect(tied.occurrences.map(\.event) == [stableFirst] && tied.outcome.isComplete,
				"Distinct original occurrences sharing a current start must use a deterministic next-match tie break")
		}
		var wrongA = original, wrongB = duplicate
		wrongA.calendarIdentifier = "unrelated-calendar"; wrongB.calendarIdentifier = "unrelated-calendar"
		let unrelated = await resolve(entry, events: [wrongA, wrongB, later])
		try expect(unrelated.occurrences.map(\.event) == [later] && unrelated.outcome.isComplete,
			"An ambiguous group in another calendar must not block a known series")
		var ended = original
		ended.startDate = now.addingTimeInterval(-3_600); ended.endDate = now.addingTimeInterval(-1_800)
		let mixedValidity = await resolve(entry, events: [ended, duplicate, later])
		try expect(mixedValidity.occurrences.isEmpty && !mixedValidity.outcome.isComplete,
			"Filtering an ended duplicate must not falsely prove its still-future counterpart unique")
	}

	private static func fuzzyAmbiguity() async throws {
		var original = event(start: 3_600), later = event(start: 86_400)
		original.title = "Client planning workshop"; later.title = "Client planning workshop"
		var duplicate = original
		duplicate.id = "fuzzy-copy"; duplicate.localIdentifier = "fuzzy-copy-item"
		duplicate.title = "Client planning session"
		duplicate.startDate.addTimeInterval(60); duplicate.endDate.addTimeInterval(60)
		var entry = makeEntry(pin: original)
		entry.reminders[0].resolvedOccurrence = nil
		entry.reminders[0].occurrencePolicy = .everyMatch
		entry.reminders[0].selector = .fuzzy(.init(semanticDescription: "client planning workshop", timeBucket: .any,
			locationDescription: nil, examples: []))
		let probe = MatchProbe()
		let services = ReminderModelServices(budget: { _, _, _ in
			try ModelContextBudget(contextSize: 20_000, instructionTokens: 0, schemaTokens: 0,
				outputTokens: 500, safetyTokens: 0, count: { $0.utf8.count })
		}, drafts: { _, _, _ in throw Failure("Resolution must not extract reminders") },
			schedule: { _, _, _ in throw Failure("Resolution must not regenerate schedules") },
			match: { _, prompt, _ in await probe.classify(prompt) })
		var semantic = later
		semantic.title = "Planning with clients"
		let result = await ReminderEngine.resolve(entries: [entry], events: [original, duplicate, semantic, semantic],
			now: now, modelIsAvailable: { true }, services: services)
		let prompts = await probe.prompts
		try expect(result.occurrences.map(\.event) == [semantic] && result.incompleteReminderIDs == [entry.reminders[0].id]
			&& !result.outcome.isComplete && prompts.count == 1,
			"Ambiguous fuzzy candidates must never share a decision key or reach inference; a unique semantic candidate may still be classified once")
		try expect(result.examplesByReminderID[entry.reminders[0].id]?.map(\.event) == [semantic],
			"Ambiguous snapshots must not become confident positive or negative match examples")
		entry.reminders[0].occurrencePolicy = .nextMatch
		let blocked = await ReminderEngine.resolve(entries: [entry], events: [original, duplicate, later],
			now: now, modelIsAvailable: { true }, services: services)
		try expect(blocked.occurrences.isEmpty && blocked.resolvedOccurrencesByReminderID.isEmpty && !blocked.outcome.isComplete,
			"A potentially matching ambiguous fuzzy group must not be skipped for a later exact title")
		var unrelatedA = original, unrelatedB = duplicate
		unrelatedA.title = "Dentist"; unrelatedB.title = "Dentist appointment"
		let unrelated = await ReminderEngine.resolve(entries: [entry], events: [unrelatedA, unrelatedB, later],
			now: now, modelIsAvailable: { true }, services: services)
		try expect(unrelated.occurrences.map(\.event) == [later] && unrelated.outcome.isComplete,
			"Ambiguous events with no deterministic semantic anchor must not block an unrelated exact target")
		var located = entry
		located.reminders[0].selector = .fuzzy(.init(semanticDescription: "client planning workshop", timeBucket: .any,
			locationDescription: "Office", examples: []))
		var office = later
		office.location = "Office"
		let wrongLocation = await ReminderEngine.resolve(entries: [located], events: [original, duplicate, office],
			now: now, modelIsAvailable: { true }, services: services)
		try expect(wrongLocation.occurrences.map(\.event) == [office] && wrongLocation.outcome.isComplete,
			"A required location can exclude every snapshot of an ambiguous group before pin selection")
		var expired = entry
		expired.reminders[0].expiresAt = now.addingTimeInterval(7_200)
		var lateA = original, lateB = duplicate
		lateA.startDate.addTimeInterval(172_800); lateA.endDate.addTimeInterval(172_800)
		lateB.startDate.addTimeInterval(172_800); lateB.endDate.addTimeInterval(172_800)
		var valid = event(start: 1_800)
		valid.title = "Client planning workshop"
		let outsideWindow = await ReminderEngine.resolve(entries: [expired], events: [lateA, lateB, valid],
			now: now, modelIsAvailable: { true }, services: services)
		try expect(outsideWindow.occurrences.map(\.event) == [valid] && outsideWindow.outcome.isComplete,
			"Ambiguous future occurrences outside expiry must not block an in-window exact match")
		let calls = await probe.prompts.count
		try expect(calls == 1, "Exact, ambiguous, and deterministically excluded groups must not introduce classifier calls")
	}

	private actor MatchProbe {
		var prompts: [String] = []
		func classify(_ prompt: String) -> GeneratedEventMatch {
			prompts.append(prompt)
			return GeneratedEventMatch(matches: true, reason: "Controlled match for the unique candidate")
		}
	}

	#if os(iOS)
	private static func activityCompatibility() async throws {
		let original = event(start: 3_600)
		var otherCalendar = original
		otherCalendar.calendarIdentifier = "another-calendar"
		var moved = original
		moved.startDate.addTimeInterval(900); moved.endDate.addTimeInterval(900)
		try expect(original.focusKey != otherCalendar.focusKey && original.focusKey == moved.focusKey,
			"Occurrence grouping must separate calendar copies and remain stable when an original occurrence moves")
		let first = makeEntry(pin: original), second = makeEntry(pin: otherCalendar)
		let resolved = await ReminderEngine.resolve(entries: [first, second], events: [original, otherCalendar], now: now, modelIsAvailable: { false })
		var settings = JournalSettings()
		settings.calendarSyncEnabled = true
		let backend = Backend()
		let manager = ReminderActivityManager(operations: backend.operations)
		let revisions = [first.id: 1, second.id: 1]
		await manager.synchronize(occurrences: resolved.occurrences, settings: settings, sourceRevisions: revisions, now: now, generation: 1)
		try expect(backend.items.count == 2, "Same original date and native ID across calendars must produce separate activity groups")
		let sources = [ReminderActivitySource(entry: first, inputRevision: 1), ReminderActivitySource(entry: second, inputRevision: 1)]
		let initialTrace = backend.trace
		await manager.retireObsolete(sources: sources, events: [original, original, otherCalendar], settings: settings, now: now, generation: 2)
		try expect(backend.items.count == 2 && backend.requests == 2 && backend.trace == initialTrace,
			"Repeated identical cache snapshots must not retire or replace an existing exact activity")
		let oldID = backend.items.first { $0.value.attributes.calendarIdentifier == original.calendarIdentifier }!.key
		backend.trace = []
		let gate = Gate()
		backend.endGate = gate
		let retire = Task { await manager.retireObsolete(sources: sources, events: [moved, otherCalendar], settings: settings, now: now, generation: 3) }
		try await wait { gate.waiting }
		let current = await ReminderEngine.resolve(entries: [first, second], events: [moved, otherCalendar], now: now, modelIsAvailable: { false })
		let replacement = Task { await manager.synchronize(occurrences: current.occurrences, settings: settings, sourceRevisions: revisions, now: now, generation: 4) }
		try expect(backend.requests == 2, "A moved occurrence must wait for actual obsolete native cleanup before replacement")
		gate.release()
		_ = await retire.value
		_ = await replacement.value
		try expect(backend.items.count == 2 && backend.items[oldID] == nil && backend.requests == 3
			&& backend.trace.first == "end:\(oldID)" && backend.maximumOperations == 1,
			"A stable occurrence key with changed start/end must retire its old descriptor, then replace exactly once without disturbing another calendar")
		var oldFormat = backend.items.first { $0.value.attributes.calendarIdentifier == original.calendarIdentifier }!
		oldFormat.value.attributes.eventKey = "\(original.id)::\(Int(original.startDate.timeIntervalSince1970))"
		backend.items[oldFormat.key] = oldFormat.value
		await manager.synchronize(occurrences: current.occurrences, settings: settings, sourceRevisions: revisions, now: now, generation: 5)
		try expect(backend.items.count == 2 && backend.items[oldFormat.key] == nil && backend.requests == 4,
			"A persisted pre-cutover activity key must be replaced without losing or duplicating the current reminder group")
		var conflicting = moved
		conflicting.id = "activity-conflict"; conflicting.localIdentifier = "activity-conflict-item"
		await manager.retireObsolete(sources: sources, events: [moved, conflicting, otherCalendar], settings: settings, now: now, generation: 6)
		try expect(backend.items.count == 1 && backend.items.values.first?.attributes.calendarIdentifier == otherCalendar.calendarIdentifier
			&& backend.requests == 4,
			"Distinct native items sharing an occurrence identity must retire only that ambiguous activity without creating a substitute")
		await manager.endAll(generation: 7)
	}

	@MainActor private final class Gate {
		var waiting = false
		private var continuation: CheckedContinuation<Void, Never>?
		func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
		func release() { continuation?.resume(); continuation = nil; waiting = false }
	}
	@MainActor private final class Backend {
		var items: [String: DesiredReminderActivity] = [:]
		var requests = 0
		var trace: [String] = []
		var endGate: Gate?
		var operationsInFlight = 0
		var maximumOperations = 0
		private func begin() { operationsInFlight += 1; maximumOperations = max(maximumOperations, operationsInFlight) }
		var operations: ReminderActivityOperations {
			.init(enabled: { true }, existing: { self.items.map { .init(id: $0.key, attributes: $0.value.attributes, content: $0.value.state) } },
				end: { id in
					self.begin(); defer { self.operationsInFlight -= 1 }
					let gate = self.endGate; self.endGate = nil; await gate?.wait()
					self.items[id] = nil; self.trace.append("end:\(id)")
				}, update: { id, item in
					self.begin(); defer { self.operationsInFlight -= 1 }; self.items[id] = item
				}, request: { item, _ in
					self.begin(); defer { self.operationsInFlight -= 1 }
					let id = UUID().uuidString
					self.items[id] = item; self.requests += 1; self.trace.append("request:\(id)")
					return id
				})
		}
	}
	private static func wait(_ predicate: @MainActor () -> Bool) async throws {
		for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
		throw Failure("Timed out waiting for held activity cleanup")
	}
	#endif

	private static func event(start: TimeInterval) -> JournalCalendarEvent {
		let date = now.addingTimeInterval(start)
		var event = JournalCalendarEvent(id: "native-series", localIdentifier: "local-series", externalIdentifier: "external-series",
			calendarIdentifier: "calendar-A", calendarTitle: "Work", title: "Planning workshop", startDate: date,
			endDate: date.addingTimeInterval(1_800), isAllDay: false, isRecurring: true)
		event.occurrenceDate = date
		return event
	}
	private static func makeEntry(pin: JournalCalendarEvent) -> JournalEntry {
		let reminder = EventReminderRule(text: "Bring the notebook", motivation: "Prepare your notes", evidence: "Bring the notebook",
			selector: .series(.init(event: pin)), occurrencePolicy: .nextMatch, createdAt: now.addingTimeInterval(-3_600), resolvedOccurrence: pin)
		return JournalEntry(createdAt: now.addingTimeInterval(-3_600), duration: 30, transcript: "Bring the notebook", headline: "Saved reminder",
			calendarEvent: pin, reminders: [reminder])
	}
	private static func seed(_ root: URL, pin: JournalCalendarEvent) async throws -> (JournalRepository, JournalEntry) {
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = makeEntry(pin: pin)
		try await repository.save([entry])
		return (repository, entry)
	}
	private static func resolve(_ entry: JournalEntry, events: [JournalCalendarEvent], at date: Date = now) async -> ReminderResolutionResult {
		await ReminderEngine.resolve(entries: [entry], events: events, now: date, modelIsAvailable: { false })
	}
	private static func commit(_ result: ReminderResolutionResult, repository: JournalRepository, entryID: UUID) async throws -> JournalRecord {
		try expect(result.outcome != .cancelled, "Canceled resolution must never be committed")
		let source = try await record(repository, entryID)
		let ids = Set(result.resolvedOccurrencesByReminderID.keys).union(result.consumedAtByReminderID.keys)
		let updates = ids.map { ReminderResolutionUpdate(reminderID: $0, occurrence: result.resolvedOccurrencesByReminderID[$0],
			examples: nil, consumedAt: result.consumedAtByReminderID[$0]) }
		return try await repository.commitReminderResolution(updates, source: source)
	}
	private static func record(_ repository: JournalRepository, _ id: UUID) async throws -> JournalRecord {
		guard let record = await repository.record(id: id) else { throw Failure("Missing saved manifest") }
		return record
	}
	private static func savedEntry(_ record: JournalRecord) throws -> JournalEntry {
		guard let entry = record.entry else { throw Failure("Missing saved entry") }
		return entry
	}
	private static func onlyEntry(_ entries: [JournalEntry]) throws -> JournalEntry {
		guard entries.count == 1 else { throw Failure("Expected exactly one durable entry") }
		return entries[0]
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-occurrence-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
}
#endif
