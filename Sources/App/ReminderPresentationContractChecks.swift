#if DEBUG
import ActivityKit
import Foundation

@MainActor
enum ReminderPresentationContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-presentation-contract-tests") else { return }
		do {
			try await descriptorChanges()
			try await leadAndLimits()
			try await contributorOrderingAndCounts()
			try await earlyRetirement()
			try await captureSuspension()
			try await failuresAndNativeStates()
			try await restoredDescriptors()
			print("REMINDER PRESENTATION CONTRACT: descriptor replacement, lead normalization, bounded scheduling, contributor retirement, hidden counts, capture suspension, failures, and relaunch passed")
			fflush(stdout)
		} catch { fatalError("REMINDER PRESENTATION CONTRACT: \(error)") }
	}

	static func runNativeSmokeFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-activity-native-smoke") else { return }
		let scope = NativeScope()
		var passed = true
		for (name, check) in [("immediate", nativeImmediate), ("scheduled replacement", nativeScheduled)] {
			do {
				try await check(scope)
				nativeLog("\(name) passed")
			} catch {
				passed = false
				nativeLog("\(name) failed: \(String(reflecting: error))")
			}
			for id in scope.ownedIDs { await scope.operations.end(id) }
			do { try await wait { !scope.operations.existing().contains(where: \.isLive) } }
			catch { passed = false; nativeLog("cleanup failed: \(String(reflecting: error))") }
		}
		nativeLog(passed ? "API lifecycle passed; alert delivery was not measured" : "incomplete; see exact native results above")
	}

	static func runNativePreviewFromLaunchArguments() async {
		let arguments = ProcessInfo.processInfo.arguments
		let cleanup = arguments.contains("-reminder-activity-native-preview-cleanup")
		let index = arguments.firstIndex(of: "-reminder-activity-native-preview")
		guard cleanup || index != nil else { return }
		let prefix = "DEBUG-reminder-preview-ticket16"
		let live = ReminderActivityOperations.live
		let fixtures = live.existing().filter {
			$0.isLive && $0.attributes.eventKey.hasPrefix(prefix + "::") && $0.attributes.calendarIdentifier == prefix
		}
		for fixture in fixtures { await live.end(fixture.id) }
		previewLog("cleanup ended \(fixtures.count)")
		guard !cleanup else { return }
		guard let index, arguments.indices.contains(index + 1), let count = Int(arguments[index + 1]), (2...4).contains(count)
		else { previewLog("failure: expected a reminder count of 2, 3, or 4"); return }
		let date = Date.now
		let event = JournalCalendarEvent(id: prefix, calendarIdentifier: prefix, calendarTitle: "Preview",
			title: "Planning meeting", startDate: date.addingTimeInterval(60), endDate: date.addingTimeInterval(3_600), isAllDay: false)
		let texts = ["Review the project notes", "Confirm next week's plan", "Discuss the launch checklist", "Share the final decision"]
		let occurrences = (0..<count).map { offset in
			let sourceID = UUID(uuidString: "00000000-0000-4000-8000-00000000160\(offset + 1)")!
			let ruleID = UUID(uuidString: "00000000-0000-4000-8000-00000000161\(offset + 1)")!
			let rule = EventReminderRule(id: ruleID, text: texts[offset], motivation: "Native preview", evidence: "Native preview",
				selector: .series(.init(event: event)), occurrencePolicy: .nextMatch, createdAt: date.addingTimeInterval(-Double(offset + 1)),
				resolvedOccurrence: event)
			return EventReminderOccurrence(sourceEntryID: sourceID, reminder: rule, event: event)
		}
		let revisions = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.sourceEntryID, 1) })
		guard let item = ReminderActivityManager.desiredActivities(from: occurrences, defaultLeadMinutes: 2,
			sourceRevisions: revisions, now: date).first else { previewLog("failure: missing desired fixture"); return }
		do {
			let id = try live.request(item, date)
			previewLog("ready count=\(count) id=\(id)")
		} catch { previewLog("failure: \(String(reflecting: error))") }
	}

	private static func previewLog(_ message: String) {
		print("REMINDER ACTIVITY NATIVE PREVIEW: \(message)")
		fflush(stdout)
	}

	private static func nativeImmediate(_ scope: NativeScope) async throws {
		let date = Date.now
		let occurrence = nativeOccurrence(at: date, secondsUntilEvent: 120)
		guard var item = ReminderActivityManager.desiredActivities(from: [occurrence], defaultLeadMinutes: 2,
			sourceRevisions: [occurrence.sourceEntryID: 1], now: date).first else { throw Failure("Missing immediate fixture") }
		let id = try scope.operations.request(item, date)
		try await wait { scope.operations.existing().contains { $0.id == id && $0.isLive && $0.attributes == item.attributes && $0.content == item.state } }
		nativeLog("immediate inventory: \(String(describing: scope.operations.existing().first { $0.id == id }?.state))")
		item.state.reminderTexts = ["Native smoke update", "Second harmless reminder", "Third harmless reminder"]
		await scope.operations.update(id, item)
		try await wait { scope.operations.existing().contains { $0.id == id && $0.content == item.state } }
		await scope.operations.end(id)
		try await wait { !scope.operations.existing().contains { $0.id == id && $0.isLive } }
	}

	private static func nativeScheduled(_ scope: NativeScope) async throws {
		let date = Date.now
		var occurrence = nativeOccurrence(at: date, secondsUntilEvent: 60)
		let manager = ReminderActivityManager(operations: scope.operations)
		let first = await sync(manager, [occurrence], settings: settings(lead: 0), now: date)
		try expect(first.requestedCount == 1, "Scheduled request was not accepted: \(first.unavailableReason ?? first.failures.joined(separator: "; "))")
		guard let old = scope.operations.existing().first(where: \.isLive) else { throw Failure("Missing scheduled inventory") }
		nativeLog("scheduled inventory: \(old.id), \(old.state)")
		try expect(old.state == .pending, "Accepted short-future activity must initially be pending")
		scope.trace = []
		occurrence.event.title = "Native smoke replacement"
		occurrence.event.startDate.addTimeInterval(30)
		occurrence.event.endDate.addTimeInterval(30)
		occurrence.sourceEntryID = UUID()
		occurrence.reminder.resolvedOccurrence = occurrence.event
		let replacement = await sync(manager, [occurrence], settings: settings(lead: 0), now: date, generation: 2)
		try expect(replacement.requestedCount == 1, "Replacement request was not accepted: \(replacement.failures)")
		let live = scope.operations.existing().filter(\.isLive)
		try expect(live.count == 1 && live[0].id != old.id && live[0].attributes.eventTitle == occurrence.event.title
			&& live[0].attributes.sourceEntryID == occurrence.sourceEntryID, "Replacement must expose the changed immutable descriptor")
		try expect(scope.trace == ["end:\(old.id)", "request:\(live[0].id)"], "Native replacement must end the old ID before requesting the new one")
	}

	private static func nativeOccurrence(at date: Date, secondsUntilEvent: TimeInterval) -> EventReminderOccurrence {
		let event = JournalCalendarEvent(id: "native-smoke-\(UUID().uuidString)", calendarIdentifier: "native-smoke",
			calendarTitle: "Native smoke", title: "Harmless native smoke", startDate: date.addingTimeInterval(secondsUntilEvent),
			endDate: date.addingTimeInterval(secondsUntilEvent + 300), isAllDay: false)
		let rule = EventReminderRule(text: "Harmless reminder fixture", motivation: "Native smoke", evidence: "Native smoke",
			selector: .series(.init(event: event)), occurrencePolicy: .nextMatch, createdAt: date.addingTimeInterval(-1), resolvedOccurrence: event)
		return EventReminderOccurrence(sourceEntryID: UUID(), reminder: rule, event: event)
	}
	private static func nativeLog(_ message: String) {
		print("REMINDER ACTIVITY NATIVE SMOKE: \(message)")
		fflush(stdout)
	}

	private static let now = Date(timeIntervalSince1970: 2_000_000_000)

	private static func descriptorChanges() async throws {
		let mutations: [(inout EventReminderOccurrence) -> Void] = [
			{ $0.event.title = "Changed title" }, { $0.event.endDate.addTimeInterval(300) },
			{ $0.sourceEntryID = UUID() }, { $0.reminder.leadTimeOverrideMinutes = 37 },
			{ $0.reminder.text = "Changed pending alert" }, { $0.event.calendarIdentifier = "another-calendar" },
			{ $0.event.notes = "Updated event context" }, { $0.event.location = "Updated meeting location" }
		]
		for mutate in mutations {
			let backend = Backend()
			let manager = ReminderActivityManager(operations: backend.operations)
			var occurrence = occurrence("descriptor")
			_ = await sync(manager, [occurrence])
			let old = backend.requests[0]
			backend.trace = []
			mutate(&occurrence)
			let result = await sync(manager, [occurrence], generation: 2)
			try expect(backend.requests.count == 2 && backend.live.count == 1 && result.requestedCount == 1,
				"Changing an immutable descriptor must create one replacement")
			try expect(backend.trace == ["end:\(old.id)", "request:\(backend.requests[1].id)"], "The old descriptor must end before requesting its replacement")
		}
		let backend = Backend()
		let manager = ReminderActivityManager(operations: backend.operations)
		let first = occurrence("content")
		var second = occurrence("content", text: "Secondary", createdOffset: -1)
		_ = await sync(manager, [first, second])
		backend.trace = []
		second.reminder.text = "Updated secondary content"
		_ = await sync(manager, [first, second], generation: 2)
		try expect(backend.requests.count == 1 && backend.trace == ["update:\(backend.requests[0].id)"], "Content changes with the same immutable alert must update the existing activity")
		backend.trace = []
		_ = await sync(manager, [first, second], generation: 3)
		try expect(backend.trace.isEmpty, "An identical descriptor and content must not call ActivityKit again")
	}

	private static func leadAndLimits() async throws {
		for (global, override, inherited, expected) in [(60, 15, true, 60), (37, 0, true, 37), (37, 37, false, 37),
			(Int.min, Int.min, true, 0), (Int.max, Int.max, true, 1_440), (37, Int.max, true, 1_440)] {
			let backend = Backend()
			let manager = ReminderActivityManager(operations: backend.operations)
			var first = occurrence("lead")
			first.reminder.leadTimeOverrideMinutes = override
			var occurrences = [first]
			if inherited { occurrences.append(occurrence("lead", text: "Inherited", createdOffset: -1)) }
			_ = await sync(manager, occurrences, settings: settings(lead: global))
			let desired = try requested(backend)
			try expect(desired.attributes.triggerDate == first.event.startDate.addingTimeInterval(-Double(expected) * 60),
				"Every rule must contribute its override or inherited lead, clamped before date arithmetic")
		}
		let events = [occurrence("third", hours: 4), occurrence("second", hours: 3), occurrence("first", hours: 2), occurrence("outside", hours: 27)]
		let backend = Backend()
		let manager = ReminderActivityManager(operations: backend.operations)
		let result = await sync(manager, events)
		try expect(backend.requests.map(\.item.attributes.eventTitle) == ["first", "second"] && result.requestedCount == 2
			&& result.activeCount == 2 && result.deferredCount == 2, "Only the next two eligible groups may occupy reminder activities; other groups must remain deferred")
		let boundaryBackend = Backend()
		let boundaryManager = ReminderActivityManager(operations: boundaryBackend.operations)
		var outside = occurrence("outside-boundary", hours: 25)
		outside.event.startDate.addTimeInterval(1)
		outside.event.endDate.addTimeInterval(1)
		_ = await sync(boundaryManager, [outside, occurrence("boundary", hours: 25), occurrence("immediate", hours: 1)])
		try expect(boundaryBackend.requests.map(\.item.attributes.eventTitle) == ["immediate", "boundary"], "The 24-hour trigger horizon must include its exact boundary and exclude later triggers")
	}

	private static func contributorOrderingAndCounts() async throws {
		for count in [2, 3, 4] {
			let occurrences = (0..<count).map { occurrence("group", text: "Duplicate text", createdOffset: -Double($0)) }
			let backend = Backend()
			let manager = ReminderActivityManager(operations: backend.operations)
			_ = await sync(manager, occurrences.reversed())
			let item = try requested(backend)
			try expect(item.attributes.sourceEntryID == occurrences[0].sourceEntryID && item.attributes.contributors.count == count,
				"The primary link must follow display ordering while retaining every source/rule contributor")
			try expect(item.state.hiddenCount(visibleLimit: 2) == count - 2 && item.state.hiddenCount(visibleLimit: 1) == count - 1,
				"Each widget surface must report reminders hidden by its own visible limit, including duplicate text")
			let reordered = Backend()
			_ = await sync(ReminderActivityManager(operations: reordered.operations), occurrences)
			try expect(try requested(reordered).attributes == item.attributes, "Input order must not change the immutable contributor descriptor")
		}
		let tied = [occurrence("zeta", hours: 2), occurrence("alpha", hours: 2), occurrence("beta", hours: 2)]
		let backend = Backend()
		_ = await sync(ReminderActivityManager(operations: backend.operations), tied)
		try expect(backend.requests.map(\.item.attributes.eventTitle) == ["alpha", "beta"], "Equal trigger/start groups must use stable occurrence-key ordering")
		let tiedRules = [occurrence("tied-rules", text: "First candidate"), occurrence("tied-rules", text: "Second candidate")]
		let firstOrder = Backend(), reverseOrder = Backend()
		_ = await sync(ReminderActivityManager(operations: firstOrder.operations), tiedRules)
		_ = await sync(ReminderActivityManager(operations: reverseOrder.operations), tiedRules.reversed())
		let expectedPrimary = tiedRules.min { $0.reminder.id.uuidString < $1.reminder.id.uuidString }!
		try expect(try requested(firstOrder).attributes == requested(reverseOrder).attributes
			&& requested(firstOrder).attributes.sourceEntryID == expectedPrimary.sourceEntryID,
			"Equal creation dates must use stable rule/source ordering for both text and primary link")
	}

	private static func earlyRetirement() async throws {
		let primary = occurrence("retirement")
		let secondary = occurrence("retirement", text: "Secondary source", createdOffset: -1)
		let backend = Backend()
		let manager = ReminderActivityManager(operations: backend.operations)
		_ = await sync(manager, [primary, secondary])
		let resolverGate = Gate()
		let resolver = Task { await resolverGate.wait(); return [primary] }
		try await wait { resolverGate.waiting }
		_ = await manager.retireObsolete(sources: [source(primary)], events: [primary.event], settings: settings(), now: now, generation: 2)
		try expect(backend.live.isEmpty && backend.requests.count == 1 && resolverGate.waiting,
			"Removing a secondary contributor must retire the whole activity before an unrelated resolver completes")
		resolverGate.release()
		_ = await sync(manager, await resolver.value, generation: 3)
		try expect(backend.live.count == 1 && backend.requests.count == 2, "Current surviving sources may refill presentation after guarded resolution completes")
		_ = await manager.retireObsolete(sources: [source(primary, revision: 2)], events: [primary.event], settings: settings(), now: now, generation: 4)
		try expect(backend.live.isEmpty, "Changing a contributor's committed input revision must retire its obsolete presentation")
		let eventMutations: [(inout JournalCalendarEvent) -> Void] = [
			{ $0.notes = "The agenda now covers another topic" }, { $0.location = "A different meeting room" }
		]
		for mutate in eventMutations {
			let original = occurrence("event-input-retirement")
			var changed = original
			mutate(&changed.event)
			let backend = Backend()
			let manager = ReminderActivityManager(operations: backend.operations)
			_ = await sync(manager, [original])
			let gate = Gate()
			let resolver = Task { await gate.wait(); return [changed] }
			try await wait { gate.waiting }
			_ = await manager.retireObsolete(sources: [source(original)], events: [changed.event], settings: settings(), now: now, generation: 2)
			try expect(backend.live.isEmpty && backend.requests.count == 1 && gate.waiting,
				"Changed event notes or location must retire presentation before matching finishes, despite unchanged event identity and times")
			gate.release()
			_ = await sync(manager, await resolver.value, generation: 3)
			try expect(backend.live.count == 1 && backend.requests.count == 2,
				"A fresh resolution may recreate presentation using the changed event input")
		}
	}

	private static func captureSuspension() async throws {
		let occurrences = [occurrence("capture-one"), occurrence("capture-two", hours: 4)]
		let backend = Backend()
		let manager = ReminderActivityManager(operations: backend.operations)
		_ = await sync(manager, occurrences)
		let heldEnd = Gate()
		backend.nextEnd = heldEnd
		manager.setCaptureSuspended(true, generation: 2)
		try await wait { heldEnd.waiting }
		var drained = false
		let drain = Task { let result = await manager.waitForCaptureSuspension(); drained = true; return result }
		let attemptedRefill = Task { await sync(manager, occurrences, generation: 3) }
		try expect(!drained && backend.requests.count == 2, "Closing reminder admission must return to capture while native end remains suspended")
		heldEnd.release()
		try expect(await drain.value, "The owned native drain must confirm capture suspension after all ends finish")
		_ = await attemptedRefill.value
		try expect(backend.live.isEmpty && backend.requests.count == 2, "Ordinary synchronization must not reopen reminders during capture")
		manager.setCaptureSuspended(false, generation: 4)
		_ = await sync(manager, occurrences, generation: 5)
		try expect(backend.live.count == 2 && backend.requests.count == 4, "Reminder admission may reopen only after capture releases it and a new schedule arrives")
	}

	private static func failuresAndNativeStates() async throws {
		let desired = occurrence("retry")
		let backend = Backend()
		backend.failRequest = true
		let manager = ReminderActivityManager(operations: backend.operations)
		let failed = await sync(manager, [desired])
		try expect(!failed.failures.isEmpty && failed.requestedCount == 0 && backend.live.isEmpty, "A native request failure must remain visible without creating a success receipt")
		backend.failRequest = false
		let retried = await sync(manager, [desired])
		try expect(retried.failures.isEmpty && retried.requestedCount == 1 && backend.requests.count == 1, "The identical desired state must retry after a native request failure")
		let id = backend.requests[0].id
		backend.items[id]?.state = .active
		backend.trace = []
		_ = await sync(manager, [desired], now: desired.event.startDate.addingTimeInterval(-30), generation: 2)
		try expect(backend.trace.isEmpty, "A scheduled activity becoming active must preserve its immutable trigger descriptor")
		backend.items[id]?.state = .ended
		var dismissed = backend.items[id]!
		dismissed.id = "dismissed"
		dismissed.state = .dismissed
		backend.items[dismissed.id] = dismissed
		_ = await sync(manager, [desired], generation: 3)
		try expect(backend.requests.count == 2 && !backend.trace.contains("end:\(id)") && !backend.trace.contains("end:dismissed"),
			"Ended and dismissed native inventory must not block a fresh request or be ended again")
		backend.enabled = false
		let unavailable = await sync(manager, [desired], generation: 4)
		try expect(unavailable.unavailableReason != nil && backend.live.isEmpty, "Disabled native activities must retire presentation and expose its availability state")
	}

	private static func restoredDescriptors() async throws {
		let occurrence = occurrence("restored")
		let backend = Backend()
		_ = await sync(ReminderActivityManager(operations: backend.operations), [occurrence])
		let id = backend.requests[0].id
		let descriptor = backend.items[id]!.attributes
		backend.items[id]?.attributes = try JSONDecoder().decode(ReminderActivityAttributes.self, from: JSONEncoder().encode(descriptor))
		backend.trace = []
		_ = await sync(ReminderActivityManager(operations: backend.operations), [occurrence])
		try expect(backend.trace.isEmpty, "A recreated manager must recognize a complete persisted descriptor")
		let legacy = LegacyAttributes(eventKey: descriptor.eventKey, sourceEntryID: descriptor.sourceEntryID,
			eventTitle: descriptor.eventTitle, startDate: descriptor.startDate, endDate: descriptor.endDate)
		backend.items[id]?.attributes = try JSONDecoder().decode(ReminderActivityAttributes.self, from: JSONEncoder().encode(legacy))
		_ = await sync(ReminderActivityManager(operations: backend.operations), [occurrence])
		try expect(backend.requests.count == 2 && backend.trace == ["end:\(id)", "request:\(backend.requests[1].id)"],
			"A legacy descriptor must stay decodable and be retired before its current replacement")
	}

	private static func sync(_ manager: ReminderActivityManager, _ occurrences: [EventReminderOccurrence], settings: JournalSettings? = nil,
		now: Date = now, generation: Int = 1) async -> ReminderPresentationResult {
		let revisions = Dictionary(uniqueKeysWithValues: Set(occurrences.map(\.sourceEntryID)).map { ($0, 1) })
		return await manager.synchronize(occurrences: occurrences, settings: settings ?? self.settings(), sourceRevisions: revisions,
			now: now, generation: generation)
	}
	private static func settings(lead: Int = 60) -> JournalSettings {
		var settings = JournalSettings()
		settings.calendarSyncEnabled = true
		settings.eventReminderLeadMinutes = lead
		return settings
	}
	private static func occurrence(_ name: String, text: String = "Reminder", hours: Double = 3, createdOffset: Double = 0) -> EventReminderOccurrence {
		let event = JournalCalendarEvent(id: name, calendarIdentifier: "calendar", calendarTitle: "Calendar", title: name,
			startDate: now.addingTimeInterval(hours * 3_600), endDate: now.addingTimeInterval(hours * 3_600 + 1_800), isAllDay: false)
		let reminder = EventReminderRule(text: text, motivation: "Test", evidence: "Test", selector: .series(.init(event: event)),
			occurrencePolicy: .nextMatch, createdAt: now.addingTimeInterval(createdOffset), resolvedOccurrence: event)
		return EventReminderOccurrence(sourceEntryID: UUID(), reminder: reminder, event: event)
	}
	private static func source(_ occurrence: EventReminderOccurrence, revision: Int = 1) -> ReminderActivitySource {
		ReminderActivitySource(entry: JournalEntry(id: occurrence.sourceEntryID, duration: 30, transcript: "Fixture", headline: "Fixture",
			calendarEvent: occurrence.event, reminders: [occurrence.reminder]), inputRevision: revision)
	}
	private static func requested(_ backend: Backend) throws -> DesiredReminderActivity {
		guard let item = backend.requests.first?.item else { throw Failure("Expected a reminder request") }
		return item
	}
	private static func wait(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure("Timed out waiting for reminder presentation") }
			await Task.yield()
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
	private struct LegacyAttributes: Encodable {
		var eventKey: String; var sourceEntryID: UUID; var eventTitle: String; var startDate: Date; var endDate: Date
	}
	@MainActor private final class Gate {
		var waiting = false
		private var continuation: CheckedContinuation<Void, Never>?
		func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
		func release() { waiting = false; continuation?.resume(); continuation = nil }
	}
	@MainActor private final class Backend {
		var enabled = true
		var failRequest = false
		var items: [String: ReminderActivityOperations.Existing] = [:]
		var requests: [(id: String, item: DesiredReminderActivity)] = []
		var trace: [String] = []
		var nextEnd: Gate?
		var live: [ReminderActivityOperations.Existing] { items.values.filter { [.active, .pending, .stale].contains($0.state) } }
		var operations: ReminderActivityOperations {
			ReminderActivityOperations(enabled: { self.enabled }, existing: { self.items.values.sorted { $0.id < $1.id } },
				end: { id in
					let gate = self.nextEnd; self.nextEnd = nil
					await gate?.wait()
					self.items[id]?.state = .ended
					self.trace.append("end:\(id)")
				}, update: { id, item in
					self.items[id]?.content = item.state
					self.trace.append("update:\(id)")
				}, request: { item, now in
					if self.failRequest { throw Failure("Injected native request failure") }
					let id = UUID().uuidString
					self.items[id] = .init(id: id, attributes: item.attributes,
						state: item.startDate > now.addingTimeInterval(5) ? .pending : .active, content: item.state)
					self.requests.append((id, item)); self.trace.append("request:\(id)")
					return id
				})
		}
	}
	@MainActor private final class NativeScope {
		var ownedIDs = Set<String>()
		var trace: [String] = []
		private let live = ReminderActivityOperations.live
		var operations: ReminderActivityOperations {
			ReminderActivityOperations(enabled: { self.live.enabled() }, existing: {
				self.live.existing().filter { self.ownedIDs.contains($0.id) }
			}, end: { id in
				guard self.ownedIDs.contains(id) else { return }
				await self.live.end(id)
				self.trace.append("end:\(id)")
				nativeLog("end returned: \(id)")
			}, update: { id, item in
				guard self.ownedIDs.contains(id) else { return }
				await self.live.update(id, item)
				nativeLog("update returned: \(id)")
			}, request: { item, date in
				do {
					let id = try self.live.request(item, date)
					self.ownedIDs.insert(id)
					self.trace.append("request:\(id)")
					nativeLog("request accepted: \(id)")
					return id
				} catch {
					nativeLog("request error: \(String(reflecting: error))")
					throw error
				}
			})
		}
	}
}
#endif
