#if DEBUG
import Foundation

@MainActor
enum ReminderExactTargetContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-exact-target-contract-tests") else { return }
		do {
			try await unavailableChecks()
			try await exactChecks()
			try await semanticAdmissionChecks()
			try await constraintChecks()
			print("REMINDER EXACT TARGET CONTRACT: complete ordered names, normalization, alternatives, explicit alias, deceptive prefixes, semantic admission, and validity/time guards passed")
			fflush(stdout)
		} catch { fatalError("REMINDER EXACT TARGET CONTRACT: \(error)") }
	}

	private static let now = Date(timeIntervalSince1970: 1_900_000_000)

	private static func unavailableChecks() async throws {
		let cases = [
			("client consultation", "Client construction"),
			("team planning", "Team planetarium"),
			("project review", "Projection review"),
			("client review", "Clientele review"),
			("client consultation", "Client consultations"),
			("client consultation", "Consultation client"),
			("client consultation", "Client quarterly consultation"),
			("client consultation", "Client of consultation"),
			("meeting", "Meeting"),
			("gaming meetup", "Gaming meetup"),
			("client client", "Client client"),
			("Clock Tower Cafe", "Clocktower Cafe")
		]
		for (target, title) in cases {
			let probe = Probe(matches: true)
			let result = await resolve(target, titles: [title], available: false, probe: probe)
			let calls = await probe.prompts.count
			try expect(result.occurrences.isEmpty && calls == 0,
				"Without semantic inference, '\(target)' must not accept '\(title)' as an exact name")
		}
	}

	private static func exactChecks() async throws {
		let cases = [
			("client consultation", "Client Consultation"),
			("client consultation", "Moved: Client Consultation — Room 2"),
			("CAFÉ client consultation", "Cafe—CLIENT   CONSULTATION"),
			("cafe\u{301} client consultation", "CAFÉ CLIENT CONSULTATION"),
			("the client consultation event", "Client Consultation"),
			("Ultimate Werewolf game", "Ultimate Werewolf"),
			("Blood on the Clock Tower event", "Blood on the Clocktower"),
			("Blood on the Clocktower", "Social: Blood on the Clock Tower")
		]
		for (target, title) in cases {
			let probe = Probe(matches: false)
			let result = await resolve(target, titles: [title], available: true, probe: probe)
			let calls = await probe.prompts.count
			try expect(result.outcome.isComplete && result.occurrences.map(\.event.title) == [title] && calls == 0,
				"The full normalized name '\(target)' in '\(title)' must match without semantic inference")
		}
		let alternatives = Probe(matches: false)
		let result = await resolve("Ultimate Werewolf or Blood on the Clocktower game",
			titles: ["Ultimate Werewolf", "Blood on the Clock Tower"], available: false, probe: alternatives)
		let alternativeCalls = await alternatives.prompts.count
		try expect(Set(result.occurrences.map(\.event.title)) == ["Ultimate Werewolf", "Blood on the Clock Tower"]
			&& alternativeCalls == 0, "Each explicitly named alternative must be accepted independently")
	}

	private static func semanticAdmissionChecks() async throws {
		let negative = Probe(matches: false)
		let rejected = await resolve("client consultation", titles: ["Client construction"], available: true, probe: negative)
		let negativePrompts = await negative.prompts
		try expect(rejected.outcome.isComplete && rejected.occurrences.isEmpty && negativePrompts.count == 1
			&& negativePrompts[0].contains("Selector: client consultation") && negativePrompts[0].contains("Title: Client construction"),
			"An approximate lexical anchor must reach the classifier and obey its rejection, never bypass it as exact")
		let positive = Probe(matches: true)
		let accepted = await resolve("improv class", titles: ["Improvisation workshop"], available: true, probe: positive)
		let positiveCalls = await positive.prompts.count
		try expect(accepted.occurrences.map(\.event.title) == ["Improvisation workshop"] && positiveCalls == 1,
			"Improv/improvisation must retain approximate admission and be accepted only through a classifier decision")
		let unavailable = await resolve("improv class", titles: ["Improvisation workshop"], available: false, probe: Probe(matches: true))
		try expect(unavailable.occurrences.isEmpty && unavailable.outcome == .unavailable,
			"A semantic synonym remains unknown while its classifier is unavailable")
	}

	private static func constraintChecks() async throws {
		let exact = event("Client consultation", offset: 3_600)
		var reminder = rule("client consultation")
		reminder.expiresAt = exact.startDate.addingTimeInterval(-1)
		let expiryProbe = Probe(matches: true)
		let expired = await resolve(reminder, events: [exact], available: true, probe: expiryProbe)
		let expiryCalls = await expiryProbe.prompts.count
		try expect(expired.occurrences.isEmpty && expiryCalls == 0, "An exact name must not bypass occurrence expiration")
		reminder = rule("client consultation", time: .morning)
		var evening = exact
		let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
		evening.startDate = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: tomorrow)!
		evening.endDate = evening.startDate.addingTimeInterval(1_800)
		let timeProbe = Probe(matches: true)
		let wrongTime = await resolve(reminder, events: [evening], available: true, probe: timeProbe)
		let timeCalls = await timeProbe.prompts.count
		try expect(wrongTime.occurrences.isEmpty && timeCalls == 0, "An exact name must not bypass its morning-only constraint")
	}

	private static func resolve(_ target: String, titles: [String], available: Bool, probe: Probe) async -> ReminderResolutionResult {
		await resolve(rule(target), events: titles.enumerated().map { event($0.element, offset: Double($0.offset + 1) * 3_600) },
			available: available, probe: probe)
	}
	private static func resolve(_ reminder: EventReminderRule, events: [JournalCalendarEvent], available: Bool, probe: Probe) async -> ReminderResolutionResult {
		let entry = JournalEntry(createdAt: now, duration: 30, transcript: "Bring notes", headline: "Exact target fixture", reminders: [reminder])
		return await ReminderEngine.resolve(entries: [entry], events: events, now: now, modelIsAvailable: { available }, services: services(probe))
	}
	private static func rule(_ target: String, time: EventReminderTimeBucket = .any) -> EventReminderRule {
		EventReminderRule(text: "Bring notes", motivation: "Prepare", evidence: "Bring notes",
			selector: .fuzzy(.init(semanticDescription: target, timeBucket: time, locationDescription: nil, examples: [])),
			occurrencePolicy: .everyMatch, createdAt: now.addingTimeInterval(-60))
	}
	private static func event(_ title: String, offset: TimeInterval) -> JournalCalendarEvent {
		let start = now.addingTimeInterval(offset)
		return JournalCalendarEvent(id: title, calendarIdentifier: "exact-calendar", calendarTitle: "Exact targets", title: title,
			startDate: start, endDate: start.addingTimeInterval(1_800), isAllDay: false)
	}
	private static func services(_ probe: Probe) -> ReminderModelServices {
		ReminderModelServices(budget: { _, _, _ in
			try ModelContextBudget(contextSize: 20_000, instructionTokens: 0, schemaTokens: 0, outputTokens: 500, safetyTokens: 0, count: { $0.utf8.count })
		}, drafts: { _, _, _ in throw Failure("Resolution must not extract reminders") },
		schedule: { _, _, _ in throw Failure("Resolution must not regenerate schedules") },
		match: { _, prompt, _ in await probe.classify(prompt) })
	}
	private actor Probe {
		let matches: Bool
		var prompts: [String] = []
		init(matches: Bool) { self.matches = matches }
		func classify(_ prompt: String) -> GeneratedEventMatch {
			prompts.append(prompt)
			return GeneratedEventMatch(matches: matches, reason: "Controlled semantic decision")
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
