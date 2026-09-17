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
	@ObservationIgnored private var ownsSession = false
	@ObservationIgnored private let makePlayer: (URL) throws -> AVAudioPlayer
	@ObservationIgnored private let activateAudioSession: (AnyObject) throws -> Void
	@ObservationIgnored private let deactivateAudioSession: (AnyObject) -> Void
	@ObservationIgnored private let invalidateAudioSession: (AnyObject) -> Void

	init(
		makePlayer: @escaping (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) },
		activateAudioSession: @escaping (AnyObject) throws -> Void = {
			try AudioSessionController.shared.activate($0, category: .playback, mode: .spokenAudio)
		},
		deactivateAudioSession: @escaping (AnyObject) -> Void = { AudioSessionController.shared.deactivate($0) },
		invalidateAudioSession: @escaping (AnyObject) -> Void = { AudioSessionController.shared.invalidate($0) },
		notificationCenter: NotificationCenter = .default
	) {
		self.makePlayer = makePlayer
		self.activateAudioSession = activateAudioSession
		self.deactivateAudioSession = deactivateAudioSession
		self.invalidateAudioSession = invalidateAudioSession
		super.init()
		let session = AVAudioSession.sharedInstance()
		notificationCenter.addObserver(self, selector: #selector(interruptionChanged), name: AVAudioSession.interruptionNotification, object: session)
		notificationCenter.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: session)
		notificationCenter.addObserver(self, selector: #selector(mediaServicesLost), name: AVAudioSession.mediaServicesWereLostNotification, object: session)
		notificationCenter.addObserver(self, selector: #selector(mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: session)
	}

	func load(url: URL, fallbackDuration: TimeInterval) async {
		guard loadedURL != url || !isReady else { return }
		stop()
		duration = fallbackDuration
		loadedURL = url
		guard rebuildPlayer() else { return }

		let waveform = await Task.detached(priority: .utility) {
			Self.readWaveform(at: url, count: 52)
		}.value
		guard loadedURL == url else { return }
		levels = waveform
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
		player?.delegate = nil
		player?.stop()
		player = nil
		loadedURL = nil
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

	nonisolated private static func readWaveform(at url: URL, count: Int) -> [Double] {
		guard let file = try? AVAudioFile(forReading: url),
			file.length > 0,
			let buffer = AVAudioPCMBuffer(
				pcmFormat: file.processingFormat,
				frameCapacity: 4_096
			)
		else {
			return Array(repeating: 0.16, count: count)
		}

		let framesPerLevel = max(1, Int64(ceil(Double(file.length) / Double(count))))
		var rawLevels: [Double] = []
		rawLevels.reserveCapacity(count)

		for index in 0..<count {
			let endFrame = min(file.length, Int64(index + 1) * framesPerLevel)
			var sumOfSquares = 0.0
			var sampleCount = 0

			while file.framePosition < endFrame {
				let frameCount = AVAudioFrameCount(min(
					Int64(buffer.frameCapacity),
					endFrame - file.framePosition
				))
				do {
					try file.read(into: buffer, frameCount: frameCount)
				} catch {
					break
				}
				guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { break }

				for channel in 0..<Int(buffer.format.channelCount) {
					let samples = channelData[channel]
					for frame in 0..<Int(buffer.frameLength) {
						let sample = Double(samples[frame])
						sumOfSquares += sample * sample
					}
					sampleCount += Int(buffer.frameLength)
				}
			}

			rawLevels.append(sampleCount > 0 ? sqrt(sumOfSquares / Double(sampleCount)) : 0)
		}

		let peak = rawLevels.max() ?? 0
		guard peak > 0 else { return Array(repeating: 0.08, count: count) }
		return rawLevels.map { max(0.08, min(1, pow($0 / peak, 0.55))) }
	}
}
