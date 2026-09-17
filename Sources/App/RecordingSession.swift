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
	private(set) var isDiscarding = false
	var errorMessage: String?
	var saveErrorMessage: String?
	var discardErrorMessage: String?
	@ObservationIgnored private var finishedRecording: FinishedRecording?

	var canFinish: Bool { recorder.hasRecording || finishedRecording != nil }
	var duration: TimeInterval { finishedRecording?.duration ?? recorder.duration }
	var isCommitting: Bool { isFinishing || isDiscarding }
	var statusMessage: String? {
		if isFinishing { return "Saving recording…" }
		if isDiscarding { return "Discarding recording…" }
		if finishedRecording != nil { return "Recording stopped. Finish to save or discard it." }
		return recorder.statusMessage
	}

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
		isDiscarding = false
		discardErrorMessage = nil
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
		guard !isVisualDemo, !isCommitting else { return nil }
		if finishedRecording == nil { finishedRecording = recorder.finish() }
		guard let recording = finishedRecording else { return nil }
		isFinishing = true
		defer { isFinishing = false }
		generation = nil
		liveActivity.end()
		UIApplication.shared.isIdleTimerDisabled = false
		do {
			let entryID = try await store.finishRecording(
				at: recording.url, calendarEvent: calendarEvent)
			activeURL = nil
			finishedRecording = nil
			context = nil
			return entryID
		} catch {
			saveErrorMessage = "Your audio is still on this device. Try Finish again. " + error.localizedDescription
			return nil
		}
	}

	@discardableResult
	func discard() async -> Bool {
		guard !isCommitting else { return false }
		isDiscarding = true
		defer { isDiscarding = false }
		generation = nil
		startupTask?.cancel()
		startupTask = nil
		if finishedRecording == nil { finishedRecording = recorder.finish() }
		if recorder.state == .starting { _ = recorder.cancel() }
		liveActivity.end()
		UIApplication.shared.isIdleTimerDisabled = false
		do {
			if let url = finishedRecording?.url ?? activeURL {
				try await store.cancelRecording(at: url)
			}
			store.cancelRecordingLocationCapture()
			finishedRecording = nil
			activeURL = nil
			context = nil
			errorMessage = nil
			discardErrorMessage = nil
			return true
		} catch {
			let retained = canFinish ? "Its audio is still on this device. Try discarding again, or Finish to save it." : "Recording will not start. Try discarding again."
			discardErrorMessage = "The recording hasn’t been discarded. " + retained + " " + error.localizedDescription
			return false
		}
	}

	private func beginRecording(generation: UUID) async {
		guard self.generation == generation, !Task.isCancelled else { return }
		do {
			let url = try await store.destinationForNewRecording(calendarEvent: calendarEvent)
			guard self.generation == generation, !Task.isCancelled else {
				do { try await store.cancelRecording(at: url) }
				catch { store.storageErrorMessage = "Cancelled recording cleanup is pending. " + error.localizedDescription }
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
			errorMessage = error.localizedDescription
		}
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
