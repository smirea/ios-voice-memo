import SwiftUI

struct ReminderFeedbackView: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var store: JournalStore
	let entryID: UUID

	@State private var recorder = AudioRecorder()
	@State private var activeURL: URL?
	@State private var isSubmitting = false
	@State private var errorMessage: String?

	private var isVisualDemo: Bool {
		ProcessInfo.processInfo.arguments.contains("-demo-reminder-feedback")
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 28) {
				Text("Say what was missed, what should change, or what should be removed.")
					.font(.system(size: 17, weight: .medium))
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 24)

				WaveformView(levels: isVisualDemo ? demoLevels : recorder.levels)
					.frame(height: 52)
					.padding(.horizontal, 28)

				Text((isVisualDemo ? 12 : recorder.duration).clockText)
					.font(.system(size: 22, weight: .medium, design: .monospaced))
					.monospacedDigit()

				if isSubmitting {
					ProgressView("Updating reminders")
						.tint(AppStyle.accent)
				} else {
					Button(action: useFeedback) {
						Label("Use feedback", systemImage: "checkmark")
							.font(.system(size: 17, weight: .semibold))
							.foregroundStyle(.white)
							.frame(maxWidth: .infinity)
							.frame(height: 56)
							.background(AppStyle.accent, in: Capsule())
					}
					.buttonStyle(.plain)
					.disabled(!isVisualDemo && (!recorder.isRecording || recorder.duration < 0.4))
					.padding(.horizontal, 24)
				}

				Text("The recording is transcribed for this correction, then deleted.")
					.font(.footnote)
					.foregroundStyle(.tertiary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 32)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(AppStyle.background)
			.navigationTitle("Add feedback")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						_ = recorder.cancel()
						dismiss()
					}
					.disabled(isSubmitting)
				}
			}
		}
		.preferredColorScheme(.dark)
		.presentationBackground(AppStyle.background)
		.presentationDetents([.medium])
		.interactiveDismissDisabled(isSubmitting)
		.task {
			guard !isVisualDemo else { return }
			await startRecording()
		}
		.onDisappear {
			guard !isSubmitting else { return }
			_ = recorder.cancel()
		}
		.alert("Couldn’t update reminders", isPresented: Binding(
			get: { errorMessage != nil },
			set: { if !$0 { errorMessage = nil } }
		)) {
			Button("Cancel", role: .cancel) {}
			Button("Record again") {
				Task { await startRecording() }
			}
		} message: {
			Text(errorMessage ?? "")
		}
	}

	private func startRecording() async {
		guard activeURL == nil else { return }
		let url = store.temporaryReminderFeedbackURL()
		activeURL = url
		do {
			try await recorder.start(at: url)
		} catch {
			activeURL = nil
			errorMessage = error.localizedDescription
		}
	}

	private func useFeedback() {
		guard !isVisualDemo else { return }
		guard let finished = recorder.finish() else { return }
		activeURL = nil
		isSubmitting = true
		Task {
			do {
				try await store.applyReminderFeedback(entryID: entryID, audioURL: finished.url)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
				isSubmitting = false
			}
		}
	}

	private var demoLevels: [Double] {
		(0..<46).map { index in
			0.18 + abs(sin(Double(index) * 0.63)) * 0.68
		}
	}
}
