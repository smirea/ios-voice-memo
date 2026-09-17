#if DEBUG
import Foundation

@MainActor
enum ReminderSourceRepositoryContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-source-repository-contract-tests") else { return }
		do {
			try await resolutionChecks()
			try await processingRevisionChecks()
			try await sourceEditChecks()
			try await writeFailureChecks()
			try await exclusionChecks()
			print("REMINDER SOURCE REPOSITORY CONTRACT: atomic resolution, source revisions, stale/deleted output rejection, write fault preservation, and pending-source exclusions passed")
			fflush(stdout)
		} catch { fatalError("REMINDER SOURCE REPOSITORY CONTRACT: \(error)") }
	}

	private static func resolutionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		let source = try await record(repository, entry.id)
		let location = JournalLocation(latitude: 12, longitude: 34, city: "Saved location")
		let located = try await repository.apply(.location(location), to: entry.id)
		try expect(located.inputRevision == source.inputRevision && located.revision > source.revision,
			"Unrelated location edits must not invalidate reminder source")
		let first = event(1), second = event(2)
		let example = ReminderMatchExample(event: first, matches: true, reason: "Fixture match")
		let updates = [
			ReminderResolutionUpdate(reminderID: entry.reminders[0].id, occurrence: first, examples: [example]),
			ReminderResolutionUpdate(reminderID: entry.reminders[1].id, occurrence: second, examples: nil)
		]
		let saved = try await repository.commitReminderResolution(updates, source: source)
		try expect(saved.revision == located.revision + 1 && saved.inputRevision == source.inputRevision,
			"All derived updates must commit once without replacing the source revision")
		try expect(saved.entry?.location == location && saved.entry?.reminders[0].resolvedOccurrence == first
			&& saved.entry?.reminders[0].selector.examples == [example] && saved.entry?.reminders[1].resolvedOccurrence == second,
			"Atomic resolution must preserve the latest unrelated fields and every requested rule update")
		let data = try Data(contentsOf: manifest(entry.id, root))
		let unchanged = try await repository.commitReminderResolution([], source: saved)
		try expect(unchanged.revision == saved.revision && (try Data(contentsOf: manifest(entry.id, root))) == data,
			"No-op validation must not rewrite or revise a manifest")
		try await stale {
			_ = try await repository.commitReminderResolution([
				ReminderResolutionUpdate(reminderID: entry.reminders[0].id, occurrence: event(3), examples: nil)
			], source: source)
		}
		try expect((try Data(contentsOf: manifest(entry.id, root))) == data,
			"A competing pin computed from old exact rules must not overwrite the winner")
		try await stale {
			_ = try await repository.commitReminderResolution([
				ReminderResolutionUpdate(reminderID: entry.reminders[0].id, occurrence: event(4), examples: nil),
				ReminderResolutionUpdate(reminderID: UUID(), occurrence: event(5), examples: nil)
			], source: saved)
		}
		try expect((try Data(contentsOf: manifest(entry.id, root))) == data,
			"An invalid member must reject the whole update batch before any durable mutation")
		_ = try await repository.delete(id: entry.id)
		try await stale { _ = try await repository.commitReminderResolution(updates, source: saved) }
		let reloaded = try await JournalRepository(rootURL: root).load()
		try expect(reloaded.entries.isEmpty, "A late resolution must not restore a deleted note")
	}

	private static func processingRevisionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		let source = try await record(repository, entry.id)
		_ = try await repository.requestProcessing(id: entry.id)
		let speech = try await claim(repository, .transcribe)
		let transcript = try await repository.commitTranscription(
			TranscriptionResult(transcript: "Replacement transcript", modelName: "Fixture"), lease: speech)
		try expect(transcript.inputRevision == source.inputRevision + 1 && transcript.processing?.inputRevision == transcript.inputRevision,
			"A complete transcript replacement must atomically advance both source and queued job revision")
		try await stale { _ = try await repository.commitReminderResolution([], source: source) }
		let reflection = try await claim(repository, .reflect)
		try expect(reflection.inputRevision == transcript.inputRevision, "The next stage must claim the new transcript revision")
		let reflected = try await repository.commitReflection(
			ReflectionResult(headline: "Current title", summary: "Current summary", modelName: "Fixture"), lease: reflection)
		try expect(reflected.inputRevision == transcript.inputRevision, "Derived title/summary must not advance reminder source")
		_ = try await repository.commitReminderResolution([], source: transcript)
		let reminders = try await claim(repository, .reminders)
		try expect(reminders.inputRevision == transcript.inputRevision, "Reminder parsing must use the completed transcript revision")
		var replacement = entry.reminders
		replacement[0].text = "Replacement action"
		let parsed = try await repository.commitReminders(ReminderParsingResult(reminders: replacement, modelName: "Fixture"), lease: reminders)
		try expect(parsed.inputRevision == transcript.inputRevision + 1 && parsed.processing?.inputRevision == parsed.inputRevision,
			"Replacing complete reminder rules must advance the guarded source coherently")
		try await stale { _ = try await repository.commitReminderResolution([], source: reflected) }
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reminders)
		let disabled = try await claim(repository, .reminders)
		let skipped = try await repository.commitReminders(nil, lease: disabled)
		try expect(skipped.inputRevision == parsed.inputRevision && skipped.entry?.reminders == replacement
			&& skipped.processing?.skippedStages.contains(.reminders) == true,
			"Disabled parsing must preserve existing rules without inventing a replacement source")
		let restarted = try await JournalRepository(rootURL: root).load()
		try expect(restarted.records.first?.inputRevision == skipped.inputRevision
			&& restarted.entries.first?.reminders == replacement, "Source revisions and current rules must survive restart")
	}

	private static func sourceEditChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		let original = try await record(repository, entry.id)
		let feedback = ReminderFeedback(kind: .voice, text: "Use the later event")
		let corrected = try await repository.apply(.feedback(feedback), to: entry.id)
		try expect(corrected.inputRevision == original.inputRevision + 1, "Saved feedback must invalidate old resolution input")
		try await stale { _ = try await repository.commitReminderResolution([], source: original) }
		let duplicate = try await repository.apply(.feedback(feedback), to: entry.id)
		try expect(duplicate.revision == corrected.revision && duplicate.inputRevision == corrected.inputRevision,
			"Retrying a committed feedback intent must not create another source generation")
		let work = try await claim(repository, .reminders)
		let removed = try await repository.apply(.removeReminder(entry.reminders[0].id,
			ReminderFeedback(kind: .manualRemoval, text: "Keep removed", focusedReminderID: entry.reminders[0].id)), to: entry.id)
		try expect(removed.inputRevision == corrected.inputRevision + 1 && removed.processing?.attemptID == nil,
			"Removal must invalidate the active parser attempt as well as old resolution")
		try await stale { _ = try await repository.commitReminderResolution([], source: corrected) }
		try await stale {
			_ = try await repository.commitReminders(ReminderParsingResult(reminders: entry.reminders, modelName: "Late fixture"), lease: work)
		}
		let saved = try await record(repository, entry.id)
		try expect(saved.entry?.reminders.count == 1 && saved.entry?.reminderFeedback.count == 2,
			"An old parser result cannot resurrect a removed rule or lose correction history")
	}

	private static func writeFailureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		let source = try await record(repository, entry.id)
		let first = event(1)
		let pinned = try await repository.commitReminderResolution([
			ReminderResolutionUpdate(reminderID: entry.reminders[0].id, occurrence: first, examples: nil)
		], source: source)
		let destination = manifest(entry.id, root)
		let held = root.appendingPathComponent("held.json")
		try FileManager.default.moveItem(at: destination, to: held)
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
		let update = ReminderResolutionUpdate(reminderID: entry.reminders[0].id, occurrence: event(2), examples: nil)
		var failed = false
		do { _ = try await repository.commitReminderResolution([update], source: pinned) }
		catch { failed = true }
		try expect(failed, "A real blocked manifest must reject publication")
		let current = try await record(repository, entry.id)
		try expect(current.revision == pinned.revision && current.entry?.reminders[0].resolvedOccurrence == first,
			"A failed pin write must not alter repository memory or its acknowledgment")
		let noOp = try await repository.commitReminderResolution([], source: pinned)
		try expect(noOp.revision == pinned.revision, "No-op source validation must not require a write even on read-only media")
		try FileManager.default.removeItem(at: destination)
		try FileManager.default.moveItem(at: held, to: destination)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let recovered = try await record(restarted, entry.id)
		try expect(recovered.entry?.reminders[0].resolvedOccurrence == first, "Failure must preserve the previous durable pin after restart")
		let retried = try await restarted.commitReminderResolution([update], source: recovered)
		try expect(retried.entry?.reminders[0].resolvedOccurrence == event(2), "The unchanged source must remain retryable after storage recovers")
	}

	private static func exclusionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, first) = try await seed(root)
		let second = makeEntry()
		try await repository.save([second])
		_ = try await repository.requestProcessing(id: first.id)
		_ = try await repository.requestProcessing(id: second.id)
		let excluded: Set<UUID> = [first.id]
		guard let work = try await repository.claimProcessing(excluding: excluded) else { throw Failure("Expected another eligible note") }
		try expect(work.lease.entryID == second.id, "Pending source edits must not block another note's claim")
		_ = try await repository.failProcessing(work.lease, message: "Fixture transient failure", retryAfter: .distantFuture)
		try expect(await repository.nextProcessingRetry(excluding: excluded) == .distantFuture,
			"An excluded queued note must not replace a real retry with an immediate wake")
		try expect(try await repository.claimProcessing(excluding: excluded) == nil,
			"No work may be claimed from an excluded source before its edit commits")
		let all: Set<UUID> = [first.id, second.id]
		try expect(await repository.nextProcessingRetry(excluding: all) == nil,
			"An entirely excluded queue must not spin a retry timer")
		guard let restored = try await repository.claimProcessing(excluding: [second.id]) else { throw Failure("Expected unblocked note") }
		try expect(restored.lease.entryID == first.id, "Removing an exclusion must restore the original queued job")
	}

	private static func seed(_ root: URL) async throws -> (JournalRepository, JournalEntry) {
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = makeEntry()
		try await repository.save([entry])
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		return (restarted, entry)
	}
	private static func makeEntry() -> JournalEntry {
		let rules = ["Bring notes", "Bring water"].map { text in
			EventReminderRule(text: text, motivation: "Prepare", evidence: text,
				selector: .fuzzy(FuzzyEventSelector(semanticDescription: "Meeting", timeBucket: .any, locationDescription: nil, examples: [])),
				occurrencePolicy: .nextMatch)
		}
		let id = UUID()
		return JournalEntry(id: id, duration: 30, transcript: "A completed memo", headline: "Saved memo",
			audioFilename: "\(id.uuidString).m4a", reminders: rules)
	}
	private static func event(_ number: Int) -> JournalCalendarEvent {
		let start = Date(timeIntervalSince1970: 2_000_000_000 + Double(number * 3_600))
		return JournalCalendarEvent(id: "fixture-\(number)", calendarIdentifier: "fixture", calendarTitle: "Fixture",
			title: "Meeting", startDate: start, endDate: start.addingTimeInterval(1_800), isAllDay: false)
	}
	private static func record(_ repository: JournalRepository, _ id: UUID) async throws -> JournalRecord {
		guard let record = await repository.record(id: id) else { throw Failure("Expected a saved fixture record") }
		return record
	}
	private static func claim(_ repository: JournalRepository, _ stage: ProcessingStage) async throws -> ProcessingLease {
		guard let work = try await repository.claimProcessing(), work.lease.stage == stage else { throw Failure("Expected \(stage) work") }
		return work.lease
	}
	private static func stale(_ operation: () async throws -> Void) async throws {
		var rejected = false
		do { try await operation() } catch RepositoryError.staleProcessing { rejected = true }
		try expect(rejected, "Obsolete output must be rejected at the repository boundary")
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-source-repository-\(UUID())")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func manifest(_ id: UUID, _ root: URL) -> URL { root.appendingPathComponent("Records/\(id.uuidString).json") }
	private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
