#if DEBUG
import Foundation

@MainActor
enum ReminderValidityContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-validity-contract-tests") else { return }
		do {
			try await boundaryChecks()
			try await pinnedChecks()
			try await fuzzyChecks()
			print("REMINDER VALIDITY CONTRACT: inclusive expiry, creation/end boundaries, ongoing and indefinite rules, pinned no-retarget, pre-inference filtering, and historical examples passed")
			fflush(stdout)
		} catch { fatalError("REMINDER VALIDITY CONTRACT: \(error)") }
	}

	private static let now = Date(timeIntervalSince1970: 1_900_000_000)
	private static let expiry = now.addingTimeInterval(3_600)

	private static func boundaryChecks() async throws {
		let within = event("Within", start: 600), boundary = event("Boundary", start: 3_600)
		let beyond = event("Beyond", start: 3_601)
		let ongoing = event("Ongoing", start: -300, end: 300)
		let ended = event("Ended", start: -400, end: -1)
		let endBoundary = event("End boundary", start: -200, end: 0)
		let atCreation = event("Creation boundary", start: -600, end: 300)
		let next = await resolve(rule(.nextMatch), events: [beyond, boundary])
		try expect(next.occurrences.map(\.event.id) == [boundary.id]
			&& next.resolvedOccurrencesByReminderID.values.map(\.id) == [boundary.id],
			"A next occurrence beginning exactly at expiration must be eligible; one second later must not be pinned")
		let every = await resolve(rule(.everyMatch), events: [beyond, ended, atCreation, boundary, ongoing, within, endBoundary])
		try expect(Set(every.occurrences.map(\.event.id)) == Set([ongoing.id, within.id, boundary.id, endBoundary.id]),
			"Every-match must share inclusive expiry/end and strict creation boundaries while retaining ongoing events")
		var atExpiry = rule(.nextMatch)
		atExpiry.expiresAt = now
		let startingNow = event("Starts now", start: 0)
		let exactNow = await resolve(atExpiry, events: [startingNow])
		let expiredNow = await resolve(atExpiry, events: [startingNow], at: now.addingTimeInterval(1))
		try expect(exactNow.occurrences.count == 1 && expiredNow.occurrences.isEmpty,
			"The existing rule-active boundary must remain inclusive, then expire even during an ongoing event")
		var indefinite = rule(.everyMatch)
		indefinite.expiresAt = nil
		let distant = event("Distant", start: 365 * 86_400)
		try expect(await resolve(indefinite, events: [distant]).occurrences.map(\.event.id) == [distant.id],
			"An absent expiration must not impose a hidden future cutoff")
	}

	private static func pinnedChecks() async throws {
		let boundary = event("Pinned", start: 3_600)
		let alternative = event("Alternative", start: 600)
		var pinned = rule(.nextMatch)
		pinned.resolvedOccurrence = boundary
		let accepted = await resolve(pinned, events: [alternative, boundary])
		try expect(accepted.occurrences.map(\.event.id) == [boundary.id], "An exact pin at the expiry boundary must remain selected")
		let outside = event("Outside pin", start: 3_601)
		pinned.resolvedOccurrence = outside
		let rejected = await resolve(pinned, events: [outside, alternative])
		try expect(rejected.occurrences.isEmpty && rejected.resolvedOccurrencesByReminderID[pinned.id] == outside
			&& rejected.consumedAtByReminderID[pinned.id] == nil,
			"An exact current pin outside validity must remain pinned without delivery, consumption, or substitution")
		pinned.resolvedOccurrence = boundary
		var moved = boundary
		moved.startDate = expiry.addingTimeInterval(1)
		moved.endDate = moved.startDate.addingTimeInterval(1_800)
		let missingExact = await resolve(pinned, events: [moved, alternative])
		try expect(missingExact.occurrences.isEmpty && missingExact.resolvedOccurrencesByReminderID[pinned.id] == nil
			&& missingExact.consumedAtByReminderID[pinned.id] == nil,
			"A changed start outside validity must not make an unproved occurrence identity retarget to another event")
		pinned.resolvedOccurrence = event("Before creation", start: -601, end: 300)
		let tooEarly = await resolve(pinned, events: [pinned.resolvedOccurrence!, alternative])
		try expect(tooEarly.occurrences.isEmpty, "Pinned occurrences must also satisfy the reminder creation boundary")
	}

	private static func fuzzyChecks() async throws {
		var fuzzy = rule(.everyMatch)
		fuzzy.selector = .fuzzy(.init(semanticDescription: "client consultation", timeBucket: .any, locationDescription: nil, examples: []))
		let historical = event("Client consultation", start: -7_200, end: -3_600)
		let upcoming = event("Upcoming discussion", start: 600)
		let boundary = event("Boundary discussion", start: 3_600)
		let outside = event("Excluded future discussion", start: 3_601)
		let probe = Probe()
		let result = await resolve(fuzzy, events: [outside, historical, boundary, upcoming], services: services(probe))
		let prompts = await probe.prompts
		try expect(result.outcome.isComplete && Set(result.occurrences.map(\.event.id)) == [upcoming.id, boundary.id],
			"Fuzzy decisions must materialize only occurrences within the same validity window")
		try expect(prompts.count == 2 && !prompts.contains(where: { $0.contains("Title: " + historical.title) })
			&& !prompts.contains(where: { $0.contains(outside.title) }),
			"Only eligible occurrences require native classification; historical deterministic examples remain available")
		let examples = result.examplesByReminderID[fuzzy.id, default: []]
		try expect(examples.contains(where: { $0.event.id == historical.id && $0.matches })
			&& !examples.contains(where: { $0.event.id == outside.id }),
			"Historical completed or deterministic examples must remain visible and filtered future events must not become false-negative examples")
		let excludedProbe = Probe()
		let excluded = await resolve(fuzzy, events: [outside], services: services(excludedProbe))
		let excludedCalls = await excludedProbe.prompts.count
		try expect(excludedCalls == 0 && excluded.outcome.isComplete && excluded.occurrences.isEmpty,
			"A solely out-of-window future candidate must never invoke native inference")
		fuzzy.expiresAt = now.addingTimeInterval(-1)
		let expiredProbe = Probe()
		let expired = await resolve(fuzzy, events: [upcoming], services: services(expiredProbe))
		let expiredCalls = await expiredProbe.prompts.count
		try expect(expired.occurrences.isEmpty && expiredCalls == 0, "Expired rules must remain inactive without native work")
	}

	private static func resolve(_ rule: EventReminderRule, events: [JournalCalendarEvent], at date: Date = now,
		services: ReminderModelServices = .live) async -> ReminderResolutionResult {
		let entry = JournalEntry(createdAt: rule.createdAt, duration: 30, transcript: "Bring notes", headline: "Validity fixture", reminders: [rule])
		return await ReminderEngine.resolve(entries: [entry], events: events, now: date, modelIsAvailable: { true }, services: services)
	}
	private static func rule(_ policy: EventReminderOccurrencePolicy) -> EventReminderRule {
		EventReminderRule(text: "Bring notes", motivation: "Prepare", evidence: "Bring notes",
			selector: .series(EventSeriesReference(event: event("Source", start: -3_600))), occurrencePolicy: policy,
			createdAt: now.addingTimeInterval(-600), expiresAt: expiry)
	}
	private static func event(_ id: String, start: TimeInterval, end: TimeInterval? = nil) -> JournalCalendarEvent {
		JournalCalendarEvent(id: id, externalIdentifier: "validity-series", calendarIdentifier: "validity-calendar", calendarTitle: "Validity",
			title: id, startDate: now.addingTimeInterval(start), endDate: now.addingTimeInterval(end ?? start + 1_800),
			isAllDay: false, notes: "Client consultation preparation", isRecurring: true)
	}
	private static func services(_ probe: Probe) -> ReminderModelServices {
		ReminderModelServices(budget: { _, _, _ in
			try ModelContextBudget(contextSize: 20_000, instructionTokens: 0, schemaTokens: 0, outputTokens: 500, safetyTokens: 0, count: { $0.utf8.count })
		}, drafts: { _, _, _ in throw Failure("Resolution must not extract reminders") },
		schedule: { _, _, _ in throw Failure("Resolution must not regenerate schedules") },
		match: { _, prompt, _ in
			await probe.record(prompt)
			return GeneratedEventMatch(matches: true, reason: "Controlled semantic match")
		})
	}
	private actor Probe {
		var prompts: [String] = []
		func record(_ prompt: String) { prompts.append(prompt) }
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
