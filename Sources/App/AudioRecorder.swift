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
			"Microphone access is required to record a voice memo."
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
		try Task.checkCancellation()

		let session = AVAudioSession.sharedInstance()
		try session.setCategory(
			.playAndRecord,
			mode: .default,
			options: [.defaultToSpeaker, .allowBluetoothHFP, .bluetoothHighQualityRecording]
		)
		try session.setActive(true)

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
				try AVAudioSession.sharedInstance().setActive(true)
				guard recorder.record() else { return }
				isPaused = false
				statusMessage = nil
				startMetering()
			} catch {
				statusMessage = "Recording paused until the microphone is available."
			}
		} else {
			recorder.pause()
			isPaused = true
			stopMetering()
		}
	}

	func finish() -> FinishedRecording? {
		guard let recorder, let outputURL else { return nil }
		let recorderDuration = recorder.currentTime
		stopMetering()
		isRecording = false
		isPaused = false
		recorder.stop()
		let fileDuration = try? AVAudioFile(forReading: outputURL).duration
		self.recorder = nil
		self.outputURL = nil
		statusMessage = nil
		deactivateSession()
		return FinishedRecording(url: outputURL, duration: fileDuration ?? recorderDuration)
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
	}

	private func handleInterruption(_ notification: Notification) {
		guard isRecording,
			let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: rawType)
		else { return }

		switch type {
		case .began:
			wasRecordingBeforeInterruption = !isPaused
			isPaused = true
			statusMessage = "Recording paused."
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
				statusMessage = "Recording paused until the microphone is available."
				return
			}
			isPaused = false
			statusMessage = nil
			startMetering()
		} catch {
			statusMessage = "Recording paused until the microphone is available."
		}
	}

	private func makeFileRecoverable(at url: URL) throws {
		try FileManager.default.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: url.path
		)
		var url = url
		var values = URLResourceValues()
		values.isExcludedFromBackup = false
		try url.setResourceValues(values)
	}

	private func deactivateSession() {
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

struct TranscriptionResult: Sendable {
	let transcript: String
	let modelName: String
	let warning: String?

	init(transcript: String, modelName: String, warning: String? = nil) {
		self.transcript = transcript
		self.modelName = modelName
		self.warning = warning
	}

	func warningThatElevenLabsFailed(_ reason: String) -> TranscriptionResult {
		TranscriptionResult(
			transcript: transcript,
			modelName: modelName,
			warning: "\(reason) Apple Speech was used instead."
		)
	}
}

enum AudioTranscriber {
	static func transcribe(
		url: URL,
		preferElevenLabs: Bool,
		elevenLabsAPIKey: String? = nil,
		onUpdate: @escaping @Sendable (TranscriptionResult) -> Void = { _ in }
	) async throws -> TranscriptionResult {
		guard preferElevenLabs else {
			return try await transcribeWithApple(url: url, onUpdate: onUpdate)
		}
		guard let apiKey = preferredAPIKey(elevenLabsAPIKey)
			?? ElevenLabsTranscriber.bundledAPIKey
		else {
			do {
				return try await transcribeWithApple(url: url, onUpdate: onUpdate)
					.warningThatElevenLabsFailed(
						"ElevenLabs is enabled, but its API key is missing from this build."
					)
			} catch {
				throw AudioTranscriptionError.allServicesFailed(
					"its API key is missing from this build"
				)
			}
		}

		let appleTask = Task {
			try await transcribeWithApple(url: url, onUpdate: onUpdate)
		}
		do {
			let result = try await ElevenLabsTranscriber.transcribe(url: url, apiKey: apiKey)
			appleTask.cancel()
			_ = try? await appleTask.value
			return result
		} catch {
			guard !Task.isCancelled else {
				appleTask.cancel()
				throw CancellationError()
			}
			let reason = (error as? LocalizedError)?.errorDescription
				?? error.localizedDescription
			do {
				return try await appleTask.value.warningThatElevenLabsFailed(
					"ElevenLabs transcription failed: \(reason)."
				)
			} catch {
				throw AudioTranscriptionError.allServicesFailed(reason)
			}
		}
	}

	private static func preferredAPIKey(_ apiKey: String?) -> String? {
		guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
			!apiKey.isEmpty
		else { return nil }
		return apiKey
	}

	private static func transcribeWithApple(
		url: URL,
		onUpdate: @escaping @Sendable (TranscriptionResult) -> Void
	) async throws -> TranscriptionResult {
		if SpeechTranscriber.isAvailable,
			let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
		{
			let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
			do {
				return try await transcribe(
					url: url,
					with: transcriber,
					modelName: "Apple SpeechTranscriber · \(locale.identifier)",
					onUpdate: onUpdate
				)
			} catch where !Task.isCancelled {}
		}

		if let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
			let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
			return try await transcribe(
				url: url,
				with: transcriber,
				modelName: "Apple DictationTranscriber · \(locale.identifier)",
				onUpdate: onUpdate
			)
		}

		return TranscriptionResult(transcript: "", modelName: "Apple Speech")
	}

	private static func transcribe(
		url: URL,
		with transcriber: SpeechTranscriber,
		modelName: String,
		onUpdate: @escaping @Sendable (TranscriptionResult) -> Void
	) async throws -> TranscriptionResult {
		if let installationRequest = try await AssetInventory.assetInstallationRequest(
			supporting: [transcriber]
		) {
			try await installationRequest.downloadAndInstall()
		}

		let accumulator = TranscriptAccumulator(modelName: modelName, onUpdate: onUpdate)
		let resultsTask = Task {
			for try await result in transcriber.results {
				await accumulator.append(result.text)
			}
		}
		return try await analyze(
			url: url,
			with: transcriber,
			resultsTask: resultsTask,
			accumulator: accumulator
		)
	}

	private static func transcribe(
		url: URL,
		with transcriber: DictationTranscriber,
		modelName: String,
		onUpdate: @escaping @Sendable (TranscriptionResult) -> Void
	) async throws -> TranscriptionResult {
		if let installationRequest = try await AssetInventory.assetInstallationRequest(
			supporting: [transcriber]
		) {
			try await installationRequest.downloadAndInstall()
		}

		let accumulator = TranscriptAccumulator(modelName: modelName, onUpdate: onUpdate)
		let resultsTask = Task {
			for try await result in transcriber.results {
				await accumulator.append(result.text)
			}
		}
		return try await analyze(
			url: url,
			with: transcriber,
			resultsTask: resultsTask,
			accumulator: accumulator
		)
	}

	private static func analyze(
		url: URL,
		with module: any SpeechModule,
		resultsTask: Task<Void, any Error>,
		accumulator: TranscriptAccumulator
	) async throws -> TranscriptionResult {
		let file = try AVAudioFile(forReading: url)
		let analyzer = SpeechAnalyzer(modules: [module])

		do {
			if let lastSample = try await analyzer.analyzeSequence(from: file) {
				try await analyzer.finalizeAndFinish(through: lastSample)
			} else {
				await analyzer.cancelAndFinishNow()
			}
			try await resultsTask.value
			return await accumulator.result
		} catch {
			await analyzer.cancelAndFinishNow()
			resultsTask.cancel()
			_ = try? await resultsTask.value
			let partialResult = await accumulator.result
			guard partialResult.transcript.isEmpty else { return partialResult }
			throw error
		}
	}
}

