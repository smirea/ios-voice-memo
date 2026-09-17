#if DEBUG
import AVFoundation
import Foundation
import Speech
import Synchronization

@MainActor
enum TranscriptionContractChecks {
	static func runFromLaunchArguments() async {
		let arguments = ProcessInfo.processInfo.arguments
		if let index = arguments.firstIndex(of: "-native-transcription-smoke"), arguments.indices.contains(index + 1) {
			guard arguments.contains("-demo") else { fatalError("Native transcription smoke requires -demo") }
			await nativeSmoke(url: URL(fileURLWithPath: arguments[index + 1]))
			return
		}
		guard arguments.contains("-transcription-contract-tests") else { return }
		guard ProcessInfo.processInfo.arguments.contains("-demo") else {
			fatalError("Transcription contract checks require -demo")
		}
		do {
			trace("audio formats begin")
			try await audioFormatChecks()
			trace("audio formats end; fallback begin")
			try await fallbackChecks()
			trace("fallback end; analysis lifetime begin")
			try await analysisLifetimeChecks()
			trace("analysis lifetime end; remote begin")
			try await remoteChecks()
			trace("remote end; cancellation begin")
			try await cancellationChecks()
			trace("cancellation end")
			print("TRANSCRIPTION CONTRACT: native audio conversion/tail, partial failure/fallback, silence vs unavailable, setup cleanup, owned analysis/results, preferred remote/fallback, and cancellation draining passed")
			fflush(stdout)
		} catch { fatalError("TRANSCRIPTION CONTRACT: \(error)") }
	}

	private static let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("missing-transcription-\(UUID().uuidString).m4a")

	private static func nativeSmoke(url: URL) async {
		do {
			let result = try await AudioTranscriber.transcribe(url: url, preferElevenLabs: false)
			print("NATIVE TRANSCRIPTION COMPLETED model=\(result.modelName) transcript=\(result.transcript)")
		} catch let failure as TranscriptionFailure {
			print("NATIVE TRANSCRIPTION FAILED category=\(failure.category.rawValue) message=\(failure.message) partial=\(failure.partial?.transcript ?? "none")")
		} catch {
			print("NATIVE TRANSCRIPTION FAILED error=\(error)")
		}
		print("NATIVE TRANSCRIPTION SMOKE FINISHED")
		fflush(stdout)
	}

