import SwiftUI

@main
struct VoiceMemoApp: App {
	@State private var store = JournalStore()

	var body: some Scene {
		WindowGroup {
			RootView(store: store)
				.preferredColorScheme(.dark)
				.tint(AppStyle.accent)
		}
	}
}