private enum AudioTranscriptionError: LocalizedError {
	case allServicesFailed(String)

	var errorDescription: String? {
		switch self {
		case let .allServicesFailed(elevenLabsReason):
			"ElevenLabs transcription failed: \(elevenLabsReason). Apple Speech also could not transcribe this recording."
		}
	}
}

private enum ElevenLabsTranscriber {
	private struct Response: Decodable {
		let text: String
	}

	private enum TranscriptionError: LocalizedError {
		case invalidResponse
		case requestFailed(Int)
		case emptyTranscript

		var errorDescription: String? {
			switch self {
			case .invalidResponse:
				"the server returned an invalid response"
			case let .requestFailed(status):
				"the server returned HTTP \(status)"
			case .emptyTranscript:
				"the server returned an empty transcript"
			}
		}
	}

	static var bundledAPIKey: String? {
		guard let url = Bundle.main.url(forResource: "LocalSecrets", withExtension: "xcconfig"),
			let contents = try? String(contentsOf: url, encoding: .utf8),
			let line = contents.split(whereSeparator: \.isNewline).first(where: {
				$0.trimmingCharacters(in: .whitespaces).hasPrefix("ELEVENLABS_API_KEY")
			}),
			let separator = line.firstIndex(of: "=")
		else {
			return nil
		}
		let key = line[line.index(after: separator)...]
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return key.isEmpty ? nil : key
	}

