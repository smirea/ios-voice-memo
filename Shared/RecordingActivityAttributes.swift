import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		var isPaused: Bool
	}

	var startedAt: Date
}
