#if DEBUG
import Foundation

@MainActor
enum CalendarNavigationContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-calendar-navigation-contract-tests") else { return }
		do {
			try await navigation()
			try selection()
			print("CALENDAR NAVIGATION CONTRACT: exact current provider routing, recurring native detail, failed and obsolete opens, and same-ID occurrence selection passed")
			fflush(stdout)
		} catch { fatalError("CALENDAR NAVIGATION CONTRACT: \(error)") }
	}

	private static func navigation() async throws {
		var stored = event(hour: 9)
		stored.isRecurring = false
		stored.occurrenceDate = nil
		stored.providerURL = URL(string: "https://calendar.google.com/calendar/event?eid=cached")!
		var current = stored
		let freshURL = URL(string: "https://calendar.google.com/calendar/event?eid=current")!
		current.providerURL = freshURL
		var opened: [URL] = []
		let success = await CalendarEventNavigation.destination(stored: stored, resolved: current, preferredApp: .google,
			openURL: { opened.append($0); return true }, isCurrent: { true })
		try expect(success == .provider && opened == [freshURL], "Only the current resolved event may provide a preferred provider URL")
		let missing = await CalendarEventNavigation.destination(stored: stored, resolved: nil, preferredApp: .google,
			openURL: { opened.append($0); return true }, isCurrent: { true })
		var wrong = current
		wrong.calendarIdentifier = "other-account"
		let wrongCalendar = await CalendarEventNavigation.destination(stored: stored, resolved: wrong, preferredApp: .google,
			openURL: { opened.append($0); return true }, isCurrent: { true })
		try expect(missing == .unavailable && wrongCalendar == .unavailable && opened.count == 1,
			"Cached provider URLs cannot bypass missing or wrong-calendar occurrence resolution")
		let failure = await CalendarEventNavigation.destination(stored: stored, resolved: current, preferredApp: .google,
			openURL: { _ in false }, isCurrent: { true })
		try expect(failure == .native, "A failed provider opening must fall back to the already proven native event")
		var noURL = current
		noURL.providerURL = nil
		let noLink = await CalendarEventNavigation.destination(stored: stored, resolved: noURL, preferredApp: .google,
			openURL: { _ in throwFailure(); return true }, isCurrent: { true })
		let apple = await CalendarEventNavigation.destination(stored: stored, resolved: current, preferredApp: .apple,
			openURL: { _ in throwFailure(); return true }, isCurrent: { true })
		try expect(noLink == .native && apple == .native, "No current provider link and native preference both select exact native details")
		let recurring = event(hour: 9)
		let recurrence = await CalendarEventNavigation.destination(stored: recurring, resolved: recurring, preferredApp: .google,
			openURL: { _ in throwFailure(); return true }, isCurrent: { true })
		try expect(recurrence == .native, "An attached recurring URL does not prove an instance destination and must use exact native details")
		var ownsPresentation = true
		let gate = OpenGate()
		let delayed = Task {
			await CalendarEventNavigation.destination(stored: stored, resolved: current, preferredApp: .google,
				openURL: { _ in await gate.hold() }, isCurrent: { ownsPresentation })
		}
		while gate.continuation == nil { await Task.yield() }
		ownsPresentation = false
		gate.continuation?.resume(returning: false)
		let result = await delayed.value
		try expect(result == .superseded, "A late provider failure after leaving or changing a note cannot present obsolete native details")
	}

	private static func selection() throws {
		let first = event(hour: 9), second = event(hour: 15)
		var otherCalendar = second
		otherCalendar.calendarIdentifier = "other-account"
		let values = [first, second, otherCalendar]
		try expect(Set(values.map(\.id)).count == 1 && Set(values.map(\.focusKey)).count == 3,
			"Setup must distinguish recurring instances and calendars despite identical native raw IDs")
		try expect(RecordingEventSelection.event(for: second.focusKey, in: values) == second,
			"Selecting the second occurrence must attach its current and original dates, not the first shared raw ID")
		let ongoing = RecordingEventSelection.closestKey(in: values.prefix(2).map { $0 }, at: second.startDate.addingTimeInterval(60))
		try expect(ongoing == second.focusKey, "The ongoing-event default must retain exact occurrence identity")
		var moved = second
		moved.startDate = second.startDate.addingTimeInterval(3_600)
		moved.endDate = second.endDate.addingTimeInterval(3_600)
		try expect(RecordingEventSelection.event(for: second.focusKey, in: [first, moved]) == moved,
			"A selected occurrence keeps its selection when its current time moves with a proven original date")
		var duplicate = second
		duplicate.localIdentifier = "independent-copy"
		try expect(RecordingEventSelection.event(for: second.focusKey, in: [second, duplicate]) == nil
			&& RecordingEventSelection.closestKey(in: [second, duplicate], at: second.startDate) == nil
			&& RecordingEventSelection.rows(in: [first, second, duplicate]).count == 2,
			"Ambiguous identities must render once, cannot be selected by default, and cannot silently attach the first candidate")
		try expect(RecordingEventSelection.event(for: second.focusKey, in: [second, second]) == second,
			"Repeated identical query snapshots must not make an otherwise exact selection unavailable")
	}

	private static func event(hour: Int) -> JournalCalendarEvent {
		let start = Date(timeIntervalSince1970: 1_900_000_000 + Double(hour * 3_600))
		return JournalCalendarEvent(id: "series", localIdentifier: "local-series", externalIdentifier: "external-series",
			providerURL: URL(string: "https://calendar.google.com/calendar/event?eid=series"), calendarIdentifier: "work",
			calendarTitle: "Work", title: "Project check-in", startDate: start, endDate: start.addingTimeInterval(3_600),
			isAllDay: false, isRecurring: true, occurrenceDate: start)
	}
	private static func throwFailure() { fatalError("Unexpected provider opening") }
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
	private struct Failure: Error { var message: String }
	@MainActor
	private final class OpenGate {
		var continuation: CheckedContinuation<Bool, Never>?
		func hold() async -> Bool { await withCheckedContinuation { continuation = $0 } }
	}
}
#endif
