import SwiftUI

@main
struct VoiceMemoApp: App {
	@State private var store: JournalStore
	@State private var recordingSession: RecordingSession

	init() {
		_ = ProcessingTemporaryFiles.launchDate
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
					_ = await ProcessingTemporaryFiles.shared.cleanOnce()
					#if DEBUG
					await LocalModelProbe.runFromLaunchArguments()
					#endif
					await ReminderBenchmark.runFromLaunchArguments()
					#if DEBUG
					await LocationContractChecks.runFromLaunchArguments()
					await RecordingContractChecks.runFromLaunchArguments()
					await PlaybackContractChecks.runFromLaunchArguments()
					await StorageContractChecks.runFromLaunchArguments()
					await AudioFinalizationContractChecks.runFromLaunchArguments()
					await TranscriptionContractChecks.runFromLaunchArguments()
					await ModelOutcomeContractChecks.runFromLaunchArguments()
					await ProcessingRepositoryContractChecks.runFromLaunchArguments()
					await ProcessingWorkerContractChecks.runFromLaunchArguments()
					await ServiceAdmissionContractChecks.runFromLaunchArguments()
					await ProcessingReliabilityContractChecks.runFromLaunchArguments()
					await ReminderSchedulingContractChecks.runFromLaunchArguments()
					await ReminderSourceRepositoryContractChecks.runFromLaunchArguments()
					await ReminderActivityContractChecks.runFromLaunchArguments()
					#endif
				}
		}
	}
}
