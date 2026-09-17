import ActivityKit
import Foundation

struct ReminderActivityAttributes: ActivityAttributes, Hashable, Sendable {
	struct ContentState: Codable, Hashable, Sendable {
		var reminderTexts: [String]
		var additionalReminderCount: Int

		func hiddenCount(visibleLimit: Int) -> Int {
			let (total, overflow) = reminderTexts.count.addingReportingOverflow(max(0, additionalReminderCount))
			return (overflow ? Int.max : total) - min(max(0, visibleLimit), reminderTexts.count)
		}
	}

	struct Contributor: Codable, Hashable, Sendable {
		var sourceEntryID: UUID
		var reminderID: UUID
		var inputRevision: Int
	}

	var eventKey: String
	var sourceEntryID: UUID
	var eventTitle: String
	var startDate: Date
	var endDate: Date
	var descriptorVersion: Int = 0
	var triggerDate: Date? = nil
	var calendarIdentifier: String? = nil
	var alertBody: String? = nil
	var eventInputFingerprint: String? = nil
	var contributors: [Contributor] = []

	private enum CodingKeys: CodingKey {
		case eventKey, sourceEntryID, eventTitle, startDate, endDate, descriptorVersion
		case triggerDate, calendarIdentifier, alertBody, eventInputFingerprint, contributors
	}

	init(eventKey: String, sourceEntryID: UUID, eventTitle: String, startDate: Date, endDate: Date,
		descriptorVersion: Int = 0, triggerDate: Date? = nil, calendarIdentifier: String? = nil,
		alertBody: String? = nil, eventInputFingerprint: String? = nil, contributors: [Contributor] = []) {
		self.eventKey = eventKey
		self.sourceEntryID = sourceEntryID
		self.eventTitle = eventTitle
		self.startDate = startDate
		self.endDate = endDate
		self.descriptorVersion = descriptorVersion
		self.triggerDate = triggerDate
		self.calendarIdentifier = calendarIdentifier
		self.alertBody = alertBody
		self.eventInputFingerprint = eventInputFingerprint
		self.contributors = contributors
	}

	init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		eventKey = try values.decode(String.self, forKey: .eventKey)
		sourceEntryID = try values.decode(UUID.self, forKey: .sourceEntryID)
		eventTitle = try values.decode(String.self, forKey: .eventTitle)
		startDate = try values.decode(Date.self, forKey: .startDate)
		endDate = try values.decode(Date.self, forKey: .endDate)
		descriptorVersion = try values.decodeIfPresent(Int.self, forKey: .descriptorVersion) ?? 0
		triggerDate = try values.decodeIfPresent(Date.self, forKey: .triggerDate)
		calendarIdentifier = try values.decodeIfPresent(String.self, forKey: .calendarIdentifier)
		alertBody = try values.decodeIfPresent(String.self, forKey: .alertBody)
		eventInputFingerprint = try values.decodeIfPresent(String.self, forKey: .eventInputFingerprint)
		contributors = try values.decodeIfPresent([Contributor].self, forKey: .contributors) ?? []
	}
}
