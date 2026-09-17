import SwiftUI

@main
struct VoiceMemoApp: App {
	@State private var store: JournalStore
	@State private var recordingSession: RecordingSession

	init() {
		let store = JournalStore()
		_store = State(initialValue: store)
		_recordingSession = State(initialValue: RecordingSession(store: store))
	}

	var body: some Scene {
		WindowGroup {
			RootView(store: store, recordingSession: recordingSession)
				.preferredColorScheme(.dark)
				.tint(AppStyle.accent)
				.task {
					#if DEBUG
					await LocalModelProbe.runFromLaunchArguments()
					#endif
					await ReminderBenchmark.runFromLaunchArguments()
					#if DEBUG
					await LocationContractChecks.runFromLaunchArguments()
					await RecordingContractChecks.runFromLaunchArguments()
					await PlaybackContractChecks.runFromLaunchArguments()
					await StorageContractChecks.runFromLaunchArguments()
					#endif
				}
		}
	}
}
