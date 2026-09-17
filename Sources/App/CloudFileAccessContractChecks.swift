#if DEBUG
import Foundation
import Synchronization

@MainActor
enum CloudFileAccessContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-cloud-file-access-contract-tests") else { return }
		do {
			try await nativeAccess()
			try await remappedAccess()
			try await failurePropagation()
			try await cancelledCoordination()
			try await cancelledAccessor()
			try await cancelledCoordination(timedOut: true)
			try await cancelledAccessor(timedOut: true)
			print("CLOUD FILE ACCESS CONTRACT: native access, remapped URLs, error propagation, cancellation, deadlines, and owned cleanup passed")
			fflush(stdout)
		} catch {
			fatalError("CLOUD FILE ACCESS CONTRACT: \(error)")
		}
	}

	private static func nativeAccess() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let url = root.appendingPathComponent("native.txt")
		let access = CloudFileAccess()
		let contents = Data("coordinated contents".utf8)
		let onMainThread = try await access.perform(.write, at: url) { actual, checkCancellation in
			try checkCancellation()
			try contents.write(to: actual, options: .atomic)
			return Thread.isMainThread
		}
		try expect(!onMainThread, "Coordinated IO must run outside the main thread")
		let read = try await access.perform(.read, at: url) { actual, _ in try Data(contentsOf: actual) }
		try expect(read == contents, "Native coordination must read the file written through its accessor")
		try await access.perform(.delete, at: url) { actual, _ in try FileManager.default.removeItem(at: actual) }
		try expect(!FileManager.default.fileExists(atPath: url.path), "Native deletion must remove the coordinated file")
	}

	private static func remappedAccess() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let requested = root.appendingPathComponent("requested.txt")
		let remapped = root.appendingPathComponent("remapped.txt")
		let original = Data("original".utf8)
		try original.write(to: requested)
		let access = CloudFileAccess(makeCoordinator: {
			.init(coordinate: { _, _, accessor in accessor(remapped) }, cancel: {})
		})
		let contents = Data("replacement".utf8)
		let used = try await access.perform(.write, at: requested) { actual, _ in
			try contents.write(to: actual)
			return actual
		}
		let read = try await access.perform(.read, at: requested) { actual, _ in try Data(contentsOf: actual) }
		try await access.perform(.delete, at: requested) { actual, _ in try FileManager.default.removeItem(at: actual) }
		try expect(used == remapped && read == contents && !FileManager.default.fileExists(atPath: remapped.path),
			"Read, write, and deletion must use the actual accessor URL")
		try expect(try Data(contentsOf: requested) == original, "Remapped coordination must never modify the original requested path")
	}

	private static func failurePropagation() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let url = root.appendingPathComponent("preserved.txt")
		let staging = root.appendingPathComponent("staging.txt")
		let contents = Data("preserve original".utf8)
		try contents.write(to: url)
		let coordinatorFailure = CloudFileAccess(makeCoordinator: {
			.init(coordinate: { _, _, _ in throw ProbeError.coordination }, cancel: {})
		})
		let failed = await failure {
			try await coordinatorFailure.perform(.write, at: url) { actual, _ in try Data().write(to: actual) }
		}
		try expect(failed as? ProbeError == .coordination, "A coordinator failure before the accessor must propagate")
		let absentAccessor = CloudFileAccess(makeCoordinator: { .init(coordinate: { _, _, _ in }, cancel: {}) })
		let absent = await failure { try await absentAccessor.perform(.read, at: url) { _, _ in true } }
		guard case .accessorNotInvoked = absent as? CloudFileAccess.AccessError else {
			throw Failure(message: "A coordinator that skips its accessor must not report success")
		}
		let operationFailure = await failure {
			let _: Void = try await CloudFileAccess().perform(.write, at: url) { _, _ in
				defer { try? FileManager.default.removeItem(at: staging) }
				try Data("staged replacement".utf8).write(to: staging)
				throw ProbeError.operation
			}
		}
		try expect(operationFailure as? ProbeError == .operation, "Accessor errors must propagate independently of coordination errors")
		try expect(try Data(contentsOf: url) == contents && !FileManager.default.fileExists(atPath: staging.path),
			"An accessor failure before replacement must finish cleanup and preserve the original destination")
		let both = CloudFileAccess(makeCoordinator: {
			.init(coordinate: { _, actual, accessor in accessor(actual); throw ProbeError.coordination }, cancel: {})
		})
		let combined = await failure {
			let _: Void = try await both.perform(.read, at: url) { _, _ in throw ProbeError.operation }
		}
		guard case let .coordinationAndOperation(coordinator, operation) = combined as? CloudFileAccess.AccessError else {
			throw Failure(message: "Simultaneous coordination and accessor failures must both be retained")
		}
		try expect(coordinator as? ProbeError == .coordination && operation as? ProbeError == .operation, "Combined errors must preserve each original cause")
	}

	private static func cancelledCoordination(timedOut: Bool = false) async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let url = root.appendingPathComponent("cancelled.txt")
		let probe = Probe(holdBeforeAccessor: true)
		let access = CloudFileAccess(timeout: timedOut ? .milliseconds(100) : .seconds(30), makeCoordinator: { probe.nextCoordinator() })
		let first = Task {
			try await access.perform(.write, at: url) { actual, _ in try Data("obsolete".utf8).write(to: actual) }
		}
		try await wait { probe.snapshot.starts == [1] }
		if !timedOut { first.cancel() }
		let failed = await failure { try await first.value }
		try expect(expectedStop(failed, timedOut: timedOut) && probe.snapshot.cancelled == [1], "Cancellation and deadlines must reach the owned native coordinator while preserving their distinct errors")
		try expect(!FileManager.default.fileExists(atPath: url.path), "Cancellation before the accessor must prevent file mutation")
		let contents = Data("next request".utf8)
		try await access.perform(.write, at: url) { actual, _ in try contents.write(to: actual) }
		try expect(try Data(contentsOf: url) == contents && probe.snapshot.ends == [1, 2], "The queue must make progress after cancelled coordination drains")
	}

	private static func cancelledAccessor(timedOut: Bool = false) async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let url = root.appendingPathComponent("serial.txt")
		let staging = root.appendingPathComponent("staging.txt")
		let original = Data("original".utf8)
		try original.write(to: url)
		let probe = Probe(holdBeforeAccessor: false)
		let access = CloudFileAccess(timeout: timedOut ? .milliseconds(100) : .seconds(30), makeCoordinator: { probe.nextCoordinator() })
		let first = Task {
			defer { probe.change { $0.callerReturned = true } }
			try await access.perform(.write, at: url) { actual, checkCancellation in
				defer {
					try? FileManager.default.removeItem(at: staging)
					probe.change { $0.cleanupFinished = true }
				}
				try Data("obsolete".utf8).write(to: staging)
				probe.change { $0.accessorStarted = true }
				try probe.awaitRelease()
				try checkCancellation()
				_ = try FileManager.default.replaceItemAt(actual, withItemAt: staging)
			}
		}
		try await wait { probe.snapshot.accessorStarted }
		if !timedOut { first.cancel() }
		try await wait { probe.snapshot.cancelled == [1] }
		let second = Task {
			try await access.perform(.write, at: url) { actual, _ in
				guard probe.snapshot.cleanupFinished else { throw ProbeError.overlap }
				try Data("latest".utf8).write(to: actual)
			}
		}
		try await wait { probe.snapshot.factoryCalls == 2 }
		try expect(!probe.snapshot.callerReturned && probe.snapshot.starts == [1], "Cancellation must retain the serial slot and caller lifetime until a running accessor exits")
		probe.release()
		let failed = await failure { try await first.value }
		try await second.value
		try expect(expectedStop(failed, timedOut: timedOut) && probe.snapshot.maximumActive == 1 && probe.snapshot.ends == [1, 2],
			"The next operation must start only after cancelled accessor cleanup completes")
		try expect(try Data(contentsOf: url) == Data("latest".utf8) && !FileManager.default.fileExists(atPath: staging.path),
			"Cancelled staging must be cleaned before the replacement operation commits")
	}

	private static func expectedStop(_ error: (any Error)?, timedOut: Bool) -> Bool {
		if !timedOut { return error is CancellationError }
		if case .timedOut = error as? CloudFileAccess.AccessError { return true }
		return false
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-access-contract-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private static func failure<T>(_ operation: () async throws -> T) async -> (any Error)? {
		do { _ = try await operation(); return nil } catch { return error }
	}

	private static func wait(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure(message: "Timed out waiting for coordinated access") }
			await Task.yield()
		}
	}

	private static func expect(_ condition: Bool, _ message: String) throws {
		if !condition { throw Failure(message: message) }
	}
	private struct Failure: Error, CustomStringConvertible {
		var message: String
		var description: String { message }
	}
	private enum ProbeError: Error { case coordination, operation, timeout, overlap }

	private final class Probe: Sendable {
		struct State: Sendable {
			var factoryCalls = 0
			var starts: [Int] = []
			var ends: [Int] = []
			var cancelled: Set<Int> = []
			var active = 0
			var maximumActive = 0
			var accessorStarted = false
			var cleanupFinished = false
			var callerReturned = false
		}
		private let state = Mutex(State())
		private let gate = DispatchSemaphore(value: 0)
		private let holdBeforeAccessor: Bool
		init(holdBeforeAccessor: Bool) { self.holdBeforeAccessor = holdBeforeAccessor }
		var snapshot: State { state.withLock { $0 } }
		func change(_ mutation: (inout State) -> Void) { state.withLock { mutation(&$0) } }
		func release() { gate.signal() }
		func awaitRelease() throws {
			guard gate.wait(timeout: .now() + 5) == .success else { throw ProbeError.timeout }
		}
		func nextCoordinator() -> CloudFileAccess.Coordination {
			let index = state.withLock { value in value.factoryCalls += 1; return value.factoryCalls }
			return .init(coordinate: { _, url, accessor in
				self.change { $0.starts.append(index); $0.active += 1; $0.maximumActive = max($0.maximumActive, $0.active) }
				defer { self.change { $0.ends.append(index); $0.active -= 1 } }
				if index == 1 && self.holdBeforeAccessor {
					try self.awaitRelease()
					if self.snapshot.cancelled.contains(index) { throw ProbeError.coordination }
				}
				accessor(url)
			}, cancel: {
				self.change { $0.cancelled.insert(index) }
				if self.holdBeforeAccessor { self.release() }
			})
		}
	}
}
#endif
