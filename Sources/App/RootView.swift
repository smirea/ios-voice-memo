import SwiftUI

private enum AppRoute: Hashable {
	case entry(UUID)
	case reminderBenchmark
	case review
}

struct RootView: View {
	@Environment(\.scenePhase) private var scenePhase
	@Bindable var store: JournalStore
	@Bindable var recordingSession: RecordingSession
	@State private var path: [AppRoute] = []
	@State private var showsSettings = false

	init(store: JournalStore, recordingSession: RecordingSession) {
		self.store = store
		self.recordingSession = recordingSession
		let arguments = ProcessInfo.processInfo.arguments
		if arguments.contains("-demo-entry"), let entry = store.entries.first(where: { Calendar.current.component(.day, from: $0.createdAt) == 11 }) {
			_path = State(initialValue: [.entry(entry.id)])
		}
		if arguments.contains("-demo-reminders"), let entry = store.entries.first(where: { !$0.reminders.isEmpty }) {
			_path = State(initialValue: [.entry(entry.id)])
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
				onNewRecording: { recordingSession.present(startsImmediately: false) },
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
		.fullScreenCover(item: Binding(
			get: { recordingSession.context },
			// Only finishing or explicitly discarding may dismiss an owned recording session.
			set: { _ in }
		)) { _ in
			RecordView(
				store: store,
				session: recordingSession,
				onClose: { path.removeAll() },
				onFinished: { entryID in
					path = [.entry(entryID)]
				}
			)
		}
		.sheet(isPresented: $showsSettings) {
			SettingsView(store: store)
		}
		.alert("ElevenLabs wasn’t used", isPresented: Binding(
			get: { store.transcriptionAlertMessage != nil },
			set: { if !$0 { store.clearTranscriptionAlert() } }
		)) {
			Button("OK", role: .cancel) { store.clearTranscriptionAlert() }
		} message: {
			Text(store.transcriptionAlertMessage ?? "")
		}
		.alert("Journal storage", isPresented: Binding(
			get: { !showsSettings && recordingSession.context == nil && store.storageErrorMessage != nil },
			set: { if !$0 { store.storageErrorMessage = nil } }
		)) {
			if store.hasUnsavedNoteChanges {
				Button("Try Saving Again") {
					store.storageErrorMessage = nil
					Task { await store.retrySavingChanges() }
				}
			}
			Button("OK", role: .cancel) { store.storageErrorMessage = nil }
		} message: {
			Text(store.storageErrorMessage ?? "")
		}
		.onOpenURL { url in
			guard url.scheme == "myvoicememo" else { return }
			switch url.host {
			case "record":
				guard recordingSession.context == nil else { return }
				path.removeAll()
				recordingSession.present(startsImmediately: true)
			case "entry":
				guard recordingSession.context == nil else { return }
				guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
					.queryItems?
					.first(where: { $0.name == "id" })?
					.value,
					let id = UUID(uuidString: value)
				else { return }
				Task {
					if !store.isDemoMode { try? await store.waitUntilLoaded() }
					guard recordingSession.context == nil, store.entry(id: id) != nil else { return }
					path = [.entry(id)]
				}
			default:
				return
			}
		}
		.task {
			if recordingSession.isVisualDemo {
				recordingSession.present(startsImmediately: true)
			}
			#if DEBUG
			if store.isDemoMode, ProcessInfo.processInfo.arguments.contains("-demo-storage-error") {
				try? await Task.sleep(for: .milliseconds(600))
				store.storageErrorMessage = "Couldn’t delete one note. Its audio is still on this device. Try deleting it again."
			}
			#endif
			await store.refreshCalendar()
		}
		.onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
			store.retryCloudSync()
		}
		.onChange(of: scenePhase) { _, phase in
			guard phase == .active else { return }
			store.resumeStaleProcessing()
			Task { await store.refreshCalendar() }
		}
	}
}
