import AVFoundation
import Foundation
import Observation
import Speech

struct FinishedRecording: Sendable {
	var url: URL
	var duration: TimeInterval
}

enum RecordingError: LocalizedError {
	case microphonePermissionDenied
	case couldNotStart

	var errorDescription: String? {
		switch self {
		case .microphonePermissionDenied:
			"Microphone access is required to record a journal entry."
		case .couldNotStart:
			"The recording could not be started."
		}
	}
}

@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
	private(set) var isRecording = false
	private(set) var isPaused = false
	private(set) var duration: TimeInterval = 0
	private(set) var levels = Array(repeating: 0.08, count: 46)
	private(set) var statusMessage: String?

	@ObservationIgnored private var recorder: AVAudioRecorder?
	@ObservationIgnored private var meterTimer: Timer?
	@ObservationIgnored private var outputURL: URL?
	@ObservationIgnored private var interruptionTask: Task<Void, Never>?
	@ObservationIgnored private var routeChangeTask: Task<Void, Never>?
	@ObservationIgnored private var wasRecordingBeforeInterruption = false

	override init() {
		super.init()
		observeAudioSession()
	}

	deinit {
		interruptionTask?.cancel()
		routeChangeTask?.cancel()
	}

	func start(at url: URL) async throws {
		guard await requestMicrophonePermission() else {
			throw RecordingError.microphonePermissionDenied
		}

		#if os(iOS)
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
		try session.setActive(true)
		#endif

		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
			AVSampleRateKey: 44_100,
			AVNumberOfChannelsKey: 1,
			AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
		]
		let recorder = try AVAudioRecorder(url: url, settings: settings)
		recorder.delegate = self
		recorder.isMeteringEnabled = true
		recorder.prepareToRecord()
		try makeFileRecoverable(at: url)
		guard recorder.record() else { throw RecordingError.couldNotStart }

		self.recorder = recorder
		outputURL = url
		duration = 0
		levels = Array(repeating: 0.08, count: 46)
		isPaused = false
		isRecording = true
		statusMessage = nil
		startMetering()
	}

	func togglePause() {
		guard let recorder else { return }
		if isPaused {
			do {
				#if os(iOS)
				try AVAudioSession.sharedInstance().setActive(true)
				#endif
				guard recorder.record() else { return }
				isPaused = false
				statusMessage = nil
				startMetering()
			} catch {
				statusMessage = "Recording is safely paused until the microphone is available."
			}
		} else {
			recorder.pause()
			isPaused = true
			stopMetering()
		}
	}

	func finish() -> FinishedRecording? {
		guard let recorder, let outputURL else { return nil }
		let finalDuration = recorder.currentTime
		stopMetering()
		isRecording = false
		isPaused = false
		recorder.stop()
		self.recorder = nil
		self.outputURL = nil
		statusMessage = nil
		deactivateSession()
		return FinishedRecording(url: outputURL, duration: finalDuration)
	}

	func cancel() -> URL? {
		let url = outputURL
		stopMetering()
		isRecording = false
		isPaused = false
		recorder?.stop()
		recorder = nil
		outputURL = nil
		if let url { try? FileManager.default.removeItem(at: url) }
		statusMessage = nil
		deactivateSession()
		return url
	}

	private func requestMicrophonePermission() async -> Bool {
		return await AVAudioApplication.requestRecordPermission()
	}

	private func startMetering() {
		meterTimer?.invalidate()
		let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.updateMeters() }
		}
		RunLoop.main.add(timer, forMode: .common)
		meterTimer = timer
	}

	private func stopMetering() {
		meterTimer?.invalidate()
		meterTimer = nil
	}

	private func updateMeters() {
		guard let recorder else { return }
		duration = recorder.currentTime
		guard !isPaused else { return }
		recorder.updateMeters()
		let power = recorder.averagePower(forChannel: 0)
		let normalized = max(0.08, min(1, pow(10, power / 38)))
		levels.removeFirst()
		levels.append(Double(normalized))
	}

	private func observeAudioSession() {
		#if os(iOS)
		let session = AVAudioSession.sharedInstance()
		interruptionTask = Task { @MainActor [weak self] in
			for await notification in NotificationCenter.default.notifications(
				named: AVAudioSession.interruptionNotification,
				object: session
			) {
				self?.handleInterruption(notification)
			}
		}
		routeChangeTask = Task { @MainActor [weak self] in
			for await _ in NotificationCenter.default.notifications(
				named: AVAudioSession.routeChangeNotification,
				object: session
			) {
				await self?.recoverAfterRouteChange()
			}
		}
		#endif
	}

	#if os(iOS)
	private func handleInterruption(_ notification: Notification) {
		guard isRecording,
			let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: rawType)
		else { return }

		switch type {
		case .began:
			wasRecordingBeforeInterruption = !isPaused
			isPaused = true
			statusMessage = "Recording paused. Your audio is saved on this iPhone."
			stopMetering()
		case .ended:
			guard wasRecordingBeforeInterruption else { return }
			wasRecordingBeforeInterruption = false
			resumeAfterSystemChange()
		@unknown default:
			break
		}
	}

	private func recoverAfterRouteChange() async {
		guard isRecording, !isPaused else { return }
		try? await Task.sleep(for: .milliseconds(250))
		guard recorder?.isRecording == false else { return }
		resumeAfterSystemChange()
	}

	private func resumeAfterSystemChange() {
		do {
			try AVAudioSession.sharedInstance().setActive(true)
			guard recorder?.record() == true else {
				statusMessage = "Recording is safely paused until the microphone is available."
				return
			}
			isPaused = false
			statusMessage = nil
			startMetering()
		} catch {
			statusMessage = "Recording is safely paused until the microphone is available."
		}
	}
	#endif

	private func makeFileRecoverable(at url: URL) throws {
		#if os(iOS)
		try FileManager.default.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: url.path
		)
		#endif
		var url = url
		var values = URLResourceValues()
		values.isExcludedFromBackup = false
		try url.setResourceValues(values)
	}

	private func deactivateSession() {
		#if os(iOS)
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		#endif
	}

	nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		guard !flag else { return }
		Task { @MainActor [weak self] in
			guard let self, self.isRecording else { return }
			self.isPaused = true
			self.stopMetering()
			self.statusMessage = "Recording stopped unexpectedly, but everything captured so far is saved."
		}
	}

	nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
		Task { @MainActor [weak self] in
			guard let self, self.isRecording else { return }
			self.isPaused = true
			self.stopMetering()
			self.statusMessage = "Recording stopped unexpectedly, but everything captured so far is saved."
		}
	}
}

