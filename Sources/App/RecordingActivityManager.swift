@preconcurrency import ActivityKit
import Foundation

@MainActor
struct RecordingActivityOperations {
	typealias State = RecordingActivityAttributes.ContentState
	struct Existing {
		var id: String
		var attributes: RecordingActivityAttributes
		var state: ActivityState = .active
		var content: State? = nil
		var isLive: Bool { state != .ended && state != .dismissed }
	}
	var enabled: () -> Bool
	var existing: () -> [Existing]
	var request: (RecordingActivityAttributes, State) throws -> String
	var update: (String, State) async -> Void
	var end: (String, State) async -> Void

	static let disabled = RecordingActivityOperations(enabled: { false }, existing: { [] },
		request: { _, _ in throw ActivityAuthorizationError.unsupported }, update: { _, _ in }, end: { _, _ in })

	static let live = RecordingActivityOperations(
		enabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
		existing: { Activity<RecordingActivityAttributes>.activities.map {
			Existing(id: $0.id, attributes: $0.attributes, state: $0.activityState, content: $0.content.state)
		} },
		request: { attributes, state in
			try Activity.request(attributes: attributes, content: content(state)).id
		},
		update: { id, state in
			await Activity<RecordingActivityAttributes>.activities.first { $0.id == id }?.update(content(state))
		},
		end: { id, state in
			await Activity<RecordingActivityAttributes>.activities.first { $0.id == id }?.end(content(state), dismissalPolicy: .immediate)
		})

	private static func content(_ state: State) -> ActivityContent<State> {
		ActivityContent(state: state, staleDate: state.freshUntil, relevanceScore: 100)
	}
}

@MainActor
final class RecordingActivityManager {
	typealias State = RecordingActivityAttributes.ContentState
	private struct Desired {
		var attributes: RecordingActivityAttributes
		var state: State
		var prepare: @MainActor () async -> Bool
	}
	let initialActivities: [RecordingActivityOperations.Existing]
	private(set) var lastFailure: String?
	private let operations: RecordingActivityOperations
	private var orphans: [RecordingActivityOperations.Existing]
	private var desired: Desired?
	private var owned: RecordingActivityOperations.Existing?
	private var finalStates: [UUID: State] = [:]
	private var attemptedCaptureID: UUID?
	private var revision = UUID()
	private var worker: Task<Void, Never>?

	init(operations: RecordingActivityOperations? = nil) {
		let operations = operations ?? .live
		self.operations = operations
		initialActivities = operations.existing().filter(\.isLive)
		orphans = initialActivities
		if !orphans.isEmpty { enqueue() }
	}

	func start(captureID: UUID, startedAt: Date, state: State,
		prepare: @escaping @MainActor () async -> Bool = { true }) {
		if desired?.attributes.captureID != captureID {
			attemptedCaptureID = nil
			lastFailure = nil
		}
		desired = Desired(attributes: .init(startedAt: startedAt, captureID: captureID), state: state, prepare: prepare)
		enqueue()
	}

	func update(captureID: UUID, state: State) {
		guard desired?.attributes.captureID == captureID else { return }
		desired?.state = state
		enqueue()
	}

	func end(captureID: UUID, state: State) {
		guard desired?.attributes.captureID == captureID else { return }
		if owned?.attributes.captureID == captureID { finalStates[captureID] = Self.frozen(state) }
		desired = nil
		enqueue()
	}

	func waitUntilSettled() async {
		while let worker { await worker.value }
	}

	private func enqueue() {
		revision = UUID()
		if worker == nil { worker = Task { await reconcile() } }
	}

	private func reconcile() async {
		defer { worker = nil }
		while !orphans.isEmpty {
			let orphan = orphans.removeFirst()
			await operations.end(orphan.id, Self.frozen(orphan.content ?? Self.unverifiedState))
		}
		while true {
			let revision = revision
			let desired = desired
			if let owned, owned.attributes.captureID != desired?.attributes.captureID || desired == nil {
				let final = owned.attributes.captureID.flatMap { finalStates.removeValue(forKey: $0) }
				await operations.end(owned.id, final ?? Self.frozen(owned.content ?? Self.unverifiedState))
				self.owned = nil
				continue
			}
			guard let desired, let captureID = desired.attributes.captureID else { return }
			if let owned {
				guard operations.existing().contains(where: { $0.id == owned.id && $0.isLive }) else {
					self.owned = nil
					continue
				}
				if owned.content != desired.state {
					await operations.update(owned.id, desired.state)
					self.owned?.content = desired.state
				}
				if revision == self.revision { return }
				continue
			}
			guard attemptedCaptureID != captureID else { return }
			let prepared = await desired.prepare()
			guard revision == self.revision else { continue }
			attemptedCaptureID = captureID
			guard prepared, operations.enabled() else { return }
			do {
				let id = try operations.request(desired.attributes, desired.state)
				owned = .init(id: id, attributes: desired.attributes, content: desired.state)
			} catch {
				lastFailure = "The recording Live Activity could not be shown. Recording continues in the app."
				#if DEBUG
				print("RECORDING ACTIVITY REQUEST FAILED: \(String(reflecting: error))")
				#endif
			}
			if revision == self.revision { return }
		}
	}

	private static func frozen(_ state: State) -> State {
		var state = state
		state.isPaused = true
		state.resumedAt = nil
		state.status = .stopped
		return state
	}

	private static var unverifiedState: State {
		.init(isPaused: true, locationName: "Location unavailable", elapsed: 0, resumedAt: nil)
	}
}
