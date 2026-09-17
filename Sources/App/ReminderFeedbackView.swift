import SwiftUI

struct ReminderFeedbackView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var session: ReminderFeedbackSession

	init(store: JournalStore, entryID: UUID) {
		_session = State(initialValue: ReminderFeedbackSession(store: store, entryID: entryID))
	}

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(spacing: 24) {
					Text("Say what was missed, what should change, or what should be removed.")
						.font(.system(size: 17, weight: .medium))
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)

					if let transcript = session.completedTranscription {
						Text(transcript.transcript)
							.font(.body)
							.frame(maxWidth: .infinity, alignment: .leading)
							.textSelection(.enabled)
						if let warning = transcript.warning {
							Text(warning).font(.footnote).foregroundStyle(.secondary)
						}
					} else {
						WaveformView(levels: session.isVisualDemo ? demoLevels : session.recorder.levels)
							.frame(height: 52)
						Text(session.duration.clockText)
							.font(.system(size: 22, weight: .medium, design: .monospaced))
							.monospacedDigit()
					}

					if session.isWorking {
						ProgressView(session.statusMessage ?? "Processing feedback…")
							.tint(AppStyle.accent)
					} else {
						if let status = session.statusMessage {
							Text(status).font(.footnote).foregroundStyle(.secondary)
								.multilineTextAlignment(.center)
						}
						if let error = session.errorMessage {
							Text(error).font(.footnote).foregroundStyle(.secondary)
								.multilineTextAlignment(.center)
						}
						Button(action: session.submit) {
							Label(session.phase == .failed ? "Retry" : "Use feedback", systemImage: "checkmark")
								.font(.system(size: 17, weight: .semibold))
								.foregroundStyle(.white)
								.frame(maxWidth: .infinity)
								.frame(height: 56)
								.background(AppStyle.accent, in: Capsule())
						}
						.buttonStyle(.plain)
						.disabled(!session.canSubmit)
						if session.phase == .failed || session.phase == .stopped {
							Button("Record again", action: session.recordAgain)
								.tint(AppStyle.accent)
						}
					}

					Text("Audio stays available if submission fails. It is deleted after saving, Cancel, or Record again.")
						.font(.footnote)
						.foregroundStyle(.tertiary)
						.multilineTextAlignment(.center)
				}
				.padding(.horizontal, 24)
				.padding(.vertical, 20)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(AppStyle.background)
			.navigationTitle("Add feedback")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { session.cancel(); dismiss() }
				}
			}
		}
		.preferredColorScheme(.dark)
		.presentationBackground(AppStyle.background)
		.presentationDetents([.medium, .large])
		.task { session.start() }
		.onDisappear { session.cancel() }
		.onChange(of: session.hasCommitted) { _, committed in if committed { dismiss() } }
	}

	private var demoLevels: [Double] {
		(0..<46).map { 0.18 + abs(sin(Double($0) * 0.63)) * 0.68 }
	}
}
