import SwiftUI

struct ReminderFeedbackView: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var store: JournalStore
	let entryID: UUID

	@State private var recorder = AudioRecorder()
	@State private var activeURL: URL?
	@State private var capturePriorityOwner: UUID?
	@State private var capturePriorityReleaseTask: Task<Void, Never>?
	@State private var isSubmitting = false
	@State private var errorMessage: String?

	private var isVisualDemo: Bool {
		ProcessInfo.processInfo.arguments.contains("-demo-reminder-feedback")
	}

	var body: some View {
		NavigationStack {
			ScrollView {
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

					if let statusMessage = recorder.statusMessage {
						Text(statusMessage)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
							.padding(.horizontal, 24)
					}

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
						.disabled(!isVisualDemo && (!recorder.hasRecording || recorder.duration < 0.4))
						.padding(.horizontal, 24)
					}

					Text("The recording is transcribed for this correction, then deleted.")
						.font(.footnote)
						.foregroundStyle(.tertiary)
						.multilineTextAlignment(.center)
						.padding(.horizontal, 32)
				}
				.padding(.vertical, 20)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(AppStyle.background)
			.navigationTitle("Add feedback")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						_ = recorder.cancel()
						activeURL = nil
						_ = releaseCapturePriority()
						dismiss()
					}
					.disabled(isSubmitting)
				}
			}
		}
		.preferredColorScheme(.dark)
		.presentationBackground(AppStyle.background)
		.presentationDetents([.medium, .large])
		.interactiveDismissDisabled(isSubmitting)
		.task {
			guard !isVisualDemo else {
				#if DEBUG
				if ProcessInfo.processInfo.arguments.contains("-demo-audio-reset") {
					recorder.showStoppedDemo(duration: 12)
				}
				#endif
				return
			}
			await startRecording()
		}
		.onDisappear {
			guard !isSubmitting else { return }
			_ = recorder.cancel()
			activeURL = nil
			_ = releaseCapturePriority()
		}
		.onChange(of: recorder.state) { _, _ in
			if case .stopped = recorder.state { _ = releaseCapturePriority() }
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
		let owner = UUID()
		capturePriorityOwner = owner
		let url = store.temporaryReminderFeedbackURL()
		activeURL = url
		await store.beginCapturePriority(owner: owner)
		guard capturePriorityOwner == owner, !Task.isCancelled else {
			if capturePriorityOwner == owner { capturePriorityOwner = nil; activeURL = nil }
			await store.endCapturePriority(owner: owner)
			return
		}
		do {
			try await recorder.start(at: url)
		} catch {
			if capturePriorityOwner == owner { capturePriorityOwner = nil }
			await store.endCapturePriority(owner: owner)
			guard activeURL == url else { return }
			activeURL = nil
			guard !Task.isCancelled else { return }
			errorMessage = error.localizedDescription
		}
	}

	private func useFeedback() {
		guard !isVisualDemo else { return }
		guard let finished = recorder.finish() else { return }
		let release = releaseCapturePriority()
		activeURL = nil
		isSubmitting = true
		Task {
			await release?.value
			do {
				try await store.applyReminderFeedback(entryID: entryID, audioURL: finished.url)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
				isSubmitting = false
			}
		}
	}

	private func releaseCapturePriority() -> Task<Void, Never>? {
		guard let owner = capturePriorityOwner else { return capturePriorityReleaseTask }
		capturePriorityOwner = nil
		let task = Task { await store.endCapturePriority(owner: owner) }
		capturePriorityReleaseTask = task
		return task
	}

	private var demoLevels: [Double] {
		(0..<46).map { index in
			0.18 + abs(sin(Double(index) * 0.63)) * 0.68
		}
	}
}
