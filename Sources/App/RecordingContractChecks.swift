#if DEBUG
import AVFoundation

@MainActor
enum RecordingContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-recording-contract-tests") else { return }
		guard ProcessInfo.processInfo.arguments.contains("-demo"),
			!ProcessInfo.processInfo.arguments.contains("-demo-recording")
		else { fatalError("Recording contract checks require -demo without -demo-recording") }
		do {
			try await run()
			try await runCaptureStateChecks()
			try await runDurabilityChecks()
			print("RECORDING CONTRACT: startup cancellation, route/pause races, interruption recovery, reset preservation, stale callbacks, durable finish/discard retries, and cancelled permission after failed discard passed")
			fflush(stdout)
		} catch {
			fatalError("RECORDING CONTRACT: \(error)")
		}
	}

	private static func run() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("recording-contract-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let store = JournalStore(storageRootURL: root)
		let permission = PermissionGate()
		let recorder = AudioRecorder(permissionRequest: { await permission.request() })
		let session = RecordingSession(store: store, recorder: recorder)
		let recordsURL = root.appendingPathComponent("Records")

		session.present(startsImmediately: true)
		try await permission.waitForRequest(1)
		let cancelledStart = session.startupTask!
		let originalContext = session.context?.id
		session.present(startsImmediately: true)
		try expect(session.context?.id == originalContext, "Opening the recorder again must preserve its session")
		try expect(permission.requests.count == 1, "One session must not create competing microphone requests")
		await session.discard()
		permission.resolve(0, granted: true)
		await cancelledStart.value
		await store.waitForPendingWrites()
		try expect(!recorder.isRecording && session.context == nil, "Granting permission after discard must not start invisible capture")

		try expect(try recordingFiles(in: root).isEmpty, "Cancelled startup must not create orphan audio")

		session.present(startsImmediately: true)
		try await permission.waitForRequest(2)
		let failedStart = session.startupTask!
		permission.resolve(1, granted: false)
		await failedStart.value
		await store.waitForPendingWrites()
		try expect(session.errorMessage != nil && session.context != nil, "A denied microphone must keep the error visible until acknowledged")

		await session.discard()

		session.present(startsImmediately: true)
		try await permission.waitForRequest(3)
		let oldStart = session.startupTask!
		await session.discard()
		session.present(startsImmediately: true)
		try await permission.waitForRequest(4)
		let newStart = session.startupTask!
		let newContext = session.context?.id
		await store.waitForPendingWrites()
		let manifests = try FileManager.default.contentsOfDirectory(at: recordsURL, includingPropertiesForKeys: nil)
		let pendingURL = try manifests.first { url in
			try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: url)).state == .recording
		}!
		let newPending = try Data(contentsOf: pendingURL)
		permission.resolve(2, granted: true)
		await oldStart.value
		try expect(session.context?.id == newContext && session.errorMessage == nil, "The old permission result must not dismiss or fail the replacement session")
		try expect(try Data(contentsOf: pendingURL) == newPending, "The old completion must not remove the replacement session's recovery metadata")
		try expect(!recorder.isRecording, "The old session must not start capture while the replacement awaits permission")
		await session.discard()
		permission.resolve(3, granted: true)
		await newStart.value
		await store.waitForPendingWrites()
		try expect(!recorder.isRecording && session.context == nil, "The replacement startup must also be cancellable")
		try expect(try recordingFiles(in: root).isEmpty, "Neither cancelled generation may leave audio behind")
	}

	private static func runCaptureStateChecks() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("capture-state-contract-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let backend = CaptureBackend()
		let delay = RecoveryGate()
		let recorder = AudioRecorder(
			permissionRequest: { true },
			hardware: RecordingHardware(
				makeRecorder: { try backend.makeRecorder(at: $0) },
				activate: { _ in try backend.activate() },
				deactivate: { _ in backend.deactivations += 1 }
			),
			recoveryDelay: { await delay.wait() },
			observeSession: false
		)
		let firstURL = root.appendingPathComponent("first.m4a")
		try await recorder.start(at: firstURL)
		let first = backend.devices[0]
		first.currentTime = 8
		first.isRecording = false
		recorder.handleRouteChange()
		let pausedRecovery = recorder.routeRecoveryTask!
		try await delay.waitForRequest(1)
		try expect(recorder.isPaused && recorder.wantsToRecord, "Lost input must freeze elapsed state while preserving automatic resume intent")
		recorder.togglePause()
		delay.resolve(0)
		await pausedRecovery.value
		try expect(recorder.state == .pausedByUser && !recorder.wantsToRecord && first.recordCalls == 1, "A Pause tap during delayed route recovery must cancel automatic resume")

		recorder.togglePause()
		try expect(recorder.isRecording && first.recordCalls == 2, "Explicit Resume must restart the paused device")
		recorder.handleInterruption(interruption(.began))
		backend.activationShouldFail = true
		recorder.handleInterruption(interruption(.ended))
		try expect(recorder.state == .waitingForInput && recorder.isPaused && recorder.wantsToRecord, "Failed interruption resume must report waiting, not active capture")
		backend.activationShouldFail = false
		recorder.handleRouteChange()
		let recoveredInput = recorder.routeRecoveryTask!
		try await delay.waitForRequest(2)
		delay.resolve(1)
		await recoveredInput.value
		try expect(recorder.isRecording && first.recordCalls == 3, "A later route becoming available must recover a failed interruption resume")
		first.isRecording = false
		recorder.handleRouteChange()
		let naturallyRecoveredInput = recorder.routeRecoveryTask!
		try await delay.waitForRequest(3)
		first.isRecording = true
		delay.resolve(2)
		await naturallyRecoveredInput.value
		try expect(recorder.isRecording && first.recordCalls == 3, "If the device recovers during the delay, observed state must recover without restarting it")

		recorder.handleInterruption(interruption(.began))
		recorder.togglePause()
		recorder.handleInterruption(interruption(.ended))
		try expect(recorder.state == .pausedByUser && first.recordCalls == 3, "A user pause during interruption must suppress automatic resume")
		recorder.togglePause()
		first.isRecording = false
		first.canRecord = false
		recorder.handleRouteChange()
		let failedInput = recorder.routeRecoveryTask!
		try await delay.waitForRequest(4)
		delay.resolve(3)
		await failedInput.value
		try expect(recorder.state == .waitingForInput && !recorder.isRecording, "A false device.record result must never advertise active capture")
		first.canRecord = true
		recorder.handleRouteChange()
		let obsoleteRecovery = recorder.routeRecoveryTask!
		try await delay.waitForRequest(5)
		_ = recorder.cancel()
		let secondURL = root.appendingPathComponent("second.m4a")
		try await recorder.start(at: secondURL)
		let second = backend.devices[1]
		second.isRecording = false
		delay.resolve(4)
		await obsoleteRecovery.value
		try expect(second.recordCalls == 1, "A route callback from the old recording must not operate on its replacement")
		second.isRecording = true
		second.currentTime = 12
		recorder.pause()
		recorder.togglePause()
		second.currentTime = 0
		let preserved = try Data(contentsOf: secondURL)
		recorder.handleMediaServicesReset()
		try expect(recorder.state == .stopped(.mediaServicesReset) && recorder.isPaused && recorder.hasRecording && !recorder.canTogglePause, "Media reset must expose stopped, finishable capture instead of offering destructive Resume")
		try expect(recorder.duration == 12, "An invalidated device clock must not erase already observed elapsed time")
		recorder.togglePause()
		recorder.handleRouteChange()
		try expect(second.recordCalls == 2 && backend.devices.count == 2, "Reset must not reopen or overwrite the current recording")
		try expect(try Data(contentsOf: secondURL) == preserved, "Reset must preserve captured file bytes")
		let finished = recorder.finish()
		try expect(finished?.url == secondURL && finished?.duration == 12, "A stopped recording must remain finishable")
		try expect(try Data(contentsOf: secondURL) == preserved, "Finish must retain reset capture bytes")

		try await recorder.start(at: root.appendingPathComponent("third.m4a"))
		let third = backend.devices[2]
		recorder.handleDeviceFinished(ObjectIdentifier(second), successfully: false)
		try expect(recorder.isRecording && third.isRecording, "A stale recorder delegate must not stop a newer capture")
		recorder.handleDeviceFinished(ObjectIdentifier(third), successfully: false)
		try expect(recorder.state == .stopped(.encodingFailure) && !recorder.canTogglePause, "Encoder failure must stop automatic and manual reuse of the failed recorder")
		_ = recorder.cancel()
	}

	private static func runDurabilityChecks() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("recording-durability-contract-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let store = JournalStore(storageRootURL: root)
		let backend = CaptureBackend()
		let recorder = AudioRecorder(permissionRequest: { true }, hardware: RecordingHardware(
			makeRecorder: { try backend.makeRecorder(at: $0) },
			activate: { _ in }, deactivate: { _ in }), observeSession: false)
		let session = RecordingSession(store: store, recorder: recorder)
		session.present(startsImmediately: true)
		await session.startupTask?.value
		try expect(recorder.isRecording, "The capture fixture must actually enter recording")
		backend.devices[0].currentTime = 12
		let audioURL = backend.devices[0].url
		let id = UUID(uuidString: audioURL.deletingPathExtension().lastPathComponent)!
		let recordURL = root.appendingPathComponent("Records/\(id.uuidString).json")
		let original = try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: recordURL))
		let bytes = try Data(contentsOf: audioURL)
		let heldURL = try blockWrite(to: recordURL, root: root)
		let failedFinish = await session.finish()
		try expect(failedFinish == nil && session.context != nil && session.canFinish && session.saveErrorMessage != nil,
			"A real finish write failure must retain the presentation and retryable finalized recording")
		try expect(!recorder.isRecording && store.entries.isEmpty, "A failed finish must stop capture without publishing a saved note")
		try expect(try Data(contentsOf: audioURL) == bytes, "Failed finish must preserve the original audio bytes")
		try restoreWrite(at: recordURL, from: heldURL)
		let finishedID = await session.finish()
		try expect(finishedID == id && session.context == nil && store.entries.count == 1,
			"Finish retry must commit exactly one note with the original capture ID")
		try expect(store.entries[0].createdAt == original.entry?.createdAt && store.entries[0].duration >= 12,
			"Finish retry must retain the original start date and finalized audio duration")
		let repeatedFinish = await session.finish()
		try expect(repeatedFinish == nil && store.entries.count == 1, "Repeated Finish must not duplicate a committed note")

		session.present(startsImmediately: true)
		await session.startupTask?.value
		backend.devices[1].currentTime = 12
		let discardedAudio = backend.devices[1].url
		let discardedID = UUID(uuidString: discardedAudio.deletingPathExtension().lastPathComponent)!
		let discardedRecord = root.appendingPathComponent("Records/\(discardedID.uuidString).json")
		let discardedBytes = try Data(contentsOf: discardedAudio)
		let heldDiscard = try blockWrite(to: discardedRecord, root: root)
		let failedDiscard = await session.discard()
		try expect(!failedDiscard && session.context != nil && session.canFinish && session.discardErrorMessage != nil,
			"A failed discard tombstone must retain session ownership and explicit retry controls")
		try expect(!recorder.isRecording && session.duration >= 12, "A failed discard must not leave the microphone running")
		try expect(try Data(contentsOf: discardedAudio) == discardedBytes, "Audio must not be removed before deletion intent is durable")
		try restoreWrite(at: discardedRecord, from: heldDiscard)
		let retriedDiscard = await session.discard()
		try expect(retriedDiscard && session.context == nil && !FileManager.default.fileExists(atPath: discardedAudio.path),
			"Discard retry must remove audio and dismiss only after its tombstone is committed")
		let reloaded = try await JournalRepository(rootURL: root).load()
		try expect(reloaded.entries.map(\.id) == [id], "Relaunch must neither duplicate the finished note nor resurrect the discarded capture")

		let permission = PermissionGate()
		let pendingRecorder = AudioRecorder(permissionRequest: { await permission.request() }, observeSession: false)
		let pendingSession = RecordingSession(store: store, recorder: pendingRecorder)
		pendingSession.present(startsImmediately: true)
		try await permission.waitForRequest(1)
		let pendingTask = pendingSession.startupTask!
		let pendingRecord = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Records"), includingPropertiesForKeys: nil).first {
			try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: $0)).state == .recording
		}!
		let heldPending = try blockWrite(to: pendingRecord, root: root)
		let pendingDiscard = await pendingSession.discard()
		try expect(!pendingDiscard && pendingSession.context != nil, "A pending startup must retain its context if its tombstone cannot be written")
		permission.resolve(0, granted: true)
		await pendingTask.value
		try expect(!pendingRecorder.isRecording && pendingSession.discardErrorMessage != nil,
			"Permission granted after failed discard must never restart capture or clear its retry error")
		try restoreWrite(at: pendingRecord, from: heldPending)
		let pendingRetry = await pendingSession.discard()
		try expect(pendingRetry && pendingSession.context == nil, "Pending startup discard must remain retryable after permission resolves")
	}

	private static func blockWrite(to url: URL, root: URL) throws -> URL {
		let preserved = root.appendingPathComponent("held-\(UUID().uuidString).json")
		try FileManager.default.moveItem(at: url, to: preserved)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return preserved
	}

	private static func restoreWrite(at url: URL, from preserved: URL) throws {
		try FileManager.default.removeItem(at: url)
		try FileManager.default.moveItem(at: preserved, to: url)
	}

	private static func interruption(_ type: AVAudioSession.InterruptionType) -> Notification {
		Notification(name: AVAudioSession.interruptionNotification, userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
	}

	@MainActor
	private final class CaptureBackend {
		var devices: [CaptureDevice] = []
		var activationShouldFail = false
		var deactivations = 0

		func makeRecorder(at url: URL) throws -> CaptureDevice {
			let device = CaptureDevice(url: url)
			devices.append(device)
			return device
		}

		func activate() throws {
			if activationShouldFail { throw Failure(message: "Input unavailable") }
		}
	}

	@MainActor
	private final class CaptureDevice: AudioRecordingDevice {
		let url: URL
		var isRecording = false
		var currentTime: TimeInterval = 0
		weak var delegate: (any AVAudioRecorderDelegate)?
		var isMeteringEnabled = false
		var canRecord = true
		var recordCalls = 0

		init(url: URL) { self.url = url }

		func prepareToRecord() -> Bool {
			do {
				let file = try AVAudioFile(forWriting: url, settings: RecordingAudioFormat.captureSettings)
				let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)!
				buffer.frameLength = 44_100
				for index in 0..<44_100 { buffer.floatChannelData![0][index] = 0 }
				for _ in 0..<12 { try file.write(from: buffer) }
				file.close()
				return true
			} catch { return false }
		}

		func record() -> Bool {
			recordCalls += 1
			isRecording = canRecord
			return isRecording
		}

		func pause() { isRecording = false }
		func stop() { isRecording = false }
		func updateMeters() {}
		func averagePower(forChannel channelNumber: Int) -> Float { -20 }
	}

	@MainActor
	private final class RecoveryGate {
		var requests: [CheckedContinuation<Void, Never>?] = []

		func wait() async { await withCheckedContinuation { requests.append($0) } }

		func resolve(_ index: Int) {
			requests[index]?.resume()
			requests[index] = nil
		}

		func waitForRequest(_ count: Int) async throws {
			let deadline = ContinuousClock.now.advanced(by: .seconds(5))
			while requests.count < count {
				guard ContinuousClock.now < deadline else { throw Failure(message: "Route recovery never reached its delay") }
				await Task.yield()
			}
		}
	}

	private static func recordingFiles(in root: URL) throws -> [URL] {
		try FileManager.default.contentsOfDirectory(
			at: root.appendingPathComponent("Recordings", isDirectory: true),
			includingPropertiesForKeys: nil
		)
	}

	private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
		guard try condition() else { throw Failure(message: message) }
	}

	private struct Failure: Error, CustomStringConvertible {
		let message: String
		var description: String { message }
	}

	@MainActor
	private final class PermissionGate {
		var requests: [CheckedContinuation<Bool, Never>?] = []

		func request() async -> Bool {
			await withCheckedContinuation { requests.append($0) }
		}

		func resolve(_ index: Int, granted: Bool) {
			requests[index]?.resume(returning: granted)
			requests[index] = nil
		}

		func waitForRequest(_ count: Int) async throws {
			let deadline = ContinuousClock.now.advanced(by: .seconds(5))
			while requests.count < count {
				guard ContinuousClock.now < deadline else { throw Failure(message: "Microphone request never started") }
				await Task.yield()
			}
		}
	}
}
#endif
