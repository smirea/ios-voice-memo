@preconcurrency import ActivityKit
import CryptoKit
import Foundation
import Synchronization

struct ReminderActivitySource: Sendable {
	var entry: JournalEntry
	var inputRevision: Int
}

struct ReminderPresentationResult: Sendable {
	var requestedCount = 0
	var activeCount = 0
	var deferredCount = 0
	var unavailableReason: String?
	var failures: [String] = []
}

@MainActor
struct ReminderActivityOperations {
	struct Existing {
		var id: String
		var attributes: ReminderActivityAttributes
		var state: ActivityState = .active
		var content: ReminderActivityAttributes.ContentState? = nil
		var isLive: Bool { state != .ended && state != .dismissed }
	}
	var enabled: () -> Bool
	var existing: () -> [Existing]
	var end: (String) async -> Void
	var update: (String, DesiredReminderActivity) async -> Void
	var request: (DesiredReminderActivity, Date) throws -> String

	static let disabled = ReminderActivityOperations(enabled: { false }, existing: { [] },
		end: { _ in }, update: { _, _ in }, request: { _, _ in throw ActivityAuthorizationError.unsupported })

	static let live = ReminderActivityOperations(
		enabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
		existing: { Activity<ReminderActivityAttributes>.activities.map {
			Existing(id: $0.id, attributes: $0.attributes, state: $0.activityState, content: $0.content.state)
		} },
		end: { id in
			await Activity<ReminderActivityAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
		},
		update: { id, item in
			await Activity<ReminderActivityAttributes>.activities.first { $0.id == id }?.update(item.content)
		},
		request: { item, now in
			if item.startDate > now.addingTimeInterval(5) {
				let alert = AlertConfiguration(title: "Up next: \(item.attributes.eventTitle)",
					body: "\(item.attributes.alertBody ?? "Event reminders are ready.")", sound: .default)
				return try Activity.request(attributes: item.attributes, content: item.content,
					style: .standard, alertConfiguration: alert, start: item.startDate).id
			}
			return try Activity.request(attributes: item.attributes, content: item.content, style: .standard).id
		})
}

@MainActor
final class ReminderActivityManager {
	private final class ResultBox { var value = ReminderPresentationResult() }
	private struct Request {
		let id = UUID()
		let generation: Int
		let desired: [DesiredReminderActivity]
		let retirementOnly: Bool
		let now: Date
		let isCurrent: @MainActor () -> Bool
		let cancellation = Cancellation()
		let result = ResultBox()
	}
	private final class Cancellation: Sendable {
		private let value = Mutex(false)
		var isCancelled: Bool { value.withLock { $0 } }
		func cancel() { value.withLock { $0 = true } }
	}
	private let operations: ReminderActivityOperations
	private let usesNativeOperations: Bool
	private var generation = 0
	private var latestRequestID = UUID()
	private var pending: Request?
	private var reconciliationTask: Task<Void, Never>?
	private var captureSuspended = false
	private var observationTasks: [Task<Void, Never>] = []
	private var activityObservers: [String: Task<Void, Never>] = [:]
	private var knownActivityIDs = Set<String>()
	private var managedEndIDs = Set<String>()
	private var dismissedDescriptors = Set<ReminderActivityAttributes>()
	private var changeTask: Task<Void, Never>?
	var onChange: (() -> Void)?

	init(operations: ReminderActivityOperations? = nil) {
		self.operations = operations ?? .live
		usesNativeOperations = operations == nil
		if operations == nil { observeNativeChanges() }
	}

	deinit {
		for task in observationTasks { task.cancel() }
		for task in activityObservers.values { task.cancel() }
		changeTask?.cancel()
	}

	func invalidate(generation: Int) {
		guard generation >= self.generation else { return }
		self.generation = generation
		latestRequestID = UUID()
		pending = nil
		if captureSuspended { enqueue(Request(generation: generation, desired: [], retirementOnly: false, now: .now, isCurrent: { true })) }
	}

	func setCaptureSuspended(_ suspended: Bool, generation: Int) {
		guard generation >= self.generation else { return }
		captureSuspended = suspended
		invalidate(generation: generation)
	}

