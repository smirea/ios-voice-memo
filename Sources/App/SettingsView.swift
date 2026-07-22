import SwiftUI

struct SettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var store: JournalStore
	@State private var draft: JournalSettings
	@State private var showsClearConfirmation = false

	init(store: JournalStore) {
		self.store = store
		_draft = State(initialValue: store.settings)
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					privacyRow
				} header: {
					Text("Privacy")
				}

				Section("Recording") {
					Toggle("Keep screen awake", isOn: $draft.keepScreenAwakeWhileRecording)
					Toggle("Haptics", isOn: $draft.hapticsEnabled)
				}

				Section("Journal") {
					Toggle("Show transcripts", isOn: $draft.showTranscripts)
					LabeledContent("Storage", value: store.isDemoMode ? "Demo" : "On this iPhone")
					LabeledContent("iCloud Backup", value: store.isDemoMode ? "Demo" : "Included")
				}

				Section {
					Button("Delete all entries", role: .destructive) {
						showsClearConfirmation = true
					}
					.disabled(store.entries.isEmpty || store.isDemoMode)
				} footer: {
					Text("Your journal stays available offline and MyVoiceMemo makes no network requests. iOS includes it in iCloud Backup when backup is enabled for this iPhone.")
				}
			}
			.scrollContentBackground(.hidden)
			.background(.black)
			.navigationTitle("Settings")
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
		.preferredColorScheme(.dark)
		.presentationBackground(.black)
		.onChange(of: draft) { _, newValue in store.updateSettings(newValue) }
		.alert("Delete the journal?", isPresented: $showsClearConfirmation) {
			Button("Cancel", role: .cancel) {}
			Button("Delete all", role: .destructive) { store.clearJournal() }
		} message: {
			Text("This removes every recording, transcript, and reflection from this device.")
		}
	}

	private var privacyRow: some View {
		HStack(alignment: .top, spacing: 14) {
			Image(systemName: "iphone.gen3.radiowaves.left.and.right")
				.font(.system(size: 20))
				.foregroundStyle(.white)
				.frame(width: 28)
			VStack(alignment: .leading, spacing: 5) {
				Text("Local first, automatically backed up")
					.font(.system(size: 14, weight: .medium))
				Text("Recording, transcription, and reflection happen on device. There’s no MyVoiceMemo server, account, analytics, or network traffic.")
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 5)
	}
}
