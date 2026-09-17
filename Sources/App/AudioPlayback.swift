import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
	private(set) var isPlaying = false
	private(set) var isReady = false
	private(set) var currentTime: TimeInterval = 0
	private(set) var duration: TimeInterval = 0
	private(set) var levels = Array(repeating: 0.16, count: 52)

	@ObservationIgnored private var player: AVAudioPlayer?
	@ObservationIgnored private var timer: Timer?
	@ObservationIgnored private var loadedURL: URL?
	@ObservationIgnored private var loadedIdentity: WaveformFileIdentity?
	@ObservationIgnored private var completedWaveform: WaveformFileIdentity?
	@ObservationIgnored private var loadGeneration: UUID?
	@ObservationIgnored private var identityTask: Task<WaveformFileIdentity, Error>?
	@ObservationIgnored private var waveformTask: Task<[Double], Error>?
	@ObservationIgnored private var ownsSession = false
	@ObservationIgnored private let makePlayer: (URL) throws -> AVAudioPlayer
	@ObservationIgnored private let activateAudioSession: (AnyObject) throws -> Void
	@ObservationIgnored private let deactivateAudioSession: (AnyObject) -> Void
	@ObservationIgnored private let invalidateAudioSession: (AnyObject) -> Void
	@ObservationIgnored private let waveformIdentity: @Sendable (URL) throws -> WaveformFileIdentity
	@ObservationIgnored private let waveformLoader: @Sendable (WaveformFileIdentity) async throws -> [Double]

	init(
		makePlayer: @escaping (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) },
		activateAudioSession: @escaping (AnyObject) throws -> Void = {
			try AudioSessionController.shared.activate($0, category: .playback, mode: .spokenAudio)
		},
		deactivateAudioSession: @escaping (AnyObject) -> Void = { AudioSessionController.shared.deactivate($0) },
		invalidateAudioSession: @escaping (AnyObject) -> Void = { AudioSessionController.shared.invalidate($0) },
		notificationCenter: NotificationCenter = .default,
		waveformIdentity: @escaping @Sendable (URL) throws -> WaveformFileIdentity = { try .read(at: $0) },
		waveformLoader: @escaping @Sendable (WaveformFileIdentity) async throws -> [Double] = { try await WaveformLoader().levels(for: $0) }
	) {
		self.makePlayer = makePlayer
		self.activateAudioSession = activateAudioSession
		self.deactivateAudioSession = deactivateAudioSession
		self.invalidateAudioSession = invalidateAudioSession
		self.waveformIdentity = waveformIdentity
		self.waveformLoader = waveformLoader
		super.init()
		let session = AVAudioSession.sharedInstance()
		notificationCenter.addObserver(self, selector: #selector(interruptionChanged), name: AVAudioSession.interruptionNotification, object: session)
		notificationCenter.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: session)
		notificationCenter.addObserver(self, selector: #selector(mediaServicesLost), name: AVAudioSession.mediaServicesWereLostNotification, object: session)
		notificationCenter.addObserver(self, selector: #selector(mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: session)
	}

	deinit {
		identityTask?.cancel()
		waveformTask?.cancel()
	}

	func load(url: URL, fallbackDuration: TimeInterval) async {
		guard !Task.isCancelled else { return }
		let generation = UUID()
		loadGeneration = generation
		identityTask?.cancel()
		waveformTask?.cancel()
		identityTask = nil
		waveformTask = nil
		if loadedURL != url && !isFinalizedReplacement(url) {
			stopPlayer()
			duration = fallbackDuration
		}
		defer {
			if loadGeneration == generation {
				identityTask = nil
				waveformTask = nil
			}
		}
		let identify = waveformIdentity
		let lookup = Task.detached(priority: .utility) { try identify(url) }
		identityTask = lookup
		do {
			let identity = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
			try Task.checkCancellation()
			guard loadGeneration == generation else { return }
			identityTask = nil
			if loadedURL != url || loadedIdentity != identity || !isReady {
				let finalized = isFinalizedReplacement(url)
				let preservesPosition = finalized || loadedURL == url
				let position = preservesPosition ? (player?.currentTime ?? currentTime) : 0
				let resumesPlayback = preservesPosition && isPlaying && player?.isPlaying == true
				let previousLevels = levels
				stopPlayer()
				if finalized { levels = previousLevels }
				duration = fallbackDuration
				currentTime = position
				loadedURL = url
				loadedIdentity = identity
				guard rebuildPlayer() else { return }
				if resumesPlayback { togglePlayback() }
			}
			guard completedWaveform != identity else { return }
			let loader = waveformLoader
			let work = Task.detached(priority: .utility) {
				let levels = try await loader(identity)
				try Task.checkCancellation()
				guard levels.count == identity.count, levels.allSatisfy({ $0.isFinite && (0.08...1).contains($0) }),
					try WaveformFileIdentity.read(at: identity.url, count: identity.count, version: identity.version) == identity
				else { throw WaveformError.changed }
				return levels
			}
			waveformTask = work
			let waveform = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
			try Task.checkCancellation()
			guard loadGeneration == generation else { return }
			levels = waveform
			completedWaveform = identity
		} catch {}
	}

	private func isFinalizedReplacement(_ url: URL) -> Bool {
		["aac", "caf"].contains(loadedURL?.pathExtension.lowercased() ?? "") && url.pathExtension.lowercased() == "m4a"
			&& loadedURL?.deletingPathExtension() == url.deletingPathExtension()
	}

	func togglePlayback() {
		guard let player else { return }
		if isPlaying {
			pause()
			return
		}

		if currentTime >= duration {
			player.currentTime = 0
			currentTime = 0
		}

		do {
			try activateAudioSession(self)
			ownsSession = true
			guard player.play() else {
				deactivateSession()
				return
			}
			isPlaying = true
			startTimer()
		} catch {
			isPlaying = false
			deactivateSession()
		}
	}

	func pause() {
		if let player {
			currentTime = player.currentTime
			player.pause()
		}
		isPlaying = false
		stopTimer()
		deactivateSession()
	}

	func seek(to progress: Double) {
		guard let player else { return }
		let position = max(0, min(1, progress)) * duration
		player.currentTime = position
		currentTime = position
	}

	func stop() {
		loadGeneration = nil
		identityTask?.cancel()
		identityTask = nil
		waveformTask?.cancel()
		waveformTask = nil
		stopPlayer()
	}

	private func stopPlayer() {
		player?.delegate = nil
		player?.stop()
		player = nil
		loadedURL = nil
		loadedIdentity = nil
		completedWaveform = nil
		levels = Array(repeating: 0.16, count: 52)
		isPlaying = false
		isReady = false
		currentTime = 0
		stopTimer()
		deactivateSession()
	}

	@discardableResult
	private func rebuildPlayer() -> Bool {
		guard let loadedURL else { return false }
		do {
			let replacement = try makePlayer(loadedURL)
			replacement.delegate = self
			duration = replacement.duration
			currentTime = min(currentTime, duration)
			replacement.currentTime = currentTime
			player = replacement
			isReady = true
			return true
		} catch {
			isReady = false
			return false
		}
	}

	private func startTimer() {
		stopTimer()
		let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self, self.isPlaying, let player = self.player else { return }
				self.currentTime = player.currentTime
				if !player.isPlaying { self.pause() }
			}
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	private func stopTimer() {
		timer?.invalidate()
		timer = nil
	}

	private func deactivateSession() {
		guard ownsSession else { return }
		ownsSession = false
		deactivateAudioSession(self)
	}

	@objc nonisolated private func interruptionChanged(_ notification: Notification) {
		guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
			AVAudioSession.InterruptionType(rawValue: rawType) == .began
		else { return }
		Task { @MainActor [weak self] in
			guard let self else { return }
			self.ownsSession = false
			self.pause()
		}
	}

	@objc nonisolated private func routeChanged(_ notification: Notification) {
		guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
			AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
		else { return }
		Task { @MainActor [weak self] in self?.pause() }
	}

	@objc nonisolated private func mediaServicesLost(_ notification: Notification) {
		Task { @MainActor [weak self] in self?.invalidatePlayer() }
	}

	@objc nonisolated private func mediaServicesReset(_ notification: Notification) {
		Task { @MainActor [weak self] in
			guard let self else { return }
			self.invalidatePlayer()
			self.rebuildPlayer()
		}
	}

	private func invalidatePlayer() {
		ownsSession = false
		invalidateAudioSession(self)
		player?.delegate = nil
		player = nil
		isPlaying = false
		isReady = false
		stopTimer()
	}

	nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		let identity = ObjectIdentifier(player)
		Task { @MainActor [weak self] in
			guard let self, let currentPlayer = self.player,
				ObjectIdentifier(currentPlayer) == identity, !currentPlayer.isPlaying
			else { return }
			self.currentTime = flag ? self.duration : currentPlayer.currentTime
			self.isPlaying = false
			self.stopTimer()
			self.deactivateSession()
		}
	}

	nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
		let identity = ObjectIdentifier(player)
		Task { @MainActor [weak self] in
			guard let self, let currentPlayer = self.player,
				ObjectIdentifier(currentPlayer) == identity
			else { return }
			self.pause()
			self.isReady = false
		}
	}

}
