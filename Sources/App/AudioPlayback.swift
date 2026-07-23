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

	func load(url: URL, fallbackDuration: TimeInterval) async {
		guard loadedURL != url else { return }
		stop()
		duration = fallbackDuration
		currentTime = 0
		isReady = false

		do {
			let player = try AVAudioPlayer(contentsOf: url)
			player.delegate = self
			player.prepareToPlay()
			self.player = player
			loadedURL = url
			duration = player.duration
			isReady = true
		} catch {
			return
		}

		levels = await Task.detached(priority: .utility) {
			Self.readWaveform(at: url, count: 52)
		}.value
	}

	func togglePlayback() {
		guard let player else { return }
		if isPlaying {
			player.pause()
			isPlaying = false
			stopTimer()
			deactivateSession()
			return
		}

		if currentTime >= duration {
			player.currentTime = 0
			currentTime = 0
		}

		do {
			#if os(iOS)
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, mode: .spokenAudio)
			try session.setActive(true)
			#endif
			guard player.play() else { return }
			isPlaying = true
			startTimer()
		} catch {
			isPlaying = false
		}
	}

	func seek(to progress: Double) {
		guard let player else { return }
		let position = max(0, min(1, progress)) * duration
		player.currentTime = position
		currentTime = position
	}

	func stop() {
		player?.stop()
		player = nil
		loadedURL = nil
		isPlaying = false
		isReady = false
		currentTime = 0
		stopTimer()
		deactivateSession()
	}

	private func startTimer() {
		stopTimer()
		let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self, let player = self.player else { return }
				self.currentTime = player.currentTime
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
		#if os(iOS)
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		#endif
	}

	nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		Task { @MainActor [weak self] in
			guard let self else { return }
			self.currentTime = self.duration
			self.isPlaying = false
			self.stopTimer()
			self.deactivateSession()
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
