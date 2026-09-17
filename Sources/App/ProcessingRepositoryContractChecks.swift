#if DEBUG
import AVFAudio
import Foundation

@MainActor
enum ProcessingRepositoryContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-processing-repository-contract-tests") else { return }
		do {
			try await recordingChecks()
			try await restartChecks()
			try await leaseChecks()
			try await failureChecks()
			try await editChecks()
			try await completionChecks()
			try await migrationChecks()
			print("PROCESSING REPOSITORY CONTRACT: durable stages, restart/cancellation, stale leases, write failure retry, narrow edits, skipped outcomes, and deletion passed")
			fflush(stdout)
		} catch { fatalError("PROCESSING REPOSITORY CONTRACT: \(error)") }
	}

	private static func recordingChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let finished = try await repository.beginRecording(calendarEvent: nil)
		try writeAudio(root.appendingPathComponent("Recordings/\(finished.audioFilename!)"))
		_ = try await repository.finishRecording(id: finished.id)
		let committed = try diskRecord(finished.id, root: root)
		try expect(committed.state == .saved && committed.processing?.stage == .finalizeAudio && committed.processing?.status == .queued,
			"Finishing capture must durably queue finalization in the recording's own manifest")
		let finalization = try await claim(repository, stage: .finalizeAudio)
		let request = try await repository.prepareAudioFinalization(id: finished.id)
		try writeAudio(request.stagingURL)
		let media = try AVAudioFile(forReading: request.stagingURL)
		_ = try await repository.commitFinalizedAudio(FinalizedAudio(request: request, preparedURL: request.stagingURL,
			duration: Double(media.length) / media.processingFormat.sampleRate), lease: finalization)
		let interrupted = try await repository.beginRecording(calendarEvent: nil)
		try writeAudio(root.appendingPathComponent("Recordings/\(interrupted.id.uuidString).caf"))
		let restarted = try await JournalRepository(rootURL: root).load()
		let recovered = restarted.records.first { $0.id == interrupted.id }
		try expect(restarted.entries.count == 2 && recovered?.state == .saved && recovered?.entry?.createdAt == interrupted.createdAt,
			"Recovery must preserve the capture ID and date instead of inventing a second note")
		try expect(recovered?.processing?.stage == .finalizeAudio && recovered?.processing?.status == .queued,
			"Recovered native audio must have a durable processing job")
		try expect(restarted.records.first { $0.id == finished.id }?.processing?.requestID == committed.processing?.requestID,
			"Restart must preserve an existing processing request")
		let finalized = restarted.records.first { $0.id == finished.id }
		try expect(finalized?.processing?.stage == .transcribe && finalized?.processing?.completedStages.contains(.finalizeAudio) == true
			&& finalized?.entry?.audioFilename?.hasSuffix(".m4a") == true,
			"Restart after media publication must resume transcription without redoing finalization")
	}

	private static func restartChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let transcription = try await claim(repository, stage: .transcribe)
		_ = try await repository.commitTranscription(.init(transcript: "Durable transcript", modelName: "fixture"), lease: transcription)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let reflection = try await claim(restarted, stage: .reflect)
		try expect(reflection.requestID == transcription.requestID, "Relaunch must resume the next stage of the same request")
		let interruptedAgain = JournalRepository(rootURL: root)
		_ = try await interruptedAgain.load()
		let resumed = try await claim(interruptedAgain, stage: .reflect)
		try expect(resumed.attemptID != reflection.attemptID && resumed.requestID == reflection.requestID,
			"A running stage must relaunch queued and acquire a fresh attempt")
		try await stale { _ = try await interruptedAgain.commitReflection(reflectionResult, lease: reflection) }
		_ = try await interruptedAgain.commitReflection(reflectionResult, lease: resumed)
		let reflectedRestart = JournalRepository(rootURL: root)
		_ = try await reflectedRestart.load()
		let reminders = try await claim(reflectedRestart, stage: .reminders)
		try expect(reminders.requestID == resumed.requestID, "Restart after reflection must resume reminders in the same request")
		_ = try await reflectedRestart.pauseProcessing(reminders, canceled: true)
		let canceledRestart = JournalRepository(rootURL: root)
		_ = try await canceledRestart.load()
		let canceledWork = try await canceledRestart.claimProcessing(now: .distantFuture)
		let canceled = await canceledRestart.record(id: entry.id)
		try expect(canceledWork == nil && canceled?.processing?.status == .canceled,
			"Explicit cancellation must survive launch and must not be automatically retried")
		try expect(canceled?.entry?.transcript == "Durable transcript" && canceled?.entry?.headline == reflectionResult.headline
			&& canceled?.processing?.completedStages.isSuperset(of: [.transcribe, .reflect]) == true,
			"Canceling a later stage must preserve the previous stage's committed output")
	}

	private static func leaseChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let obsoleteRequest = try await claim(repository, stage: .transcribe)
		_ = try await repository.requestProcessing(id: entry.id)
		let firstAttempt = try await claim(repository, stage: .transcribe)
		let output = TranscriptionResult(transcript: "Current transcript", modelName: "fixture")
		try await stale { _ = try await repository.commitTranscription(output, lease: obsoleteRequest) }
		for invalid in [
			ProcessingLease(entryID: entry.id, requestID: firstAttempt.requestID, attemptID: UUID(), inputRevision: firstAttempt.inputRevision, stage: .transcribe),
			ProcessingLease(entryID: entry.id, requestID: firstAttempt.requestID, attemptID: firstAttempt.attemptID, inputRevision: firstAttempt.inputRevision + 1, stage: .transcribe),
			ProcessingLease(entryID: entry.id, requestID: firstAttempt.requestID, attemptID: firstAttempt.attemptID, inputRevision: firstAttempt.inputRevision, stage: .reflect)
		] { try await stale { _ = try await repository.commitTranscription(output, lease: invalid) } }
		_ = try await repository.pauseProcessing(firstAttempt)
		let current = try await claim(repository, stage: .transcribe)
		try await stale { _ = try await repository.commitTranscription(output, lease: firstAttempt) }
		_ = try await repository.commitTranscription(output, lease: current)
		try await stale { _ = try await repository.commitTranscription(output, lease: current) }
		let reflecting = try await claim(repository, stage: .reflect)
		_ = try await repository.delete(id: entry.id)
		try await stale { _ = try await repository.commitReflection(reflectionResult, lease: reflecting) }
		let retry = await repository.nextProcessingRetry()
		let deletedWork = try await repository.claimProcessing(now: .distantFuture)
		try expect(retry == nil && deletedWork == nil && (try diskRecord(entry.id, root: root)).processing == nil,
			"Deletion must invalidate the lease and remove all pending processing/retry state")
		let (retryRepository, retryEntry) = try await seed(root)
		_ = try await retryRepository.requestProcessing(id: retryEntry.id)
		let failedLease = try await claim(retryRepository, stage: .transcribe)
		_ = try await retryRepository.failProcessing(failedLease, message: "Temporarily unavailable", retryAfter: .distantFuture)
		let scheduled = await retryRepository.nextProcessingRetry()
		try expect(scheduled == .distantFuture, "A failed processing job must expose its durable future retry")
		_ = try await retryRepository.delete(id: retryEntry.id)
		let deletedRetry = await retryRepository.nextProcessingRetry()
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let restartedWork = try await restarted.claimProcessing(now: .distantFuture)
		try expect(deletedRetry == nil && restartedWork == nil,
			"Deleting a failed job must erase its future retry and remain unschedulable after restart")
	}

	private static func failureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let lease = try await claim(repository, stage: .transcribe)
		let partial = TranscriptionProgress(transcript: "Incomplete replacement", modelName: "fixture")
		_ = try await repository.savePartial(partial, lease: lease)
		_ = try await repository.failProcessing(lease, message: "Provider interrupted", partial: partial, retryAfter: .distantFuture,
			fallback: ReflectionResult(headline: "Must not replace complete analysis", summary: nil, modelName: "fallback"))
		let failed = try diskRecord(entry.id, root: root)
		try expect(failed.entry == entry && failed.processing?.status == .partial && failed.processing?.partialTranscript == partial,
			"Partial failure must preserve the last complete transcript/analysis while recording incomplete progress separately")
		_ = try await repository.retryProcessing(id: entry.id)
		let retry = try await claim(repository, stage: .transcribe)
		let before = try diskRecord(entry.id, root: root)
		let manifest = recordURL(entry.id, root: root)
		let preserved = root.appendingPathComponent("preserved.json")
		try FileManager.default.moveItem(at: manifest, to: preserved)
		try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
		let output = TranscriptionResult(transcript: "Complete replacement", modelName: "replacement")
		var didFail = false
		do { _ = try await repository.commitTranscription(output, lease: retry) } catch { didFail = true }
		let retained = await repository.record(id: entry.id)
		try expect(didFail && retained?.entry == before.entry && retained?.processing == before.processing && retained?.revision == before.revision,
			"An actual manifest write failure must not advance the stage or publish replacement data")
		try FileManager.default.removeItem(at: manifest)
		try FileManager.default.moveItem(at: preserved, to: manifest)
		_ = try await repository.commitTranscription(output, lease: retry)
		let saved = try diskRecord(entry.id, root: root)
		try expect(saved.entry?.transcript == output.transcript && saved.processing?.stage == .reflect && saved.processing?.partialTranscript == nil,
			"The same valid lease must commit exactly once after storage is repaired")
	}

	private static func editChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let transcription = try await claim(repository, stage: .transcribe)
		_ = try await repository.commitTranscription(.init(transcript: "Fresh transcript", modelName: "new speech"), lease: transcription)
		let location = JournalLocation(latitude: 41.88, longitude: -87.63, city: "Chicago")
		_ = try await repository.apply(.location(location), to: entry.id)
		let reflection = try await claim(repository, stage: .reflect)
		_ = try await repository.commitReflection(reflectionResult, lease: reflection)
		let extraction = try await claim(repository, stage: .reminders)
		let rule = entry.reminders[0]
		let removal = ReminderFeedback(kind: .manualRemoval, text: "Keep removed", focusedReminderID: rule.id)
		let edited = try await repository.apply(.removeReminder(rule.id, removal), to: entry.id)
		let repeated = try await repository.apply(.removeReminder(rule.id, removal), to: entry.id)
		try expect(repeated.entry?.reminderFeedback.count == 1 && repeated.inputRevision == edited.inputRevision,
			"Retrying the same narrow removal must not duplicate feedback or advance inputs twice")
		try await stale { _ = try await repository.commitReminders(.init(reminders: [rule], modelName: "stale"), lease: extraction) }
		let current = try await claim(repository, stage: .reminders)
		_ = try await repository.commitReminders(.init(reminders: [], modelName: "new reminders"), lease: current)
		let committed = try diskRecord(entry.id, root: root)
		try expect(committed.entry?.transcript == "Fresh transcript" && committed.entry?.headline == reflectionResult.headline
			&& committed.entry?.location == location && committed.entry?.reminders.isEmpty == true,
			"Delayed location/reminder edits must preserve newly committed stage outputs")
		let feedback = ReminderFeedback(kind: .voice, text: "Different upcoming event")
		let changed = try await repository.apply(.feedback(feedback), to: entry.id)
		let retried = try await repository.apply(.feedback(feedback), to: entry.id)
		try expect(retried.entry?.reminderFeedback.filter { $0.id == feedback.id }.count == 1
			&& retried.processing?.requestID == changed.processing?.requestID && retried.processing?.stage == .reminders,
			"Retrying committed feedback must retain one feedback ID and one reminder request")
	}

	private static func completionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root, headline: "Processing ideas for next week")
		let migrated = await repository.record(id: entry.id)
		try expect(migrated?.processing?.status == .complete, "An arbitrary completed headline must not trigger a legacy requeue")
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reminders)
		let noEvent = try await claim(repository, stage: .reminders)
		_ = try await repository.commitReminders(nil, lease: noEvent)
		try expect(try diskRecord(entry.id, root: root).processing?.skippedStages.contains(.reminders) == true,
			"A disabled/inapplicable reminder stage must persist an explicit skip")
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reminders)
		let skipped = try await claim(repository, stage: .reminders)
		_ = try await repository.commitReminders(.init(reminders: [], modelName: nil, outcome: .skipped), lease: skipped)
		try expect(try diskRecord(entry.id, root: root).processing?.skippedStages.contains(.reminders) == true,
			"A model's skipped outcome must persist as skipped")
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reminders)
		let emptySuccess = try await claim(repository, stage: .reminders)
		_ = try await repository.commitReminders(.init(reminders: [], modelName: "fixture", outcome: .complete), lease: emptySuccess)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let completed = await restarted.record(id: entry.id)
		let work = try await restarted.claimProcessing(now: .distantFuture)
		try expect(completed?.processing?.status == .complete && completed?.processing?.skippedStages.contains(.reminders) == false && work == nil,
			"Successful extraction of zero reminders must remain distinguishable from skipped and must not requeue")
	}

	private static func migrationChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = JournalEntry(duration: 1, transcript: "Durable original", headline: "Complete legacy note")
		try await repository.save([entry])
		let damagedURL = recordURL(UUID(), root: root)
		let damaged = Data("{ broken processing metadata".utf8)
		try damaged.write(to: damagedURL)
		let loaded = try await JournalRepository(rootURL: root).load()
		try expect(!loaded.issues.isEmpty && loaded.entries == [entry]
			&& loaded.records.first(where: { $0.id == entry.id })?.processing?.status == .complete,
			"One corrupt manifest must not prevent healthy notes from migrating their processing state")
		try expect(try Data(contentsOf: damagedURL) == damaged, "Processing migration must preserve corrupt originals")
		try FileManager.default.removeItem(at: damagedURL)
		let legacy = JournalEntry(duration: 1, transcript: "Readable before a migration write", headline: "Legacy note")
		try await repository.save([legacy])
		let legacyURL = recordURL(legacy.id, root: root)
		let original = try Data(contentsOf: legacyURL)
		let recordsURL = root.appendingPathComponent("Records")
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordsURL.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordsURL.path) }
		let blocked = try await JournalRepository(rootURL: root).load()
		try expect(blocked.entries.count == 2 && !blocked.issues.isEmpty
			&& blocked.records.first(where: { $0.id == legacy.id })?.processing == nil,
			"A real migration write failure must keep readable notes available and leave uncommitted work unclaimed")
		try expect(try Data(contentsOf: legacyURL) == original, "Failed processing migration must preserve original manifest bytes")
	}

	private static var reflectionResult: ReflectionResult {
		ReflectionResult(headline: "Updated reflection", summary: "Fresh complete analysis", modelName: "fixture")
	}

	private static func seed(_ root: URL, headline: String = "Previously completed note") async throws -> (JournalRepository, JournalEntry) {
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let id = UUID()
		let reminder = EventReminderRule(text: "Bring notes", motivation: "Prepare", evidence: "Bring notes",
			selector: .fuzzy(.init(semanticDescription: "Meeting", timeBucket: .any, locationDescription: nil, examples: [])), occurrencePolicy: .everyMatch)
		let entry = JournalEntry(id: id, duration: 0.1, transcript: "Prior complete transcript", summary: "Prior complete analysis",
			headline: headline, audioFilename: "\(id.uuidString).m4a", summaryModel: "old model", transcriptModel: "old speech", reminders: [reminder])
		try writeAudio(root.appendingPathComponent("Recordings/\(entry.audioFilename!)"))
		try await repository.save([entry])
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		return (restarted, entry)
	}

	private static func claim(_ repository: JournalRepository, stage: ProcessingStage) async throws -> ProcessingLease {
		guard let work = try await repository.claimProcessing(), work.lease.stage == stage else {
			throw Failure("Expected claimable \(stage) work")
		}
		return work.lease
	}

	private static func stale(_ operation: () async throws -> Void) async throws {
		do { try await operation(); throw Failure("An obsolete processing result was accepted") }
		catch RepositoryError.staleProcessing {}
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-repository-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private static func recordURL(_ id: UUID, root: URL) -> URL { root.appendingPathComponent("Records/\(id.uuidString).json") }
	private static func diskRecord(_ id: UUID, root: URL) throws -> JournalRecord {
		try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: recordURL(id, root: root)))
	}

	private static func writeAudio(_ url: URL) throws {
		let settings = url.pathExtension == "caf" ? RecordingAudioFormat.pcmSettings : RecordingAudioFormat.captureSettings
		let file = try AVAudioFile(forWriting: url, settings: settings)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)!
		buffer.frameLength = 4_410
		for frame in 0..<4_410 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.1) * 0.05 }
		try file.write(from: buffer)
		file.close()
	}

	private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
		guard try condition() else { throw Failure(message) }
	}
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
}
#endif
