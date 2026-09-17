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
					await RecordingActivityContractChecks.runFromLaunchArguments(session: recordingSession)
					await RecordingPresentationContractChecks.runFromLaunchArguments()
					await CalendarOccurrenceContractChecks.runFromLaunchArguments()
					await ReminderOccurrenceContractChecks.runFromLaunchArguments()
					await CalendarNavigationContractChecks.runFromLaunchArguments()
					await ReminderBenchmarkContractChecks.runFromLaunchArguments()
					await ReminderMatchingContractChecks.runFromLaunchArguments()
					await ReminderFeedbackContractChecks.runFromLaunchArguments()
					await PlaybackContractChecks.runFromLaunchArguments()
					await WaveformDecoderContractChecks.runFromLaunchArguments()
					await PlaybackWaveformContractChecks.runFromLaunchArguments()
					await StorageContractChecks.runFromLaunchArguments()
					await AudioFinalizationContractChecks.runFromLaunchArguments()
					await TranscriptionContractChecks.runFromLaunchArguments()
					await ModelOutcomeContractChecks.runFromLaunchArguments()
					await WeeklyRecordingMetricContractChecks.runFromLaunchArguments()
					await ModelContextContractChecks.runFromLaunchArguments()
					await ReflectionContextContractChecks.runFromLaunchArguments()
					await ReminderContextContractChecks.runFromLaunchArguments()
					await ReminderIdentityContractChecks.runFromLaunchArguments()
					await ReminderValidityContractChecks.runFromLaunchArguments()
					await ReminderExactTargetContractChecks.runFromLaunchArguments()
					await ReminderBackfillContractChecks.runFromLaunchArguments()
					await ReminderDeliveryContractChecks.runFromLaunchArguments()
					await ReminderPresentationContractChecks.runFromLaunchArguments()
					await ReminderPresentationContractChecks.runNativeSmokeFromLaunchArguments()
					await ReminderPresentationContractChecks.runNativePreviewFromLaunchArguments()
					await ProcessingRepositoryContractChecks.runFromLaunchArguments()
					await ProcessingWorkerContractChecks.runFromLaunchArguments()
					await ServiceAdmissionContractChecks.runFromLaunchArguments()
					await ProcessingReliabilityContractChecks.runFromLaunchArguments()
					await ReminderSchedulingContractChecks.runFromLaunchArguments()
					await ReminderSourceRepositoryContractChecks.runFromLaunchArguments()
					await ReminderActivityContractChecks.runFromLaunchArguments()
					await ICloudMirrorContractChecks.runFromLaunchArguments()
					await ICloudStoreContractChecks.runFromLaunchArguments()
					await CloudStateContractChecks.runFromLaunchArguments()
					await CloudFileAccessContractChecks.runFromLaunchArguments()
					await ICloudProviderContractChecks.runFromLaunchArguments()
					await CloudStoreReliabilityContractChecks.runFromLaunchArguments()
					#endif
				}
		}
	}
}
