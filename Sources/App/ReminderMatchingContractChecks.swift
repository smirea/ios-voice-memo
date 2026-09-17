#if DEBUG
import Foundation

@MainActor
enum ReminderMatchingContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-matching-contract-tests") else { return }
		do {
			try await completedCache()
			try await changedInputs()
			try await uncertaintyOrder()
			try await failureAndCancellation()
			try await pruneAndBound()
			print("REMINDER MATCHING CONTRACT: completed yes/no cache, exact input invalidation, bounded pruning, canceled/error exclusion, and ordered delivery uncertainty passed")
			fflush(nil)
		} catch { fatalError("REMINDER MATCHING CONTRACT: \(error)") }
	}

	private static let now = Date(timeIntervalSince1970: 2_000_000_000)
	private static func event(_ id: String = "candidate", offset: TimeInterval = 3_600, title: String = "Planning with clients") -> JournalCalendarEvent {
		JournalCalendarEvent(id: id, calendarIdentifier: "work", calendarTitle: "Work", title: title,
			startDate: now.addingTimeInterval(offset), endDate: now.addingTimeInterval(offset + 1_800),
			isAllDay: false, location: "Office", notes: "Discuss the client plan")
	}
	private static func entry(policy: EventReminderOccurrencePolicy = .everyMatch) -> JournalEntry {
		let reminder = EventReminderRule(text: "Bring notes", motivation: "Prepare", evidence: "Bring notes",
			selector: .fuzzy(.init(semanticDescription: "client planning", timeBucket: .any, examples: [])),
			occurrencePolicy: policy, createdAt: now.addingTimeInterval(-60))
		return JournalEntry(createdAt: now, duration: 15, transcript: "Bring notes", headline: "Plan", reminders: [reminder])
	}
	private static func resolve(_ entry: JournalEntry, _ events: [JournalCalendarEvent], _ probe: Probe,
		cache: ReminderMatchCache? = nil, available: Bool = true, context: ReminderMatchContext = .init()) async -> ReminderResolutionResult {
		await ReminderEngine.resolve(entries: [entry], events: events, now: now, modelIsAvailable: { available },
			services: services(probe), cache: cache, matchingContext: context)
	}
	private static func services(_ probe: Probe) -> ReminderModelServices {
		ReminderModelServices(budget: { _, _, _ in
			await probe.tokenized()
			return try ModelContextBudget(contextSize: 20_000, instructionTokens: 0, schemaTokens: 0,
				outputTokens: 256, safetyTokens: 0, count: { $0.utf8.count })
		}, drafts: { _, _, _ in throw Failure("Unexpected extraction") }, schedule: { _, _, _ in throw Failure("Unexpected scheduling") },
			match: { _, prompt, _ in try await probe.match(prompt) })
	}

	private static func completedCache() async throws {
		for matches in [true, false] {
			let probe = Probe(matches: matches), cache = ReminderMatchCache(), candidate = event()
			var source = entry()
			let first = await resolve(source, [candidate], probe, cache: cache)
			try expect(first.outcome.isComplete && first.occurrences.count == (matches ? 1 : 0), "Controlled completed decision must be used")
			if case var .fuzzy(selector) = source.reminders[0].selector {
				selector.examples = [.init(event: candidate, matches: matches, reason: "Derived output")]
				source.reminders[0].selector = .fuzzy(selector)
			}
			source.reminders[0].id = UUID(); source.reminders[0].text = "Bring different notes"
			let second = await resolve(source, [candidate], probe, cache: cache, available: false)
			let counts = await probe.counts
			try expect(second.outcome.isComplete && second.occurrences.count == first.occurrences.count && counts == [1, 1],
				"Completed yes/no must survive unavailable inference and derived examples/presentation edits without tokenization")
		}
	}

	private static func changedInputs() async throws {
		for field in ["title", "notes", "location", "start", "end", "calendar", "calendarTitle", "nativeID", "originalDate", "allDay", "recurrence",
			"selector", "selectorLocation", "locale", "timeZone", "calendarEnvironment", "version", "model"] {
			let probe = Probe(), cache = ReminderMatchCache()
			var source = entry(), candidate = event(), context = ReminderMatchContext()
			_ = await resolve(source, [candidate], probe, cache: cache)
			switch field {
			case "title": candidate.title += " follow-up"
			case "notes": candidate.notes = "Changed agenda"
			case "location": candidate.location = "Office room2"
			case "start": candidate.startDate.addTimeInterval(1)
			case "end": candidate.endDate.addTimeInterval(1)
			case "calendar": candidate.calendarIdentifier = "another-work-calendar"
			case "calendarTitle": candidate.calendarTitle = "Updated calendar"
			case "nativeID": candidate.id = "changed-native-item"
			case "originalDate": candidate.occurrenceDate = candidate.startDate
			case "allDay": candidate.isAllDay = true
			case "recurrence": candidate.isRecurring = true
			case "selector", "selectorLocation":
				if case var .fuzzy(selector) = source.reminders[0].selector {
					if field == "selector" { selector.semanticDescription += " review" }
					else { selector.locationDescription = "Office" }
					source.reminders[0].selector = .fuzzy(selector)
				}
			case "locale": context.locale = "fr_FR"
			case "timeZone": context.timeZone = "Pacific/Auckland"
			case "calendarEnvironment": context.calendar = "buddhist"
			case "version": context.version += "-next"
			default: context.model += "-next"
			}
			let changed = await resolve(source, [candidate], probe, cache: cache, context: context)
			let counts = await probe.counts
			try expect(changed.outcome.isComplete && counts == [2, 2], "Changing \(field) must invalidate the exact completed inference input")
		}
	}

	private static func uncertaintyOrder() async throws {
		let source = entry(policy: .nextMatch)
		let exact = event("exact", offset: 7_200, title: "Client planning")
		let historical = event("historical", offset: -86_400)
		let later = event("later", offset: 86_400)
		let probe = Probe(fails: true)
		let safe = await resolve(source, [historical, exact, later], probe)
		let safeCalls = await probe.calls
		try expect(safe.outcome.isComplete && safe.occurrences.map(\.event) == [exact] && safeCalls == 0,
			"Historical unknowns and an unneeded later candidate must not delay or suppress a proven next occurrence")
		let earlier = event("earlier", offset: 3_600)
		let blocked = await resolve(source, [earlier, exact], probe)
		try expect(!blocked.outcome.isComplete && blocked.occurrences.isEmpty && blocked.resolvedOccurrencesByReminderID.isEmpty,
			"An earlier failed eligible classification must prevent skipping to a later proven match")
		let every = await resolve(entry(), [historical, earlier, exact], probe)
		try expect(!every.outcome.isComplete && every.occurrences.map(\.event) == [exact],
			"Every-match must preserve independent proven eligible matches when another remains unknown")
		var pinned = source
		pinned.reminders[0].resolvedOccurrence = earlier
		let missing = await resolve(pinned, [exact], probe)
		try expect(missing.occurrences.isEmpty, "A missing consumed-or-pinned rule must not use matching cache to retarget")
	}

	private static func failureAndCancellation() async throws {
		let source = entry(), candidate = event(), cache = ReminderMatchCache(), probe = Probe(fails: true)
		_ = await resolve(source, [candidate], probe, cache: cache)
		try expect(await cache.count == 0, "Failed inference must not become a cached false")
		await probe.setFailure(false)
		_ = await resolve(source, [candidate], probe, cache: cache)
		let retryCalls = await probe.calls, retryCount = await cache.count
		try expect(retryCalls == 2 && retryCount == 1, "A later pass must retry an uncached execution failure")
		let held = Probe(held: true), canceledCache = ReminderMatchCache()
		let task = Task { await resolve(source, [candidate], held, cache: canceledCache) }
		try await wait { await held.calls == 1 }
		task.cancel()
		let canceled = await task.value
		let canceledCount = await canceledCache.count
		try expect(canceled.outcome == .cancelled && canceledCount == 0,
			"Cancellation must return promptly without caching an uncooperative late response")
		await canceledCache.retain(entries: [], events: [], now: now, context: .init())
		await held.release()
		try await wait { await held.finished }
		try expect(await canceledCache.count == 0, "A late response must not refill pruned obsolete cache scope")
	}

	private static func pruneAndBound() async throws {
		let source = entry(), cache = ReminderMatchCache(capacity: 9_999)
		guard case let .fuzzy(selector) = source.reminders[0].selector else { throw Failure("Missing selector") }
		let candidates = (0..<520).map { event("bounded-\($0)", offset: Double($0 + 1) * 3_600) }
		let context = ReminderMatchContext()
		await cache.retain(entries: [source], events: candidates, now: now, context: context)
		for candidate in candidates {
			await cache.insert(.init(matches: true, reason: "Completed fixture"), for: .init(selector: selector, event: candidate, context: context))
		}
		try expect(await cache.count == 512, "Completed cross-product cache must remain bounded at512 even with a larger requested capacity")
		await cache.retain(entries: [source], events: [candidates.last!], now: now, context: context)
		try expect(await cache.count == 1, "Events leaving the retained calendar horizon must be pruned")
		let canceledRetain = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			await cache.retain(entries: [], events: [], now: now, context: context)
		}
		await canceledRetain.value
		try expect(await cache.count == 1, "A canceled old retain must not replace a newer allowed cache horizon")
		await cache.retain(entries: [], events: candidates, now: now, context: context)
		try expect(await cache.count == 0, "Removed selectors must release their completed decisions")
		await cache.insert(.init(matches: true, reason: "Obsolete"), for: .init(selector: selector, event: candidates[0], context: context))
		try expect(await cache.count == 0, "A pruned source cannot be reinserted by stale work")
	}

	private actor Probe {
		let matches: Bool
		var fails: Bool
		var held: Bool
		var calls = 0
		var tokens = 0
		var finished = false
		var continuation: CheckedContinuation<Void, Never>?
		init(matches: Bool = true, fails: Bool = false, held: Bool = false) { self.matches = matches; self.fails = fails; self.held = held }
		var counts: [Int] { [calls, tokens] }
		func tokenized() { tokens += 1 }
		func setFailure(_ value: Bool) { fails = value }
		func match(_ prompt: String) async throws -> GeneratedEventMatch {
			calls += 1
			if held { await withCheckedContinuation { continuation = $0 } }
			finished = true
			if fails { throw ModelProcessingError.invalidOutput }
			return .init(matches: matches, reason: "Controlled complete decision")
		}
		func release() { held = false; continuation?.resume(); continuation = nil }
	}
	private static func wait(_ condition: @MainActor () async -> Bool) async throws {
		for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
		throw Failure("Timed out waiting for controlled matching")
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible { let description: String; init(_ message: String) { description = message } }
}
#endif