	private static func audioFormatChecks() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcription-format-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		for rate in [22_050.0, 44_100.0] {
			let sourceURL = root.appendingPathComponent("source-\(Int(rate)).m4a")
			try writeAudioFixture(at: sourceURL, sampleRate: rate)
			let original = try Data(contentsOf: sourceURL)
			for commonFormat in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
				trace("convert \(Int(rate)) Hz to \(commonFormat.rawValue) begin")
				let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: 16_000, channels: 1,
					interleaved: commonFormat == .pcmFormatInt16)!
				let convertedURL = root.appendingPathComponent("converted.caf")
				let source = try AVAudioFile(forReading: sourceURL)
				let converted = try AudioTranscriber.prepareAnalysisFile(source, format: format, temporaryURL: convertedURL)
				try expect(converted.processingFormat == format, "Prepared file must retain the requested sample rate, PCM layout, and interleaving")
				let duration = Double(converted.length) / converted.processingFormat.sampleRate
				let sourceDuration = Double(source.length) / source.processingFormat.sampleRate
				try expect(abs(duration - sourceDuration) < 0.025, "Native conversion must flush the entire recording, including the final buffer")
				let readable = try AVAudioFile(forReading: convertedURL, commonFormat: .pcmFormatFloat32, interleaved: false)
				let tail = AVAudioPCMBuffer(pcmFormat: readable.processingFormat, frameCapacity: 1_600)!
				readable.framePosition = max(0, readable.length - Int64(tail.frameCapacity))
				try readable.read(into: tail)
				let samples = UnsafeBufferPointer(start: tail.floatChannelData![0], count: Int(tail.frameLength))
				let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
				try expect(energy > 0.01, "Conversion must preserve audible data at the recording's tail")
				let preserved = try Data(contentsOf: sourceURL)
				try expect(preserved == original, "Speech preparation must not change original audio")
				try FileManager.default.removeItem(at: convertedURL)
				trace("convert \(Int(rate)) Hz to \(commonFormat.rawValue) end")
			}
		}
		let canceledURL = root.appendingPathComponent("canceled.caf")
		trace("pre-canceled conversion begin")
		let canceled = Task.detached {
			withUnsafeCurrentTask { $0?.cancel() }
			let source = try AVAudioFile(forReading: root.appendingPathComponent("source-44100.m4a"))
			let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
			return try AudioTranscriber.prepareAnalysisFile(source, format: target, temporaryURL: canceledURL)
		}
		do {
			_ = try await canceled.value
			throw Failure("Canceled preparation unexpectedly returned audio")
		} catch is CancellationError {}
		try expect(!FileManager.default.fileExists(atPath: canceledURL.path), "Canceled setup must leave no temporary audio")
		trace("pre-canceled conversion end")
	}

	private static func writeAudioFixture(at url: URL, sampleRate: Double) throws {
		let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
			AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1])
		defer { file.close() }
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sampleRate * 1.137))!
		buffer.frameLength = buffer.frameCapacity
		for index in 0..<Int(buffer.frameLength) {
			buffer.floatChannelData![0][index] = index > Int(sampleRate * 0.8)
				? Float(sin(Double(index) * 2 * .pi * 440 / sampleRate) * 0.4) : 0
		}
		try file.write(from: buffer)
	}

	private static func fallbackChecks() async throws {
		trace("partial speech to dictation begin")
		let calls = Probe()
		let longer = "The beginning and middle of a recording"
		let complete = try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: false,
			providers: providers(speech: { _, update in
				calls.append("speech")
				return try await partialFailure(longer, model: "speech", update: update)
			}, dictation: { _, _ in
				calls.append("dictation")
				return TranscriptionResult(transcript: "The complete recording including its ending", modelName: "dictation")
			}))
		try expect(calls.values == ["speech", "dictation"] && complete.transcript.hasSuffix("ending"),
			"Speech failure after partial text must attempt Dictation and accept only its complete result")
		trace("partial speech to dictation end; exhausted providers begin")

		do {
			_ = try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: false,
				providers: providers(speech: { _, update in
					try await partialFailure(longer, model: "speech", update: update)
				}, dictation: { _, update in
					try await partialFailure("Shorter", model: "dictation", update: update)
				}))
			throw Failure("Partial text was returned as completed transcription")
		} catch let failure as TranscriptionFailure {
			try expect(failure.partial?.transcript == longer && failure.partial?.modelName == "speech",
				"Exhausted providers must report failure while retaining the best available incomplete text")
		}

		let silence = try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: false,
			providers: providers(speech: { _, _ in TranscriptionResult(transcript: "", modelName: "speech") }))
		try expect(silence.transcript.isEmpty && silence.modelName == "speech", "Successfully analyzed silence must remain a complete empty result")
		do {
			_ = try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: false, providers: providers())
			throw Failure("Unavailable local providers were counted as silent success")
		} catch let failure as TranscriptionFailure {
			try expect(failure.category == .unavailable && failure.partial == nil, "Unsupported language must report availability failure, not empty speech")
		}
	}

	private static func analysisLifetimeChecks() async throws {
		trace("missing file setup begin")
		let consumers = Probe()
		let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
		do {
			_ = try await AudioTranscriber.analyze(url: fixtureURL, with: module, modelName: "setup fixture", onUpdate: { _ in }) { _ in
				consumers.append("started")
			}
			throw Failure("Missing input audio unexpectedly opened")
		} catch let failure as TranscriptionFailure {
			try expect(failure.category == .unreadableAudio && consumers.values.isEmpty,
				"A real AVAudioFile setup failure must not start a results consumer")
		}

		for failsInConsumer in [false, true] {
			trace("child failure consumer=\(failsInConsumer) begin")
			let ready = Signal()
			let analyzerStarted = Signal()
			let stopped = Signal()
			let lifetime = Probe()
			do {
				_ = try await AudioTranscriber.runAnalysis(modelName: "fixture", onUpdate: { _ in }, analyze: {
					await analyzerStarted.open()
					await ready.wait()
					if !failsInConsumer { throw Failure("Analyzer failed after partial input") }
					await stopped.wait()
					lifetime.append("analyzer exited")
					try Task.checkCancellation()
				}, consume: { accumulator in
					await accumulator.append(AttributedString("Incomplete preview"))
					await ready.open()
					await analyzerStarted.wait()
					if failsInConsumer { throw Failure("Result stream failed") }
					await stopped.wait()
					lifetime.append("consumer exited")
					try Task.checkCancellation()
				}, cancel: {
					await ready.open()
					await analyzerStarted.open()
					await stopped.open()
				})
				throw Failure("Failed analysis was counted as complete")
			} catch let failure as TranscriptionFailure {
				try expect(failure.partial?.transcript == "Incomplete preview", "Analysis and result-stream failures must retain incomplete text")
				try expect(lifetime.values.contains(failsInConsumer ? "analyzer exited" : "consumer exited"),
					"A failed child must cancel native work and drain its sibling before returning")
			}
			trace("child failure consumer=\(failsInConsumer) end")
		}

		trace("analysis cancellation begin")
		let stop = Signal()
		let lifetime = Probe()
		let updates = Probe()
		let task = Task {
			try await AudioTranscriber.runAnalysis(modelName: "fixture", onUpdate: { updates.append($0.transcript) }, analyze: {
				lifetime.append("analysis started")
				await stop.wait()
				lifetime.append("analysis exited")
				try Task.checkCancellation()
			}, consume: { accumulator in
				await accumulator.append(AttributedString("Partial before cancel"))
				lifetime.append("consumer started")
				await stop.wait()
				await accumulator.append(AttributedString(" buffered after cancellation"))
				lifetime.append("consumer exited")
				try Task.checkCancellation()
			}, cancel: { await stop.open() })
		}
		defer { task.cancel(); Task { await stop.open() } }
		try await waitUntil { lifetime.values.contains("analysis started") && lifetime.values.contains("consumer started") }
		trace("analysis cancellation children started")
		task.cancel()
		do { _ = try await task.value; throw Failure("Canceled analysis returned success") }
		catch is CancellationError {}
		try expect(lifetime.values.contains("analysis exited") && lifetime.values.contains("consumer exited"),
			"Cancellation must join both actual analysis and consumer work")
		try expect(updates.values == ["Partial before cancel"], "Buffered post-cancellation results must not escape as progress")
	}

	private static func remoteChecks() async throws {
		trace("preferred remote begin")
		let lifetime = Probe()
		let appleStarted = Signal()
		let preferred = try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: true, elevenLabsAPIKey: "fixture",
			providers: providers(speech: { _, update in
				update(TranscriptionProgress(transcript: "Apple preview", modelName: "speech"))
				await appleStarted.open()
				do { try await Task.sleep(for: .seconds(60)); throw Failure("Apple was not canceled") }
				catch { lifetime.append("apple drained"); throw error }
			}, remote: { _, _ in
				await appleStarted.wait()
				return TranscriptionResult(transcript: "Preferred complete text", modelName: "remote")
			}))
		try expect(preferred.modelName == "remote" && lifetime.values == ["apple drained"],
			"Remote success must win and drain canceled Apple work before returning")
		trace("preferred remote end; remote fallback begin")

		let fallback = try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: true, elevenLabsAPIKey: "fixture",
			providers: providers(speech: { _, _ in TranscriptionResult(transcript: "Complete Apple fallback", modelName: "speech") }))
		try expect(fallback.modelName == "speech" && fallback.warning != nil, "Remote failure may use completed Apple output with a warning")
		do {
			_ = try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: true, elevenLabsAPIKey: "fixture",
				providers: providers(speech: { _, update in try await partialFailure("Partial Apple fallback", model: "speech", update: update) }))
			throw Failure("Remote failure accepted incomplete Apple output")
		} catch let failure as TranscriptionFailure {
			try expect(failure.partial?.transcript == "Partial Apple fallback", "Failed remote and Apple services must preserve partial text without claiming completion")
		}
	}

	private static func cancellationChecks() async throws {
		for hasKey in [false, true] {
			trace("fallback cancellation key=\(hasKey) begin")
			let lifetime = Probe()
			let task = Task {
				try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: true, elevenLabsAPIKey: hasKey ? "fixture" : nil,
					providers: providers(speech: { _, _ in
						lifetime.append("apple started")
						do { try await Task.sleep(for: .seconds(60)); throw Failure("Apple was not canceled") }
						catch { lifetime.append("apple exited"); throw error }
					}))
			}
			defer { task.cancel() }
			try await waitUntil { lifetime.values.contains("apple started") }
			task.cancel()
			do { _ = try await task.value; throw Failure("Canceled fallback returned success") }
			catch is CancellationError {}
			try expect(lifetime.values.contains("apple exited"), "Missing-key and failed-remote fallback cancellation must drain Apple and remain CancellationError")
			trace("fallback cancellation key=\(hasKey) end")
		}

		trace("late remote cancellation begin")
		let lifetime = Probe()
		let remoteGate = Signal()
		let task = Task {
			try await AudioTranscriber.transcribe(url: fixtureURL, preferElevenLabs: true, elevenLabsAPIKey: "fixture",
				providers: providers(speech: { _, _ in
					lifetime.append("apple started")
					do { try await Task.sleep(for: .seconds(60)); throw Failure("Apple was not canceled") }
					catch { lifetime.append("apple exited"); throw error }
				}, remote: { _, _ in
					lifetime.append("remote started")
					await remoteGate.wait()
					return TranscriptionResult(transcript: "Late remote response", modelName: "remote")
				}))
		}
		defer { task.cancel(); Task { await remoteGate.open() } }
		try await waitUntil { lifetime.values.contains("apple started") && lifetime.values.contains("remote started") }
		trace("late remote services started")
		task.cancel()
		try await waitUntil { lifetime.values.contains("apple exited") }
		await remoteGate.open()
		do { _ = try await task.value; throw Failure("Late remote response overrode cancellation") }
		catch is CancellationError {}
	}

	private static func partialFailure(_ text: String, model: String, update: @escaping TranscriptionUpdate) async throws -> TranscriptionResult {
		let partialReady = Signal()
		return try await AudioTranscriber.runAnalysis(modelName: model, onUpdate: update,
			analyze: { await partialReady.wait(); throw Failure("Decoder stopped early") },
			consume: { accumulator in await accumulator.append(AttributedString(text)); await partialReady.open() },
			cancel: { await partialReady.open() })
	}

	private static func providers(
		speech: @escaping TranscriptionProviders.AppleProvider = { _, _ in nil },
		dictation: @escaping TranscriptionProviders.AppleProvider = { _, _ in nil },
		remote: @escaping @Sendable (URL, String) async throws -> TranscriptionResult = { _, _ in throw Failure("Remote unavailable") }
	) -> TranscriptionProviders {
		TranscriptionProviders(speech: speech, dictation: dictation, elevenLabs: remote, bundledAPIKey: { nil })
	}

	private static func waitUntil(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure("A transcription fixture did not reach its expected state") }
			await Task.yield()
		}
	}

	private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
		guard condition() else { throw Failure(message) }
	}

	private nonisolated static func trace(_ message: String) {
		print("TRANSCRIPTION CHECK \(message) canceled=\(Task.isCancelled)")
		fflush(stdout)
	}

	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}

	private final class Probe: Sendable {
		private let storage = Mutex<[String]>([])
		func append(_ value: String) { storage.withLock { $0.append(value) } }
		var values: [String] { storage.withLock { $0 } }
	}

	private actor Signal {
		private var isOpen = false
		private var waiters: [CheckedContinuation<Void, Never>] = []
		func wait() async {
			guard !isOpen else { return }
			await withCheckedContinuation { waiters.append($0) }
		}
		func open() {
			isOpen = true
			for waiter in waiters { waiter.resume() }
			waiters.removeAll()
		}
	}
}
#endif