	func waitForCaptureSuspension() async -> Bool {
		while captureSuspended, let task = reconciliationTask { await task.value }
		return captureSuspended && !operations.existing().contains(where: \.isLive)
	}

	@discardableResult
	func synchronize(occurrences: [EventReminderOccurrence], settings: JournalSettings,
		sourceRevisions: [UUID: Int] = [:], now: Date = .now, generation: Int,
		isCurrent: @escaping @MainActor () -> Bool = { true }) async -> ReminderPresentationResult {
		guard !Task.isCancelled, generation >= self.generation, isCurrent() else { return .init() }
		let reason = unavailableReason(settings: settings)
		let all = reason == nil ? Self.desiredActivities(from: occurrences, defaultLeadMinutes: settings.eventReminderLeadMinutes,
			sourceRevisions: sourceRevisions, now: now) : []
		dismissedDescriptors.formIntersection(Set(all.map(\.attributes)))
		let available = all.filter { !dismissedDescriptors.contains($0.attributes) }
		let eligible = available.filter { $0.startDate <= now.addingTimeInterval(86_400) }
		let desired = Array(eligible.prefix(2))
		return await submit(desired: desired, retirementOnly: false, now: now, generation: generation,
			isCurrent: isCurrent, result: ReminderPresentationResult(deferredCount: max(0, available.count - desired.count), unavailableReason: reason))
	}

	@discardableResult
	func retireObsolete(sources: [ReminderActivitySource], events: [JournalCalendarEvent], settings: JournalSettings,
		now: Date = .now, generation: Int, isCurrent: @escaping @MainActor () -> Bool = { true }) async -> ReminderPresentationResult {
		guard !Task.isCancelled, generation >= self.generation, isCurrent() else { return .init() }
		let reason = unavailableReason(settings: settings)
		let sourcesByID = Dictionary(sources.map { ($0.entry.id, $0) }, uniquingKeysWith: { _, latest in latest })
		var retained: [DesiredReminderActivity] = []
		if reason == nil, settings.calendarSyncEnabled {
			for existing in operations.existing() where existing.isLive {
				let attributes = existing.attributes
				guard attributes.descriptorVersion == 1, !attributes.contributors.isEmpty,
					let calendarID = attributes.calendarIdentifier,
					settings.includedCalendarIdentifiers?.contains(calendarID) ?? true else { continue }
				let matches = events.filter { $0.focusKey == attributes.eventKey && $0.calendarIdentifier == calendarID }
				guard matches.count == 1 else { continue }
				let event = matches[0]
				let occurrences = attributes.contributors.compactMap { contributor -> EventReminderOccurrence? in
					guard let source = sourcesByID[contributor.sourceEntryID], source.inputRevision == contributor.inputRevision,
						let rule = source.entry.reminders.first(where: { $0.id == contributor.reminderID }), rule.allows(event, at: now)
					else { return nil }
					return EventReminderOccurrence(sourceEntryID: source.entry.id, reminder: rule, event: event)
				}
				guard occurrences.count == attributes.contributors.count else { continue }
				let revisions = sourcesByID.mapValues(\.inputRevision)
				if let rebuilt = Self.desiredActivities(from: occurrences, defaultLeadMinutes: settings.eventReminderLeadMinutes,
					sourceRevisions: revisions, now: now).first, rebuilt.attributes == attributes,
					rebuilt.startDate <= now.addingTimeInterval(86_400) { retained.append(rebuilt) }
			}
		}
		return await submit(desired: retained, retirementOnly: true, now: now, generation: generation,
			isCurrent: isCurrent, result: ReminderPresentationResult(unavailableReason: reason))
	}

	@discardableResult
	func endAll(generation: Int, isCurrent: @escaping @MainActor () -> Bool = { true }) async -> ReminderPresentationResult {
		await submit(desired: [], retirementOnly: false, now: .now, generation: generation, isCurrent: isCurrent)
	}

	private func unavailableReason(settings: JournalSettings) -> String? {
		guard settings.eventRemindersEnabled && settings.eventReminderLiveActivitiesEnabled else { return "Reminder Live Activities are turned off." }
		guard operations.enabled() else { return "Live Activities are unavailable or disabled for this app." }
		return captureSuspended ? "Reminder Live Activities are paused while recording." : nil
	}

