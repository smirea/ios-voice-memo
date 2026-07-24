@preconcurrency import ActivityKit
import Foundation

@MainActor
final class ReminderActivityManager {
	func synchronize(
		occurrences: [EventReminderOccurrence],
		settings: JournalSettings,
		now: Date = .now
	) async {
		guard settings.eventRemindersEnabled,
			settings.eventReminderLiveActivitiesEnabled,
			ActivityAuthorizationInfo().areActivitiesEnabled
		else {
			await endAll()
			return
		}

		let desired = desiredActivities(
			from: occurrences.filter { $0.event.endDate > now },
			defaultLeadMinutes: settings.eventReminderLeadMinutes
		)
		let desiredKeys = Set(desired.map(\.attributes.eventKey))
		let existing = Activity<ReminderActivityAttributes>.activities

		for activity in existing where !desiredKeys.contains(activity.attributes.eventKey)
			|| activity.attributes.endDate <= now {
			await activity.end(nil, dismissalPolicy: .immediate)
		}

		for item in desired {
			if let activity = existing.first(where: {
				$0.attributes.eventKey == item.attributes.eventKey
					&& $0.attributes.startDate == item.attributes.startDate
					&& $0.attributes.endDate == item.attributes.endDate
			}) {
				await activity.update(item.content)
				continue
			}

			let start = item.startDate
			if start > now.addingTimeInterval(5) {
				let alert = AlertConfiguration(
					title: "Up next: \(item.attributes.eventTitle)",
					body: "\(item.state.reminderTexts.first ?? "Event reminders are ready.")",
					sound: .default
				)
				_ = try? Activity.request(
					attributes: item.attributes,
					content: item.content,
					style: .standard,
					alertConfiguration: alert,
					start: start
				)
			} else {
				_ = try? Activity.request(
					attributes: item.attributes,
					content: item.content,
					style: .standard
				)
			}
		}
	}

	func endAll() async {
		for activity in Activity<ReminderActivityAttributes>.activities {
			await activity.end(nil, dismissalPolicy: .immediate)
		}
	}

	private func desiredActivities(
		from occurrences: [EventReminderOccurrence],
		defaultLeadMinutes: Int
	) -> [DesiredReminderActivity] {
		let groups = Dictionary(grouping: occurrences, by: \.eventKey)
		return groups.values.compactMap { group in
			guard let first = group.first else { return nil }
			let ordered = group.sorted {
				$0.reminder.createdAt > $1.reminder.createdAt
			}
			let texts = ordered.map(\.reminder.text)
			let state = ReminderActivityAttributes.ContentState(
				reminderTexts: Array(texts.prefix(3)),
				additionalReminderCount: max(0, texts.count - 3)
			)
			let leadMinutes = ordered
				.compactMap(\.reminder.leadTimeOverrideMinutes)
				.max() ?? defaultLeadMinutes
			let attributes = ReminderActivityAttributes(
				eventKey: first.eventKey,
				sourceEntryID: first.sourceEntryID,
				eventTitle: first.event.title,
				startDate: first.event.startDate,
				endDate: first.event.endDate
			)
			return DesiredReminderActivity(
				attributes: attributes,
				state: state,
				startDate: first.event.startDate.addingTimeInterval(TimeInterval(-leadMinutes * 60))
			)
		}
		.sorted { $0.attributes.startDate < $1.attributes.startDate }
	}
}

private struct DesiredReminderActivity {
	var attributes: ReminderActivityAttributes
	var state: ReminderActivityAttributes.ContentState
	var startDate: Date

	var content: ActivityContent<ReminderActivityAttributes.ContentState> {
		ActivityContent(
			state: state,
			staleDate: attributes.endDate,
			relevanceScore: 25
		)
	}
}