enum LocalTranscriber {
	static func transcribe(
		url: URL,
		onUpdate: @escaping @Sendable (String) -> Void = { _ in }
	) async throws -> String {
		let authorized = await withCheckedContinuation { continuation in
			SFSpeechRecognizer.requestAuthorization { status in
				continuation.resume(returning: status == .authorized)
			}
		}
		guard authorized, let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
			return ""
		}

		let request = SFSpeechURLRecognitionRequest(url: url)
		request.requiresOnDeviceRecognition = true
		request.shouldReportPartialResults = true

		return try await withCheckedThrowingContinuation { continuation in
			let state = RecognitionState(continuation: continuation)
			recognizer.recognitionTask(with: request) { result, error in
				if let error {
					state.fail(error)
				} else if let result {
					let transcript = result.bestTranscription.formattedString
					onUpdate(transcript)
					if result.isFinal { state.finish(transcript) }
				}
			}
		}
	}
}

private final class RecognitionState: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<String, any Error>?

	init(continuation: CheckedContinuation<String, any Error>) {
		self.continuation = continuation
	}

	func finish(_ transcript: String) {
		lock.lock()
		let continuation = self.continuation
		self.continuation = nil
		lock.unlock()
		continuation?.resume(returning: transcript)
	}

	func fail(_ error: any Error) {
		lock.lock()
		let continuation = self.continuation
		self.continuation = nil
		lock.unlock()
		continuation?.resume(throwing: error)
	}
}
