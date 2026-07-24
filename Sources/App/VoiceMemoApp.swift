import SwiftUI

@main
struct VoiceMemoApp: App {
	@State private var store = JournalStore()

	var body: some Scene {
		WindowGroup {
			RootView(store: store)
				.preferredColorScheme(.dark)
				.tint(AppStyle.accent)
				.task {
					await ReminderBenchmark.runFromLaunchArguments()
					#if DEBUG
					await LocationContractChecks.runFromLaunchArguments()
					#endif
				}
		}
	}
}
