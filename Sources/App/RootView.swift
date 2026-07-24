import SwiftUI

private enum AppRoute: Hashable {
	case entry(UUID)
	case reminderBenchmark
	case review
}

private struct RecordingContext: Identifiable {
	let id = UUID()
	let startsImmediately: Bool
}

struct RootView: View {
	@Environment(\.scenePhase) private var scenePhase
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
		if arguments.contains("-demo-reminders"), let entry = store.entries.first(where: { !$0.reminders.isEmpty }) {
			_path = State(initialValue: [.entry(entry.id)])
		}
		if arguments.contains("-demo-recording") {
			_recordingContext = State(initialValue: RecordingContext(startsImmediately: true))
		}
		if arguments.contains("-demo-review") {
			_path = State(initialValue: [.review])
		}
		if arguments.contains("-demo-reminder-benchmark") {
			_path = State(initialValue: [.reminderBenchmark])
		}
		if arguments.contains("-demo-settings") {
			_showsSettings = State(initialValue: true)
		}
	}

	var body: some View {
		NavigationStack(path: $path) {
			JournalView(
				store: store,
				onSelectEntry: { path.append(.entry($0.id)) },
				onNewRecording: { recordingContext = RecordingContext(startsImmediately: false) },
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
				case .reminderBenchmark:
					ReminderBenchmarkView()
				case .review:
					ReviewView(store: store, date: .now)
				}
			}
		}
		.background(AppStyle.background)
		.fullScreenCover(item: $recordingContext) { context in
			RecordView(
				store: store,
				startsImmediately: context.startsImmediately,
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
			guard url.scheme == "myvoicememo" else { return }
			switch url.host {
			case "record":
				guard recordingContext == nil else { return }
				path.removeAll()
				recordingContext = RecordingContext(startsImmediately: true)
			case "entry":
				guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
					.queryItems?
					.first(where: { $0.name == "id" })?
					.value,
					let id = UUID(uuidString: value),
					store.entry(id: id) != nil
				else { return }
				recordingContext = nil
				path = [.entry(id)]
			default:
				return
			}
		}
		.task {
			await store.refreshCalendar()
		}
		.onChange(of: scenePhase) { _, phase in
			guard phase == .active else { return }
			Task { await store.refreshCalendar() }
		}
	}
}
