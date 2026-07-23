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
				Section("Recording") {
					Toggle("Keep screen awake", isOn: $draft.keepScreenAwakeWhileRecording)
					Toggle("Haptics", isOn: $draft.hapticsEnabled)
				}

				Section("Journal") {
					Toggle("Show transcripts", isOn: $draft.showTranscripts)
				}

				Section("Data") {
					Button("Delete all entries", role: .destructive) {
						showsClearConfirmation = true
					}
					.disabled(store.entries.isEmpty || store.isDemoMode)
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
}