	static func transcribe(url: URL, apiKey: String) async throws -> TranscriptionResult {
		let boundary = "MyVoiceMemo-\(UUID().uuidString)"
		let bodyURL = try multipartBody(audioURL: url, boundary: boundary)
		defer { try? FileManager.default.removeItem(at: bodyURL) }

		var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
		request.httpMethod = "POST"
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
		guard let response = response as? HTTPURLResponse else {
			throw TranscriptionError.invalidResponse
		}
		guard (200..<300).contains(response.statusCode) else {
			throw TranscriptionError.requestFailed(response.statusCode)
		}

		let transcript = try JSONDecoder()
			.decode(Response.self, from: data)
			.text
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !transcript.isEmpty else { throw TranscriptionError.emptyTranscript }
		return TranscriptionResult(transcript: transcript, modelName: "ElevenLabs Scribe v2")
	}

	private static func multipartBody(audioURL: URL, boundary: String) throws -> URL {
		let bodyURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("elevenlabs-\(UUID().uuidString)")
			.appendingPathExtension("multipart")
		guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
			throw TranscriptionError.invalidResponse
		}

		let output = try FileHandle(forWritingTo: bodyURL)
		do {
			try writeField("model_id", value: "scribe_v2", boundary: boundary, to: output)
			try writeField("tag_audio_events", value: "false", boundary: boundary, to: output)
			try writeField("timestamps_granularity", value: "none", boundary: boundary, to: output)
			try write(
				"--\(boundary)\r\n"
					+ "Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n"
					+ "Content-Type: audio/mp4\r\n\r\n",
				to: output
			)

			let input = try FileHandle(forReadingFrom: audioURL)
			defer { try? input.close() }
			while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
				try output.write(contentsOf: chunk)
			}
			try write("\r\n--\(boundary)--\r\n", to: output)
			try output.close()
			return bodyURL
		} catch {
			try? output.close()
			try? FileManager.default.removeItem(at: bodyURL)
			throw error
		}
	}

	private static func writeField(
		_ name: String,
		value: String,
		boundary: String,
		to output: FileHandle
	) throws {
		try write(
			"--\(boundary)\r\n"
				+ "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
				+ "\(value)\r\n",
			to: output
		)
	}

	private static func write(_ value: String, to output: FileHandle) throws {
		try output.write(contentsOf: Data(value.utf8))
	}
}

private actor TranscriptAccumulator {
	private var transcript = ""
	private let modelName: String
	private let onUpdate: @Sendable (TranscriptionResult) -> Void

	init(modelName: String, onUpdate: @escaping @Sendable (TranscriptionResult) -> Void) {
		self.modelName = modelName
		self.onUpdate = onUpdate
	}

	var result: TranscriptionResult {
		TranscriptionResult(transcript: transcript, modelName: modelName)
	}

	func append(_ fragment: AttributedString) {
		transcript += String(fragment.characters)
		onUpdate(result)
	}
}

private extension AVAudioFile {
	var duration: TimeInterval {
		guard processingFormat.sampleRate > 0 else { return 0 }
		return Double(length) / processingFormat.sampleRate
	}
}
