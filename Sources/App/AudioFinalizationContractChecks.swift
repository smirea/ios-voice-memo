#if DEBUG
import AVFoundation
import Darwin
import Foundation

@MainActor
enum AudioFinalizationContractChecks {
	static func runFromLaunchArguments() async {
		let arguments = ProcessInfo.processInfo.arguments
		do {
			if let fixture = argument(after: "-audio-crash-writer", in: arguments) {
				try await writeCrashFixture(fixture)
			} else if let fixture = argument(after: "-audio-publication-writer", in: arguments) {
				try await writePublicationFixture(fixture)
			} else if let fixture = argument(after: "-audio-recovery-verify", in: arguments) {
				try await verifyCrashFixture(fixture)
			} else if arguments.contains("-audio-finalization-contract-tests") {
				try await publicationFailureChecks()
				try await cancellationAndDeletionChecks()
				try await runningExportCancellationCheck()
				try await invalidAudioChecks()
				print("AUDIO FINALIZATION CONTRACT: native AAC passthrough, CAF conversion, commit failure/restart, stale metadata, running-export cancellation, deletion, invalid audio, and export gating passed")
				fflush(stdout)
			}
		} catch { fatalError("AUDIO FINALIZATION CONTRACT: \(error)") }
	}

	private static func publicationFailureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await savedFixture(root: root)
		let request = try await repository.prepareAudioFinalization(id: entry.id)
		let prepared = try await AudioFinalizer().prepare(request)
		let sourceDigest = try digest(request.sourceURL)
		let outputDigest = try digest(prepared.preparedURL)
		try expect(sourceDigest.frames == outputDigest.frames && abs(sourceDigest.energy - outputDigest.energy) < 0.001,
			"AAC publication must remux the original samples without a second lossy encode")
		try expect(FileManager.default.fileExists(atPath: request.sourceURL.path)
			&& !FileManager.default.fileExists(atPath: request.destinationURL.path), "Conversion must leave the source intact and final destination unpublished")
		let protectionValue = try FileManager.default.attributesOfItem(atPath: prepared.preparedURL.path)[.protectionKey]
		let protection = (protectionValue as? FileProtectionType)?.rawValue ?? (protectionValue as? String)
		#if targetEnvironment(simulator)
		if protection != FileProtectionType.completeUntilFirstUserAuthentication.rawValue {
			print("AUDIO FINALIZATION PROTECTION: Simulator returned \(String(describing: protectionValue)); device data protection remains unverified")
		}
		#else
		try expect(protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
			"Prepared media must retain lock-screen-compatible file protection")
		#endif
		let manifest = root.appendingPathComponent("Records/\(entry.id.uuidString).json")
		let held = root.appendingPathComponent("held-record.json")
		try FileManager.default.moveItem(at: manifest, to: held)
		try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
		var rejected = false
		do { _ = try await repository.commitFinalizedAudio(prepared) }
		catch { rejected = true }
		try expect(rejected && FileManager.default.fileExists(atPath: request.sourceURL.path)
			&& FileManager.default.fileExists(atPath: request.destinationURL.path), "A post-publication manifest failure must preserve both source and published media")
		try FileManager.default.removeItem(at: manifest)
		try FileManager.default.moveItem(at: held, to: manifest)
		let restarted = JournalRepository(rootURL: root)
		let loaded = try await restarted.load()
		try expect(loaded.entries.map(\.id) == [entry.id] && loaded.entries[0].audioFilename == entry.audioFilename,
			"Restart between publication and metadata commit must preserve one pending recording identity")
		let retry = try await restarted.prepareAudioFinalization(id: entry.id)
		let reused = try await AudioFinalizer().prepare(retry)
		try expect(reused.preparedURL == retry.destinationURL, "Retry must adopt already-validated published audio")
		let committed = try await restarted.commitFinalizedAudio(reused)
		try expect(!FileManager.default.fileExists(atPath: request.sourceURL.path), "Raw source cleanup must follow a successful manifest commit")
		var stale = entry
		stale.headline = "A later title edit"
		stale.duration = 999
		try await restarted.save([stale])
		let current = await restarted.record(id: entry.id)
		try expect(current?.entry?.audioFilename == committed.audioFilename && current?.entry?.duration == committed.duration
			&& current?.entry?.headline == stale.headline, "Older UI snapshots must preserve canonical media while saving unrelated edits")
		let finalLoad = try await JournalRepository(rootURL: root).load()
		try expect(finalLoad.entries.count == 1 && finalLoad.entries[0].audioFilename == committed.audioFilename,
			"Completed conversion must remain singular after another restart")

