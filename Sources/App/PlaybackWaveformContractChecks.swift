#if DEBUG
import AVFoundation
import Observation
import Synchronization

@MainActor
enum PlaybackWaveformContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-waveform-contract-tests") else { return }
		do {
			try await staleWaveformChecks()
			try await staleIdentityChecks()
			try await finalizedReplacementChecks()
			try await cancellationAndRetryChecks()
			try await failedWaveformChecks()
			try await repeatedVisitChecks()
			try await captureObservationChecks()
			print("WAVEFORM PLAYBACK CONTRACT: immediate readiness, stale identity and A-B-A results, owned cancellation, paused retry, failure recovery, cached repeat visits, and capture observation passed")
			fflush(stdout)
		} catch { fatalError("WAVEFORM PLAYBACK CONTRACT: \(error)") }
	}

	private static func staleWaveformChecks() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let probe = WaveformProbe(cooperative: false)
		let backend = Backend()
		let playback = makePlayback(backend, loader: { try await probe.load($0) })
		defer { playback.stop() }
		let oldA = Task { await playback.load(url: fixture.a, fallbackDuration: 20) }
		do {
			try await wait { await probe.count == 1 }
			try expect(playback.isReady && backend.players.count == 1,
				"Player readiness must not wait for a complete waveform scan")
			let b = Task { await playback.load(url: fixture.b, fallbackDuration: 20) }
			try await wait { await probe.count == 2 }
			oldA.cancel()
			await probe.release(1, level: 0.3)
			await b.value
			let bCancelled = await probe.cancelledAtCompletion[1]
			try expect(bCancelled == false && playback.levels == levels(0.3),
				"Canceling an older caller must not cancel or suppress the newer B waveform")
			let alreadyCanceled = Task { await playback.load(url: fixture.a, fallbackDuration: 20) }
			alreadyCanceled.cancel()
			await alreadyCanceled.value
			try expect(backend.players.count == 2 && playback.levels == levels(0.3),
				"An already-canceled caller must not invalidate the current ready note")
			let newestA = Task { await playback.load(url: fixture.a, fallbackDuration: 20) }
			try await wait { await probe.count == 3 }
			await probe.release(2, level: 0.7)
			await newestA.value
			await probe.release(0, level: 0.95)
			await oldA.value
			try expect(playback.levels == levels(0.7) && backend.urls.map(\.lastPathComponent) == ["a.caf", "b.caf", "a.caf"],
				"An obsolete A result finishing after A-B-A replacement must not overwrite the newest waveform")
		} catch {
			oldA.cancel()
			await probe.releaseAll()
			await oldA.value
			throw error
		}
	}

	private static func staleIdentityChecks() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let gate = IdentityGate()
		let backend = Backend()
		let playback = makePlayback(backend, identity: { try gate.read($0) }, loader: { _ in levels(0.4) })
		defer { playback.stop(); gate.release() }
		let old = Task { await playback.load(url: fixture.a, fallbackDuration: 20) }
		do {
			try await wait { gate.started }
			try expect(backend.players.isEmpty, "Player construction must wait for this load's file identity")
			await playback.load(url: fixture.b, fallbackDuration: 20)
			try expect(playback.isReady && backend.urls.map(\.lastPathComponent) == ["b.caf"], "A newer identity must be able to prepare its player")
			gate.release()
			await old.value
			try expect(backend.urls.map(\.lastPathComponent) == ["b.caf"] && playback.levels == levels(0.4),
				"An obsolete metadata lookup must never rebuild the prior player after a newer note is ready")
		} catch {
			gate.release()
			old.cancel()
			await old.value
			throw error
		}
	}

	private static func cancellationAndRetryChecks() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let probe = WaveformProbe(cooperative: true)
		let backend = Backend()
		let playback = makePlayback(backend, loader: { try await probe.load($0) })
		defer { playback.stop() }
		let caller = Task { await playback.load(url: fixture.a, fallbackDuration: 20) }
		do {
			try await wait { await probe.count == 1 }
			playback.togglePlayback()
			playback.seek(to: 0.25)
			playback.pause()
			caller.cancel()
			try await wait { await probe.cancellations == 1 }
			await caller.value
			try expect(playback.isReady && !playback.isPlaying && playback.currentTime == 5,
				"Caller cancellation for capture priority must stop waveform work without destroying paused playback")
			let retry = Task { await playback.load(url: fixture.a, fallbackDuration: 20) }
			try await wait { await probe.count == 2 }
			await probe.release(1, level: 0.6)
			await retry.value
			try expect(playback.levels == levels(0.6) && backend.players.count == 1
				&& playback.currentTime == 5 && !playback.isPlaying && backend.players[0].playCalls == 1,
				"Retrying canceled waveform work for the same file must preserve its ready player, position, and pause intent")

			let stopping = Task { await playback.load(url: fixture.b, fallbackDuration: 20) }
			try await wait { await probe.count == 3 }
			playback.stop()
			try await wait { await probe.cancellations == 2 }
			await stopping.value
			try expect(!playback.isReady && !playback.isPlaying && playback.currentTime == 0,
				"Stopping playback must cancel its actual waveform task and keep the stopped state")
		} catch {
			caller.cancel()
			await probe.releaseAll()
			await caller.value
			throw error
		}
	}

	private static func finalizedReplacementChecks() async throws {
		for captureExtension in ["caf", "aac"] {
			let fixture = try Fixture()
			defer { fixture.remove() }
			let source = fixture.root.appendingPathComponent("finalizing.\(captureExtension)")
			let destination = fixture.root.appendingPathComponent("finalizing.m4a")
			try fixture.write(source)
			try fixture.write(destination)
			let probe = WaveformProbe(cooperative: false)
			let backend = Backend()
			let playback = makePlayback(backend, loader: { try await probe.load($0) })
			defer { playback.stop() }
			let old = Task { await playback.load(url: source, fallbackDuration: 20) }
			do {
				try await wait { await probe.count == 1 }
				playback.togglePlayback()
				playback.seek(to: 0.35)
				let oldPlayer = backend.players[0]
				oldPlayer.currentTime = 9
				try FileManager.default.removeItem(at: source)
				let replacement = Task { await playback.load(url: destination, fallbackDuration: 20) }
				try await wait { await probe.count == 2 }
				try expect(playback.isReady && playback.isPlaying && playback.currentTime == 9
					&& backend.players.count == 2 && !oldPlayer.isPlaying && backend.players[1].playCalls == 1,
					"Finalization during a held waveform must preserve current playback after deleting its capture source")
				await probe.release(1, level: 0.65)
				await replacement.value
				await probe.release(0, level: 0.9)
				await old.value
				try expect(playback.levels == levels(0.65) && playback.currentTime == 9 && playback.isPlaying,
					"A retired capture scan must not publish after its finalized M4A waveform is ready")
			} catch {
				old.cancel()
				await probe.releaseAll()
				await old.value
				throw error
			}
		}
	}

	private static func failedWaveformChecks() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let attempts = Mutex(0)
		let backend = Backend()
		let playback = makePlayback(backend, loader: { _ in
			let attempt = attempts.withLock { value in value += 1; return value }
			if attempt == 1 { throw WaveformError.incomplete }
			return levels(0.8)
		})
		defer { playback.stop() }
		await playback.load(url: fixture.a, fallbackDuration: 20)
		try expect(playback.isReady && playback.levels == levels(0.16),
			"A failed waveform must leave playable audio ready without presenting partial levels as complete")
		await playback.load(url: fixture.a, fallbackDuration: 20)
		try expect(playback.levels == levels(0.8) && attempts.withLock({ $0 }) == 2 && backend.players.count == 1,
			"A failed scan must remain retryable without rebuilding an unchanged ready player")
		await playback.load(url: fixture.a, fallbackDuration: 20)
		try expect(attempts.withLock({ $0 }) == 2 && backend.players.count == 1,
			"An unchanged complete waveform must not decode or reconstruct playback again")
	}

	private static func repeatedVisitChecks() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let buffers = Mutex(0)
		let loader = WaveformLoader(cache: WaveformCache(capacity: 4), didReadBuffer: { _, _ in
			buffers.withLock { $0 += 1 }
		})
		let first = makePlayback(Backend(), loader: { try await loader.levels(for: $0) })
		await first.load(url: fixture.a, fallbackDuration: 20)
		let firstLevels = first.levels
		let scanned = buffers.withLock { $0 }
		try expect(first.isReady && scanned > 0, "The first visit must decode the native audio fixture")
		first.stop()
		let second = makePlayback(Backend(), loader: { try await loader.levels(for: $0) })
		defer { second.stop() }
		await second.load(url: fixture.a, fallbackDuration: 20)
		try expect(second.isReady && second.levels == firstLevels && buffers.withLock({ $0 }) == scanned,
			"A fresh playback object revisiting the same immutable file must reuse the completed waveform cache")
	}

	private static func captureObservationChecks() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-observation-\(UUID())")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = JournalStore(storageRootURL: root)
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		let changes = Mutex(0)
		let owner = UUID()
		do {
			try expect(!store.isCapturePriorityActive, "An idle store must begin outside capture priority")
			withObservationTracking { _ = store.isCapturePriorityActive } onChange: { changes.withLock { $0 += 1 } }
			await store.beginCapturePriority(owner: owner)
			try expect(store.isCapturePriorityActive && changes.withLock({ $0 }) == 1,
				"Starting capture must invalidate observers of the waveform task's capture priority key")
			withObservationTracking { _ = store.isCapturePriorityActive } onChange: { changes.withLock { $0 += 1 } }
			await store.endCapturePriority(owner: owner)
			try expect(!store.isCapturePriorityActive && changes.withLock({ $0 }) == 2,
				"Ending capture must invalidate the same key so a canceled waveform can retry")
			await store.stopCloudForContract()
		} catch {
			await store.endCapturePriority(owner: owner)
			await store.stopCloudForContract()
			throw error
		}
	}

	private static func makePlayback(_ backend: Backend,
		identity: @escaping @Sendable (URL) throws -> WaveformFileIdentity = { try .read(at: $0) },
		loader: @escaping @Sendable (WaveformFileIdentity) async throws -> [Double]) -> AudioPlayback {
		AudioPlayback(makePlayer: { try backend.makePlayer($0) }, activateAudioSession: { _ in },
			deactivateAudioSession: { _ in }, invalidateAudioSession: { _ in }, notificationCenter: NotificationCenter(),
			waveformIdentity: identity, waveformLoader: loader)
	}

	nonisolated private static func levels(_ value: Double) -> [Double] { Array(repeating: value, count: 52) }

	private actor WaveformProbe {
		let cooperative: Bool
		private(set) var count = 0
		private(set) var cancellations = 0
		private(set) var cancelledAtCompletion: [Int: Bool] = [:]
		private var pending: [Int: CheckedContinuation<[Double], Error>] = [:]
		init(cooperative: Bool) { self.cooperative = cooperative }
		func load(_ identity: WaveformFileIdentity) async throws -> [Double] {
			let index = count
			count += 1
			let result = try await withTaskCancellationHandler {
				if cooperative { try Task.checkCancellation() }
				return try await withCheckedThrowingContinuation { pending[index] = $0 }
			} onCancel: {
				if self.cooperative { Task { await self.cancel(index) } }
			}
			cancelledAtCompletion[index] = Task.isCancelled
			return result
		}
		private func cancel(_ index: Int) {
			guard let continuation = pending.removeValue(forKey: index) else { return }
			cancellations += 1
			continuation.resume(throwing: CancellationError())
		}
		func release(_ index: Int, level: Double) {
			pending.removeValue(forKey: index)?.resume(returning: levels(level))
		}
		func releaseAll() {
			for continuation in pending.values { continuation.resume(returning: levels(0.2)) }
			pending.removeAll()
		}
	}

	private final class IdentityGate: Sendable {
		private let state = Mutex((started: false, released: false))
		private let semaphore = DispatchSemaphore(value: 0)
		var started: Bool { state.withLock { $0.started } }
		func read(_ url: URL) throws -> WaveformFileIdentity {
			let identity = try WaveformFileIdentity.read(at: url)
			let shouldWait = state.withLock { state in
				guard !state.started else { return false }
				state.started = true
				return !state.released
			}
			if shouldWait { semaphore.wait() }
			return identity
		}
		func release() {
			let first = state.withLock { state in defer { state.released = true }; return !state.released }
			if first { semaphore.signal() }
		}
	}

	private struct Fixture {
		let root: URL
		var a: URL { root.appendingPathComponent("a.caf") }
		var b: URL { root.appendingPathComponent("b.caf") }
		init() throws {
			root = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-playback-\(UUID())")
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try write(a)
			try write(b)
		}
		func write(_ url: URL) throws {
			let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
			let settings: [String: Any] = ["aac", "m4a"].contains(url.pathExtension) ? [
				AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1
			] : format.settings
			let file = try AVAudioFile(forWriting: url, settings: settings)
			let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
			buffer.frameLength = 4_096
			for frame in 0..<4_096 { buffer.floatChannelData![0][frame] = sin(Float(frame) / 10) * 0.25 }
			try file.write(from: buffer)
			file.close()
		}
		func remove() { try? FileManager.default.removeItem(at: root) }
	}

	@MainActor
	private final class Backend {
		var players: [Player] = []
		var urls: [URL] = []
		func makePlayer(_ url: URL) throws -> AVAudioPlayer {
			let player = try Player(contentsOf: url)
			players.append(player)
			urls.append(url)
			return player
		}
	}
	private final class Player: AVAudioPlayer, @unchecked Sendable {
		private var simulatedPlaying = false
		private var position: TimeInterval = 0
		var playCalls = 0
		override var duration: TimeInterval { 20 }
		override var isPlaying: Bool { simulatedPlaying }
		override var currentTime: TimeInterval {
			get { position }
			set { position = newValue }
		}
		override func play() -> Bool { playCalls += 1; simulatedPlaying = true; return true }
		override func pause() { simulatedPlaying = false }
		override func stop() { simulatedPlaying = false }
	}

	private static func wait(_ condition: () async -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !(await condition()) {
			guard ContinuousClock.now < deadline else { throw Failure("Timed out at \(file):\(line)") }
			try await Task.sleep(for: .milliseconds(1))
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ message: String) { description = message }
	}
}
#endif
