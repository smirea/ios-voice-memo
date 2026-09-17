import AVFoundation

struct WaveformFileIdentity: Hashable, Sendable {
	var url: URL
	var size: Int64
	var modifiedAt: Date
	var fileNumber: UInt64?
	var count: Int
	var version = 1

	static func read(at url: URL, count: Int = 52, version: Int = 1) throws -> Self {
		try Task.checkCancellation()
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		guard count > 0, attributes[.type] as? FileAttributeType == .typeRegular,
			let size = attributes[.size] as? NSNumber, size.int64Value > 0,
			let modified = attributes[.modificationDate] as? Date else { throw WaveformError.unreadable }
		return Self(url: url.resolvingSymlinksInPath(), size: size.int64Value, modifiedAt: modified,
			fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value, count: count, version: version)
	}
}

enum WaveformError: Error { case unreadable, incomplete, changed }

actor WaveformCache {
	static let shared = WaveformCache()
	private struct Entry { var levels: [Double]; var used: UInt64 }
	private let capacity: Int
	private var entries: [WaveformFileIdentity: Entry] = [:]
	private var clock: UInt64 = 0

	init(capacity: Int = 64) { self.capacity = max(0, capacity) }

	func levels(for identity: WaveformFileIdentity) -> [Double]? {
		guard var entry = entries[identity] else { return nil }
		clock &+= 1
		entry.used = clock
		entries[identity] = entry
		return entry.levels
	}

	func insert(_ levels: [Double], for identity: WaveformFileIdentity) throws {
		try Task.checkCancellation()
		guard levels.count == identity.count, levels.allSatisfy({ $0.isFinite && (0.08...1).contains($0) }) else {
			throw WaveformError.incomplete
		}
		guard capacity > 0 else { return }
		clock &+= 1
		entries[identity] = Entry(levels: levels, used: clock)
		if entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
			entries[oldest] = nil
		}
	}
}

struct WaveformLoader: Sendable {
	private let cache: WaveformCache
	private let didReadBuffer: @Sendable (AVAudioFramePosition, AVAudioFramePosition) throws -> Void

	init(cache: WaveformCache = .shared,
		didReadBuffer: @escaping @Sendable (AVAudioFramePosition, AVAudioFramePosition) throws -> Void = { _, _ in }) {
		self.cache = cache
		self.didReadBuffer = didReadBuffer
	}

	func levels(for identity: WaveformFileIdentity) async throws -> [Double] {
		try validate(identity)
		if let levels = await cache.levels(for: identity) {
			try validate(identity)
			return levels
		}
		let levels = try decode(identity)
		try validate(identity)
		try await cache.insert(levels, for: identity)
		return levels
	}

	private func validate(_ identity: WaveformFileIdentity) throws {
		try Task.checkCancellation()
		guard try WaveformFileIdentity.read(at: identity.url, count: identity.count, version: identity.version) == identity else {
			throw WaveformError.changed
		}
	}

	private func decode(_ identity: WaveformFileIdentity) throws -> [Double] {
		try Task.checkCancellation()
		let file = try AVAudioFile(forReading: identity.url, commonFormat: .pcmFormatFloat32, interleaved: false)
		defer { file.close() }
		guard file.length > 0, file.processingFormat.channelCount > 0,
			let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
			throw WaveformError.unreadable
		}
		let framesPerLevel = max(1, Int64(ceil(Double(file.length) / Double(identity.count))))
		var rawLevels: [Double] = []
		rawLevels.reserveCapacity(identity.count)
		for index in 0..<identity.count {
			let endFrame = min(file.length, Int64(index + 1) * framesPerLevel)
			var sumOfSquares = 0.0
			var sampleCount = 0
			while file.framePosition < endFrame {
				try Task.checkCancellation()
				let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), endFrame - file.framePosition))
				let previous = file.framePosition
				try file.read(into: buffer, frameCount: requested)
				guard buffer.frameLength > 0, file.framePosition > previous,
					let channels = buffer.floatChannelData else { throw WaveformError.incomplete }
				try didReadBuffer(file.framePosition, file.length)
				try Task.checkCancellation()
				for channel in 0..<Int(buffer.format.channelCount) {
					for frame in 0..<Int(buffer.frameLength) {
						let sample = Double(channels[channel][frame])
						guard sample.isFinite else { throw WaveformError.incomplete }
						sumOfSquares += sample * sample
					}
					sampleCount += Int(buffer.frameLength)
				}
			}
			rawLevels.append(sampleCount > 0 ? sqrt(sumOfSquares / Double(sampleCount)) : 0)
		}
		try Task.checkCancellation()
		guard file.framePosition == file.length, rawLevels.allSatisfy(\.isFinite) else { throw WaveformError.incomplete }
		let peak = rawLevels.max() ?? 0
		guard peak > 0 else { return Array(repeating: 0.08, count: identity.count) }
		return rawLevels.map { max(0.08, min(1, pow($0 / peak, 0.55))) }
	}
}
