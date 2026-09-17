import AVFoundation
import Foundation

enum RecordingAudioFormat {
	static let fileExtension = "aac"

	static func needsFinalization(_ filename: String) -> Bool {
		["caf", "aac"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased())
	}

	static var captureSettings: [String: Any] {
		[
			AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
			AVSampleRateKey: 44_100,
			AVNumberOfChannelsKey: 1,
			AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
		]
	}

	static var pcmSettings: [String: Any] {
		[
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 44_100,
			AVNumberOfChannelsKey: 1,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsFloatKey: false,
			AVLinearPCMIsBigEndianKey: false
		]
	}
}

struct AudioFinalizationRequest: Sendable {
	let entryID: UUID
	let sourceURL: URL
	let destinationURL: URL
	let stagingURL: URL
}

struct FinalizedAudio: Sendable {
	let request: AudioFinalizationRequest
	let preparedURL: URL
	let duration: TimeInterval
}

actor AudioFinalizer {
	func prepare(_ request: AudioFinalizationRequest) async throws -> FinalizedAudio {
		try Task.checkCancellation()
		let duration = try Self.validatedDuration(at: request.sourceURL)
		if let existingDuration = try? Self.validatedDuration(at: request.destinationURL),
			abs(existingDuration - duration) <= 0.05 {
			try Task.checkCancellation()
			try protect(request.destinationURL)
			return FinalizedAudio(request: request, preparedURL: request.destinationURL, duration: existingDuration)
		}
		try Task.checkCancellation()
		guard let exporter = AVAssetExportSession(
			asset: AVURLAsset(url: request.sourceURL),
			presetName: request.sourceURL.pathExtension.lowercased() == "aac"
				? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
		) else { throw RepositoryError.invalidAudio }
		do {
			try await exporter.export(to: request.stagingURL, as: .m4a)
			try Task.checkCancellation()
			let exportedDuration = try Self.validatedDuration(at: request.stagingURL)
			guard abs(exportedDuration - duration) <= 0.05 else { throw RepositoryError.invalidAudio }
			try protect(request.stagingURL)
			return FinalizedAudio(request: request, preparedURL: request.stagingURL, duration: exportedDuration)
		} catch {
			try? FileManager.default.removeItem(at: request.stagingURL)
			throw error
		}
	}

	private func protect(_ outputURL: URL) throws {
		try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: outputURL.path)
		var url = outputURL
		var values = URLResourceValues()
		values.isExcludedFromBackup = false
		try url.setResourceValues(values)
	}

	nonisolated static func validatedDuration(at url: URL) throws -> TimeInterval {
		_ = try url.resourceValues(forKeys: [.fileSizeKey])
		let file = try AVAudioFile(forReading: url)
		guard file.length > 0, file.processingFormat.sampleRate > 0,
			let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)
		else { throw RepositoryError.invalidAudio }
		var frames: AVAudioFramePosition = 0
		while frames < file.length {
			try Task.checkCancellation()
			try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - frames)))
			guard buffer.frameLength > 0 else { throw RepositoryError.invalidAudio }
			frames += Int64(buffer.frameLength)
		}
		return Double(frames) / file.processingFormat.sampleRate
	}
}
