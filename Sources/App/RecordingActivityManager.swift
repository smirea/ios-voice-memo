@preconcurrency import ActivityKit
import Foundation

@MainActor
final class RecordingActivityManager {
	private var activity: Activity<RecordingActivityAttributes>?
	private var state = RecordingActivityAttributes.ContentState(
		isPaused: false,
		locationName: "Finding location…",
		elapsed: 0,
		resumedAt: nil
	)

	func start(elapsed: TimeInterval = 0, locationName: String = "Finding location…") {
		guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
		let startedAt = Date.now
		state = RecordingActivityAttributes.ContentState(
			isPaused: false,
			locationName: locationName,
			elapsed: elapsed,
			resumedAt: startedAt
		)
		let attributes = RecordingActivityAttributes(startedAt: startedAt)
		let content = ActivityContent(
			state: state,
			staleDate: nil
		)
		activity = try? Activity.request(attributes: attributes, content: content)
	}

	func setPaused(_ isPaused: Bool, elapsed: TimeInterval) {
		state.isPaused = isPaused
		state.elapsed = elapsed
		state.resumedAt = isPaused ? nil : .now
		update()
	}

	func setLocation(_ locationName: String?) {
		state.locationName = locationName ?? "Location unavailable"
		update()
	}

	private func update() {
		guard let activity else { return }
		let state = state
		Task {
			await activity.update(ActivityContent(
				state: state,
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
