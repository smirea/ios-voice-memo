import SwiftUI

private enum AppRoute: Hashable {
	case entry(UUID)
	case review
}

private struct RecordingContext: Identifiable {
	let id = UUID()
}

struct RootView: View {
	@Bindable var store: JournalStore
	@State private var path: [AppRoute] = []
	@State private var recordingContext: RecordingContext?
	@State private var showsSettings = false

	init(store: JournalStore) {
		self.store = store
		let arguments = ProcessInfo.processInfo.arguments
		if arguments.contains("-demo-entry"), let entry = store.entries.first(where: { Calendar.current.component(.day, from: $0.createdAt) == 11 }) {
			_path = State(initialValue: [.entry(entry.id)])
		}
		if arguments.contains("-demo-recording") {
			_recordingContext = State(initialValue: RecordingContext())
		}
		if arguments.contains("-demo-review") {
			_path = State(initialValue: [.review])
		}
	}

	var body: some View {
		NavigationStack(path: $path) {
			JournalView(
				store: store,
				onSelectEntry: { path.append(.entry($0.id)) },
				onNewRecording: { recordingContext = RecordingContext() },
				onReview: { path.append(.review) },
				onSettings: { showsSettings = true }
			)
			.toolbar(.hidden, for: .navigationBar)
			.navigationDestination(for: AppRoute.self) { route in
				switch route {
				case let .entry(entryID):
					if let entry = store.entry(id: entryID) {
						EntryView(store: store, entry: entry)
					}
				case .review:
					ReviewView(store: store, date: .now)
				}
			}
		}
		.background(AppStyle.background)
		.fullScreenCover(item: $recordingContext) { _ in
			RecordView(
				store: store,
				onClose: { recordingContext = nil },
				onFinished: { entryID in
					path = [.entry(entryID)]
					recordingContext = nil
				}
			)
		}
		.sheet(isPresented: $showsSettings) {
			SettingsView(store: store)
		}
		.onOpenURL { url in
			guard url.scheme == "myvoicememo", url.host == "record" else { return }
			guard recordingContext == nil else { return }
			path.removeAll()
			recordingContext = RecordingContext()
		}
	}
}