		let caf = root.appendingPathComponent("Recordings/\(UUID().uuidString).caf")
		try writeAudio(at: caf)
		let legacy = AudioFinalizationRequest(entryID: UUID(), sourceURL: caf,
			destinationURL: caf.deletingPathExtension().appendingPathExtension("m4a"),
			stagingURL: root.appendingPathComponent(".caf-staging.m4a"))
		let converted = try await AudioFinalizer().prepare(legacy)
		try expect(abs(converted.duration - 3) < 0.05, "Existing PCM CAF sources must remain convertible")

		let truncated = root.appendingPathComponent("Recordings/trimmed-tail.aac")
		try writeAudio(at: truncated)
		let tailData = try Data(contentsOf: truncated)
		try tailData.dropLast(37).write(to: truncated)
		let tailRequest = AudioFinalizationRequest(entryID: UUID(), sourceURL: truncated,
			destinationURL: root.appendingPathComponent("trimmed-tail.m4a"),
			stagingURL: root.appendingPathComponent(".trimmed-tail-staging.m4a"))
		let tailPrepared = try await AudioFinalizer().prepare(tailRequest)
		try expect(tailPrepared.duration > 2.5, "A torn AAC tail must recover through the last complete native packet")

		let cloud = root.appendingPathComponent("Cloud")
		let mirror = ICloudDriveMirror(containerURL: cloud)
		var pending = entry
		pending.audioFilename = caf.lastPathComponent
		_ = await mirror.sync(entries: [pending], recordingsURL: root.appendingPathComponent("Recordings"),
			configuration: AppConfiguration(settings: JournalSettings(), locations: [], elevenLabsAPIKey: ""),
			deletedRecordingReferences: [], revision: 1)
		let exports = try FileManager.default.contentsOfDirectory(at: cloud.appendingPathComponent("Documents"), includingPropertiesForKeys: nil)
		try expect(exports.allSatisfy { $0.lastPathComponent == "config.json" }, "Pending capture formats must not escape as completed cloud audio/metadata pairs")
	}

	private static func cancellationAndDeletionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await savedFixture(root: root)
		let request = try await repository.prepareAudioFinalization(id: entry.id)
		let canceled = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await AudioFinalizer().prepare(request)
		}
		do { _ = try await canceled.value; throw Failure(message: "Canceled conversion unexpectedly completed") }
		catch is CancellationError {}
		try expect(FileManager.default.fileExists(atPath: request.sourceURL.path)
			&& !FileManager.default.fileExists(atPath: request.stagingURL.path), "Canceled preparation must preserve source audio without creating an export")
		let failedExport = AudioFinalizationRequest(entryID: entry.id, sourceURL: request.sourceURL,
			destinationURL: request.destinationURL, stagingURL: root.appendingPathComponent("missing-folder/staging.m4a"))
		var exportFailed = false
		do { _ = try await AudioFinalizer().prepare(failedExport) } catch { exportFailed = true }
		try expect(exportFailed && FileManager.default.fileExists(atPath: request.sourceURL.path),
			"A native export write failure must retain the source")
		let prepared = try await AudioFinalizer().prepare(request)
		let commit = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await repository.commitFinalizedAudio(prepared)
		}
		do { _ = try await commit.value; throw Failure(message: "Canceled publication unexpectedly committed") }
		catch is CancellationError {}
		try expect(!FileManager.default.fileExists(atPath: request.destinationURL.path), "Cancellation after export must prevent publication")
		_ = try await repository.delete(id: entry.id)
		try await repository.cleanupDeletedAudio(id: entry.id)
		do { _ = try await repository.commitFinalizedAudio(prepared); throw Failure(message: "Deleted conversion unexpectedly committed") }
		catch is RepositoryError {}
		try expect(!FileManager.default.fileExists(atPath: request.destinationURL.path), "A late conversion must not recreate deleted media")
		let loaded = try await JournalRepository(rootURL: root).load()
		try expect(loaded.entries.isEmpty, "Deleted finalization must not reappear on launch")
	}

	private static func runningExportCancellationCheck() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let source = root.appendingPathComponent("long-capture.caf")
		try writeAudio(at: source, seconds: 90)
		let request = AudioFinalizationRequest(entryID: UUID(), sourceURL: source,
			destinationURL: root.appendingPathComponent("long-capture.m4a"),
			stagingURL: root.appendingPathComponent(".long-capture-staging.m4a"))
		let exporting = Task { try await AudioFinalizer().prepare(request) }
		do {
			let deadline = ContinuousClock.now.advanced(by: .seconds(15))
			while !FileManager.default.fileExists(atPath: request.stagingURL.path) {
				guard ContinuousClock.now < deadline else { throw Failure(message: "Native export never opened its staging file") }
				try await Task.sleep(for: .milliseconds(1))
			}
		} catch {
			exporting.cancel()
			_ = await exporting.result
			throw error
		}
		exporting.cancel()
		let result = await exporting.result
		if case .success = result { throw Failure(message: "Canceled running export unexpectedly returned completed audio") }
		try expect(FileManager.default.fileExists(atPath: source.path)
			&& !FileManager.default.fileExists(atPath: request.stagingURL.path)
			&& !FileManager.default.fileExists(atPath: request.destinationURL.path),
			"Canceling a running native export must preserve its source and remove its unpublished output")
		try expect(abs(AudioFinalizer.validatedDuration(at: source) - 90) < 0.01,
			"Native export cancellation must leave the complete source playable")
	}

	private static func invalidAudioChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = try await repository.beginRecording(calendarEvent: nil)
		let audioURL = root.appendingPathComponent("Recordings/\(entry.audioFilename!)")
		let original = Data("unreadable capture".utf8)
		try original.write(to: audioURL)
		do { _ = try await repository.finishRecording(id: entry.id); throw Failure(message: "Unreadable audio was acknowledged as saved") }
		catch is Failure { throw Failure(message: "Unreadable audio was acknowledged as saved") }
		catch {}
		let recovered = try await JournalRepository(rootURL: root).load()
		try expect(recovered.entries.isEmpty && !recovered.issues.isEmpty && (try Data(contentsOf: audioURL)) == original,
			"Unreadable recovery must report the problem and preserve exact source bytes")
	}

	private static func writeCrashFixture(_ fixture: String) async throws {
		let root = try fixtureRoot(fixture, create: true)
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = try await repository.beginRecording(calendarEvent: nil)
		let file = try AVAudioFile(forWriting: root.appendingPathComponent("Recordings/\(entry.audioFilename!)"),
			settings: RecordingAudioFormat.captureSettings)
		let buffer = makeBuffer(format: file.processingFormat)
		var batches = 0
		while true {
			try file.write(from: buffer)
			batches += 1
			if batches == 30 {
				try await repository.checkpoint(id: entry.id, duration: 3)
				print("AUDIO_CAPTURE_READY pid=\(getpid()) id=\(entry.id.uuidString) root=\(root.path)")
				fflush(stdout)
			}
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	private static func writePublicationFixture(_ fixture: String) async throws {
		let root = try fixtureRoot(fixture, create: true)
		let (repository, entry) = try await savedFixture(root: root)
		let request = try await repository.prepareAudioFinalization(id: entry.id)
		let prepared = try await AudioFinalizer().prepare(request)
		await repository.setAudioPublicationCheckpoint {
			print("AUDIO_PUBLICATION_READY pid=\(getpid()) id=\(entry.id.uuidString) root=\(root.path)")
			fflush(stdout)
			while true { sleep(1) }
		}
		_ = try await repository.commitFinalizedAudio(prepared)
	}

	private static func verifyCrashFixture(_ fixture: String) async throws {
		let root = try fixtureRoot(fixture, create: false)
		let repository = JournalRepository(rootURL: root)
		let loaded = try await repository.load()
		try expect(loaded.issues.isEmpty && loaded.entries.count == 1, "Crash fixture must recover exactly one readable note")
		let entry = loaded.entries[0]
		let request = try await repository.prepareAudioFinalization(id: entry.id)
		let prepared = try await AudioFinalizer().prepare(request)
		try expect(FileManager.default.fileExists(atPath: request.sourceURL.path), "Recovery must retain source until metadata commit")
		let committed = try await repository.commitFinalizedAudio(prepared)
		let duration = try AudioFinalizer.validatedDuration(at: request.destinationURL)
		try expect(duration >= 2 && !FileManager.default.fileExists(atPath: request.sourceURL.path), "Recovery must publish playable media before cleaning source")
		let restarted = try await JournalRepository(rootURL: root).load()
		try expect(restarted.entries.map(\.id) == [entry.id] && restarted.entries[0].audioFilename == committed.audioFilename,
			"Repeated recovery must preserve one stable identity and final media")
		print("AUDIO_RECOVERY_VERIFIED pid=\(getpid()) id=\(entry.id.uuidString) duration=\(duration) root=\(root.path)")
		fflush(stdout)
	}

	private static func savedFixture(root: URL) async throws -> (JournalRepository, JournalEntry) {
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = try await repository.beginRecording(calendarEvent: nil)
		try writeAudio(at: root.appendingPathComponent("Recordings/\(entry.audioFilename!)"))
		let saved = try await repository.finishRecording(id: entry.id)
		return (repository, saved)
	}

	private static func writeAudio(at url: URL, seconds: Int = 3) throws {
		let file = try AVAudioFile(forWriting: url,
			settings: url.pathExtension == "caf" ? RecordingAudioFormat.pcmSettings : RecordingAudioFormat.captureSettings)
		let buffer = makeBuffer(format: file.processingFormat)
		for _ in 0..<(seconds * 10) { try file.write(from: buffer) }
		file.close()
	}

	private static func makeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
		buffer.frameLength = 4_410
		for index in 0..<4_410 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.1) * 0.1 }
		return buffer
	}

	private static func digest(_ url: URL) throws -> (frames: Int64, energy: Double) {
		let file = try AVAudioFile(forReading: url)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
		var frames: Int64 = 0
		var energy = 0.0
		while frames < file.length {
			try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - frames)))
			guard buffer.frameLength > 0 else { throw Failure(message: "Unexpected short audio read") }
			frames += Int64(buffer.frameLength)
			for index in 0..<Int(buffer.frameLength) { energy += Double(abs(buffer.floatChannelData![0][index])) }
		}
		return (frames, energy)
	}

	private static func temporaryRoot() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("finalization-contract-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private static func fixtureRoot(_ value: String, create: Bool) throws -> URL {
		guard let id = UUID(uuidString: value) else { throw Failure(message: "Fixture argument must be a UUID") }
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-recovery-\(id.uuidString)")
		if create {
			try expect(!FileManager.default.fileExists(atPath: url.path), "Use a new fixture UUID for each crash writer")
			try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		}
		return url
	}

	private static func argument(after flag: String, in arguments: [String]) -> String? {
		guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
		return arguments[index + 1]
	}

	private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
		guard try condition() else { throw Failure(message: message) }
	}
	private struct Failure: Error { let message: String }
}
#endif
