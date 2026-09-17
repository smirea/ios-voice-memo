@preconcurrency import ActivityKit
import Foundation
import Synchronization

@MainActor
struct ReminderActivityOperations {
	struct Existing {
		var id: String
		var attributes: ReminderActivityAttributes
	}
	var enabled: () -> Bool
	var existing: () -> [Existing]
	var end: (String) async -> Void
	var update: (String, DesiredReminderActivity) async -> Void
	var request: (DesiredReminderActivity, Date) -> Void

	static let live = ReminderActivityOperations(
		enabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
		existing: { Activity<ReminderActivityAttributes>.activities.map { Existing(id: $0.id, attributes: $0.attributes) } },
		end: { id in
			await Activity<ReminderActivityAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
		},
		update: { id, item in
			await Activity<ReminderActivityAttributes>.activities.first { $0.id == id }?.update(item.content)
		},
		request: { item, now in
			if item.startDate > now.addingTimeInterval(5) {
				let alert = AlertConfiguration(
					title: "Up next: \(item.attributes.eventTitle)",
					body: "\(item.state.reminderTexts.first ?? "Event reminders are ready.")",
					sound: .default)
				_ = try? Activity.request(attributes: item.attributes, content: item.content,
					style: .standard, alertConfiguration: alert, start: item.startDate)
			} else {
				_ = try? Activity.request(attributes: item.attributes, content: item.content, style: .standard)
			}
		})
}

@MainActor
final class ReminderActivityManager {
	private struct Request {
		let id: UUID
		let generation: Int
		let desired: [DesiredReminderActivity]
		let now: Date
		let isCurrent: @MainActor () -> Bool
		let cancellation: Cancellation
	}
	private final class Cancellation: Sendable {
		private let value = Mutex(false)
		var isCancelled: Bool { value.withLock { $0 } }
		func cancel() { value.withLock { $0 = true } }
	}
	private let operations: ReminderActivityOperations
	private var generation = 0
	private var latestRequestID = UUID()
	private var pending: Request?
	private var reconciliationTask: Task<Void, Never>?

	init(operations: ReminderActivityOperations = .live) { self.operations = operations }

	func invalidate(generation: Int) {
		guard generation >= self.generation else { return }
		self.generation = generation
		latestRequestID = UUID()
		pending = nil
	}

	func synchronize(
		occurrences: [EventReminderOccurrence],
		settings: JournalSettings,
		now: Date = .now,
		generation: Int,
		isCurrent: @escaping @MainActor () -> Bool = { true }
	) async {
		let enabled = settings.eventRemindersEnabled && settings.eventReminderLiveActivitiesEnabled && operations.enabled()
		let desired = enabled ? desiredActivities(
			from: occurrences.filter { $0.event.endDate > now },
			defaultLeadMinutes: settings.eventReminderLeadMinutes
		) : []
		await submit(desired: desired, now: now, generation: generation, isCurrent: isCurrent)
	}

	func endAll(generation: Int, isCurrent: @escaping @MainActor () -> Bool = { true }) async {
		await submit(desired: [], now: .now, generation: generation, isCurrent: isCurrent)
	}

	private func submit(desired: [DesiredReminderActivity], now: Date, generation: Int,
		isCurrent: @escaping @MainActor () -> Bool) async {
		guard !Task.isCancelled, generation >= self.generation, isCurrent() else { return }
		self.generation = generation
		let cancellation = Cancellation()
		let request = Request(id: UUID(), generation: generation, desired: desired,
			now: now, isCurrent: isCurrent, cancellation: cancellation)
		latestRequestID = request.id
		pending = request
		if reconciliationTask == nil {
			reconciliationTask = Task { await reconcilePending() }
		}
		let task = reconciliationTask
		await withTaskCancellationHandler {
			await task?.value
		} onCancel: {
			cancellation.cancel()
		}
	}

	private func reconcilePending() async {
		defer { reconciliationTask = nil }
		while let request = pending {
			pending = nil
			if isCurrent(request) { await reconcile(request) }
		}
	}

	private func isCurrent(_ request: Request) -> Bool {
		request.id == latestRequestID && request.generation == generation
			&& !request.cancellation.isCancelled && request.isCurrent()
	}

	private func reconcile(_ request: Request) async {
		let desiredKeys = Set(request.desired.map(\.attributes.eventKey))
		let existing = operations.existing()

		for activity in existing where !desiredKeys.contains(activity.attributes.eventKey)
			|| activity.attributes.endDate <= request.now {
			guard isCurrent(request) else { return }
			await operations.end(activity.id)
			guard isCurrent(request) else { return }
		}

		for item in request.desired {
			guard isCurrent(request) else { return }
			if let activity = existing.first(where: {
				$0.attributes.eventKey == item.attributes.eventKey
					&& $0.attributes.startDate == item.attributes.startDate
					&& $0.attributes.endDate == item.attributes.endDate
			}) {
				await operations.update(activity.id, item)
				guard isCurrent(request) else { return }
				continue
			}
			operations.request(item, request.now)
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

struct DesiredReminderActivity {
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
