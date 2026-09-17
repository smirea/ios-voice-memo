#if DEBUG
import Foundation

@MainActor
enum ServiceAdmissionContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-service-admission-contract-tests") else { return }
		do {
			try await waitingCancellationAndDeadline()
			try await activeCancellationAndSuspension()
			try await timeoutQuarantine()
			try await concurrentRequests()
			print("SERVICE ADMISSION CONTRACT: queue cancellation, owned cleanup, admission deadlines, suspension revisions, task context, and serial fanout passed")
			fflush(nil)
		} catch { fatalError("SERVICE ADMISSION CONTRACT: \(error)") }
	}

	private static func waitingCancellationAndDeadline() async throws {
		let gate = ServiceAdmission()
		let events = AdmissionEvents()
		let hold = AdmissionHold()
		defer { Task { await hold.release() } }
		let neverStarted = request(gate, "already-canceled", events)
		neverStarted.cancel()
		try await wait { await events.has("return:already-canceled") }
		try expect(await neverStarted.value == .cancelled, "Already-canceled work must be rejected before admission")
		try expect(await !events.has("start:already-canceled"), "Already-canceled operation must never start")
		let first = request(gate, "first", events, hold: hold)
		try await wait { await events.has("start:first") }
		let canceled = request(gate, "canceled", events)
		try await wait { await gate.contractState().waiting == 1 }
		canceled.cancel()
		try await wait { await events.has("return:canceled") }
		try expect(await canceled.value == .cancelled, "Canceling a waiter must return cancellation")
		try expect(await gate.contractState().waiting == 0, "Canceled waiter must be removed")
		let next = ServiceAdmission.$activity.withValue({ active in
			await events.record(active ? "observer:start" : "observer:finish")
		}) { request(gate, "next", events, timeout: .milliseconds(40)) }
		try await wait { await gate.contractState().waiting == 1 }
		try await Task.sleep(for: .milliseconds(80))
		try expect(await !events.has("return:next"), "Deadline must not run while waiting for admission")
		try expect(await !events.has("observer:start"), "Queued task must not charge admitted time")
		await hold.release()
		try await wait { await events.has("return:next") }
		let nextOutcome = await next.value
		try expect(await first.value == .complete && nextOutcome == .complete, "Release must admit the uncanceled next request")
		try expect(await !events.has("start:canceled"), "Canceled waiter must never run")
		try expect(await events.has("observer:finish"), "Queued request must retain its own task-local observer")
		try expect(await events.maximumActive == 1, "Admission must serialize actual operations")
	}

	private static func activeCancellationAndSuspension() async throws {
		let gate = ServiceAdmission()
		let events = AdmissionEvents()
		let hold = AdmissionHold()
		defer { Task { await hold.release() } }
		let active = ServiceAdmission.$activity.withValue({ running in
			await events.record(running ? "observer:start" : "observer:finish")
		}) { request(gate, "active", events, hold: hold) }
		try await wait { await events.has("start:active") }
		active.cancel()
		try await wait { await events.has("return:active") }
		try expect(await active.value == .cancelled, "Cancel must return before uncooperative cleanup exits")
		try expect(await gate.contractState().hasActive, "Canceled actual operation must retain admission")
		try expect(await !events.has("observer:finish"), "Cancellation must not report actual completion early")
		let waiting = request(gate, "waiting", events)
		try await wait { await gate.contractState().waiting == 1 }
		await gate.setSuspended(true, revision: 3)
		try await wait { await events.has("return:waiting") }
		try expect(await waiting.value == .cancelled, "Suspension must cancel waiters without awaiting active cleanup")
		await gate.setSuspended(false, revision: 2)
		try expect(await gate.contractState().suspended, "A stale resume must not reopen admission")
		let rejected = request(gate, "rejected", events)
		try await wait { await events.has("return:rejected") }
		try expect(await rejected.value == .cancelled, "Suspended gate must reject new work")
		await gate.setSuspended(false, revision: 4)
		let resumed = request(gate, "resumed", events)
		try await wait { await gate.contractState().waiting == 1 }
		try expect(await !events.has("start:resumed"), "Resume must not bypass the canceled operation")
		await hold.release()
		try await wait { await events.has("return:resumed") }
		let observerFinished = await events.has("observer:finish")
		try expect(await resumed.value == .complete && observerFinished, "Actual exit must release admission and finish its observer")
		try expect(await events.maximumActive == 1, "Suspension must never overlap cleanup and resumed service work")
	}

	private static func timeoutQuarantine() async throws {
		let gate = ServiceAdmission()
		let events = AdmissionEvents()
		let hold = AdmissionHold()
		defer { Task { await hold.release() } }
		let timed = request(gate, "timed", events, hold: hold, timeout: .milliseconds(30))
		try await wait { await events.has("return:timed") }
		try expect(await timed.value == .timedOut, "Deadline must return a typed timeout promptly")
		let next = request(gate, "after-timeout", events)
		try await wait { await gate.contractState().waiting == 1 }
		try expect(await !events.has("start:after-timeout"), "Timed-out operation must retain its slot until actual exit")
		await hold.release()
		try await wait { await events.has("return:after-timeout") }
		let maximumActive = await events.maximumActive
		try expect(await next.value == .complete && maximumActive == 1, "Late success must not double-release admission")
	}

	private static func concurrentRequests() async throws {
		let gate = ServiceAdmission()
		let events = AdmissionEvents()
		let hold = AdmissionHold()
		defer { Task { await hold.release() } }
		let first = request(gate, "held", events, hold: hold)
		try await wait { await events.has("start:held") }
		let tasks = (0..<30).map { request(gate, "fanout:\($0)", events) }
		try await wait { await gate.contractState().waiting == 30 }
		for index in stride(from: 0, to: tasks.count, by: 2) { tasks[index].cancel() }
		try await wait { await gate.contractState().waiting == 15 }
		await hold.release()
		try await wait { await events.returnedCount == 31 }
		try expect(await first.value == .complete, "Initial service request must complete")
		for (index, task) in tasks.enumerated() {
			try expect(await task.value == (index.isMultiple(of: 2) ? .cancelled : .complete), "Fanout cancellation must retain each request's result")
		}
		let state = await gate.contractState()
		try expect(await events.maximumActive == 1 && !state.hasActive,
			"Concurrent completions and cancellations must neither leak nor duplicate a permit")
	}

	private static func request(
		_ gate: ServiceAdmission, _ name: String, _ events: AdmissionEvents,
		hold: AdmissionHold? = nil, timeout: Duration? = nil
	) -> Task<Outcome, Never> {
		Task {
			let outcome: Outcome
			do {
				try await gate.run(timeout: timeout) {
					await events.enter(name)
					if let hold { await hold.wait() }
					await events.leave(name)
				}
				outcome = .complete
			} catch is CancellationError { outcome = .cancelled
			} catch is ServiceAdmissionError { outcome = .timedOut
			} catch { outcome = .failed }
			await events.record("return:\(name)")
			return outcome
		}
	}

	private static func wait(_ condition: @Sendable () async -> Bool) async throws {
		for _ in 0..<200 {
			if await condition() { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		throw Failure(message: "Timed out waiting for fixture state")
	}

	private static func expect(_ value: Bool, _ message: String) throws {
		guard value else { throw Failure(message: message) }
	}

	private enum Outcome { case complete, cancelled, timedOut, failed }
	private struct Failure: Error { var message: String }
}

private actor AdmissionEvents {
	private var events: Set<String> = []
	private var active = 0
	private(set) var maximumActive = 0
	var returnedCount: Int { events.filter { $0.hasPrefix("return:") }.count }
	func has(_ value: String) -> Bool { events.contains(value) }
	func record(_ value: String) { events.insert(value) }
	func enter(_ name: String) {
		active += 1
		maximumActive = max(maximumActive, active)
		record("start:\(name)")
	}
	func leave(_ name: String) {
		active -= 1
		record("finish:\(name)")
	}
}

private actor AdmissionHold {
	private var released = false
	private var continuation: CheckedContinuation<Void, Never>?
	func wait() async {
		guard !released else { return }
		await withCheckedContinuation { continuation = $0 }
	}
	func release() {
		released = true
		continuation?.resume()
		continuation = nil
	}
}
#endif
