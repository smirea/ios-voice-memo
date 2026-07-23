import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		var isPaused: Bool
		var locationName: String
		var elapsed: TimeInterval
		var resumedAt: Date?
	}

	var startedAt: Date
}
