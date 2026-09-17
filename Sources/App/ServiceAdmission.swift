import Foundation

enum ServiceAdmissionError: LocalizedError {
	case timedOut

	var errorDescription: String? {
		"The processing service took too long. Your saved audio is preserved."
	}
}

actor ServiceAdmission {
	static let model = ServiceAdmission()
	static let speech = ServiceAdmission()
	@TaskLocal static var activity: (@Sendable (Bool) async -> Void)?

	private struct Request {
		var id: UUID
		var timeout: Duration?
		var start: @Sendable () -> Task<Void, Never>
		var cancel: @Sendable (any Error) -> Void
	}

	private struct Active {
		var request: Request
		var task: Task<Void, Never>?
		var deadline: Task<Void, Never>?
		var returned = false
	}

	private var suspended = false
	private var suspensionRevision: UInt64 = 0
	private var waiting: [Request] = []
	private var active: Active?

#if DEBUG
	func contractState() -> (waiting: Int, hasActive: Bool, suspended: Bool) {
		(waiting.count, active != nil, suspended)
	}
#endif

	func run<T: Sendable>(
		timeout: Duration? = nil,
		operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		let id = UUID()
		let activity = Self.activity
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			let value: T = try await withCheckedThrowingContinuation { continuation in
				guard !suspended else {
					continuation.resume(throwing: CancellationError())
					return
				}
				waiting.append(Request(
					id: id,
					timeout: timeout,
					start: {
						Task {
							let result: Result<T, any Error>
							var started = false
							do {
								try Task.checkCancellation()
								started = true
								await activity?(true)
								try Task.checkCancellation()
								let value = try await operation()
								try Task.checkCancellation()
								result = .success(value)
							} catch {
								result = .failure(error)
							}
							if started { await activity?(false) }
							await self.finish(id, result: result, continuation: continuation)
						}
					},
					cancel: { continuation.resume(throwing: $0) }
				))
				startNext()
			}
			try Task.checkCancellation()
			return value
		} onCancel: {
			Task { await self.cancel(id, error: CancellationError()) }
		}
	}

	func setSuspended(_ suspended: Bool, revision: UInt64? = nil) {
		if let revision {
			guard revision >= suspensionRevision else { return }
			suspensionRevision = revision
		}
		self.suspended = suspended
		guard suspended else {
			startNext()
			return
		}
		let cancelled = waiting
		waiting.removeAll()
		for request in cancelled { request.cancel(CancellationError()) }
		if let id = active?.request.id { cancel(id, error: CancellationError()) }
	}

	private func startNext() {
		guard !suspended, active == nil, !waiting.isEmpty else { return }
		let request = waiting.removeFirst()
		active = Active(request: request)
		active?.task = request.start()
		if let timeout = request.timeout {
			active?.deadline = Task {
				do { try await Task.sleep(for: timeout) } catch { return }
				cancel(request.id, error: ServiceAdmissionError.timedOut)
			}
		}
	}

	private func cancel(_ id: UUID, error: any Error) {
		if active?.request.id == id {
			guard active?.returned == false else { return }
			active?.returned = true
			active?.deadline?.cancel()
			active?.task?.cancel()
			active?.request.cancel(error)
			return
		}
		guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
		waiting.remove(at: index).cancel(error)
	}

	private func finish<T: Sendable>(
		_ id: UUID,
		result: Result<T, any Error>,
		continuation: CheckedContinuation<T, any Error>
	) {
		guard let finished = active, finished.request.id == id else { return }
		finished.deadline?.cancel()
		if !finished.returned { continuation.resume(with: result) }
		// A canceled native operation still owns admission until it actually exits.
		active = nil
		startNext()
	}
}
