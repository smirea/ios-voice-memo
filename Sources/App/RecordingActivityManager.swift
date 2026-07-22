@preconcurrency import ActivityKit
import Foundation

@MainActor
final class RecordingActivityManager {
	private var activity: Activity<RecordingActivityAttributes>?

	func start() {
		guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
		let attributes = RecordingActivityAttributes(startedAt: .now)
		let content = ActivityContent(
			state: RecordingActivityAttributes.ContentState(isPaused: false),
			staleDate: nil
		)
		activity = try? Activity.request(attributes: attributes, content: content)
	}

	func setPaused(_ isPaused: Bool) {
		guard let activity else { return }
		Task {
			await activity.update(ActivityContent(
				state: RecordingActivityAttributes.ContentState(isPaused: isPaused),
				staleDate: nil
			))
		}
	}

	func end() {
		guard let activity else { return }
		self.activity = nil
		Task {
			await activity.end(nil, dismissalPolicy: .immediate)
		}
	}
}