	private func submit(desired: [DesiredReminderActivity], retirementOnly: Bool, now: Date, generation: Int,
		isCurrent: @escaping @MainActor () -> Bool, result: ReminderPresentationResult = .init()) async -> ReminderPresentationResult {
		guard !Task.isCancelled, generation >= self.generation, isCurrent() else { return result }
		self.generation = generation
		let request = Request(generation: generation, desired: captureSuspended ? [] : desired,
			retirementOnly: retirementOnly, now: now, isCurrent: isCurrent)
		request.result.value = result
		enqueue(request)
		let task = reconciliationTask
		let cancellation = request.cancellation
		await withTaskCancellationHandler { await task?.value } onCancel: { cancellation.cancel() }
		return request.result.value
	}

	private func enqueue(_ request: Request) {
		latestRequestID = request.id
		pending = request
		if reconciliationTask == nil { reconciliationTask = Task { await reconcilePending() } }
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
		let desired = request.desired.filter { !dismissedDescriptors.contains($0.attributes) }
		let existing = operations.existing().filter(\.isLive).sorted { $0.id < $1.id }
		var retained: [ReminderActivityAttributes: ReminderActivityOperations.Existing] = [:]
		for activity in existing {
			guard isCurrent(request) else { return }
			if desired.contains(where: { $0.attributes == activity.attributes }), retained[activity.attributes] == nil {
				retained[activity.attributes] = activity
			} else {
				if usesNativeOperations { managedEndIDs.insert(activity.id) }
				await operations.end(activity.id)
				if usesNativeOperations {
					activityObservers.removeValue(forKey: activity.id)?.cancel()
					knownActivityIDs.remove(activity.id)
					managedEndIDs.remove(activity.id)
				}
				guard isCurrent(request) else { return }
			}
		}
		request.result.value.activeCount = retained.count
		guard !request.retirementOnly else { return }
		for item in desired {
			guard isCurrent(request), !captureSuspended else { return }
			if let activity = retained[item.attributes] {
				if activity.content != item.state {
					await operations.update(activity.id, item)
					guard isCurrent(request) else { return }
				}
				continue
			}
			do {
				let id = try operations.request(item, request.now)
				if usesNativeOperations {
					knownActivityIDs.insert(id)
					if let activity = Activity<ReminderActivityAttributes>.activities.first(where: { $0.id == id }) { observe(activity) }
				}
				request.result.value.requestedCount += 1
				request.result.value.activeCount += 1
			} catch {
				request.result.value.failures.append(Self.requestFailure(error))
			}
		}
	}

