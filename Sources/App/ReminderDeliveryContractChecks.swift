#if DEBUG
import Foundation

@MainActor
enum ReminderDeliveryContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-delivery-contract-tests") else { return }
		do {
			try await earlyRetirement()
			try await retryAndCapture()
			try await skippedBackfill()
			print("REMINDER DELIVERY CONTRACT: secondary-source retirement before held inference, visible retry, capture drain ownership, and enabled/startup/foreground backfill passed")
			fflush(stdout)
		} catch { fatalError("REMINDER DELIVERY CONTRACT: \(error)") }
	}

	private static func earlyRetirement() async throws {
		for mutation in ["remove", "delete", "calendar", "notes", "location", "scope"] {
			let root = try temporaryRoot()
			defer { try? FileManager.default.removeItem(at: root) }
			let now = Date.now
			let event = makeEvent(now: now)
			let first = makeEntry(event: event, date: now.addingTimeInterval(-60), text: "Bring notes")
			let second = makeEntry(event: event, date: now.addingTimeInterval(-120), text: "Bring water")
			let repository = JournalRepository(rootURL: root)
			_ = try await repository.load()
			try await repository.save([first, second])
			let backend = Backend()
			let resolver = Resolver()
			let store = JournalStore(storageRootURL: root, reminderResolver: { await resolver.resolve($0, $1, $2) },
				reminderActivityManager: backend.manager())
			try await ready(store, events: [event])
			await store.refreshReminderSchedule(now: now)
			try expect(backend.items.count == 1 && backend.items.values.first?.attributes.sourceEntryID == first.id
				&& backend.items.values.first?.attributes.contributors.count == 2,
				"Fixture must show both sources in one group with a deterministic primary note")
			await resolver.hold()
			switch mutation {
			case "remove": store.removeReminder(entryID: second.id, reminderID: second.reminders[0].id)
			case "delete": try expect(await store.deleteEntry(id: second.id), "Secondary deletion must commit")
			case "calendar", "notes", "location":
				var edited = event
				if mutation == "notes" { edited.notes = "The event purpose changed" }
				else if mutation == "location" { edited.location = "A different venue" }
				else { edited.title = "Revised event title" }
				store.calendarSync.setEventsForContract([edited])
			default: store.updateSetting(\.includedCalendarIdentifiers, Set(["excluded-calendar"]))
			}
			try await wait { await resolver.waiting > 0 }
			try expect(backend.items.isEmpty, "\(mutation) must retire the entire affected group before unrelated held inference completes")
			await resolver.release()
			await store.waitForPendingWrites()
			await store.refreshReminderSchedule()
			if mutation == "remove" || mutation == "delete" {
				try expect(backend.items.values.first?.attributes.contributors.map(\.sourceEntryID) == [first.id],
					"Only the surviving source may be presented after \(mutation)")
			}
		}
	}

	private static func retryAndCapture() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let now = Date.now, event = makeEvent(now: Date.now)
		let entry = makeEntry(event: event, date: now.addingTimeInterval(-60), text: "Bring notes")
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		try await repository.save([entry])
		let backend = Backend()
		backend.failRequests = true
		let store = JournalStore(storageRootURL: root, reminderResolver: {
			await ReminderEngine.resolve(entries: $0, events: $1, now: $2, modelIsAvailable: { false })
		}, reminderActivityManager: backend.manager())
		try await ready(store, events: [event])
		await store.refreshReminderSchedule()
		try expect(store.canRetryReminderDelivery && store.reminderPresentationMessage != nil && backend.items.isEmpty,
			"A native request failure must be visible and leave no successful activity receipt")
		let failedCalls = backend.requests
		try await Task.sleep(for: .milliseconds(40))
		try expect(backend.requests == failedCalls, "A failed request must not immediately retry itself")
		backend.failRequests = false
		await store.retryReminderDelivery()
		try expect(backend.items.count == 1 && !store.canRetryReminderDelivery,
			"Explicit Retry must request the identical failed descriptor and clear its error only on success")
		let gate = Gate()
		backend.endGate = gate
		let firstOwner = UUID(), secondOwner = UUID()
		await store.beginCapturePriority(owner: firstOwner)
		try await wait { gate.waiting }
		try expect(store.isCapturePriorityActive && !backend.items.isEmpty,
			"Capture admission must return while native reminder cleanup is still held")
		let firstDrain = Task { await store.waitForReminderActivitiesToEnd(owner: firstOwner) }
		await store.beginCapturePriority(owner: secondOwner)
		await store.endCapturePriority(owner: firstOwner)
		store.calendarSync.setEventsForContract([event])
		let requests = backend.requests
		gate.release()
		try expect(await firstDrain.value == false, "A released owner must not claim the current capture drain")
		try expect(await store.waitForReminderActivitiesToEnd(owner: secondOwner), "The remaining capture owner must observe actual cleanup completion")
		await store.refreshReminderSchedule()
		try expect(backend.items.isEmpty && backend.requests == requests,
			"Calendar generations during capture must retain closed admission after the old owner's release")
		await store.endCapturePriority(owner: secondOwner)
		await store.refreshReminderSchedule()
		try expect(backend.items.count == 1, "Final capture release must rebuild a fresh reminder presentation")
	}

	private static func skippedBackfill() async throws {
		for wake in ["enabled", "startup", "foreground", "sourceRetry"] {
			let root = try temporaryRoot()
			defer { try? FileManager.default.removeItem(at: root) }
			let now = Date.now, event = makeEvent(now: Date.now)
			let entry = makeEntry(event: event, date: now.addingTimeInterval(-60), text: "Bring notes")
			let repository = JournalRepository(rootURL: root)
			_ = try await repository.load()
			try await repository.save([entry])
			_ = try await repository.requestProcessing(id: entry.id)
			let transcription = try await claim(repository)
			_ = try await repository.commitTranscription(.init(transcript: entry.transcript, modelName: "Saved speech"), lease: transcription)
			let reflection = try await claim(repository)
			_ = try await repository.commitReflection(.init(headline: "Saved title", summary: "Saved summary", modelName: "Saved reflection"), lease: reflection)
			let reminders = try await claim(repository)
			_ = try await repository.commitReminders(nil, lease: reminders)
			var settings = JournalSettings()
			settings.eventRemindersEnabled = wake != "enabled"
			_ = try await ConfigurationRepository(rootURL: root).load(baseline: .init(settings: settings))
			let stages = Stages()
			let heldURL = root.appendingPathComponent("Records/\(entry.id.uuidString).json")
			let savedURL = heldURL.appendingPathExtension("held")
			let store = JournalStore(storageRootURL: root, processingServices: stages.services)
			let configurationGate = Gate()
			let needsFault = wake == "foreground" || wake == "sourceRetry"
			if needsFault { store.configurationLoadCheckpoint = { await configurationGate.wait() } }
			try await store.waitUntilLoaded()
			if needsFault {
				try await wait { configurationGate.waiting }
				try FileManager.default.moveItem(at: heldURL, to: savedURL)
				try FileManager.default.createDirectory(at: heldURL, withIntermediateDirectories: false)
				if wake == "sourceRetry" {
					store.removeReminder(entryID: entry.id, reminderID: entry.reminders[0].id)
					await store.waitForPendingWrites()
				}
				configurationGate.release()
			}
			await store.waitForConfigurationWritesForContract()
			if wake == "enabled" {
				try expect(await stages.calls == 0, "Disabled reminders must retain the optional CPU gate")
				store.updateSetting(\.eventRemindersEnabled, true)
			} else if needsFault {
				if wake == "foreground" { try await wait { store.reminderBackfillMessage != nil } }
				else {
					await store.retryReminderDelivery()
					try expect(store.hasUnsavedChanges(for: entry.id), "Backfill must leave failed source edits pending")
				}
				try expect(await stages.calls == 0 && store.processingStates[entry.id]?.skippedStages.contains(.reminders) == true,
					"A failed backfill write must remain skipped and expose Retry without starting inference")
				try FileManager.default.removeItem(at: heldURL)
				try FileManager.default.moveItem(at: savedURL, to: heldURL)
				if wake == "foreground" { store.resumeStaleProcessing() }
				else { await store.retrySavingChanges() }
			}
			try await wait { store.processingStates[entry.id]?.status == .complete
				&& store.processingStates[entry.id]?.skippedStages.contains(.reminders) == false }
			try expect(await stages.calls == 1 && store.entry(id: entry.id)?.headline == "Saved title"
				&& store.entry(id: entry.id)?.transcript == entry.transcript,
				"\(wake) must run only skipped reminders and retain completed transcript/reflection")
			store.resumeStaleProcessing()
			await store.retryReminderDelivery()
			try expect(await stages.calls == 1, "A successful empty extraction must never be backfilled again")
		}
	}

	private static func ready(_ store: JournalStore, events: [JournalCalendarEvent]) async throws {
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		store.updateSetting(\.calendarSyncEnabled, true)
		store.calendarSync.setEventsForContract(events)
	}
	private static func claim(_ repository: JournalRepository) async throws -> ProcessingLease {
		guard let work = try await repository.claimProcessing() else { throw Failure("Expected queued fixture stage") }
		return work.lease
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-delivery-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func makeEvent(now: Date) -> JournalCalendarEvent {
		.init(id: "delivery-event", calendarIdentifier: "delivery-calendar", calendarTitle: "Delivery", title: "Weekly planning",
			startDate: now.addingTimeInterval(3_600), endDate: now.addingTimeInterval(5_400), isAllDay: false)
	}
	private static func makeEntry(event: JournalCalendarEvent, date: Date, text: String) -> JournalEntry {
		let reminder = EventReminderRule(text: text, motivation: "Prepare", evidence: text, selector: .series(.init(event: event)),
			occurrencePolicy: .everyMatch, createdAt: date)
		return .init(createdAt: date, duration: 30, transcript: text, headline: "Saved plan", calendarEvent: event, reminders: [reminder])
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private static func wait(_ condition: @MainActor () async -> Bool) async throws {
		for _ in 0..<400 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
		throw Failure("Timed out waiting for delivery fixture")
	}
	private struct Failure: Error { var message: String; init(_ message: String) { self.message = message } }

	private actor Resolver {
		private var isHeld = false
		private var continuations: [CheckedContinuation<Void, Never>] = []
		var waiting: Int { continuations.count }
		func hold() { isHeld = true }
		func release() { isHeld = false; let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
		func resolve(_ entries: [JournalEntry], _ events: [JournalCalendarEvent], _ now: Date) async -> ReminderResolutionResult {
			if isHeld { await withCheckedContinuation { continuations.append($0) } }
			return await Task.detached { await ReminderEngine.resolve(entries: entries, events: events, now: now, modelIsAvailable: { false }) }.value
		}
	}
	private actor Stages {
		var calls = 0
		nonisolated var services: ProcessingServices {
			ProcessingServices(transcribe: { _, _, _, _ in throw Failure("Backfill must not transcribe") },
				reflect: { _, _ in fatalError("Backfill must not reflect") }, reminders: { _ in
					await self.record()
					return .init(reminders: [], modelName: "Fixture")
				})
		}
		func record() { calls += 1 }
	}
	@MainActor private final class Gate {
		var waiting = false
		private var continuation: CheckedContinuation<Void, Never>?
		func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
		func release() { continuation?.resume(); continuation = nil }
	}
	@MainActor private final class Backend {
		var items: [String: DesiredReminderActivity] = [:]
		var requests = 0
		var failRequests = false
		var endGate: Gate?
		func manager() -> ReminderActivityManager {
			ReminderActivityManager(operations: .init(enabled: { true },
				existing: { self.items.map { .init(id: $0.key, attributes: $0.value.attributes, content: $0.value.state) } },
				end: { id in
					if let gate = self.endGate { self.endGate = nil; await gate.wait() }
					self.items.removeValue(forKey: id)
				}, update: { self.items[$0] = $1 }, request: { item, _ in
					self.requests += 1
					if self.failRequests { throw Failure("Controlled request failure") }
					let id = UUID().uuidString
					self.items[id] = item
					return id
				}))
		}
	}
}
#endif
