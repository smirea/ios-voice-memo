import ActivityKit
import Foundation

struct ReminderActivityAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		var reminderTexts: [String]
		var additionalReminderCount: Int
	}

	var eventKey: String
	var sourceEntryID: UUID
	var eventTitle: String
	var startDate: Date
	var endDate: Date
}
