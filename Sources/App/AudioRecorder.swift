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
protocol AudioRecordingDevice: AnyObject {
	var isRecording: Bool { get }
	var currentTime: TimeInterval { get }
	var delegate: (any AVAudioRecorderDelegate)? { get set }
	var isMeteringEnabled: Bool { get set }
	func prepareToRecord() -> Bool
	func record() -> Bool
	func pause()
	func stop()
	func updateMeters()
	func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: AudioRecordingDevice {}

@MainActor
struct RecordingHardware {
	var makeRecorder: (URL) throws -> any AudioRecordingDevice = { url in
		let settings = url.pathExtension.lowercased() == "caf"
			? RecordingAudioFormat.pcmSettings : RecordingAudioFormat.captureSettings
		return try AVAudioRecorder(url: url, settings: settings)
	}
	var activate: (AnyObject) throws -> Void = { owner in
		try AudioSessionController.shared.activate(
			owner,
			category: .record,
			mode: .default,
			options: [.allowBluetoothHFP, .bluetoothHighQualityRecording]
		)
	}
	var deactivate: (AnyObject) -> Void = { AudioSessionController.shared.deactivate($0) }
}

enum CaptureState: Equatable {
	case idle
	case starting
	case recording
	case pausedByUser
	case interrupted
	case waitingForInput
	case stopped(CaptureStopReason)
}

enum CaptureStopReason: Equatable {
	case mediaServicesReset
	case encodingFailure
	case unexpectedFinish
}

@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
	private(set) var state = CaptureState.idle {
		didSet { onStateChange?() }
	}
	private(set) var duration: TimeInterval = 0 {
		didSet { onStateChange?() }
	}
	private(set) var levels = Array(repeating: 0.08, count: 46)
	private(set) var wantsToRecord = false
	@ObservationIgnored var onStateChange: (() -> Void)?
	@ObservationIgnored private let permissionRequest: () async -> Bool
	@ObservationIgnored private let hardware: RecordingHardware
	@ObservationIgnored private let recoveryDelay: () async throws -> Void
	@ObservationIgnored private var recorder: (any AudioRecordingDevice)?
	@ObservationIgnored private var meterTimer: Timer?
	@ObservationIgnored private var outputURL: URL?
	@ObservationIgnored private var observationTasks: [Task<Void, Never>] = []
	@ObservationIgnored private(set) var routeRecoveryTask: Task<Void, Never>?
	@ObservationIgnored private var generation: UUID?
	@ObservationIgnored private var recoveryGeneration = UUID()
	@ObservationIgnored private var interruptionIsActive = false

	var isRecording: Bool { state == .recording }
	var hasRecording: Bool { state != .idle && state != .starting }
	var isPaused: Bool { hasRecording && !isRecording }
	var canTogglePause: Bool {
		guard hasRecording else { return false }
		if case .stopped = state { return false }
		return true
	}

	var statusMessage: String? {
		switch state {
		case .idle, .starting, .recording: nil
		case .pausedByUser: "Recording paused."
		case .interrupted: "Recording paused for an audio interruption."
		case .waitingForInput: "Recording paused until the microphone is available."
		case .stopped(.mediaServicesReset):
			"Recording stopped because the audio system restarted. You can keep what was captured."
		case .stopped(.encodingFailure), .stopped(.unexpectedFinish):
			"Recording stopped unexpectedly. You can keep what was captured."
		}
	}

	init(
		permissionRequest: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
		hardware: RecordingHardware = RecordingHardware(),
		recoveryDelay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
		observeSession: Bool = true
	) {
		self.permissionRequest = permissionRequest
		self.hardware = hardware
		self.recoveryDelay = recoveryDelay
		super.init()
		if observeSession { observeAudioSession() }
	}

	deinit {
		for task in observationTasks { task.cancel() }
		routeRecoveryTask?.cancel()
	}

	func start(at url: URL) async throws {
		guard state == .idle else { throw RecordingError.couldNotStart }
		let generation = UUID()
		self.generation = generation
		state = .starting
		do {
			guard await permissionRequest() else { throw RecordingError.microphonePermissionDenied }
			try Task.checkCancellation()
			guard self.generation == generation else { throw CancellationError() }
			try hardware.activate(self)
			let recorder = try hardware.makeRecorder(url)
			self.recorder = recorder
			outputURL = url
			recorder.delegate = self
			recorder.isMeteringEnabled = true
			guard recorder.prepareToRecord() else { throw RecordingError.couldNotStart }
			try makeFileRecoverable(at: url)
			guard recorder.record() else { throw RecordingError.couldNotStart }
			duration = 0
			levels = Array(repeating: 0.08, count: 46)
			wantsToRecord = true
			interruptionIsActive = false
			state = .recording
			startMetering()
		} catch {
			if self.generation == generation {
				recorder?.delegate = nil
				recorder?.stop()
				recorder = nil
				outputURL = nil
				self.generation = nil
				state = .idle
				hardware.deactivate(self)
			}
			throw error
		}
	}

	func togglePause() {
		guard canTogglePause else { return }
		if wantsToRecord {
			pause()
		} else {
			wantsToRecord = true
			resumeIfPossible()
		}
	}

