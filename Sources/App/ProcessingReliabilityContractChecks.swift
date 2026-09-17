#if DEBUG
import Foundation

@MainActor
enum ProcessingReliabilityContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-processing-reliability-contract-tests") else { return }
		do {
			try await retryChecks()
			try await preemptionChecks()
			try await admittedDeadlineChecks()
			try temporaryFileChecks()
			print("PROCESSING RELIABILITY CONTRACT: persisted finite retries, admitted deadlines, capture/background ownership, native quarantine, and startup temporary cleanup passed")
			fflush(stdout)
		} catch { fatalError("PROCESSING RELIABILITY CONTRACT: \(error)") }
	}

	private static func retryChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try seed(root)
		var repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reflect)
		var now = Date.now
		for failure in 1...4 {
			guard let work = try await repository.claimProcessing(now: now) else { throw Failure("Expected a due attempt") }
			let saved = try await repository.failProcessing(work.lease, message: "Transient fixture failure", now: now)
			try expect(saved.processing?.failedAttempts == failure, "Failure budget must increment atomically")
			if let delay = EntryProcessing.retryDelay(after: failure) {
				try expect(saved.processing?.retryAfter == now.addingTimeInterval(delay), "Retry delay must be persisted at failure commit")
				try expect(try await repository.claimProcessing(now: now.addingTimeInterval(delay - 1)) == nil, "Backoff must prevent immediate retries")
				now = now.addingTimeInterval(delay)
			} else {
				try expect(saved.processing?.retryAfter == nil, "Exhausted retries must require manual action")
			}
			do {
				_ = try await repository.failProcessing(work.lease, message: "Late duplicate", now: now)
				throw Failure("A completed lease cannot spend another retry")
			} catch RepositoryError.staleProcessing {}
			repository = JournalRepository(rootURL: root)
			_ = try await repository.load()
			try expect(await repository.record(id: entry.id)?.processing?.failedAttempts == failure, "Relaunch cannot reset the retry budget")
		}
		try expect(try await repository.claimProcessing(now: .distantFuture) == nil, "Exhausted jobs must remain stopped after relaunch")
		try expect(await repository.nextProcessingRetry() == nil, "Exhausted jobs must not schedule a timer")
		let reset = try await repository.retryProcessing(id: entry.id)
		try expect(reset.processing?.failedAttempts == 0, "Explicit Retry intentionally resets the budget")
		let first = try await requireWork(repository)
		_ = try await repository.failProcessing(first.lease, message: "Temporary", now: now)
		let retried = try await requireWork(repository, now: .distantFuture)
		repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		try expect(await repository.record(id: entry.id)?.processing?.failedAttempts == 1, "Interrupted running jobs retain prior failures")
		let restarted = try await requireWork(repository)
		do {
			_ = try await repository.commitReflection(ReflectionResult(headline: "Stale", modelName: "Fixture"), lease: retried.lease)
			throw Failure("A pre-restart attempt cannot commit")
		} catch RepositoryError.staleProcessing {}
		let advanced = try await repository.commitReflection(ReflectionResult(headline: "Saved", modelName: "Fixture"), lease: restarted.lease)
		try expect(advanced.processing?.stage == .reminders && advanced.processing?.failedAttempts == 0, "Advancing starts a fresh stage budget")
		let reminders = try await requireWork(repository)
		let unavailable = try await repository.failProcessing(reminders.lease, message: "No model", kind: .unavailable)
		try expect(unavailable.processing?.retryAfter == nil, "Unavailable services wait for explicit retry")
		_ = try await repository.retryProcessing(id: entry.id)
		let unreadableWork = try await requireWork(repository)
		let unreadable = try await repository.failProcessing(unreadableWork.lease, message: "Unreadable input", kind: .unreadableAudio)
		try expect(unreadable.processing?.retryAfter == nil, "Unreadable input cannot enter a pointless automatic loop")
		let manifest = root.appendingPathComponent("Records/\(entry.id.uuidString).json")
		var old = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
		var oldJob = old["processing"] as! [String: Any]
		oldJob.removeValue(forKey: "failedAttempts")
		old["processing"] = oldJob
		try JSONSerialization.data(withJSONObject: old).write(to: manifest)
		let migrated = try await JournalRepository(rootURL: root).load()
		try expect(migrated.records.first?.processing?.failedAttempts == 0, "Ticket06 manifests decode without retry counters")
		var long = entry
		long.duration = 10 * 60 * 60
		try expect(ProcessingDeadline.seconds(stage: .transcribe, entry: long) > long.duration,
			"Unlimited recordings must not inherit a fixed short transcription cutoff")
		long.transcript = String(repeating: "Whole memo ", count: 20_000)
		try expect(ProcessingDeadline.seconds(stage: .reminders, entry: long) > ProcessingDeadline.seconds(stage: .reminders, entry: entry),
			"Analysis budgets must scale with input size")
	}

	private static func preemptionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try seed(root)
		let native = NativeProbe()
		let services = ProcessingServices(transcribe: { _, _, _, _ in
			try await ServiceAdmission.speech.run(timeout: .seconds(2)) { try await native.run() }
		}, reflect: { _, _ in ReflectionResult(headline: "Finished", modelName: "Fixture") },
			reminders: { _ in ReminderParsingResult(reminders: [], modelName: "Fixture") })
		let store = JournalStore(storageRootURL: root, processingServices: services)
		try await store.waitUntilLoaded()
		store.settings.eventRemindersEnabled = false
		store.reprocessEntry(id: entry.id)
		let owner = UUID(), otherOwner = UUID()
		do {
			try await wait { await native.starts == 1 }
			let initial = try lease(store, id: entry.id)
			let start = ContinuousClock.now
			await store.beginCapturePriority(owner: owner)
			try expect(start.duration(to: .now) < .seconds(1), "Capture must not wait for uncooperative processing cleanup")
			await store.beginCapturePriority(owner: otherOwner)
			store.resumeStaleProcessing()
			await store.endCapturePriority(owner: owner)
			try expect(store.isCapturePriorityActive, "One owner's release cannot release another capture")
			try await wait { store.processingStates[entry.id]?.status == .queued }
			try expect(store.processingStates[entry.id]?.failedAttempts == 0, "Capture preemption must not spend a retry")
			try expect(store.entry(id: entry.id)?.transcript == entry.transcript, "Canceled late output cannot replace completed text")
			await store.endCapturePriority(owner: otherOwner)
			try await wait { store.processingStates[entry.id]?.status == .running }
			try expect(await native.starts == 1, "The canceled native call keeps its permit while draining")
			await native.finish("Late canceled output")
			try await wait { await native.starts == 2 }
			try expect(store.entry(id: entry.id)?.transcript == entry.transcript, "A late native response must be discarded")
			store.expireBackgroundProcessing(lease: initial)
			try expect(store.processingStates[entry.id]?.status == .running, "An old expiration callback cannot stop a newer lease")
			let current = try lease(store, id: entry.id)
			store.expireBackgroundProcessing(lease: current, registration: UUID())
			try expect(store.processingStates[entry.id]?.status == .running, "An ended assertion cannot expire the same still-unwinding lease")
			store.expireBackgroundProcessing(lease: current)
			try await wait { store.processingStates[entry.id]?.status == .queued }
			await native.finish("Expired output")
			try await Task.sleep(for: .milliseconds(30))
			try expect(await native.starts == 2, "Background expiration must hold subsequent work")
			await store.beginCapturePriority(owner: owner)
			store.resumeStaleProcessing()
			try await Task.sleep(for: .milliseconds(30))
			try expect(await native.starts == 2, "Foreground cannot override capture priority")
			await store.endCapturePriority(owner: owner)
			try await wait { await native.starts == 3 }
			await native.finish("Completed after foreground")
			try await wait { store.processingStates[entry.id]?.status == .complete }
			try expect(await native.maximumActive == 1, "No native transcription overlap is allowed after preemption")
		} catch {
			await store.endCapturePriority(owner: owner)
			await store.endCapturePriority(owner: otherOwner)
			await native.finish("Fixture cleanup")
			throw error
		}
	}

	private static func admittedDeadlineChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try seed(root)
		let blocker = NativeProbe(), native = NativeProbe()
		let occupied = Task { try await ServiceAdmission.speech.run { try await blocker.run() } }
		let services = ProcessingServices(transcribe: { _, _, _, _ in
			try await ServiceAdmission.speech.run(timeout: .seconds(5)) { try await native.run() }
		}, reflect: { _, _ in ReflectionResult(headline: "Retried successfully", modelName: "Fixture") },
			reminders: { _ in ReminderParsingResult(reminders: [], modelName: "Fixture") })
		let store = JournalStore(storageRootURL: root, processingServices: services)
		do {
			try await wait { await blocker.starts == 1 }
			try await store.waitUntilLoaded()
			store.settings.eventRemindersEnabled = false
			store.processingDeadlineOverride = 0.04
			store.reprocessEntry(id: entry.id)
			try await wait { store.processingStates[entry.id]?.status == .running }
			try await Task.sleep(for: .milliseconds(100))
			try expect(store.processingStates[entry.id]?.status == .running && store.processingStates[entry.id]?.failedAttempts == 0,
				"Waiting longer than the stage budget must not spend admitted time")
			await blocker.finish("Release occupied service")
			_ = try await occupied.value
			try await wait { await native.starts == 1 }
			try await wait { store.processingStates[entry.id]?.status == .failed }
			try expect(store.processingStates[entry.id]?.failedAttempts == 1 && store.processingStates[entry.id]?.retryAfter != nil,
				"Admitted-time expiry must persist finite failure/backoff")
			try expect(store.entry(id: entry.id)?.transcript == entry.transcript,
				"An expired stage preserves the prior completed result")
			let persisted = try JSONDecoder().decode(JournalRecord.self,
				from: Data(contentsOf: root.appendingPathComponent("Records/\(entry.id.uuidString).json")))
			try expect(persisted.processing?.failedAttempts == 1, "Timeout retry state must be durable")
			store.processingDeadlineOverride = 2
			store.retryProcessingEntry(id: entry.id)
			try await wait { store.processingStates[entry.id]?.status == .running }
			try expect(await native.starts == 1, "Timeout cannot free an uncooperative native permit")
			await native.finish("Late expired value")
			try await wait { await native.starts == 2 }
			await native.finish("Fresh admitted response")
			try await wait { store.processingStates[entry.id]?.status == .complete }
			try expect(store.entry(id: entry.id)?.transcript == "Fresh admitted response",
				"A stale activity callback cannot expire or commit over the replacement attempt")
		} catch {
			occupied.cancel()
			await blocker.finish("Fixture cleanup")
			await native.finish("Fixture cleanup")
			_ = try? await occupied.value
			throw error
		}
	}

	private static func temporaryFileChecks() throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let oldNames = ["speech-input-\(UUID()).caf", "elevenlabs-\(UUID()).multipart", "reminder-feedback-\(UUID()).m4a"]
		let protectedNames = ["speech-input-original.caf", "elevenlabs-\(UUID()).m4a", "\(UUID()).m4a", "speech-input-\(UUID()).caf"]
		for name in oldNames + protectedNames { try Data([1]).write(to: root.appendingPathComponent(name)) }
		let cutoff = Date.now.addingTimeInterval(-5)
		for name in oldNames { try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(-5)], ofItemAtPath: root.appendingPathComponent(name).path) }
		let folder = root.appendingPathComponent("speech-input-\(UUID()).caf")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
		try expect(ProcessingTemporaryFiles.clean(in: root, before: cutoff).isEmpty, "Owned temporary cleanup should succeed")
		try expect(oldNames.allSatisfy { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }, "Only abandoned owned files should be removed")
		try expect(protectedNames.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
			&& FileManager.default.fileExists(atPath: folder.path), "Original, unrelated, current-process files and directories must survive")
	}

	private actor NativeProbe {
		var starts = 0
		var active = 0
		var maximumActive = 0
		var continuation: CheckedContinuation<TranscriptionResult, any Error>?
		func run() async throws -> TranscriptionResult {
			starts += 1; active += 1; maximumActive = max(maximumActive, active)
			defer { active -= 1 }
			return try await withCheckedThrowingContinuation { continuation = $0 }
		}
		func finish(_ text: String) {
			continuation?.resume(returning: TranscriptionResult(transcript: text, modelName: "Fixture"))
			continuation = nil
		}
	}
	private static func seed(_ root: URL) throws -> JournalEntry {
		let entry = JournalEntry(duration: 30, transcript: "Previously completed", headline: "Saved title", audioFilename: "\(UUID()).m4a")
		try JSONEncoder().encode([entry]).write(to: root.appendingPathComponent("entries.json"))
		return entry
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-reliability-\(UUID())")
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
		return root
	}
	private static func requireWork(_ repository: JournalRepository, now: Date = .now) async throws -> ProcessingWork {
		guard let work = try await repository.claimProcessing(now: now) else { throw Failure("Expected queued work") }
		return work
	}
	private static func lease(_ store: JournalStore, id: UUID) throws -> ProcessingLease {
		guard let job = store.processingStates[id], let attempt = job.attemptID else { throw Failure("Expected an active lease") }
		return ProcessingLease(entryID: id, requestID: job.requestID, attemptID: attempt, inputRevision: job.inputRevision, stage: job.stage)
	}
	private static func wait(_ condition: () async -> Bool) async throws {
		let until = ContinuousClock.now.advanced(by: .seconds(5))
		while !(await condition()) {
			guard ContinuousClock.now < until else { throw Failure("Timed out at an ownership boundary") }
			try await Task.sleep(for: .milliseconds(1))
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
