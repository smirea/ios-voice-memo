import Foundation
import Observation
import UIKit

struct RecordingContext: Identifiable {
	let id = UUID()
}

@MainActor
@Observable
final class RecordingSession {
	let recorder: AudioRecorder
	private(set) var context: RecordingContext?
	private(set) var hasStartedRecording = false
	private(set) var isFinishing = false
	var errorMessage: String?
	var saveErrorMessage: String?
	@ObservationIgnored private var finishedRecording: FinishedRecording?

	var canFinish: Bool { recorder.hasRecording || finishedRecording != nil }

	@ObservationIgnored private let store: JournalStore
	@ObservationIgnored private let liveActivity = RecordingActivityManager()
	@ObservationIgnored private(set) var startupTask: Task<Void, Never>?
	@ObservationIgnored private var generation: UUID?
	@ObservationIgnored private var activeURL: URL?
	@ObservationIgnored private var calendarEvent: JournalCalendarEvent?
	@ObservationIgnored private var lastCheckpointSecond = 0
	@ObservationIgnored private var lastPausedState = false

	var isVisualDemo: Bool {
		ProcessInfo.processInfo.arguments.contains("-demo-recording")
	}

	init(store: JournalStore, recorder: AudioRecorder = AudioRecorder()) {
		self.store = store
		self.recorder = recorder
		recorder.onStateChange = { [weak self] in self?.recordingStateChanged() }
	}

	func present(startsImmediately: Bool) {
		guard context == nil else { return }
		context = RecordingContext()
		hasStartedRecording = false
		isFinishing = false
		errorMessage = nil
		saveErrorMessage = nil
		finishedRecording = nil
		if startsImmediately { start(calendarEvent: nil) }
	}

	func start(calendarEvent: JournalCalendarEvent?) {
		guard context != nil, !hasStartedRecording else { return }
		hasStartedRecording = true
		self.calendarEvent = calendarEvent
		lastCheckpointSecond = 0
		lastPausedState = false
		let generation = UUID()
		self.generation = generation
		if isVisualDemo {
			liveActivity.start(elapsed: 113, locationName: "Chicago")
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-demo-audio-reset") {
				recorder.showStoppedDemo(duration: 113)
				liveActivity.setPaused(true, elapsed: 113)
			}
			#endif
			return
		}
		startupTask = Task { [weak self] in
			await self?.beginRecording(generation: generation)
		}
	}

	func finish() async -> UUID? {
		guard !isVisualDemo, !isFinishing else { return nil }
		if finishedRecording == nil { finishedRecording = recorder.finish() }
		guard let recording = finishedRecording else { return nil }
		isFinishing = true
		defer { isFinishing = false }
		generation = nil
		liveActivity.end()
		UIApplication.shared.isIdleTimerDisabled = false
		do {
			let entryID = try await store.finishRecording(
				at: recording.url, duration: recording.duration, calendarEvent: calendarEvent)
			activeURL = nil
			finishedRecording = nil
			context = nil
			return entryID
		} catch {
			saveErrorMessage = "Your audio is still on this device. Try Finish again. " + error.localizedDescription
			return nil
		}
	}

	func discard() {
		guard !isFinishing else { return }
		generation = nil
		startupTask?.cancel()
		startupTask = nil
		discardAudio()
		liveActivity.end()
		UIApplication.shared.isIdleTimerDisabled = false
		context = nil
		errorMessage = nil
	}

	private func beginRecording(generation: UUID) async {
		guard self.generation == generation, !Task.isCancelled else { return }
		do {
			let url = try await store.destinationForNewRecording(calendarEvent: calendarEvent)
			guard self.generation == generation, !Task.isCancelled else {
				store.cancelRecording(at: url)
				return
			}
			activeURL = url
			try await recorder.start(at: url)
			guard self.generation == generation, !Task.isCancelled else { return }
			startupTask = nil
			liveActivity.start(elapsed: recorder.duration)
			if recorder.isPaused {
				liveActivity.setPaused(true, elapsed: recorder.duration)
			}
			if store.settings.hapticsEnabled {
				UIImpactFeedbackGenerator(style: .light).impactOccurred()
			}
			let locationTask = store.beginRecordingLocationCapture()
			Task { [weak self] in
				let location = await locationTask.value
				guard let self, self.generation == generation else { return }
				self.liveActivity.setLocation(location.map(self.store.displayName(for:)))
			}
			UIApplication.shared.isIdleTimerDisabled = store.settings.keepScreenAwakeWhileRecording
		} catch {
			guard self.generation == generation else { return }
			startupTask = nil
			discardAudio()
			errorMessage = error.localizedDescription
		}
	}

	private func discardAudio() {
		let url = finishedRecording?.url ?? recorder.finish()?.url ?? recorder.cancel() ?? activeURL
		finishedRecording = nil
		activeURL = nil
		guard let url else { return }
		store.cancelRecording(at: url)
	}

	private func recordingStateChanged() {
		guard let activeURL, recorder.hasRecording else { return }
		let second = Int(recorder.duration)
		if second >= lastCheckpointSecond + 5 {
			lastCheckpointSecond = second
			store.checkpointRecording(at: activeURL, duration: recorder.duration)
		}
		if recorder.isPaused != lastPausedState {
			lastPausedState = recorder.isPaused
			liveActivity.setPaused(recorder.isPaused, elapsed: recorder.duration)
		}
	}
}