	func pause() {
		guard canTogglePause else { return }
		wantsToRecord = false
		cancelRouteRecovery()
		duration = max(duration, recorder?.currentTime ?? 0)
		recorder?.pause()
		stopMetering()
		state = .pausedByUser
	}

	func finish() -> FinishedRecording? {
		guard hasRecording, let outputURL else { return nil }
		duration = max(duration, recorder?.currentTime ?? 0)
		stopCapture()
		self.outputURL = nil
		state = .idle
		return FinishedRecording(url: outputURL, duration: duration)
	}

	func cancel() -> URL? {
		let url = outputURL
		stopCapture()
		outputURL = nil
		state = .idle
		if let url { try? FileManager.default.removeItem(at: url) }
		return url
	}

	private func stopCapture() {
		generation = nil
		wantsToRecord = false
		interruptionIsActive = false
		cancelRouteRecovery()
		stopMetering()
		recorder?.delegate = nil
		recorder?.stop()
		recorder = nil
		hardware.deactivate(self)
	}

	private func startMetering() {
		stopMetering()
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
		guard let recorder, isRecording else { return }
		duration = max(duration, recorder.currentTime)
		guard recorder.isRecording else {
			state = .waitingForInput
			stopMetering()
			return
		}
		recorder.updateMeters()
		let power = recorder.averagePower(forChannel: 0)
		let normalized = max(0.08, min(1, pow(10, power / 38)))
		levels.removeFirst()
		levels.append(Double(normalized))
	}

	private func observeAudioSession() {
		let session = AVAudioSession.sharedInstance()
		observationTasks.append(Task { @MainActor [weak self] in
			for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification, object: session) {
				self?.handleInterruption(notification)
			}
		})
		observationTasks.append(Task { @MainActor [weak self] in
			for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification, object: session) {
				self?.handleRouteChange()
			}
		})
		for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
			observationTasks.append(Task { @MainActor [weak self] in
				for await _ in NotificationCenter.default.notifications(named: name, object: session) {
					self?.handleMediaServicesReset()
				}
			})
		}
	}

	func handleInterruption(_ notification: Notification) {
		guard hasRecording, canTogglePause,
			let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: rawType)
		else { return }
		switch type {
		case .began:
			interruptionIsActive = true
			cancelRouteRecovery()
			duration = max(duration, recorder?.currentTime ?? 0)
			recorder?.pause()
			stopMetering()
			state = wantsToRecord ? .interrupted : .pausedByUser
		case .ended:
			interruptionIsActive = false
			if wantsToRecord { resumeIfPossible() }
		@unknown default:
			break
		}
	}

	func handleRouteChange() {
		guard hasRecording, canTogglePause, wantsToRecord, !interruptionIsActive else { return }
		cancelRouteRecovery()
		let generation = self.generation
		let recoveryGeneration = self.recoveryGeneration
		if recorder?.isRecording == false {
			duration = max(duration, recorder?.currentTime ?? 0)
			state = .waitingForInput
			stopMetering()
		}
		routeRecoveryTask = Task { [weak self, recoveryDelay] in
			do { try await recoveryDelay() } catch { return }
			guard let self, !Task.isCancelled,
				self.generation == generation,
				self.recoveryGeneration == recoveryGeneration,
				self.wantsToRecord, !self.interruptionIsActive, self.canTogglePause
			else { return }
			self.routeRecoveryTask = nil
			if self.recorder?.isRecording == true {
				self.state = .recording
				self.startMetering()
			} else {
				self.resumeIfPossible()
			}
		}
	}

	private func cancelRouteRecovery() {
		recoveryGeneration = UUID()
		routeRecoveryTask?.cancel()
		routeRecoveryTask = nil
	}

	private func resumeIfPossible() {
		guard wantsToRecord, canTogglePause, let recorder else { return }
		guard !interruptionIsActive else {
			state = .interrupted
			return
		}
		do {
			try hardware.activate(self)
			guard recorder.record() else { throw RecordingError.couldNotStart }
			state = .recording
			startMetering()
		} catch {
			state = .waitingForInput
			stopMetering()
		}
	}

	func handleMediaServicesReset() {
		guard hasRecording else { return }
		AudioSessionController.shared.invalidate(self)
		stopUnexpectedly(.mediaServicesReset)
	}

	#if DEBUG
	func showStoppedDemo(duration: TimeInterval) {
		self.duration = duration
		wantsToRecord = false
		state = .stopped(.mediaServicesReset)
	}
	#endif

	func handleDeviceFinished(_ identifier: ObjectIdentifier, successfully: Bool) {
		guard let recorder, ObjectIdentifier(recorder) == identifier, hasRecording else { return }
		stopUnexpectedly(successfully ? .unexpectedFinish : .encodingFailure)
	}

	private func stopUnexpectedly(_ reason: CaptureStopReason) {
		duration = max(duration, recorder?.currentTime ?? 0)
		stopCapture()
		state = .stopped(reason)
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

	nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		let identifier = ObjectIdentifier(recorder)
		Task { @MainActor [weak self] in self?.handleDeviceFinished(identifier, successfully: flag) }
	}

	nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
		let identifier = ObjectIdentifier(recorder)
		Task { @MainActor [weak self] in self?.handleDeviceFinished(identifier, successfully: false) }
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
