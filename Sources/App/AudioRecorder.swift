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
final class AudioRecorder: NSObject {
	private(set) var isRecording = false
	private(set) var isPaused = false
	private(set) var duration: TimeInterval = 0
	private(set) var levels = Array(repeating: 0.08, count: 46)

	@ObservationIgnored private var recorder: AVAudioRecorder?
	@ObservationIgnored private var meterTimer: Timer?
	@ObservationIgnored private var outputURL: URL?

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
		recorder.isMeteringEnabled = true
		recorder.prepareToRecord()
		guard recorder.record() else { throw RecordingError.couldNotStart }

		self.recorder = recorder
		outputURL = url
		duration = 0
		levels = Array(repeating: 0.08, count: 46)
		isPaused = false
		isRecording = true
		startMetering()
	}

	func togglePause() {
		guard let recorder else { return }
		if isPaused {
			recorder.record()
			isPaused = false
		} else {
			recorder.pause()
			isPaused = true
		}
	}

	func finish() -> FinishedRecording? {
		guard let recorder, let outputURL else { return nil }
		let finalDuration = recorder.currentTime
		recorder.stop()
		stopMetering()
		isRecording = false
		isPaused = false
		self.recorder = nil
		self.outputURL = nil
		deactivateSession()
		return FinishedRecording(url: outputURL, duration: finalDuration)
	}

	func cancel() {
		let url = outputURL
		recorder?.stop()
		stopMetering()
		isRecording = false
		isPaused = false
		recorder = nil
		outputURL = nil
		if let url { try? FileManager.default.removeItem(at: url) }
		deactivateSession()
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

	private func deactivateSession() {
		#if os(iOS)
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		#endif
	}
}

@MainActor
enum LocalTranscriber {
	static func transcribe(url: URL) async throws -> String {
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
		request.shouldReportPartialResults = false

		return try await withCheckedThrowingContinuation { continuation in
			let state = RecognitionState(continuation: continuation)
			recognizer.recognitionTask(with: request) { result, error in
				if let error {
					state.fail(error)
				} else if let result, result.isFinal {
					state.finish(result.bestTranscription.formattedString)
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
