import Foundation
import Observation

@MainActor
@Observable
final class ReminderFeedbackSession {
	enum Phase { case idle, starting, recording, stopped, transcribing, saving, failed, committed, closed }

	let recorder: AudioRecorder
	private(set) var phase: Phase = .idle
	private(set) var errorMessage: String?
	private(set) var completedTranscription: TranscriptionResult?
	private(set) var committedFeedback: ReminderFeedback?
	private(set) var pendingFeedback: ReminderFeedback?
	private(set) var feedbackID = UUID()
	private(set) var draftURL: URL?
	@ObservationIgnored private(set) var startupTask: Task<Void, Never>?
	@ObservationIgnored private(set) var submissionTask: Task<Void, Never>?
	@ObservationIgnored private var finishedRecording: FinishedRecording?
	@ObservationIgnored private var generation: UUID?
	@ObservationIgnored private var capturePriorityOwner: UUID?
	@ObservationIgnored private var capturePriorityReleaseTask: Task<Void, Never>?
	@ObservationIgnored private let store: JournalStore
	@ObservationIgnored private let entryID: UUID
	@ObservationIgnored private let makeTemporaryURL: () -> URL
	@ObservationIgnored private let appendFeedback: (UUID, ReminderFeedback) async throws -> ReminderFeedback

	var isWorking: Bool { phase == .starting || phase == .transcribing || phase == .saving }
	var hasCommitted: Bool { phase == .committed }
	var duration: TimeInterval { isVisualDemo ? 12 : finishedRecording?.duration ?? recorder.duration }
	var canSubmit: Bool {
		!isWorking && phase != .closed && phase != .committed
			&& (isVisualDemo || finishedRecording != nil || (recorder.hasRecording && duration >= 0.4))
	}
	var statusMessage: String? {
		switch phase {
		case .starting: "Starting recording…"
		case .transcribing: "Transcribing feedback…"
		case .saving: "Saving correction…"
		case .recording, .stopped: recorder.statusMessage
		default: nil
		}
	}
	var isVisualDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo-reminder-feedback") }

	init(store: JournalStore, entryID: UUID, recorder: AudioRecorder = AudioRecorder(),
		makeTemporaryURL: (() -> URL)? = nil,
		appendFeedback: ((UUID, ReminderFeedback) async throws -> ReminderFeedback)? = nil) {
		self.store = store
		self.entryID = entryID
		self.recorder = recorder
		self.makeTemporaryURL = makeTemporaryURL ?? { store.temporaryReminderFeedbackURL() }
		self.appendFeedback = appendFeedback ?? { try await store.appendReminderFeedback(entryID: $0, feedback: $1) }
		recorder.onStateChange = { [weak self] in
			guard let self, self.phase == .starting || self.phase == .recording || self.phase == .stopped else { return }
			if case .stopped = self.recorder.state {
				self.phase = .stopped
				_ = self.releaseCapturePriority()
			}
		}
	}

	deinit { startupTask?.cancel(); submissionTask?.cancel() }

	func start() {
		guard phase == .idle else { return }
		#if DEBUG
		if isVisualDemo { showVisualDemo(); return }
		#endif
		let token = UUID()
		let url = makeTemporaryURL()
		generation = token
		feedbackID = UUID()
		draftURL = url
		capturePriorityOwner = token
		phase = .starting
		startupTask = Task { [weak self] in
			guard let self else { return }
			await store.beginCapturePriority(owner: token)
			guard generation == token, !Task.isCancelled else {
				await store.endCapturePriority(owner: token)
				return
			}
			do {
				try await recorder.start(at: url)
				guard generation == token, !Task.isCancelled else { return }
				phase = .recording
				startupTask = nil
			} catch {
				await store.endCapturePriority(owner: token)
				guard generation == token else { return }
				capturePriorityOwner = nil
				startupTask = nil
				phase = .failed
				errorMessage = error.localizedDescription
			}
		}
	}

	func submit() {
		guard !isVisualDemo, canSubmit, let token = generation else { return }
		if finishedRecording == nil { finishedRecording = recorder.finish() }
		guard let recording = finishedRecording else { return }
		let release = releaseCapturePriority()
		errorMessage = nil
		phase = completedTranscription == nil ? .transcribing : .saving
		let id = feedbackID
		submissionTask = Task { [weak self] in
			guard let self else { return }
			await release?.value
			guard generation == token, !Task.isCancelled else { return }
			do {
				if completedTranscription == nil {
					let result = try await store.transcribeReminderFeedback(at: recording.url)
					guard generation == token, !Task.isCancelled else { return }
					guard !result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
						throw ReminderFeedbackError.emptyTranscript
					}
					completedTranscription = result
				}
				guard let transcription = completedTranscription else { return }
				phase = .saving
				if pendingFeedback == nil {
					pendingFeedback = ReminderFeedback(id: id, kind: .voice,
						text: transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
				}
				let receipt = try await appendFeedback(entryID, pendingFeedback!)
				guard generation == token else { return }
				committedFeedback = receipt
				removeTemporaryAudio(at: recording.url)
				draftURL = nil
				finishedRecording = nil
				submissionTask = nil
				phase = .committed
			} catch {
				guard generation == token else { return }
				submissionTask = nil
				phase = .failed
				errorMessage = error is CancellationError
					? "Processing paused. Your feedback recording is available to retry."
					: error.localizedDescription
			}
		}
	}

	func retry() { submit() }

	func recordAgain() {
		cancel()
		committedFeedback = nil
		phase = .idle
		start()
	}

	func cancel() {
		generation = nil
		startupTask?.cancel()
		submissionTask?.cancel()
		startupTask = nil
		submissionTask = nil
		_ = recorder.cancel()
		_ = releaseCapturePriority()
		if let draftURL { removeTemporaryAudio(at: draftURL) }
		draftURL = nil
		finishedRecording = nil
		completedTranscription = nil
		pendingFeedback = nil
		errorMessage = nil
		if phase != .committed { phase = .closed }
	}

	private func releaseCapturePriority() -> Task<Void, Never>? {
		guard let owner = capturePriorityOwner else { return capturePriorityReleaseTask }
		capturePriorityOwner = nil
		let task = Task { await store.endCapturePriority(owner: owner) }
		capturePriorityReleaseTask = task
		return task
	}

	private func removeTemporaryAudio(at url: URL) {
		do { try FileManager.default.removeItem(at: url) }
		catch {
			let error = error as NSError
			if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
				store.storageErrorMessage = "Temporary feedback audio cleanup is pending and will retry when the app opens."
			}
		}
	}

	#if DEBUG
	private func showVisualDemo() {
		let arguments = ProcessInfo.processInfo.arguments
		if arguments.contains("-demo-feedback-transcribing") {
			phase = .transcribing
		} else if arguments.contains("-demo-feedback-save-error") {
			completedTranscription = .init(transcript: "Remind me to bring my notebook to the next project check-in.", modelName: "Apple Speech")
			phase = .failed
			errorMessage = "The correction couldn’t be saved. Your recording and transcript are still available. Try again."
		} else if arguments.contains("-demo-feedback-transcription-error") {
			phase = .failed
			errorMessage = "Transcription is unavailable. Your feedback recording is still available. Try again."
		} else {
			phase = .recording
			if arguments.contains("-demo-audio-reset") {
				recorder.showStoppedDemo(duration: 12)
				phase = .stopped
			}
		}
	}
	#endif
}
