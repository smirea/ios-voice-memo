import SwiftUI

private struct PresentedEntry: Identifiable {
	let id: UUID
}

private struct RecordingContext: Identifiable {
	let id = UUID()
	let replacementID: UUID?
}

struct RootView: View {
	@Bindable var store: JournalStore
	@State private var presentedEntry: PresentedEntry?
	@State private var recordingContext: RecordingContext?
	@State private var showsReview = false
	@State private var showsSettings = false

	init(store: JournalStore) {
		self.store = store
		let arguments = ProcessInfo.processInfo.arguments
		if arguments.contains("-demo-entry"), let entry = store.entries.first(where: { Calendar.current.component(.day, from: $0.createdAt) == 11 }) {
			_presentedEntry = State(initialValue: PresentedEntry(id: entry.id))
		}
		if arguments.contains("-demo-recording") {
			_recordingContext = State(initialValue: RecordingContext(replacementID: nil))
		}
		if arguments.contains("-demo-review") {
			_showsReview = State(initialValue: true)
		}
	}

	var body: some View {
		ZStack {
			JournalView(
				store: store,
				onSelectEntry: { presentedEntry = PresentedEntry(id: $0.id) },
				onNewRecording: { recordingContext = RecordingContext(replacementID: nil) },
				onReview: { showsReview = true },
				onSettings: { showsSettings = true }
			)

			if let selection = presentedEntry, let entry = store.entry(id: selection.id) {
				EntryView(
					store: store,
					entry: entry,
					onClose: { presentedEntry = nil },
					onRerecord: {
						presentedEntry = nil
						recordingContext = RecordingContext(replacementID: entry.id)
					}
				)
				.transition(.opacity)
			}

			if showsReview {
				ReviewView(store: store, date: store.selectedDate, onClose: { showsReview = false })
					.transition(.opacity)
			}

			if let context = recordingContext {
				RecordView(
					store: store,
					replacementID: context.replacementID,
					onClose: { recordingContext = nil }
				)
				.transition(.opacity)
			}
		}
		.background(SlateStyle.background)
		.animation(.easeOut(duration: 0.16), value: presentedEntry?.id)
		.animation(.easeOut(duration: 0.16), value: showsReview)
		.animation(.easeOut(duration: 0.16), value: recordingContext?.id)
		.sheet(isPresented: $showsSettings) {
			SettingsView(store: store)
		}
		.onOpenURL { url in
			guard url.scheme == "myvoicememo", url.host == "record" else { return }
			guard recordingContext == nil else { return }
			presentedEntry = nil
			showsReview = false
			recordingContext = RecordingContext(replacementID: nil)
		}
	}
}
