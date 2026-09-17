#if DEBUG
import AVFoundation

@MainActor
enum ReminderFeedbackContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-reminder-feedback-contract-tests") else { return }
		guard !ProcessInfo.processInfo.arguments.contains("-demo-reminder-feedback") else {
			fatalError("Feedback contracts cannot run in feedback visual mode")
		}
		do {
			try await startupOwnership()
			try await durableRetry()
			try await cancellationBoundaries()
			try await failedSpeechAndDeletion()
			try await nativeQuarantine()
			print("REMINDER FEEDBACK CONTRACT: permission ownership, retained audio and completed-text retry, real write faults, exact receipts, cancellation boundaries, deletion, partial speech, and native quarantine passed")
			fflush(stdout)
		} catch { fatalError("REMINDER FEEDBACK CONTRACT: \(error)") }
	}

	private static func startupOwnership() async throws {
		let fixture = try await Fixture.make()
		defer { fixture.clean() }
		let permission = PermissionGate()
		let session = fixture.session(permission: { await permission.request() })
		session.start()
		try await wait { permission.requests.count == 1 }
		let old = session.startupTask!
		let oldURL = session.draftURL!
		try expect(fixture.store.isCapturePriorityActive, "Permission startup must own capture priority")
		session.recordAgain()
		try await wait { permission.requests.count == 2 }
		let current = session.startupTask!
		let currentURL = session.draftURL!
		permission.resolve(0)
		await old.value
		try expect(session.phase == .starting && session.draftURL == currentURL && fixture.store.isCapturePriorityActive,
			"Old granted permission must not change the replacement or release its capture priority")
		try expect(!FileManager.default.fileExists(atPath: oldURL.path) && fixture.backend.devices.isEmpty,
			"Canceled permission must not create invisible audio")
		permission.resolve(1)
		await current.value
		fixture.backend.devices.last?.currentTime = 12
		session.recorder.handleMediaServicesReset()
		try await wait { !fixture.store.isCapturePriorityActive }
		try expect(session.phase == .stopped && session.canSubmit && session.duration == 12,
			"Terminal audio reset must release capture priority and retain submit-ready audio and elapsed time")
		session.cancel()
		try expect(!FileManager.default.fileExists(atPath: currentURL.path), "Cancel must clean the replacement's own temporary audio")
		try expect(try Data(contentsOf: fixture.permanentURL) == Data("Permanent note audio".utf8),
			"Temporary feedback cleanup must never remove the note's permanent source")
	}

	private static func durableRetry() async throws {
		let speech = SpeechProbe()
		let fixture = try await Fixture.make(transcribe: { try await speech.complete($0) })
		defer { fixture.clean() }
		let session = fixture.session()
		try await fixture.capture(session)
		let url = session.draftURL!, id = session.feedbackID
		let bytes = try Data(contentsOf: url)
		let manifest = fixture.manifest
		let held = fixture.root.appendingPathComponent("held-manifest.json")
		try FileManager.default.moveItem(at: manifest, to: held)
		try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
		session.submit()
		await session.submissionTask?.value
		try expect(session.phase == .failed && session.completedTranscription?.transcript == "Bring my notebook.",
			"A real manifest failure must retain the completed correction instead of requiring another speech call")
		try expect(session.draftURL == url && session.feedbackID == id && session.duration == 12 && session.canSubmit,
			"Failed save must retain the original draft, receipt identity and stopped duration")
		try expect(try Data(contentsOf: url) == bytes && !fixture.store.isCapturePriorityActive,
			"Save failure must preserve audio bytes without retaining microphone priority")
		try expect(!fixture.store.hasUnsavedChanges(for: fixture.entry.id), "Feedback failure must not leave an unowned optimistic edit")
		try FileManager.default.removeItem(at: manifest)
		try FileManager.default.moveItem(at: held, to: manifest)
		session.retry()
		await session.submissionTask?.value
		try expect(await speech.calls == 1 && session.hasCommitted, "Save Retry must skip already completed speech")
		let saved = try fixture.record()
		try expect(saved.entry?.reminderFeedback.map(\.id) == [id] && saved.entry?.transcript == fixture.entry.transcript
			&& saved.entry?.headline == fixture.entry.headline, "Only the exact correction may change completed note content")
		try expect(!FileManager.default.fileExists(atPath: url.path), "Successful exact acknowledgement must delete temporary audio")
		let receipt = session.committedFeedback!
		let requestID = saved.processing?.requestID, revision = saved.inputRevision
		_ = try await fixture.store.appendReminderFeedback(entryID: fixture.entry.id, feedback: receipt)
		let repeated = try fixture.record()
		try expect(repeated.entry?.reminderFeedback == [receipt] && repeated.inputRevision == revision
			&& repeated.processing?.requestID == requestID, "Retrying a receipt must neither duplicate feedback nor restart its processing request")
		var conflict = receipt
		conflict.text = "A different correction."
		do {
			_ = try await fixture.store.appendReminderFeedback(entryID: fixture.entry.id, feedback: conflict)
			throw Failure("A reused receipt must not acknowledge different text")
		} catch RepositoryError.feedbackConflict {}

		var attempts = 0
		let lostReceipt = fixture.session(appendFeedback: { entryID, feedback in
			let receipt = try await fixture.store.appendReminderFeedback(entryID: entryID, feedback: feedback)
			attempts += 1
			if attempts == 1 { throw Failure("Fixture lost the acknowledgement after actual commit") }
			return receipt
		})
		try await fixture.capture(lostReceipt)
		lostReceipt.submit()
		await lostReceipt.submissionTask?.value
		let beforeRetry = try fixture.record()
		let stableValue = lostReceipt.pendingFeedback
		try expect(lostReceipt.phase == .failed && beforeRetry.entry?.reminderFeedback.last == stableValue,
			"Lost acknowledgement must retain the exact complete feedback value already saved")
		lostReceipt.retry()
		await lostReceipt.submissionTask?.value
		let afterRetry = try fixture.record()
		try expect(lostReceipt.hasCommitted && lostReceipt.committedFeedback == stableValue && attempts == 2
			&& afterRetry.inputRevision == beforeRetry.inputRevision
			&& afterRetry.processing?.requestID == beforeRetry.processing?.requestID
			&& afterRetry.entry?.reminderFeedback.count == 2,
			"Actual session Retry after lost acknowledgement must reuse the full value and never requeue committed work")
		try expect(await speech.calls == 2, "Lost acknowledgement Retry must not repeat completed speech")
	}

	private static func cancellationBoundaries() async throws {
		let fixture = try await Fixture.make()
		defer { fixture.clean() }
		let before = Gate()
		fixture.store.feedbackAppendCheckpoint = { await before.hold() }
		let session = fixture.session()
		try await fixture.capture(session)
		let url = session.draftURL!
		session.submit()
		let task = session.submissionTask!
		try await wait { before.started }
		session.cancel()
		before.open()
		await task.value
		try expect(try fixture.record().entry?.reminderFeedback.isEmpty == true && !fixture.store.hasUnsavedChanges(for: fixture.entry.id),
			"Cancellation before atomic append must leave neither feedback nor a queued optimistic correction")
		try expect(!FileManager.default.fileExists(atPath: url.path), "Canceled submitted audio must be cleaned")
		fixture.store.feedbackAppendCheckpoint = nil

		let after = Gate()
		fixture.store.feedbackReceiptCheckpoint = { await after.hold() }
		session.recordAgain()
		await session.startupTask?.value
		fixture.backend.devices.last?.currentTime = 12
		session.recorder.pause()
		let committedID = session.feedbackID
		session.submit()
		let savedTask = session.submissionTask!
		try await wait { after.started }
		let committed = try fixture.record()
		try expect(committed.entry?.reminderFeedback.map(\.id) == [committedID], "Receipt checkpoint must follow actual atomic persistence")
		session.recordAgain()
		await session.startupTask?.value
		let replacementURL = session.draftURL!
		after.open()
		await savedTask.value
		try expect(session.phase == .recording && session.draftURL == replacementURL && session.committedFeedback == nil
			&& FileManager.default.fileExists(atPath: replacementURL.path), "A canceled old acknowledgement cannot close or delete a replacement capture")
		try expect(fixture.store.entry(id: fixture.entry.id)?.reminderFeedback.map(\.id) == [committedID],
			"Cancellation after atomic commit must still publish the exact saved receipt")
		fixture.store.feedbackReceiptCheckpoint = nil
		session.cancel()
		let receipt = committed.entry!.reminderFeedback[0]
		_ = try await fixture.store.appendReminderFeedback(entryID: fixture.entry.id, feedback: receipt)
		try expect(try fixture.record().inputRevision == committed.inputRevision,
			"A recovered exact receipt cannot spend a second source revision")
		try await wait { !fixture.store.isCapturePriorityActive }
	}

	private static func failedSpeechAndDeletion() async throws {
		let probe = SpeechProbe()
		let fixture = try await Fixture.make(transcribe: { try await probe.failThenSilence($0) })
		defer { fixture.clean() }
		let session = fixture.session()
		try await fixture.capture(session)
		let url = session.draftURL!
		session.submit()
		await session.submissionTask?.value
		try expect(session.phase == .failed && session.completedTranscription == nil && FileManager.default.fileExists(atPath: url.path),
			"Partial speech failure must preserve audio without treating partial text as complete")
		session.retry()
		await session.submissionTask?.value
		try expect(session.phase == .failed && session.completedTranscription == nil && session.canSubmit,
			"Complete silence must retain a retryable draft and offer Record again")
		try expect(try fixture.record().entry?.reminderFeedback.isEmpty == true, "Neither partial nor empty speech may append a correction")
		session.cancel()

		let gate = Gate()
		fixture.store.feedbackAppendCheckpoint = { await gate.hold() }
		let feedback = ReminderFeedback(kind: .voice, text: "Never resurrect a deleted note.")
		let append = Task { try await fixture.store.appendReminderFeedback(entryID: fixture.entry.id, feedback: feedback) }
		try await wait { gate.started }
		let deleted = await fixture.store.deleteEntry(id: fixture.entry.id)
		gate.open()
		do { _ = try await append.value; throw Failure("Deleted note accepted late feedback") }
		catch ReminderFeedbackError.entryUnavailable {}
		try expect(deleted && fixture.store.entry(id: fixture.entry.id) == nil && (try fixture.record().state) == .deleted,
			"Deletion before append must retain its tombstone and prevent resurrection")

		let speech = Gate()
		let deletedDuringSpeech = try await Fixture.make(transcribe: { _ in
			await speech.hold()
			return .init(transcript: "Too late to append.", modelName: "Fixture")
		})
		defer { deletedDuringSpeech.clean() }
		let lateSession = deletedDuringSpeech.session()
		try await deletedDuringSpeech.capture(lateSession)
		let lateURL = lateSession.draftURL!
		lateSession.submit()
		let lateTask = lateSession.submissionTask!
		try await wait { speech.started }
		try expect(await deletedDuringSpeech.store.deleteEntry(id: deletedDuringSpeech.entry.id), "Fixture deletion must commit during speech")
		speech.open()
		await lateTask.value
		try expect(lateSession.phase == .failed && FileManager.default.fileExists(atPath: lateURL.path)
			&& (try deletedDuringSpeech.record().state) == .deleted,
			"Speech finishing after note deletion must retain a failed draft without resurrecting the note")
		lateSession.cancel()
		try expect(!FileManager.default.fileExists(atPath: lateURL.path), "Explicitly closing the unavailable-note draft must clean its audio")
	}

	private static func nativeQuarantine() async throws {
		let probe = NativeProbe()
		let fixture = try await Fixture.make(transcribe: { _ in
			try await ServiceAdmission.speech.run(timeout: .seconds(10)) { await probe.run() }
		})
		defer { fixture.clean(); Task { await probe.open() } }
		let session = fixture.session()
		try await fixture.capture(session)
		let oldURL = session.draftURL!
		session.submit()
		let oldTask = session.submissionTask!
		try await wait { await probe.starts == 1 }
		session.recordAgain()
		await session.startupTask?.value
		fixture.backend.devices.last?.currentTime = 12
		session.recorder.pause()
		session.submit()
		let queued = session.submissionTask!
		try await wait { await ServiceAdmission.speech.contractState().waiting == 1 }
		session.cancel()
		await queued.value
		try expect(await probe.starts == 1 && !fixture.store.isCapturePriorityActive,
			"Cancel during admission must not start another provider or retain capture priority")
		session.recordAgain()
		await session.startupTask?.value
		fixture.backend.devices.last?.currentTime = 12
		session.recorder.pause()
		let finalID = session.feedbackID
		session.submit()
		let finalTask = session.submissionTask!
		try await wait { await ServiceAdmission.speech.contractState().waiting == 1 }
		await probe.open()
		await oldTask.value
		await finalTask.value
		let maximumActive = await probe.maximumActive, starts = await probe.starts
		try expect(maximumActive == 1 && starts == 2,
			"Canceled native work must hold its actual service slot until it exits")
		try expect(session.hasCommitted && fixture.store.entry(id: fixture.entry.id)?.reminderFeedback.map(\.id) == [finalID]
			&& !FileManager.default.fileExists(atPath: oldURL.path), "Only the replacement correction may commit after old native work exits")
	}

	@MainActor
	private struct Fixture {
		let root: URL
		let entry: JournalEntry
		let store: JournalStore
		let backend = Backend()
		var manifest: URL { root.appendingPathComponent("Records/\(entry.id.uuidString).json") }
		var permanentURL: URL { root.appendingPathComponent("Recordings/\(entry.audioFilename!)") }

		static func make(transcribe: @escaping @Sendable (URL) async throws -> TranscriptionResult = { _ in
			TranscriptionResult(transcript: "Bring my notebook.", modelName: "Fixture")
		}) async throws -> Fixture {
			let root = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-contract-\(UUID())")
			try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
			let entry = JournalEntry(duration: 30, transcript: "Previously completed transcript.", headline: "Previously completed analysis",
				audioFilename: "\(UUID()).m4a")
			try Data("Permanent note audio".utf8).write(to: root.appendingPathComponent("Recordings/\(entry.audioFilename!)"))
			try JSONEncoder().encode([entry]).write(to: root.appendingPathComponent("entries.json"))
			let services = ProcessingServices(transcribe: { url, _, _, _ in try await transcribe(url) },
				reflect: { _, _ in ReflectionResult(headline: "Unused", modelName: "Fixture") },
				reminders: { _ in ReminderParsingResult(reminders: [], modelName: "Fixture") })
			let store = JournalStore(storageRootURL: root, processingServices: services)
			try await store.waitUntilLoaded()
			store.updateSetting(\.eventRemindersEnabled, false)
			await store.waitForConfigurationWritesForContract()
			return Fixture(root: root, entry: entry, store: store)
		}
		func session(permission: @escaping @MainActor () async -> Bool = { true },
			appendFeedback: ((UUID, ReminderFeedback) async throws -> ReminderFeedback)? = nil) -> ReminderFeedbackSession {
			let recorder = AudioRecorder(permissionRequest: permission, hardware: RecordingHardware(
				makeRecorder: { try backend.make($0) }, activate: { _ in }, deactivate: { _ in }), observeSession: false)
			return ReminderFeedbackSession(store: store, entryID: entry.id, recorder: recorder,
				makeTemporaryURL: { root.appendingPathComponent("reminder-feedback-\(UUID()).m4a") }, appendFeedback: appendFeedback)
		}
		func capture(_ session: ReminderFeedbackSession) async throws {
			session.start()
			await session.startupTask?.value
			backend.devices.last?.currentTime = 12
			session.recorder.pause()
			try expect(session.canSubmit && store.isCapturePriorityActive, "Fixture must own real session capture intent before submitting")
		}
		func record() throws -> JournalRecord { try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: manifest)) }
		func clean() { try? FileManager.default.removeItem(at: root) }
	}

	@MainActor
	private final class Backend {
		var devices: [Device] = []
		func make(_ url: URL) throws -> Device { let value = Device(url: url); devices.append(value); return value }
	}
	@MainActor
	private final class Device: AudioRecordingDevice {
		let url: URL
		var currentTime: TimeInterval = 0
		var isRecording = false
		var isMeteringEnabled = false
		weak var delegate: (any AVAudioRecorderDelegate)?
		init(url: URL) { self.url = url }
		func prepareToRecord() -> Bool { (try? Data("Owned feedback audio fixture".utf8).write(to: url)) != nil }
		func record() -> Bool { isRecording = true; return true }
		func pause() { isRecording = false }
		func stop() { isRecording = false }
		func updateMeters() {}
		func averagePower(forChannel channelNumber: Int) -> Float { -20 }
	}
	@MainActor
	private final class Gate {
		var started = false
		private var continuation: CheckedContinuation<Void, Never>?
		func hold() async { started = true; await withCheckedContinuation { continuation = $0 } }
		func open() { continuation?.resume(); continuation = nil }
	}
	@MainActor
	private final class PermissionGate {
		var requests: [CheckedContinuation<Bool, Never>?] = []
		func request() async -> Bool { await withCheckedContinuation { requests.append($0) } }
		func resolve(_ index: Int) { requests[index]?.resume(returning: true); requests[index] = nil }
	}
	private actor SpeechProbe {
		var calls = 0
		func complete(_ url: URL) throws -> TranscriptionResult {
			calls += 1
			guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("Draft was deleted before speech") }
			return .init(transcript: "Bring my notebook.", modelName: "Fixture")
		}
		func failThenSilence(_ url: URL) throws -> TranscriptionResult {
			calls += 1
			if calls == 1 { throw TranscriptionFailure(category: .serviceFailure, message: "Unavailable",
				partial: .init(transcript: "Partial must not save", modelName: "Fixture")) }
			return .init(transcript: " \n ", modelName: "Fixture")
		}
	}
	private actor NativeProbe {
		var starts = 0
		var active = 0
		var maximumActive = 0
		var continuation: CheckedContinuation<Void, Never>?
		func run() async -> TranscriptionResult {
			starts += 1
			active += 1
			maximumActive = max(maximumActive, active)
			if starts == 1 { await withCheckedContinuation { continuation = $0 } }
			active -= 1
			return .init(transcript: "Bring my notebook.", modelName: "Held fixture")
		}
		func open() { continuation?.resume(); continuation = nil }
	}
	private static func wait(_ condition: () async -> Bool) async throws {
		let until = ContinuousClock.now.advanced(by: .seconds(5))
		while !(await condition()) {
			guard ContinuousClock.now < until else { throw Failure("Timed out at a feedback ownership boundary") }
			try await Task.sleep(for: .milliseconds(1))
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
