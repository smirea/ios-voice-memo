#if DEBUG
import Foundation

@MainActor
enum ReminderActivityContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-activity-contract-tests") else { return }
		do {
			try await staleGeneration()
			try await replacedEndAll()
			try await replacedUpdate(sameGeneration: false)
			try await replacedUpdate(sameGeneration: true)
			try await invalidatedPredicate()
			try await cancelledBatch(replacementPending: false)
			try await cancelledBatch(replacementPending: true)
			print("REMINDER ACTIVITY CONTRACT: serialized effects, stale generations, latest submissions, delayed updates, predicate invalidation, and cancellation passed")
			fflush(stdout)
		} catch {
			fatalError("REMINDER ACTIVITY CONTRACT: \(error)")
		}
	}

	private static let now = Date(timeIntervalSince1970: 2_000_000_000)

	private static func staleGeneration() async throws {
		let backend = Backend(seed: occurrence("existing"))
		let manager = ReminderActivityManager(operations: backend.operations)
		let gate = backend.holdNextOperation()
		let old = synchronize(manager, [occurrence("removed")], generation: 1)
		try await wait { gate.isWaiting }
		manager.invalidate(generation: 2)
		gate.release()
		await old.value
		await manager.synchronize(occurrences: [occurrence("removed")], settings: .init(), now: now, generation: 1)
		try expect(backend.items.isEmpty && backend.requestedKeys.isEmpty, "An invalidated generation must not recreate a removed reminder after an end completes")
		try backend.verifySerialized()
	}

	private static func replacedEndAll() async throws {
		let backend = Backend(seed: occurrence("old"))
		let manager = ReminderActivityManager(operations: backend.operations)
		let gate = backend.holdNextOperation()
		let old = Task { _ = await manager.endAll(generation: 1) }
		try await wait { gate.isWaiting }
		let desired = occurrence("new")
		let latest = synchronize(manager, [desired], generation: 2)
		try await wait { backend.submissions == 1 }
		try expect(backend.requestedKeys.isEmpty, "A replacement request must wait for the previous end to finish")
		gate.release()
		await old.value
		await latest.value
		try expect(backend.items.values.map(\.attributes.eventKey) == [desired.eventKey], "An old endAll must leave the latest desired activity alive")
		try expect(backend.events == ["end:start", "end:finish", "request"], "Ending the old snapshot must finish before requesting the new activity")
		try backend.verifySerialized()
	}

	private static func replacedUpdate(sameGeneration: Bool) async throws {
		let primary = occurrence("shared", text: "Primary")
		var original = occurrence("shared", text: "original")
		original.reminder.createdAt.addTimeInterval(-1)
		let backend = Backend(seeds: [primary, original])
		let manager = ReminderActivityManager(operations: backend.operations)
		let gate = backend.holdNextOperation()
		var obsolete = original
		obsolete.reminder.text = "obsolete"
		let old = synchronize(manager, [primary, obsolete, occurrence("obsolete-extra", offset: 7_200)], generation: 1)
		try await wait { gate.isWaiting }
		var desired = original
		desired.reminder.text = "latest"
		let latest = synchronize(manager, [primary, desired], generation: sameGeneration ? 1 : 2)
		try await wait { backend.submissions == 2 }
		gate.release()
		await old.value
		await latest.value
		try expect(backend.items.values.first?.state.reminderTexts == ["Primary", "latest"], "A delayed update must be followed by the latest content, including within one generation")
		try expect(backend.updatedTexts == ["Primary", "obsolete", "Primary", "latest"] && backend.requestedKeys.isEmpty, "Superseded work must stop before requesting additional activities")
		try backend.verifySerialized()
	}

	private static func invalidatedPredicate() async throws {
		let backend = Backend(seed: occurrence("old"))
		let manager = ReminderActivityManager(operations: backend.operations)
		let gate = backend.holdNextOperation()
		var current = true
		let old = Task {
			_ = await manager.synchronize(occurrences: [occurrence("removed")], settings: .init(), now: now,
				generation: 1, isCurrent: { current })
		}
		try await wait { gate.isWaiting }
		current = false
		gate.release()
		await old.value
		try expect(backend.items.isEmpty && backend.requestedKeys.isEmpty, "An invalidated owner must not request more activities after an awaited operation")
		let desired = occurrence("replacement")
		await manager.synchronize(occurrences: [desired], settings: .init(), now: now, generation: 2)
		try expect(backend.requestedKeys == [desired.eventKey], "Invalidating an owner must not strand later synchronization")
		try backend.verifySerialized()
	}

	private static func cancelledBatch(replacementPending: Bool) async throws {
		let backend = Backend(seed: occurrence("old"))
		let manager = ReminderActivityManager(operations: backend.operations)
		let gate = backend.holdNextOperation()
		let old = synchronize(manager, [occurrence("cancelled")], generation: 1)
		try await wait { gate.isWaiting }
		old.cancel()
		let desired = occurrence("current")
		let latest = replacementPending ? synchronize(manager, [desired], generation: 2) : nil
		if replacementPending { try await wait { backend.submissions == 2 } }
		gate.release()
		await old.value
		if let latest { await latest.value }
		else {
			try expect(backend.requestedKeys.isEmpty, "Cancellation alone must stop the batch even without a newer generation")
			await manager.synchronize(occurrences: [desired], settings: .init(), now: now, generation: 2)
		}
		try expect(backend.requestedKeys == [desired.eventKey], "Cancelling a held batch must stop its remaining effects without cancelling the current desired state")
		try expect(backend.items.values.map(\.attributes.eventKey) == [desired.eventKey], "The writer must finish the latest batch after a caller cancels")
		try backend.verifySerialized()
	}

	private static func synchronize(_ manager: ReminderActivityManager, _ occurrences: [EventReminderOccurrence], generation: Int) -> Task<Void, Never> {
		Task { _ = await manager.synchronize(occurrences: occurrences, settings: .init(), now: now, generation: generation) }
	}

	private static func occurrence(_ name: String, text: String = "Reminder", offset: TimeInterval = 3_600) -> EventReminderOccurrence {
		let event = JournalCalendarEvent(id: name, calendarIdentifier: "calendar", calendarTitle: "Calendar", title: name,
			startDate: now.addingTimeInterval(offset), endDate: now.addingTimeInterval(offset + 1_800), isAllDay: false)
		let reminder = EventReminderRule(text: text, motivation: "Test", evidence: "Test", selector: .series(.init(event: event)),
			occurrencePolicy: .nextMatch, createdAt: now)
		return EventReminderOccurrence(sourceEntryID: UUID(), reminder: reminder, event: event)
	}

	private static func wait(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure(message: "Timed out waiting for a reminder operation") }
			await Task.yield()
		}
	}

	private static func expect(_ condition: Bool, _ message: String) throws {
		if !condition { throw Failure(message: message) }
	}

	private struct Failure: Error, CustomStringConvertible {
		var message: String
		var description: String { message }
	}

	@MainActor
	private final class Gate {
		var isWaiting = false
		var continuation: CheckedContinuation<Void, Never>?
		func wait() async {
			await withCheckedContinuation { continuation = $0; isWaiting = true }
		}
		func release() { continuation?.resume(); continuation = nil }
	}

	@MainActor
	private final class Backend {
		var items: [String: DesiredReminderActivity]
		var submissions = 0
		var requestedKeys: [String] = []
		var updatedTexts: [String] = []
		var events: [String] = []
		var nextGate: Gate?
		var activeOperations = 0
		var maximumOperations = 0

		convenience init(seed: EventReminderOccurrence) { self.init(seeds: [seed]) }

		init(seeds: [EventReminderOccurrence]) {
			items = ["seed": ReminderActivityManager.desiredActivities(from: seeds, defaultLeadMinutes: 60, now: now)[0]]
		}

		var operations: ReminderActivityOperations {
			ReminderActivityOperations(enabled: { self.submissions += 1; return true },
				existing: { self.items.map { .init(id: $0.key, attributes: $0.value.attributes, content: $0.value.state) } },
				end: { id in
					await self.begin("end")
					self.items[id] = nil
					self.finish("end")
				}, update: { id, item in
					await self.begin("update")
					if self.items[id] != nil { self.items[id] = item }
					self.updatedTexts.append(contentsOf: item.state.reminderTexts)
					self.finish("update")
				}, request: { item, _ in
					self.maximumOperations = max(self.maximumOperations, self.activeOperations + 1)
					self.requestedKeys.append(item.attributes.eventKey)
					let id = UUID().uuidString
					self.items[id] = item
					self.events.append("request")
					return id
				})
		}

		func holdNextOperation() -> Gate {
			let gate = Gate()
			nextGate = gate
			return gate
		}

		func begin(_ operation: String) async {
			activeOperations += 1
			maximumOperations = max(maximumOperations, activeOperations)
			events.append("\(operation):start")
			let gate = nextGate
			nextGate = nil
			await gate?.wait()
		}

		func finish(_ operation: String) {
			events.append("\(operation):finish")
			activeOperations -= 1
		}

		func verifySerialized() throws {
			try expect(maximumOperations == 1 && activeOperations == 0, "ActivityKit effects must never overlap, including requests while an update or end is suspended")
		}
	}
}
#endif