	static func desiredActivities(from occurrences: [EventReminderOccurrence], defaultLeadMinutes: Int,
		sourceRevisions: [UUID: Int] = [:], now: Date) -> [DesiredReminderActivity] {
		let valid = occurrences.filter { $0.event.endDate > now && $0.reminder.allows($0.event, at: now)
			&& $0.event.startDate.timeIntervalSinceReferenceDate.isFinite && $0.event.endDate.timeIntervalSinceReferenceDate.isFinite }
		return Dictionary(grouping: valid, by: \.eventKey).values.compactMap { group in
			let ordered = group.sorted {
				if $0.reminder.createdAt != $1.reminder.createdAt { return $0.reminder.createdAt > $1.reminder.createdAt }
				if $0.reminder.id != $1.reminder.id { return $0.reminder.id.uuidString < $1.reminder.id.uuidString }
				return $0.sourceEntryID.uuidString < $1.sourceEntryID.uuidString
			}
			guard let first = ordered.first else { return nil }
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys]
			guard let eventData = try? encoder.encode(first.event) else { return nil }
			let eventFingerprint = SHA256.hash(data: eventData).map { String(format: "%02x", $0) }.joined()
			let texts = ordered.map(\.reminder.text)
			let lead = ordered.map { min(1_440, max(0, $0.reminder.leadTimeOverrideMinutes ?? defaultLeadMinutes)) }.max() ?? 0
			let trigger = first.event.startDate.addingTimeInterval(-Double(lead) * 60)
			let contributors = ordered.map { ReminderActivityAttributes.Contributor(sourceEntryID: $0.sourceEntryID,
				reminderID: $0.reminder.id, inputRevision: sourceRevisions[$0.sourceEntryID] ?? 0) }
			let attributes = ReminderActivityAttributes(eventKey: first.eventKey, sourceEntryID: first.sourceEntryID,
				eventTitle: first.event.title, startDate: first.event.startDate, endDate: first.event.endDate,
				descriptorVersion: 1, triggerDate: trigger, calendarIdentifier: first.event.calendarIdentifier,
				alertBody: texts.first, eventInputFingerprint: eventFingerprint, contributors: contributors)
			return DesiredReminderActivity(attributes: attributes,
				state: .init(reminderTexts: Array(texts.prefix(3)), additionalReminderCount: max(0, texts.count - 3)), startDate: trigger)
		}.sorted {
			if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
			if $0.attributes.startDate != $1.attributes.startDate { return $0.attributes.startDate < $1.attributes.startDate }
			return $0.attributes.eventKey < $1.attributes.eventKey
		}
	}

	private static func requestFailure(_ error: any Error) -> String {
		switch error as? ActivityAuthorizationError {
		case .denied: "Live Activities are disabled for this app."
		case .globalMaximumExceeded, .targetMaximumExceeded: "The system has no room for another Live Activity. Try again later."
		case .visibility: "Open the app to schedule reminder Live Activities."
		case .attributesTooLarge: "This reminder group is too large for a Live Activity. Its reminders are saved in the note."
		case .unsupported, .unsupportedTarget: "Live Activities are unavailable on this device."
		default: "A reminder Live Activity could not be scheduled. Try again."
		}
	}

	private func observeNativeChanges() {
		let authorization = ActivityAuthorizationInfo()
		observationTasks.append(Task { [weak self] in
			var previous = authorization.areActivitiesEnabled
			for await enabled in authorization.activityEnablementUpdates {
				guard !Task.isCancelled else { return }
				if enabled != previous { previous = enabled; self?.notifyChange() }
			}
		})
		for activity in Activity<ReminderActivityAttributes>.activities { observe(activity) }
		observationTasks.append(Task { [weak self] in
			for await activity in Activity<ReminderActivityAttributes>.activityUpdates {
				guard !Task.isCancelled, let self else { return }
				let isNew = !self.knownActivityIDs.contains(activity.id)
				self.observe(activity)
				if isNew, activity.activityState != .ended && activity.activityState != .dismissed { self.notifyChange() }
			}
		})
	}

	private func observe(_ activity: Activity<ReminderActivityAttributes>) {
		guard activity.activityState != .ended && activity.activityState != .dismissed else { return }
		guard activityObservers[activity.id] == nil else { return }
		knownActivityIDs.insert(activity.id)
		activityObservers[activity.id] = Task { [weak self] in
			var previous = activity.activityState
			for await state in activity.activityStateUpdates {
				guard !Task.isCancelled, let self else { return }
				if state == .ended || state == .dismissed {
					let managed = self.managedEndIDs.remove(activity.id) != nil
					if !managed { self.dismissedDescriptors.insert(activity.attributes); self.notifyChange() }
					self.activityObservers[activity.id] = nil
					self.knownActivityIDs.remove(activity.id)
					return
				}
				guard state != previous else { continue }
				previous = state
				if state == .stale { self.notifyChange() }
			}
		}
	}

	private func notifyChange() {
		guard changeTask == nil else { return }
		changeTask = Task { [weak self] in
			await Task.yield()
			guard let self, !Task.isCancelled else { return }
			self.changeTask = nil
			self.onChange?()
		}
	}
}

struct DesiredReminderActivity: Equatable {
	var attributes: ReminderActivityAttributes
	var state: ReminderActivityAttributes.ContentState
	var startDate: Date

	var content: ActivityContent<ReminderActivityAttributes.ContentState> {
		ActivityContent(state: state, staleDate: attributes.endDate, relevanceScore: 25)
	}
}
