#if DEBUG
import Foundation

@MainActor
enum ReminderBackfillContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-backfill-contract-tests") else { return }
		do {
			try await durableChecks()
			try await eligibilityChecks()
			try await writeFailureChecks()
			print("REMINDER BACKFILL CONTRACT: atomic reminder-only queueing, durable history, restart idempotence, source/status exclusions, and isolated write-failure retry passed")
			fflush(stdout)
		} catch { fatalError("REMINDER BACKFILL CONTRACT: \(error)") }
	}

	private static let now = Date(timeIntervalSince1970: 1_900_000_000)

	private static func durableChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = makeEntry()
		try await repository.save([entry])
		_ = try await repository.requestProcessing(id: entry.id)
		let transcription = try await claim(repository, stage: .transcribe)
		_ = try await repository.commitTranscription(.init(transcript: entry.transcript, modelName: "Completed speech"), lease: transcription)
		let reflection = try await claim(repository, stage: .reflect)
		_ = try await repository.commitReflection(.init(headline: "Completed title", summary: "Completed summary", modelName: "Completed reflection",
			analysisContext: "Completed internal notes"), lease: reflection)
		let reminders = try await claim(repository, stage: .reminders)
		let skipped = try await repository.commitReminders(nil, lease: reminders)
		try expect(skipped.processing?.status == .complete && skipped.processing?.skippedStages.contains(.reminders) == true,
			"The fixture must finish through the production disabled-reminders path")
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let before = try await record(restarted, entry.id)
		let backfill = try await restarted.backfillSkippedReminders()
		guard let queued = backfill.records.first else { throw Failure("Expected a queued eligible note") }
		try expect(backfill.records.count == 1 && backfill.issues.isEmpty && queued.entry == before.entry
			&& queued.inputRevision == before.inputRevision && queued.contentRevision == before.contentRevision
			&& queued.processing?.stage == .reminders && queued.processing?.status == .queued
			&& queued.processing?.completedStages == before.processing?.completedStages
			&& queued.processing?.skippedStages == before.processing?.skippedStages
			&& queued.processing?.requestID != before.processing?.requestID,
			"Backfill must commit only a new reminder request while retaining the complete note, source revision, stage history and cloud content version")
		let originalBytes = try Data(contentsOf: manifest(entry.id, root))
		let repeated = try await restarted.backfillSkippedReminders()
		try expect(repeated.records.isEmpty && repeated.issues.isEmpty && (try Data(contentsOf: manifest(entry.id, root))) == originalBytes,
			"Repeated enabling must not rewrite or replace an already queued job")
		let resumed = JournalRepository(rootURL: root)
		_ = try await resumed.load()
		let reopened = try await record(resumed, entry.id)
		try expect(reopened.processing?.requestID == queued.processing?.requestID && reopened.entry?.reminderHistory == entry.reminderHistory
			&& reopened.entry?.reminderProcessedFeedbackIDs == entry.reminderProcessedFeedbackIDs,
			"Queued work and retirement/feedback history must survive relaunch intact")
		try expect(try await resumed.backfillSkippedReminders().records.isEmpty, "Foreground backfill must be idempotent after restart")
		let lease = try await claim(resumed, stage: .reminders)
		let completed = try await resumed.commitReminders(.init(reminders: [], modelName: "Completed empty extraction"), lease: lease)
		try expect(completed.processing?.status == .complete && completed.processing?.skippedStages.contains(.reminders) == false,
			"A successful empty extraction must clear the skipped reason")
		try expect(try await resumed.backfillSkippedReminders().records.isEmpty,
			"Successful empty extraction must not be repeatedly backfilled")
	}

	private static func eligibilityChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var eligible = makeRecord(), excluded = makeRecord(), empty = makeRecord(), unattached = makeRecord(), partialSource = makeRecord()
		var succeeded = makeRecord(), failed = makeRecord(), canceled = makeRecord(), queued = makeRecord(), running = makeRecord()
		var deleted = makeRecord(), recording = makeRecord()
		empty.entry?.transcript = " \n\t"
		unattached.entry?.calendarEvent = nil
		partialSource.processing?.completedStages.remove(.transcribe)
		succeeded.processing?.skippedStages.remove(.reminders)
		failed.processing?.status = .failed
		failed.processing?.failure = "Preserve the failed request"
		failed.processing?.failedAttempts = 4
		canceled.processing?.status = .canceled
		queued.processing?.status = .queued
		running.processing?.status = .queued
		deleted.state = .deleted
		deleted.entry = nil
		recording.state = .recording
		let fixtures = [eligible, excluded, empty, unattached, partialSource, succeeded, failed, canceled, queued, running, deleted, recording]
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Records"), withIntermediateDirectories: true)
		for item in fixtures { try JSONEncoder().encode(item).write(to: manifest(item.id, root), options: .atomic) }
		let repository = JournalRepository(rootURL: root)
		let loaded = try await repository.load()
		try expect(loaded.records.count == fixtures.count, "Every exclusion fixture must be a valid readable manifest")
		let otherIDs = Set(fixtures.map(\.id)).subtracting([running.id])
		guard let active = try await repository.claimProcessing(excluding: otherIDs) else { throw Failure("Expected running exclusion fixture") }
		try expect(active.lease.entryID == running.id, "The running fixture must own an actual stage lease")
		let originals = try fixtures.reduce(into: [UUID: Data]()) { result, item in result[item.id] = try Data(contentsOf: manifest(item.id, root)) }
		let result = try await repository.backfillSkippedReminders(excluding: [excluded.id])
		try expect(result.records.map(\.id) == [eligible.id] && result.issues.isEmpty,
			"Only saved complete skipped work with completed nonempty transcript and event may be backfilled")
		for item in fixtures where item.id != eligible.id {
			try expect(try Data(contentsOf: manifest(item.id, root)) == originals[item.id],
				"An ineligible, failed, canceled, pending or running note must remain byte-for-byte unchanged")
		}
		let released = try await repository.backfillSkippedReminders()
		try expect(released.records.map(\.id) == [excluded.id], "Removing a pending-source exclusion must make its original skipped note eligible")
		_ = try await repository.pauseProcessing(active.lease, canceled: true)
	}

	private static func writeFailureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let first = makeRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let second = makeRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Records"), withIntermediateDirectories: true)
		for item in [first, second] { try JSONEncoder().encode(item).write(to: manifest(item.id, root), options: .atomic) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let before = try await record(repository, first.id)
		let path = manifest(first.id, root), held = root.appendingPathComponent("held.json")
		let originalBytes = try Data(contentsOf: path)
		try FileManager.default.moveItem(at: path, to: held)
		try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
		let failed = try await repository.backfillSkippedReminders()
		let preserved = try await record(repository, first.id)
		try expect(failed.records.map(\.id) == [second.id] && failed.issues.count == 1
			&& preserved.processing == before.processing && preserved.revision == before.revision,
			"A real first-note write failure must preserve its skipped state and still queue the healthy second note")
		try expect(try Data(contentsOf: held) == originalBytes, "Failed queueing must preserve the previous durable manifest")
		try FileManager.default.removeItem(at: path)
		try FileManager.default.moveItem(at: held, to: path)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let retry = try await restarted.backfillSkippedReminders()
		try expect(retry.records.map(\.id) == [first.id] && retry.issues.isEmpty,
			"After restart only the failed eligible note must retry; the healthy queued request must remain unchanged")
		let repeated = try await restarted.backfillSkippedReminders()
		try expect(repeated.records.isEmpty && repeated.issues.isEmpty, "A repaired backfill must converge without repeated writes")
	}

	private static func makeRecord(id: UUID = UUID()) -> JournalRecord {
		var record = JournalRecord(entry: makeEntry(id: id))
		record.revision = 1
		record.contentRevision = 1
		record.inputRevision = 7
		var job = EntryProcessing(inputRevision: record.inputRevision, stage: .reminders)
		job.status = .complete
		job.completedStages = [.transcribe, .reflect, .reminders]
		job.skippedStages = [.reminders]
		record.processing = job
		return record
	}
	private static func makeEntry(id: UUID = UUID()) -> JournalEntry {
		let event = JournalCalendarEvent(id: "backfill-event", calendarIdentifier: "backfill-calendar", calendarTitle: "Backfill",
			title: "Notebook workshop", startDate: now.addingTimeInterval(3_600), endDate: now.addingTimeInterval(5_400), isAllDay: false)
		let feedback = ReminderFeedback(kind: .voice, text: "Keep the correction")
		let retired = EventReminderRule(text: "Bring notes", motivation: "Prepare", evidence: "Bring notes", selector: .series(.init(event: event)),
			occurrencePolicy: .nextMatch, createdAt: now, resolvedOccurrence: event, consumedAt: now, sourceFeedbackID: feedback.id)
		return JournalEntry(id: id, createdAt: now, duration: 30, transcript: "Next time, bring notes to this event.",
			summary: "Saved summary", headline: "Saved title", audioFilename: "\(id.uuidString).m4a", calendarEvent: event,
			summaryModel: "Saved reflection", transcriptModel: "Saved speech", reminderFeedback: [feedback], reminderHistory: [retired],
			reminderProcessedFeedbackIDs: [feedback.id])
	}
	private static func claim(_ repository: JournalRepository, stage: ProcessingStage) async throws -> ProcessingLease {
		guard let work = try await repository.claimProcessing(), work.lease.stage == stage else { throw Failure("Expected only \(stage) work") }
		return work.lease
	}
	private static func record(_ repository: JournalRepository, _ id: UUID) async throws -> JournalRecord {
		guard let record = await repository.record(id: id) else { throw Failure("Expected a saved manifest") }
		return record
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-backfill-\(UUID())")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func manifest(_ id: UUID, _ root: URL) -> URL { root.appendingPathComponent("Records/\(id.uuidString).json") }
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
