#if DEBUG
import Foundation

@MainActor
enum RecordingContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-recording-contract-tests") else { return }
		guard ProcessInfo.processInfo.arguments.contains("-demo"),
			!ProcessInfo.processInfo.arguments.contains("-demo-recording")
		else { fatalError("Recording contract checks require -demo without -demo-recording") }
		do {
			try await run()
			print("RECORDING CONTRACT: startup cancellation, reopening, failure cleanup, and session ownership passed")
			fflush(stdout)
		} catch {
			fatalError("RECORDING CONTRACT: \(error)")
		}
	}

	private static func run() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("recording-contract-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let store = JournalStore(storageRootURL: root)
		let permission = PermissionGate()
		let recorder = AudioRecorder(permissionRequest: { await permission.request() })
		let session = RecordingSession(store: store, recorder: recorder)
		let pendingURL = root.appendingPathComponent("pending-recording.json")

		session.present(startsImmediately: true)
		try await permission.waitForRequest(1)
		let cancelledStart = session.startupTask!
		let originalContext = session.context?.id
		session.present(startsImmediately: true)
		try expect(session.context?.id == originalContext, "Opening the recorder again must preserve its session")
		try expect(permission.requests.count == 1, "One session must not create competing microphone requests")
		session.discard()
		permission.resolve(0, granted: true)
		await cancelledStart.value
		try expect(!recorder.isRecording && session.context == nil, "Granting permission after discard must not start invisible capture")
		try expect(!FileManager.default.fileExists(atPath: pendingURL.path), "Discard must remove the cancelled session's recovery metadata")
		try expect(try recordingFiles(in: root).isEmpty, "Cancelled startup must not create orphan audio")

		session.present(startsImmediately: true)
		try await permission.waitForRequest(2)
		let failedStart = session.startupTask!
		permission.resolve(1, granted: false)
		await failedStart.value
		try expect(session.errorMessage != nil && session.context != nil, "A denied microphone must keep the error visible until acknowledged")
		try expect(!FileManager.default.fileExists(atPath: pendingURL.path), "Failed startup must remove its recovery metadata")
		session.discard()

		session.present(startsImmediately: true)
		try await permission.waitForRequest(3)
		let oldStart = session.startupTask!
		session.discard()
		session.present(startsImmediately: true)
		try await permission.waitForRequest(4)
		let newStart = session.startupTask!
		let newContext = session.context?.id
		let newPending = try Data(contentsOf: pendingURL)
		permission.resolve(2, granted: true)
		await oldStart.value
		try expect(session.context?.id == newContext && session.errorMessage == nil, "The old permission result must not dismiss or fail the replacement session")
		try expect(try Data(contentsOf: pendingURL) == newPending, "The old completion must not remove the replacement session's recovery metadata")
		try expect(!recorder.isRecording, "The old session must not start capture while the replacement awaits permission")
		session.discard()
		permission.resolve(3, granted: true)
		await newStart.value
		try expect(!recorder.isRecording && session.context == nil, "The replacement startup must also be cancellable")
		try expect(try recordingFiles(in: root).isEmpty, "Neither cancelled generation may leave audio behind")
	}

	private static func recordingFiles(in root: URL) throws -> [URL] {
		try FileManager.default.contentsOfDirectory(
			at: root.appendingPathComponent("Recordings", isDirectory: true),
			includingPropertiesForKeys: nil
		)
	}

	private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
		guard try condition() else { throw Failure(message: message) }
	}

	private struct Failure: Error, CustomStringConvertible {
		let message: String
		var description: String { message }
	}

	@MainActor
	private final class PermissionGate {
		var requests: [CheckedContinuation<Bool, Never>?] = []

		func request() async -> Bool {
			await withCheckedContinuation { requests.append($0) }
		}

		func resolve(_ index: Int, granted: Bool) {
			requests[index]?.resume(returning: granted)
			requests[index] = nil
		}

		func waitForRequest(_ count: Int) async throws {
			let deadline = ContinuousClock.now.advanced(by: .seconds(5))
			while requests.count < count {
				guard ContinuousClock.now < deadline else { throw Failure(message: "Microphone request never started") }
				await Task.yield()
			}
		}
	}
}
#endif
