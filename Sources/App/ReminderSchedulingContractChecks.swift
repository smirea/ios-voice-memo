#if DEBUG
import Foundation

@MainActor
enum ReminderSchedulingContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-scheduling-contract-tests") else { return }
		do {
			print("REMINDER SCHEDULING CHECK: obsoleteResults"); fflush(nil)
			try await obsoleteResults()
			print("REMINDER SCHEDULING CHECK: pinFailure"); fflush(nil)
			try await pinFailure()
			print("REMINDER SCHEDULING CHECK: isolatedEdits"); fflush(nil)
			try await isolatedEdits()
			print("REMINDER SCHEDULING CHECK: pendingSourceProcessing"); fflush(nil)
			try await pendingSourceProcessing()
			print("REMINDER SCHEDULING CHECK: disabledProcessing"); fflush(nil)
			try await disabledProcessing()
			print("REMINDER SCHEDULING CHECK: restoredProcessing"); fflush(nil)
			try await disabledProcessing(restored: true)
			print("REMINDER SCHEDULING CHECK: deletingExport"); fflush(nil)
			try await deletingExport()
			print("REMINDER SCHEDULING CHECK: resumedScheduling"); fflush(nil)
			try await resumedScheduling()
			print("REMINDER SCHEDULING CHECK: disabledActivities"); fflush(nil)
			try await disabledActivities()
			print("REMINDER SCHEDULING CONTRACT: stale source, removal, deletion, settings, calendar replacement, pin-write failure, and isolated note writes passed")
			fflush(nil)
		} catch { fatalError("REMINDER SCHEDULING CONTRACT: \(error)") }
	}

	private static func obsoleteResults() async throws {
		for mutation in ["remove", "delete", "disable", "calendar", "scope"] {
			print("REMINDER SCHEDULING CHECK: stale \(mutation)"); fflush(nil)
			let root = try temporaryRoot()
			defer { try? FileManager.default.removeItem(at: root) }
			let (entry, event) = try await seed(root: root)
			let probe = ResolverProbe()
			let activities = Activities()
			let store = JournalStore(storageRootURL: root,
				reminderResolver: { await probe.resolve($0, $1, $2) }, reminderActivityManager: activities.manager())
			try await store.waitUntilLoaded()
			await store.waitForConfigurationWritesForContract()
			store.updateSetting(\.calendarSyncEnabled, true)
			store.calendarSync.setEventsForContract([event])
			try await wait { await probe.started }
			switch mutation {
			case "remove":
				store.removeReminder(entryID: entry.id, reminderID: entry.reminders[0].id)
				await store.waitForPendingWrites()
			case "delete":
				try expect(await store.deleteEntry(id: entry.id), "Deletion fixture must commit")
			case "disable":
				var settings = store.settings
				settings.eventRemindersEnabled = false
				store.updateSettings(settings)
			case "scope":
				var settings = store.settings
				settings.includedCalendarIdentifiers = ["another-calendar"]
				store.updateSettings(settings)
				try expect(store.calendarSync.events == [event], "Scope fixture must retain its old cached event")
			default:
				var replacement = event
				replacement.startDate = event.startDate.addingTimeInterval(86_400)
				replacement.endDate = event.endDate.addingTimeInterval(86_400)
				store.calendarSync.setEventsForContract([replacement])
			}
			await store.refreshReminderSchedule()
			await probe.release()
			try await wait { await probe.finished }
			try await Task.sleep(for: .milliseconds(20))
			try expect(!activities.items.values.contains { $0.attributes.eventKey == event.focusKey },
				"Obsolete resolution must not schedule after \(mutation)")
			let loaded = try await JournalRepository(rootURL: root).load()
			let saved = loaded.entries.first { $0.id == entry.id }
			try expect(saved?.reminders.first?.resolvedOccurrence?.focusKey != event.focusKey,
				"Obsolete resolution must not pin after \(mutation)")
			if mutation == "calendar" {
				try expect(activities.items.count == 1, "Newest calendar snapshot must reconcile despite older held work")
			}
		}
	}

	private static func pinFailure() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (entry, event) = try await seed(root: root)
		let activities = Activities()
		let store = JournalStore(storageRootURL: root,
			reminderResolver: { await ReminderEngine.resolve(entries: $0, events: $1, now: $2, modelIsAvailable: { false }) },
			reminderActivityManager: activities.manager())
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		let held = try block(entry.id, root)
		store.updateSetting(\.calendarSyncEnabled, true)
		store.calendarSync.setEventsForContract([event])
		await store.refreshReminderSchedule()
		try expect(store.hasUnsavedChanges(for: entry.id) && activities.items.isEmpty,
			"A failed durable pin must remain retryable and cannot be delivered")
		try expect(store.entry(id: entry.id)?.reminders[0].resolvedOccurrence == nil,
			"A failed pin write must not appear saved")
		var settings = store.settings
		settings.eventRemindersEnabled = false
		store.updateSettings(settings)
		await store.refreshReminderSchedule()
		try expect(!store.hasUnsavedChanges(for: entry.id), "Disabling reminders must retire obsolete derived-save errors")
		try restore(entry.id, root, held)
		settings.eventRemindersEnabled = true
		store.updateSettings(settings)
		await store.retrySavingChanges()
		try expect(!store.hasUnsavedChanges(for: entry.id) && activities.items.count == 1,
			"Retry must persist the pin before delivery")
		let loaded = try await JournalRepository(rootURL: root).load()
		try expect(loaded.entries[0].reminders[0].resolvedOccurrence?.focusKey == event.focusKey,
			"The delivered pin must survive restart")
	}

	private static func isolatedEdits() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (first, _) = try await seed(root: root)
		let (second, _) = try await seed(root: root)
		let store = JournalStore(storageRootURL: root)
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		let held = try block(first.id, root)
		store.removeReminder(entryID: first.id, reminderID: first.reminders[0].id)
		let feedback = ReminderFeedback(kind: .voice, text: "Bring another notebook")
		store.persist(.feedback(feedback), entryID: second.id)
		await store.waitForPendingWrites()
		try expect(store.hasUnsavedChanges(for: first.id) && !store.hasUnsavedChanges(for: second.id),
			"One failed note must not block another note's feedback")
		let exported = try await store.committedEntryForExport(id: second.id)
		try expect(exported.reminderFeedback.filter { $0.id == feedback.id }.count == 1,
			"Sharing a healthy note must include its saved feedback despite another note's fault")
		try expect(store.entry(id: first.id)?.reminders.isEmpty == true, "Failed removal must remain optimistic")
		try restore(first.id, root, held)
		await store.retrySavingChanges()
		let loaded = try await JournalRepository(rootURL: root).load()
		try expect(loaded.entries.first { $0.id == first.id }?.reminders.isEmpty == true,
			"Removal retry must preserve the intended edit")
		try expect(loaded.entries.first { $0.id == second.id }?.reminderFeedback.filter { $0.id == feedback.id }.count == 1,
			"Retrying another note must not duplicate healthy feedback")
	}

	private static func pendingSourceProcessing() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (first, _) = try await seed(root: root)
		let (second, _) = try await seed(root: root)
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		_ = try await repository.requestProcessing(id: first.id, startAt: .reminders)
		_ = try await repository.requestProcessing(id: second.id, startAt: .reminders)
		let probe = ReminderStageProbe(heldID: first.id)
		let store = JournalStore(storageRootURL: root, processingServices: services(probe))
		store.updateSetting(\.eventRemindersEnabled, true)
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		try await wait { await probe.starts[first.id] == 1 }
		let held = try block(first.id, root)
		store.removeReminder(entryID: first.id, reminderID: first.reminders[0].id)
		await store.waitForPendingWrites()
		await probe.release()
		try await wait { store.processingStates[second.id]?.status == .complete }
		try await Task.sleep(for: .milliseconds(30))
		try expect(await probe.starts[first.id] == 1, "An unsaved source must neither restart processing nor block a healthy queued note")
		try expect(store.entry(id: first.id)?.reminders.isEmpty == true, "Late canceled model output must not undo optimistic removal")
		try restore(first.id, root, held)
		await store.retrySavingChanges()
		try await wait { store.processingStates[first.id]?.status == .complete }
		let loaded = try await JournalRepository(rootURL: root).load()
		try expect(loaded.entries.first { $0.id == first.id }?.reminders.isEmpty == true,
			"Retry must generate only from the committed updated source")
	}

	private static func disabledProcessing(restored: Bool = false) async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (entry, _) = try await seed(root: root)
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reminders)
		let probe = ReminderStageProbe(heldID: entry.id)
		let store = JournalStore(storageRootURL: root, processingServices: services(probe))
		store.updateSetting(\.eventRemindersEnabled, true)
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		try await wait { await probe.starts[entry.id] == 1 }
		var settings = store.settings
		settings.eventRemindersEnabled = false
		if restored { store.applyRestoredConfiguration(AppConfiguration(settings: settings)) }
		else { store.updateSettings(settings) }
		await probe.release()
		try await wait { store.processingStates[entry.id]?.status == .complete }
		try expect(store.processingStates[entry.id]?.skippedStages.contains(.reminders) == true
			&& store.entry(id: entry.id)?.reminders == entry.reminders,
			"Disabling during a model request must discard that result and preserve rules through explicit skip (restored: \(restored))")
	}

	private static func deletingExport() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (entry, _) = try await seed(root: root)
		let store = JournalStore(storageRootURL: root)
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		let hold = DeletionHold()
		store.deletionIntentCheckpoint = { await hold.wait() }
		let deletion = Task { await store.deleteEntry(id: entry.id) }
		try await wait { await hold.started }
		do {
			_ = try await store.committedEntryForExport(id: entry.id)
			await hold.release()
			throw Failure(message: "A pending deletion must not export as a saved note")
		} catch RepositoryError.unavailableRecord {}
		await hold.release()
		try expect(await deletion.value, "Held deletion must finish after export refusal")
	}

	private static func resumedScheduling() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (_, event) = try await seed(root: root)
		let probe = ResumeProbe()
		let activities = Activities()
		let store = JournalStore(storageRootURL: root,
			reminderResolver: { await probe.resolve($0, $1, $2) }, reminderActivityManager: activities.manager())
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		let owner = UUID()
		await store.beginCapturePriority(owner: owner)
		store.updateSetting(\.calendarSyncEnabled, true)
		store.calendarSync.setEventsForContract([event])
		try await wait { await probe.calls == 1 }
		await store.endCapturePriority(owner: owner)
		try await wait { activities.items.count == 1 }
		try await Task.sleep(for: .milliseconds(30))
		try expect(await probe.calls == 2, "Capture release must resume one canceled schedule without a reconciliation loop")
	}

	private static func disabledActivities() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (entry, event) = try await seed(root: root)
		let activities = Activities()
		activities.items[event.focusKey] = DesiredReminderActivity(
			attributes: .init(eventKey: event.focusKey, sourceEntryID: entry.id, eventTitle: event.title,
				startDate: event.startDate, endDate: event.endDate),
			state: .init(reminderTexts: [entry.reminders[0].text], additionalReminderCount: 0), startDate: .now)
		let probe = HeldResolvers()
		let store = JournalStore(storageRootURL: root,
			reminderResolver: { await probe.resolve($0, $1, $2) }, reminderActivityManager: activities.manager())
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		store.updateSetting(\.calendarSyncEnabled, true)
		store.calendarSync.setEventsForContract([event])
		try await wait { await probe.calls == 1 }
		var settings = store.settings
		settings.eventReminderLiveActivitiesEnabled = false
		store.updateSettings(settings)
		try await wait { await probe.calls == 2 }
		try expect(activities.items.isEmpty, "Disabling Live Activities must end delivery before awaiting held matching")
		await probe.release()
		await store.refreshReminderSchedule()
		try expect(activities.items.isEmpty, "Late matching must not recreate disabled Live Activities")
	}

	private static func services(_ probe: ReminderStageProbe) -> ProcessingServices {
		ProcessingServices(transcribe: { _, _, _, _ in throw Failure(message: "Unexpected transcription") },
			reflect: { _, _ in ReflectionResult(headline: "Unexpected reflection", summary: nil, modelName: "fixture") },
			reminders: { await probe.run($0) })
	}

	private static func seed(root: URL) async throws -> (JournalEntry, JournalCalendarEvent) {
		let now = Date.now
		let event = JournalCalendarEvent(id: UUID().uuidString, calendarIdentifier: "fixture", calendarTitle: "Fixture",
			title: "Project review", startDate: now.addingTimeInterval(3_600), endDate: now.addingTimeInterval(7_200), isAllDay: false)
		let reminder = EventReminderRule(text: "Bring notes", motivation: "You need them", evidence: "Bring notes",
			selector: .series(EventSeriesReference(event: event)), occurrencePolicy: .nextMatch, createdAt: now.addingTimeInterval(-60))
		let entry = JournalEntry(duration: 5, transcript: "Bring notes", headline: "Your plan", reminders: [reminder])
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		try await repository.save([entry])
		return (entry, event)
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-scheduling-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func manifest(_ id: UUID, _ root: URL) -> URL {
		root.appendingPathComponent("Records/\(id.uuidString).json")
	}
	private static func block(_ id: UUID, _ root: URL) throws -> URL {
		let url = manifest(id, root), held = url.appendingPathExtension("held")
		try FileManager.default.moveItem(at: url, to: held)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
		return held
	}
	private static func restore(_ id: UUID, _ root: URL, _ held: URL) throws {
		try FileManager.default.removeItem(at: manifest(id, root))
		try FileManager.default.moveItem(at: held, to: manifest(id, root))
	}
	private static func expect(_ condition: Bool, _ message: String) throws {
		guard condition else { throw Failure(message: message) }
	}
	private static func wait(_ label: String = #function, line: Int = #line, _ condition: @MainActor () async -> Bool) async throws {
		for _ in 0..<200 {
			if await condition() { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		throw Failure(message: "Fixture wait timed out in \(label):\(line)")
	}
	private struct Failure: Error { var message: String }

	@MainActor
	private final class Activities {
		var items: [String: DesiredReminderActivity] = [:]
		func manager() -> ReminderActivityManager {
			ReminderActivityManager(operations: ReminderActivityOperations(enabled: { true },
				existing: { self.items.map { .init(id: $0.key, attributes: $0.value.attributes) } },
				end: { self.items.removeValue(forKey: $0) }, update: { self.items[$0] = $1 },
				request: { item, _ in self.items[item.attributes.eventKey] = item }))
		}
	}
}

private actor HeldResolvers {
	private(set) var calls = 0
	private var released = false
	private var continuations: [CheckedContinuation<Void, Never>] = []
	func resolve(_ entries: [JournalEntry], _ events: [JournalCalendarEvent], _ now: Date) async -> ReminderResolutionResult {
		calls += 1
		if !released { await withCheckedContinuation { continuations.append($0) } }
		return await Task.detached {
			await ReminderEngine.resolve(entries: entries, events: events, now: now, modelIsAvailable: { false })
		}.value
	}
	func release() {
		released = true
		let pending = continuations
		continuations.removeAll()
		for continuation in pending { continuation.resume() }
	}
}

private actor ResumeProbe {
	private(set) var calls = 0
	func resolve(_ entries: [JournalEntry], _ events: [JournalCalendarEvent], _ now: Date) async -> ReminderResolutionResult {
		calls += 1
		if calls == 1 {
			return ReminderResolutionResult(occurrences: [], examplesByReminderID: [:], resolvedOccurrencesByReminderID: [:], outcome: .cancelled)
		}
		return await ReminderEngine.resolve(entries: entries, events: events, now: now, modelIsAvailable: { false })
	}
}

private actor DeletionHold {
	private(set) var started = false
	private var continuation: CheckedContinuation<Void, Never>?
	func wait() async {
		started = true
		await withCheckedContinuation { continuation = $0 }
	}
	func release() { continuation?.resume(); continuation = nil }
}

private actor ReminderStageProbe {
	let heldID: UUID
	private(set) var starts: [UUID: Int] = [:]
	private var continuation: CheckedContinuation<Void, Never>?
	init(heldID: UUID) { self.heldID = heldID }
	func run(_ entry: JournalEntry) async -> ReminderParsingResult {
		starts[entry.id, default: 0] += 1
		if entry.id == heldID, starts[entry.id] == 1 {
			await withCheckedContinuation { continuation = $0 }
		}
		return ReminderParsingResult(reminders: entry.reminders, modelName: "fixture")
	}
	func release() { continuation?.resume(); continuation = nil }
}

private actor ResolverProbe {
	private(set) var started = false
	private(set) var finished = false
	private var continuation: CheckedContinuation<Void, Never>?
	func resolve(_ entries: [JournalEntry], _ events: [JournalCalendarEvent], _ now: Date) async -> ReminderResolutionResult {
		if !started {
			started = true
			await withCheckedContinuation { continuation = $0 }
			finished = true
		}
		return await Task.detached {
			await ReminderEngine.resolve(entries: entries, events: events, now: now, modelIsAvailable: { false })
		}.value
	}
	func release() { continuation?.resume(); continuation = nil }
}
#endif
