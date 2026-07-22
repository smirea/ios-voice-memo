import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordView: View {
	@Bindable var store: JournalStore
	let replacementID: UUID?
	let onClose: () -> Void

	@State private var recorder = AudioRecorder()
	@State private var liveActivity = RecordingActivityManager()
	@State private var recordingLimit: TimeInterval = 120
	@State private var errorMessage: String?
	@State private var isFinishing = false
	@State private var activeRecordingURL: URL?
	@State private var lastCheckpointSecond = 0

	private var isVisualDemo: Bool {
		ProcessInfo.processInfo.arguments.contains("-demo-recording")
	}

	private var shownDuration: TimeInterval {
		isVisualDemo ? 113 : recorder.duration
	}

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			VStack(spacing: 0) {
				HStack {
					Spacer()
					CloseControl(action: cancel)
						.offset(y: 18)
				}
				.padding(.trailing, 8)

				Spacer()

				WaveformView(levels: displayLevels)
					.frame(height: 54)
					.padding(.horizontal, 52)
					.offset(y: -45)

				Text(shownDuration.clockText)
					.font(.system(size: 20, weight: .regular, design: .monospaced))
					.monospacedDigit()
					.padding(.top, 12)
					.offset(y: -40)

				Button {
					recordingLimit += 30
				} label: {
					Text("Add 30 seconds")
						.font(.system(size: 10))
						.foregroundStyle(Color.white.opacity(0.18))
						.padding(.vertical, 16)
				}
				.buttonStyle(.plain)
				.offset(y: -40)

				if let statusMessage = recorder.statusMessage {
					Text(statusMessage)
						.font(.system(size: 11))
						.foregroundStyle(Color.white.opacity(0.48))
						.multilineTextAlignment(.center)
						.padding(.horizontal, 54)
						.offset(y: -34)
				}

				Spacer()

				HStack(spacing: 34) {
					Button(action: togglePause) {
						Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
							.font(.system(size: 13, weight: .semibold))
							.foregroundStyle(.white)
							.frame(width: 48, height: 48)
							.background(Color.white.opacity(0.055), in: Circle())
					}
					.buttonStyle(.plain)
					.disabled(!isVisualDemo && !recorder.isRecording)
					.accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")

					Button(action: finish) {
						Image(systemName: "checkmark")
							.font(.system(size: 20, weight: .medium))
							.foregroundStyle(.black)
							.frame(width: 62, height: 62)
							.background(.white, in: Circle())
					}
					.buttonStyle(.plain)
					.disabled(!isVisualDemo && (!recorder.isRecording || isFinishing))
					.accessibilityLabel("Finish recording")
				}
				.padding(.bottom, 63)
				.offset(x: -52)
			}

			if isFinishing || store.isProcessing {
				ProcessingOverlay(message: store.processingMessage)
			}
		}
		.presentationBackground(.black)
		.task { await beginRecording() }
		.onChange(of: recorder.duration) { _, duration in
			checkpointIfNeeded(duration: duration)
			if !isVisualDemo, duration >= recordingLimit { finish() }
		}
		.onChange(of: recorder.isPaused) { _, isPaused in
			liveActivity.setPaused(isPaused)
		}
		.alert("Recording unavailable", isPresented: Binding(
			get: { errorMessage != nil },
			set: { if !$0 { errorMessage = nil } }
		)) {
			Button("Close") { onClose() }
		} message: {
			Text(errorMessage ?? "")
		}
	}

	private var displayLevels: [Double] {
		if isVisualDemo {
			return [
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.40, 0.72, 0.92, 0.86, 0.78, 0.70, 0.82, 0.74, 0.65, 0.78,
				0.60, 0.53, 0.45, 0.38, 0.30, 0.22, 0.16, 0.12, 0.08,
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.25, 0.34, 0.42, 0.38, 0.31, 0.36, 0.44, 0.39, 0.34, 0.31, 0.28, 0.24, 0.21
			]
		}
		if recorder.levels.allSatisfy({ $0 <= 0.08 }) {
			return recorder.levels.enumerated().map { index, _ in
				let center = Double(recorder.levels.count) / 2
				let distance = abs(Double(index) - center) / center
				return max(0.06, (1 - distance) * 0.42 + Double(index % 5) * 0.055)
			}
		}
		return recorder.levels
	}

	private func beginRecording() async {
		guard !isVisualDemo else { return }
		var destination: URL?
		do {
			let url = try store.destinationForNewRecording(replacing: replacementID)
			destination = url
			try await recorder.start(at: url)
			activeRecordingURL = url
			liveActivity.start()
			#if os(iOS)
			if store.settings.keepScreenAwakeWhileRecording {
				UIApplication.shared.isIdleTimerDisabled = true
			}
			#endif
		} catch {
			if let destination {
				try? FileManager.default.removeItem(at: destination)
				store.cancelRecording(at: destination)
			}
			errorMessage = error.localizedDescription
		}
	}

	private func finish() {
		guard !isVisualDemo else { return }
		guard !isFinishing, let recording = recorder.finish() else { return }
		activeRecordingURL = nil
		liveActivity.end()
		isFinishing = true
		#if os(iOS)
		UIApplication.shared.isIdleTimerDisabled = false
		#endif
		Task {
			await store.finishRecording(at: recording.url, duration: recording.duration, replacing: replacementID)
			onClose()
		}
	}

	private func cancel() {
		if let url = recorder.cancel() {
			store.cancelRecording(at: url)
		}
		activeRecordingURL = nil
		liveActivity.end()
		#if os(iOS)
		UIApplication.shared.isIdleTimerDisabled = false
		#endif
		onClose()
	}

	private func togglePause() {
		recorder.togglePause()
	}

	private func checkpointIfNeeded(duration: TimeInterval) {
		guard let activeRecordingURL else { return }
		let second = Int(duration)
		guard second >= lastCheckpointSecond + 5 else { return }
		lastCheckpointSecond = second
		store.checkpointRecording(at: activeRecordingURL, duration: duration)
	}
}
