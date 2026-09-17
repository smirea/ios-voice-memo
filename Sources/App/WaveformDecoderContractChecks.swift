#if DEBUG
import AVFoundation
import Foundation
import Synchronization

@MainActor
enum WaveformDecoderContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-waveform-contract-tests") else { return }
		do {
			let root = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-contract-\(UUID().uuidString)", isDirectory: true)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: root) }
			try await nativeFormats(root)
			try await replacementAndVariants(root)
			try await cancellationAndDeletion(root)
			try await failuresAndRepair(root)
			try await eviction(root)
			print("WAVEFORM DECODER CONTRACT: native PCM/AAC EOF, bounded reads, cache hits, replacement identity, cancellation, deletion, failure repair, and LRU eviction passed")
			fflush(stdout)
		} catch { fatalError("WAVEFORM DECODER CONTRACT: \(error)") }
	}

	private static func nativeFormats(_ root: URL) async throws {
		let cache = WaveformCache()
		for suffix in ["caf", "m4a", "aac"] {
			let url = root.appendingPathComponent("varied.\(suffix)")
			let frames = suffix == "caf" ? 16_000 * 180 + 17 : 44_100 * 4 + 17
			try writeFixture(at: url, frames: frames, channels: 2, pattern: .rising)
			let identity = try WaveformFileIdentity.read(at: url)
			let probe = ReadProbe()
			let loader = WaveformLoader(cache: cache, didReadBuffer: { try probe.read($0, $1) })
			let levels = try await load(loader, identity)
			try expect(levels.count == 52 && levels.allSatisfy { $0.isFinite && (0.08...1).contains($0) }, "Every native format must produce 52 finite display bins")
			try expect(levels.last! > levels.first! + 0.4, "The complete waveform must preserve the rising amplitude through its tail")
			let nativeLength = try AVAudioFile(forReading: url).length
			try verifyReads(probe.snapshot, expectedFrames: nativeLength)
			let reads = probe.snapshot.positions.count
			let cached = try await load(loader, identity)
			try expect(cached == levels && probe.snapshot.positions.count == reads, "A completed waveform must be reused without rescanning native audio")
		}
		for pattern in [Pattern.silence, .tail] {
			let url = root.appendingPathComponent("\(pattern).m4a")
			try writeFixture(at: url, frames: 44_100 * 3 + 113, pattern: pattern)
			let probe = ReadProbe()
			let levels = try await load(WaveformLoader(cache: cache, didReadBuffer: { try probe.read($0, $1) }), try .read(at: url))
			try verifyReads(probe.snapshot, expectedFrames: AVAudioFile(forReading: url).length)
			if pattern == .silence {
				try expect(levels.allSatisfy { abs($0 - 0.08) < 0.000_001 }, "Real compressed silence must produce the minimum waveform level")
			} else {
				try expect(levels.prefix(40).allSatisfy { $0 < 0.1 } && levels.suffix(2).max()! > 0.8, "A short final audio region must appear in the last bins without filling earlier silence")
			}
		}
	}

	private static func replacementAndVariants(_ root: URL) async throws {
		let url = root.appendingPathComponent("replace.caf")
		let replacement = root.appendingPathComponent("replacement.caf")
		try writeFixture(at: url, frames: 32_017, pattern: .rising)
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: url.path)
		let original = try WaveformFileIdentity.read(at: url)
		let cache = WaveformCache()
		let probe = ReadProbe()
		let loader = WaveformLoader(cache: cache, didReadBuffer: { try probe.read($0, $1) })
		let oldLevels = try await load(loader, original)
		try writeFixture(at: replacement, frames: 32_017, pattern: .falling)
		try FileManager.default.setAttributes([.modificationDate: original.modifiedAt], ofItemAtPath: replacement.path)
		_ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
		try FileManager.default.setAttributes([.modificationDate: original.modifiedAt], ofItemAtPath: url.path)
		let updated = try WaveformFileIdentity.read(at: url)
		try expect(updated.size == original.size && updated.modifiedAt == original.modifiedAt && updated.fileNumber != original.fileNumber,
			"The replacement fixture must keep path, size, and timestamp while changing its file identity")
		let stale = await failure { try await load(loader, original) }
		try expect(stale != nil, "A cache hit must reject an identity whose file was replaced")
		let reads = probe.snapshot.positions.count
		let newLevels = try await load(loader, updated)
		try expect(probe.snapshot.positions.count > reads && newLevels.first! > newLevels.last! + 0.4 && newLevels != oldLevels,
			"A same-size, same-date atomic replacement must trigger a new waveform")
		for (count, version) in [(17, 1), (17, 2)] {
			let variant = try WaveformFileIdentity.read(at: url, count: count, version: version)
			let before = probe.snapshot.positions.count
			let levels = try await load(loader, variant)
			try expect(levels.count == count && probe.snapshot.positions.count > before, "Bin count and decoder version must be part of the cache identity")
		}
	}

	private static func cancellationAndDeletion(_ root: URL) async throws {
		for deleting in [false, true] {
			let url = root.appendingPathComponent("held-\(deleting).caf")
			try writeFixture(at: url, frames: 160_017, pattern: .rising)
			let identity = try WaveformFileIdentity.read(at: url)
			let cache = WaveformCache()
			let probe = ReadProbe(holdFirst: true)
			let loader = WaveformLoader(cache: cache, didReadBuffer: { try probe.read($0, $1) })
			let task = Task.detached(priority: .utility) { try await loader.levels(for: identity) }
			try await wait { probe.snapshot.waiting }
			if deleting { try FileManager.default.removeItem(at: url) }
			else { task.cancel() }
			probe.release()
			let error = await failure { try await task.value }
			let cached = await cache.levels(for: identity)
			try expect(error != nil && cached == nil, "Deletion or cancellation during a scan must never publish a completed waveform")
			if !deleting {
				try expect(error is CancellationError && probe.snapshot.positions.count == 1,
					"Cancellation after the first native buffer must stop before another read or a full-file scan")
				let recovered = try await load(WaveformLoader(cache: cache), identity)
				try expect(recovered.count == 52, "Cancelling a scan must leave its original file retryable")
			}
		}
	}

	private static func failuresAndRepair(_ root: URL) async throws {
		let url = root.appendingPathComponent("repair.caf")
		let cache = WaveformCache()
		try Data("not an audio container".utf8).write(to: url)
		let invalid = try WaveformFileIdentity.read(at: url)
		let error = await failure { try await load(WaveformLoader(cache: cache), invalid) }
		let failedCache = await cache.levels(for: invalid)
		try expect(error != nil && failedCache == nil, "Unreadable audio must fail without caching a placeholder waveform")
		try writeFixture(at: url, frames: 32_000, pattern: .rising)
		let repaired = try WaveformFileIdentity.read(at: url)
		let fault = ReadProbe(failFirst: true)
		let injected = await failure {
			try await load(WaveformLoader(cache: cache, didReadBuffer: { try fault.read($0, $1) }), repaired)
		}
		let partialCache = await cache.levels(for: repaired)
		try expect(injected != nil && partialCache == nil, "A native scan failure after a real buffer must not cache partial results")
		let probe = ReadProbe()
		let retried = try await load(WaveformLoader(cache: cache, didReadBuffer: { try probe.read($0, $1) }), repaired)
		try expect(retried.count == 52 && !probe.snapshot.positions.isEmpty, "Repairing the file and retrying the failed identity must perform a complete scan")
		let nonfinite = root.appendingPathComponent("nonfinite.caf")
		try writeFixture(at: nonfinite, frames: 8_192, pattern: .nonfinite)
		let badSamples = try WaveformFileIdentity.read(at: nonfinite)
		let badResult = await failure { try await load(WaveformLoader(cache: cache), badSamples) }
		let badCache = await cache.levels(for: badSamples)
		try expect(badResult != nil && badCache == nil, "Nonfinite decoded PCM samples must not become a valid waveform")
	}

	private static func eviction(_ root: URL) async throws {
		let cache = WaveformCache(capacity: 2)
		let probe = ReadProbe()
		let loader = WaveformLoader(cache: cache, didReadBuffer: { try probe.read($0, $1) })
		let identities = try (0..<3).map { index in
			let url = root.appendingPathComponent("lru-\(index).caf")
			try writeFixture(at: url, frames: 8_192, pattern: .rising)
			return try WaveformFileIdentity.read(at: url)
		}
		_ = try await load(loader, identities[0])
		_ = try await load(loader, identities[1])
		let firstReads = probe.snapshot.positions.count
		_ = try await load(loader, identities[0])
		try expect(probe.snapshot.positions.count == firstReads, "Reading a cached waveform must refresh its recency without decoding")
		_ = try await load(loader, identities[2])
		let afterThird = probe.snapshot.positions.count
		_ = try await load(loader, identities[0])
		try expect(probe.snapshot.positions.count == afterThird, "The most recently used waveform must survive capacity eviction")
		_ = try await load(loader, identities[1])
		try expect(probe.snapshot.positions.count > afterThird, "Evicting the least recently used waveform must force its next native scan")
	}

	private static func load(_ loader: WaveformLoader, _ identity: WaveformFileIdentity) async throws -> [Double] {
		let task = Task.detached(priority: .utility) { try await loader.levels(for: identity) }
		return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
	}
	private static func verifyReads(_ state: ReadProbe.State, expectedFrames: AVAudioFramePosition) throws {
		var previous: AVAudioFramePosition = 0
		for position in state.positions {
			try expect(position > previous && position - previous <= 4_096, "Native waveform reads must advance by at most one 4096-frame buffer")
			previous = position
		}
		try expect(previous == expectedFrames && state.total == expectedFrames && !state.onMainThread,
			"Waveform decoding must reach exact native EOF on its detached worker")
	}
	private enum Pattern { case rising, falling, silence, tail, nonfinite }
	private static func writeFixture(at url: URL, frames: Int, channels: AVAudioChannelCount = 1, pattern: Pattern) throws {
		let sampleRate = url.pathExtension == "caf" ? 16_000.0 : 44_100.0
		let settings: [String: Any] = url.pathExtension == "caf"
			? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
				AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
			: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels > 1 ? 128_000 : 64_000]
		let file = try AVAudioFile(forWriting: url, settings: settings)
		defer { file.close() }
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
		var written = 0
		while written < frames {
			let count = min(4_096, frames - written)
			buffer.frameLength = AVAudioFrameCount(count)
			for frame in 0..<count {
				let position = written + frame
				let progress = Double(position) / Double(frames)
				let amplitude: Double
				switch pattern {
				case .rising: amplitude = 0.025 + 0.8 * progress
				case .falling: amplitude = 0.825 - 0.8 * progress
				case .silence: amplitude = 0
				case .tail: amplitude = progress > 0.97 ? 0.8 : 0
				case .nonfinite: amplitude = position == 4_100 ? .nan : 0.2
				}
				for channel in 0..<Int(channels) {
					buffer.floatChannelData![channel][frame] = Float(sin(Double(position) * 2 * .pi * 440 / sampleRate) * amplitude * (channel == 0 ? 1 : 0.5))
				}
			}
			try file.write(from: buffer)
			written += count
		}
	}
	private static func failure<T>(_ operation: () async throws -> T) async -> (any Error)? {
		do { _ = try await operation(); return nil } catch { return error }
	}
	private static func wait(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure("Waveform scan did not reach its first buffer") }
			await Task.yield()
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
	private enum InjectedError: Error { case scan, timeout }
	private final class ReadProbe: Sendable {
		struct State: Sendable {
			var positions: [AVAudioFramePosition] = []
			var total: AVAudioFramePosition = 0
			var waiting = false
			var onMainThread = false
		}
		private let state = Mutex(State())
		private let gate = DispatchSemaphore(value: 0)
		private let holdFirst: Bool
		private let failFirst: Bool
		init(holdFirst: Bool = false, failFirst: Bool = false) { self.holdFirst = holdFirst; self.failFirst = failFirst }
		var snapshot: State { state.withLock { $0 } }
		func release() { gate.signal() }
		func read(_ position: AVAudioFramePosition, _ total: AVAudioFramePosition) throws {
			let first = state.withLock { value in
				value.positions.append(position); value.total = total
				value.onMainThread = value.onMainThread || Thread.isMainThread
				let first = value.positions.count == 1
				if first && holdFirst { value.waiting = true }
				return first
			}
			if first && holdFirst, gate.wait(timeout: .now() + 5) != .success { throw InjectedError.timeout }
			if first && failFirst { throw InjectedError.scan }
		}
	}
}
#endif
