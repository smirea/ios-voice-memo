#if DEBUG
import AVFoundation

@MainActor
enum PlaybackContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-playback-contract-tests") else { return }
		guard ProcessInfo.processInfo.arguments.contains("-demo"),
			!ProcessInfo.processInfo.arguments.contains("-demo-recording")
		else { fatalError("Playback contract checks require -demo without -demo-recording") }
		do {
			try await run()
			try await runFinalizationTransitionChecks(captureExtension: "aac")
			try await runFinalizationTransitionChecks(captureExtension: "caf")
			print("PLAYBACK CONTRACT: interruptions, route loss, reset reconstruction, stale callbacks, session release, and AAC/CAF-to-M4A position/play-intent continuity passed")
			fflush(stdout)
		} catch {
			fatalError("PLAYBACK CONTRACT: \(error)")
		}
	}

	private static func run() async throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("playback-contract-\(UUID().uuidString).caf")
		try writeFixture(to: url)
		defer { try? FileManager.default.removeItem(at: url) }
		let events = NotificationCenter()
		let backend = Backend()
		let playback = AudioPlayback(
			makePlayer: { try backend.makePlayer(at: $0) },
			activateAudioSession: { _ in backend.activations += 1 },
			deactivateAudioSession: { _ in backend.deactivations += 1 },
			invalidateAudioSession: { _ in backend.invalidations += 1 },
			notificationCenter: events
		)
		await playback.load(url: url, fallbackDuration: 20)
		playback.stop()
		try expect(backend.deactivations == 0, "Loading or stopping inactive playback must not deactivate someone else's audio session")

		await playback.load(url: url, fallbackDuration: 20)
		playback.togglePlayback()
		playback.seek(to: 0.3)
		try expect(playback.isPlaying && backend.activations == 1, "Successful playback must become active")
		post(events, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
		try await waitUntil { !playback.isPlaying }
		try expect(playback.currentTime == 6 && backend.deactivations == 0, "Interruption must preserve position without deactivating the already interrupted session")
		post(events, AVAudioSession.interruptionNotification, [
			AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
			AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
		])
		await drainCallbacks()
		try expect(!playback.isPlaying && backend.activations == 1, "Ending an interruption must wait for explicit Play, including shouldResume")
		playback.stop()
		try expect(backend.deactivations == 0, "Stopping interrupted playback must not deactivate a newer capture session")

		await playback.load(url: url, fallbackDuration: 20)
		playback.togglePlayback()
		post(events, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
		try await waitUntil { !playback.isPlaying }
		try expect(backend.deactivations == 1, "Disconnecting headphones must pause and release active playback")
		post(events, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
		await drainCallbacks()
		try expect(!playback.isPlaying, "A new output route must not resume playback automatically")

		playback.togglePlayback()
		playback.seek(to: 0.4)
		let oldPlayer = backend.players.last!
		let oldCount = backend.players.count
		let activationsBeforeReset = backend.activations
		post(events, AVAudioSession.mediaServicesWereResetNotification)
		try await waitUntil { backend.players.count == oldCount + 1 }
		let replacement = backend.players.last!
		try expect(!playback.isPlaying && playback.isReady && playback.currentTime == 8, "Reset must rebuild ready, paused playback at the saved position")
		try expect(replacement.currentTime == 8 && replacement.playCalls == 0 && backend.activations == activationsBeforeReset, "Reconstruction must not activate audio or start the replacement player")
		playback.togglePlayback()
		playback.audioPlayerDidFinishPlaying(oldPlayer, successfully: true)
		playback.audioPlayerDecodeErrorDidOccur(oldPlayer, error: Failure(message: "stale decoder"))
		await drainCallbacks()
		try expect(playback.isPlaying && playback.isReady && playback.currentTime == 8, "Callbacks from the invalidated player must not mutate its replacement")

		post(events, AVAudioSession.mediaServicesWereLostNotification)
		try await waitUntil { !playback.isReady }
		try expect(!playback.isPlaying && playback.currentTime == 8, "Service loss must stop advertising playback and retain its position")
		backend.failConstruction = true
		post(events, AVAudioSession.mediaServicesWereResetNotification)
		try await waitUntil { backend.invalidations == 3 }
		try expect(!playback.isReady && !playback.isPlaying, "Failed reconstruction must not claim playable or playing audio")
		backend.failConstruction = false
		post(events, AVAudioSession.mediaServicesWereResetNotification)
		try await waitUntil { playback.isReady }
		backend.players.last!.canPlay = false
		let deactivationsBeforeFailure = backend.deactivations
		playback.togglePlayback()
		try expect(!playback.isPlaying && backend.deactivations == deactivationsBeforeFailure + 1, "A failed player start must release its activated audio session")
		playback.stop()
		try expect(backend.deactivations == deactivationsBeforeFailure + 1, "Cleanup after failed playback must not deactivate twice")
	}

	private static func runFinalizationTransitionChecks(captureExtension: String) async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("playback-finalization-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let id = UUID().uuidString
		let captureURL = root.appendingPathComponent("\(id).\(captureExtension)")
		let finalizedURL = root.appendingPathComponent("\(id).m4a")
		let differentURL = root.appendingPathComponent("\(UUID().uuidString).m4a")
		try writeFixture(to: captureURL)
		try writeFixture(to: finalizedURL)
		try writeFixture(to: differentURL)
		let backend = Backend()
		let events = NotificationCenter()
		let playback = AudioPlayback(makePlayer: { try backend.makePlayer(at: $0) },
			activateAudioSession: { _ in backend.activations += 1 },
			deactivateAudioSession: { _ in backend.deactivations += 1 },
			invalidateAudioSession: { _ in backend.invalidations += 1 }, notificationCenter: events)

		await playback.load(url: captureURL, fallbackDuration: 20)
		playback.togglePlayback()
		playback.seek(to: 0.35)
		let oldPlayer = backend.players.last!
		oldPlayer.currentTime = 9
		try FileManager.default.removeItem(at: captureURL)
		await playback.load(url: finalizedURL, fallbackDuration: 20)
		let replacement = backend.players.last!
		try expect(playback.isReady && playback.isPlaying && playback.currentTime == 9,
			"Adopting finalized audio must preserve active playback at the player's current position, even after source cleanup")
		try expect(replacement !== oldPlayer && replacement.currentTime == 9 && replacement.playCalls == 1 && !oldPlayer.isPlaying,
			"Finalization must replace the native player exactly once without competing playback")
		playback.audioPlayerDidFinishPlaying(oldPlayer, successfully: true)
		playback.audioPlayerDecodeErrorDidOccur(oldPlayer, error: Failure(message: "retired capture player"))
		await drainCallbacks()
		try expect(playback.isPlaying && playback.currentTime == 9 && playback.isReady,
			"Retired capture callbacks must not stop or invalidate the finalized M4A")

		try writeFixture(to: captureURL)
		playback.stop()
		await playback.load(url: captureURL, fallbackDuration: 20)
		playback.togglePlayback()
		playback.seek(to: 0.25)
		playback.pause()
		let pausedActivations = backend.activations
		await playback.load(url: finalizedURL, fallbackDuration: 20)
		try expect(playback.currentTime == 5 && !playback.isPlaying && backend.players.last!.playCalls == 0 && backend.activations == pausedActivations,
			"Finalization must preserve a user's pause and position without reactivating audio")

		playback.stop()
		await playback.load(url: captureURL, fallbackDuration: 20)
		playback.togglePlayback()
		playback.seek(to: 0.2)
		backend.players.last!.pause()
		post(events, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
		await playback.load(url: finalizedURL, fallbackDuration: 20)
		try expect(!playback.isPlaying && playback.currentTime == 4 && backend.players.last!.playCalls == 0,
			"Native playback already stopped by an interruption must not autoplay while its notification is still queued")

		playback.stop()
		await playback.load(url: captureURL, fallbackDuration: 20)
		playback.togglePlayback()
		playback.seek(to: 0.4)
		post(events, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
		try await waitUntil { !playback.isPlaying }
		await playback.load(url: finalizedURL, fallbackDuration: 20)
		post(events, AVAudioSession.interruptionNotification, [
			AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
			AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
		])
		await drainCallbacks()
		try expect(playback.currentTime == 8 && !playback.isPlaying && backend.players.last!.playCalls == 0,
			"Converting interrupted audio must retain position and require explicit Play after interruption ends")

		playback.stop()
		await playback.load(url: captureURL, fallbackDuration: 20)
		playback.togglePlayback()
		playback.seek(to: 0.3)
		let beforeReset = backend.players.count
		post(events, AVAudioSession.mediaServicesWereResetNotification)
		try await waitUntil { backend.players.count == beforeReset + 1 }
		await playback.load(url: finalizedURL, fallbackDuration: 20)
		try expect(playback.isReady && playback.currentTime == 6 && !playback.isPlaying && backend.players.last!.playCalls == 0,
			"Finalization after a media reset must not restore the play intent that the reset cleared")

		playback.stop()
		await playback.load(url: captureURL, fallbackDuration: 20)
		playback.togglePlayback()
		playback.seek(to: 0.6)
		backend.failConstruction = true
		await playback.load(url: finalizedURL, fallbackDuration: 20)
		try expect(!playback.isPlaying && !playback.isReady && playback.currentTime == 12,
			"If replacement construction fails, playback must stop while retaining the saved position")
		backend.failConstruction = false
		await playback.load(url: finalizedURL, fallbackDuration: 20)
		try expect(playback.isReady && !playback.isPlaying && playback.currentTime == 12 && backend.players.last!.playCalls == 0,
			"Retrying failed replacement must recover its position without unexpected autoplay")
		playback.togglePlayback()
		await playback.load(url: differentURL, fallbackDuration: 20)
		try expect(playback.currentTime == 0 && !playback.isPlaying && backend.players.last!.playCalls == 0,
			"A different recording must never inherit the prior recording's play position or intent")
		playback.stop()
	}

	private static func writeFixture(to url: URL) throws {
		let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
		let settings: [String: Any] = ["aac", "m4a"].contains(url.pathExtension) ? [
			AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1
		] : format.settings
		let file = try AVAudioFile(forWriting: url, settings: settings)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 441)!
		buffer.frameLength = 441
		for index in 0..<441 { buffer.floatChannelData![0][index] = 0 }
		try file.write(from: buffer)
		file.close()
	}

	private static func post(_ center: NotificationCenter, _ name: Notification.Name, _ userInfo: [String: UInt] = [:]) {
		center.post(name: name, object: AVAudioSession.sharedInstance(), userInfo: userInfo)
	}

	private static func drainCallbacks() async {
		for _ in 0..<10 { await Task.yield() }
	}

	private static func waitUntil(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure(message: "Playback notification was not handled") }
			await Task.yield()
		}
	}

	private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
		guard condition() else { throw Failure(message: message) }
	}

	private struct Failure: Error, CustomStringConvertible {
		let message: String
		var description: String { message }
	}

	@MainActor
	private final class Backend {
		var players: [Player] = []
		var activations = 0
		var deactivations = 0
		var invalidations = 0
		var failConstruction = false

		func makePlayer(at url: URL) throws -> AVAudioPlayer {
			guard !failConstruction else { throw Failure(message: "unavailable audio") }
			let player = try Player(contentsOf: url)
			players.append(player)
			return player
		}
	}

	private final class Player: AVAudioPlayer, @unchecked Sendable {
		var canPlay = true
		var playCalls = 0
		private var simulatedPlaying = false
		private var position: TimeInterval = 0

		override var duration: TimeInterval { 20 }
		override var isPlaying: Bool { simulatedPlaying }
		override var currentTime: TimeInterval {
			get { position }
			set { position = newValue }
		}

		override func play() -> Bool {
			playCalls += 1
			simulatedPlaying = canPlay
			return simulatedPlaying
		}

		override func pause() { simulatedPlaying = false }
		override func stop() { simulatedPlaying = false }
	}
}
#endif
