import Foundation
import Synchronization

final class CloudFileAccess: Sendable {
	enum Access: Sendable { case read, write, delete }
	enum AccessError: Error {
		case accessorNotInvoked
		case timedOut
		case coordinationAndOperation(any Error, any Error)
	}
	struct Coordination: Sendable {
		var coordinate: @Sendable (Access, URL, (URL) -> Void) throws -> Void
		var cancel: @Sendable () -> Void

		static var live: Coordination {
			let native = NativeCoordinator()
			return Coordination(coordinate: { try native.coordinate($0, at: $1, accessor: $2) }, cancel: { native.cancel() })
		}
	}

	private let queue: OperationQueue
	private let timeout: TimeInterval
	private let makeCoordinator: @Sendable () -> Coordination

	init(timeout: Duration = .seconds(30), makeCoordinator: @escaping @Sendable () -> Coordination = { .live }) {
		self.makeCoordinator = makeCoordinator
		let components = timeout.components
		self.timeout = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
		queue = OperationQueue()
		queue.name = "CloudFileAccess"
		queue.qualityOfService = .utility
		queue.maxConcurrentOperationCount = 1
	}

	func perform<T: Sendable>(
		_ access: Access,
		at url: URL,
		operation: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> T
	) async throws -> T {
		let coordinator = makeCoordinator()
		let cancellation = Cancellation(cancelCoordinator: coordinator.cancel)
		let timeout = timeout
		let value: T = try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				queue.addOperation {
					let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
					deadline.schedule(deadline: .now() + timeout)
					deadline.setEventHandler { cancellation.cancel(AccessError.timedOut) }
					deadline.resume()
					var result = Result<T, any Error> {
						try cancellation.check()
						var accessorResult: Result<T, any Error>?
						var coordinationError: (any Error)?
						do {
							try coordinator.coordinate(access, url) { accessorURL in
								accessorResult = Result {
									try cancellation.check()
									let value = try operation(accessorURL, { try cancellation.check() })
									try cancellation.check()
									return value
								}
							}
						} catch { coordinationError = error }
						try cancellation.check()
						if let coordinationError {
							if case let .failure(operationError) = accessorResult {
								throw AccessError.coordinationAndOperation(coordinationError, operationError)
							}
							throw coordinationError
						}
						guard let accessorResult else { throw AccessError.accessorNotInvoked }
						return try accessorResult.get()
					}
					if let error = cancellation.finish() { result = .failure(error) }
					deadline.cancel()
					continuation.resume(with: result)
				}
			}
		} onCancel: {
			cancellation.cancel()
		}
		try Task.checkCancellation()
		return value
	}

	private final class Cancellation: Sendable {
		private struct State { var error: (any Error)?; var finished = false }
		private let state = Mutex(State())
		private let cancelCoordinator: @Sendable () -> Void
		init(cancelCoordinator: @escaping @Sendable () -> Void) { self.cancelCoordinator = cancelCoordinator }
		func check() throws {
			if let error = state.withLock({ $0.error }) { throw error }
		}
		func cancel(_ error: any Error = CancellationError()) {
			let shouldCancel = state.withLock { value in
				guard value.error == nil, !value.finished else { return false }
				value.error = error
				return true
			}
			if shouldCancel { cancelCoordinator() }
		}
		func finish() -> (any Error)? {
			state.withLock { value in
				value.finished = true
				return value.error
			}
		}
	}

	// Coordination runs on the owned queue; Foundation explicitly permits cancel() from any thread.
	private final class NativeCoordinator: @unchecked Sendable {
		private let coordinator = NSFileCoordinator(filePresenter: nil)
		func coordinate(_ access: Access, at url: URL, accessor: (URL) -> Void) throws {
			var error: NSError?
			switch access {
			case .read:
				coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: accessor)
			case .write:
				coordinator.coordinate(writingItemAt: url, options: [], error: &error, byAccessor: accessor)
			case .delete:
				coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &error, byAccessor: accessor)
			}
			if let error { throw error }
		}
		func cancel() { coordinator.cancel() }
	}
}
