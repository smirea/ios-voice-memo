#if DEBUG
import Foundation

@MainActor
enum WeeklyRecordingMetricContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-weekly-recording-metric-contract-tests") else { return }
		do {
			try calendarBoundaries()
			try durationInputs()
			try await reviewOutcomes()
			#if canImport(UIKit)
			try await storeBootstrap()
			#endif
			print("WEEKLY RECORDING METRIC CONTRACT: seven local days, DST and half-open boundaries, duration-only finite aggregation, identical generated/fallback/empty/cancelled metrics, and bootstrap-safe Store loading passed")
			fflush(nil)
		} catch { fatalError("WEEKLY RECORDING METRIC CONTRACT: \(error)") }
	}

	private static var calendar: Calendar {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "America/Chicago")!
		calendar.locale = Locale(identifier: "en_US_POSIX")
		calendar.firstWeekday = 2
		return calendar
	}

	private static func calendarBoundaries() throws {
		for (month, day, expectedHours) in [(3, 3, 167.0), (10, 27, 169.0)] {
			let start = try date(month: month, day: day)
			let days = try (0...7).map { offset in
				guard let value = calendar.date(byAdding: .day, value: offset, to: start) else { throw Failure("Invalid fixture day") }
				return value
			}
			try expect(days[7].timeIntervalSince(start) == expectedHours * 3_600, "The fixture must cross a real DST transition")
			let entries = [
				memo(start.addingTimeInterval(-0.5), 60_000),
				memo(start, 60), memo(start.addingTimeInterval(30), 90),
				memo(days[1], 120),
				memo(days[6].addingTimeInterval(90 * 60), 30),
				memo(days[6].addingTimeInterval(150 * 60), 30),
				memo(days[7].addingTimeInterval(-0.5), 180),
				memo(days[7], 60_000)
			]
			let result = DailyRecordingMinutes.week(entries: entries, weekStart: start, calendar: calendar)
			try expect(result.map(\.date) == Array(days.prefix(7)) && Set(result.map(\.id)).count == 7,
				"Every local day must appear once in chronological order across DST")
			try expect(result.map(\.minutes) == [2.5, 2, 0, 0, 0, 0, 4],
				"Only starts inside the half-open week count, with multiple recordings summed on their local day")
			let noon = start.addingTimeInterval(12 * 3_600)
			try expect(DailyRecordingMinutes.week(entries: entries, weekStart: noon, calendar: calendar) == result,
				"A supplied date within the first day must normalize to its local midnight")
		}
	}

	private static func durationInputs() throws {
		let start = try date(month: 6, day: 2)
		let entries = [memo(start, 60, "x"), memo(start.addingTimeInterval(60), 120, String(repeating: "long ", count: 2_000)),
			memo(start.addingTimeInterval(86_399), 7_200, "Continues after midnight")]
		let baseline = DailyRecordingMinutes.week(entries: entries, weekStart: start, calendar: calendar)
		var changed = entries.reversed().map { $0 }
		for index in changed.indices { changed[index].transcript = String(repeating: "changed ", count: index * 501) }
		try expect(baseline.map(\.minutes) == [123, 0, 0, 0, 0, 0, 0],
			"Recorded duration belongs to its recording date, independent of transcript content")
		try expect(DailyRecordingMinutes.week(entries: changed, weekStart: start, calendar: calendar) == baseline,
			"Reordering notes and changing transcript length must not fabricate a different recording metric")
		let invalid = [0, -1, Double.nan, .infinity, -.infinity].map { memo(start, $0) }
		try expect(DailyRecordingMinutes.week(entries: entries + invalid, weekStart: start, calendar: calendar) == baseline,
			"Invalid durations must not corrupt valid totals or create negative activity")
		let extreme = (0..<121).map { _ in memo(start, Double.greatestFiniteMagnitude) }
		let saturated = DailyRecordingMinutes.week(entries: extreme, weekStart: start, calendar: calendar)
		try expect(saturated[0].minutes == Double.greatestFiniteMagnitude && saturated.allSatisfy { $0.minutes.isFinite && $0.minutes >= 0 },
			"Even an overflowing finite aggregate must remain a finite nonnegative value")
	}

	private static func reviewOutcomes() async throws {
		let start = try date(month: 3, day: 3), suppliedStart = start.addingTimeInterval(12 * 3_600)
		let inWeek = [memo(start, 75), memo(start.addingTimeInterval(2 * 86_400), 135)]
		let end = calendar.date(byAdding: .day, value: 7, to: start)!
		let outside = [memo(start.addingTimeInterval(-1), 600, "OUTSIDE PRIOR WEEK"), memo(end, 600, "OUTSIDE NEXT WEEK")]
		let entries = outside + inWeek
		let expected = DailyRecordingMinutes.week(entries: entries, weekStart: start, calendar: calendar)
		let fabricated = WeeklyReview(weekStart: start.addingTimeInterval(-86_400), title: "Controlled review", body: "Controlled analysis",
			recordingMinutes: [.init(date: start, minutes: 999)])
		let generated = await ReflectionEngine.weeklyReview(entries: entries, weekStart: suppliedStart, calendar: calendar) { fabricated }
		try expect(generated.outcome == .complete && generated.title == fabricated.title,
			"The injected completed review must remain completed")
		try expect(generated.weekStart == start && generated.recordingMinutes == expected,
			"Model output cannot replace the canonical recording dates or minutes")
		let unavailable = await ReflectionEngine.weeklyReview(entries: entries, weekStart: suppliedStart, calendar: calendar) {
			throw ModelProcessingError.unavailable
		}
		let failed = await ReflectionEngine.weeklyReview(entries: entries, weekStart: suppliedStart, calendar: calendar) {
			throw ModelProcessingError.invalidOutput
		}
		let canceled = await ReflectionEngine.weeklyReview(entries: entries, weekStart: suppliedStart, calendar: calendar) {
			throw CancellationError()
		}
		try expect(unavailable.outcome == .unavailable && !failed.outcome.isComplete && canceled.outcome == .cancelled,
			"Generation outcomes must keep their explicit unavailable, failed, and canceled status")
		try expect(!unavailable.body.contains("OUTSIDE") && !failed.body.contains("OUTSIDE"),
			"Fallback text must use the same selected week as the recording metric")
		for result in [unavailable, failed, canceled] {
			try expect(result.weekStart == start && result.recordingMinutes == expected,
				"Unavailable, failed, and canceled analysis must retain the same real recording metric")
		}
		let empty = await ReflectionEngine.weeklyReview(entries: [], weekStart: suppliedStart, calendar: calendar) {
			throw Failure("Empty input must not invoke generation")
		}
		try expect(empty.outcome == .skipped && empty.recordingMinutes.count == 7
			&& empty.recordingMinutes.allSatisfy { $0.minutes == 0 }
			&& empty.recordingMinutes.map(\.date) == expected.map(\.date),
			"An empty week must show all seven zero days without invoking a model")
		let outsideOnly = await ReflectionEngine.weeklyReview(entries: outside, weekStart: suppliedStart, calendar: calendar) {
			throw Failure("Out-of-week notes must not invoke generation")
		}
		try expect(outsideOnly.outcome == .skipped && outsideOnly.recordingMinutes == empty.recordingMinutes,
			"A week with only out-of-range input is still empty")
		let alreadyCanceled = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return await ReflectionEngine.weeklyReview(entries: entries, weekStart: suppliedStart, calendar: calendar) { fabricated }
		}
		let initialCancellation = await alreadyCanceled.value
		try expect(initialCancellation.outcome == .cancelled && initialCancellation.recordingMinutes == expected,
			"Cancellation before generation must still preserve deterministic recording totals")
		let gate = Gate()
		let task = Task {
			await ReflectionEngine.weeklyReview(entries: entries, weekStart: suppliedStart, calendar: calendar) {
				await gate.wait()
				return fabricated
			}
		}
		try await wait { await gate.started }
		task.cancel()
		await gate.release()
		let late = await task.value
		try expect(late.outcome == .cancelled && late.body.isEmpty && late.recordingMinutes == expected,
			"A late generated result after cancellation must not replace text or the canonical recording metric")
	}

	#if canImport(UIKit)
	private static func storeBootstrap() async throws {
		let start = Date(timeIntervalSince1970: 2_000_000_000).startOfWeek()
		let entry = memo(start.addingTimeInterval(60), 75)
		for cancel in [false, true] {
			let root = try temporaryRoot()
			defer { try? FileManager.default.removeItem(at: root) }
			let repository = JournalRepository(rootURL: root)
			_ = try await repository.load()
			try await repository.save([entry])
			let gate = Gate(), generation = GenerationProbe(), progress = StoreReviewProbe()
			let store = JournalStore(storageRootURL: root)
			store.journalLoadCheckpoint = { await gate.wait() }
			store.weeklyReviewGeneration = {
				await generation.run(WeeklyReview(weekStart: start, title: "Controlled", body: "Controlled review"))
			}
			let task = Task {
				progress.started = true
				let review = await store.weeklyReview(for: start)
				progress.result = review
				return review
			}
			try await wait { let held = await gate.started; return held && progress.started }
			let callsWhileHeld = await generation.calls
			try expect(store.isLoading && progress.result == nil && callsWhileHeld == 0,
				"Review must await the actual journal bootstrap instead of publishing a false empty week")
			if cancel { task.cancel() }
			await gate.release()
			let result = await task.value
			await store.waitForConfigurationWritesForContract()
			let calls = await generation.calls
			if cancel {
				try expect(result.outcome == .cancelled && calls == 0,
					"Cancellation while the shared bootstrap is held must prevent later review generation")
			} else {
				try expect(result.outcome == .complete && calls == 1
					&& result.recordingMinutes == DailyRecordingMinutes.week(entries: [entry], weekStart: start),
					"The first review must use the notes actually loaded from durable manifests")
			}
		}
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let blocked = root.appendingPathComponent("Records")
		let bytes = Data("Preserve this failed directory fixture".utf8)
		try bytes.write(to: blocked)
		let generation = GenerationProbe()
		let store = JournalStore(storageRootURL: root)
		store.weeklyReviewGeneration = {
			await generation.run(WeeklyReview(weekStart: start, title: "Unexpected", body: "Must not run"))
		}
		let result = await store.weeklyReview(for: start)
		let calls = await generation.calls
		try expect(!result.outcome.isComplete && result.recordingMinutes.isEmpty && calls == 0 && store.storageLoadMessage != nil,
			"A failed journal load must report unknown recording totals, not a completed empty week or seven zero bins")
		try expect(try Data(contentsOf: blocked) == bytes, "Review must preserve the file that caused the storage fault")
		let preserved = root.appendingPathComponent("preserved-directory-fault")
		try FileManager.default.moveItem(at: blocked, to: preserved)
		let repairedRepository = JournalRepository(rootURL: root)
		_ = try await repairedRepository.load()
		try await repairedRepository.save([entry])
		let retried = await store.weeklyReview(for: start)
		await store.waitForConfigurationWritesForContract()
		let retriedCalls = await generation.calls
		try expect(retried.outcome == .complete && retriedCalls == 1
			&& retried.recordingMinutes == DailyRecordingMinutes.week(entries: [entry], weekStart: start),
			"Retry after repairing storage must reload the saved notes instead of retaining an unknown or false empty week")
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("weekly-metric-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	@MainActor private final class StoreReviewProbe {
		var started = false
		var result: WeeklyReview?
	}
	private actor GenerationProbe {
		var calls = 0
		func run(_ result: WeeklyReview) -> WeeklyReview { calls += 1; return result }
	}
	#endif

	private static func memo(_ date: Date, _ duration: Double, _ transcript: String = "Recorded words") -> JournalEntry {
		JournalEntry(createdAt: date, duration: duration, transcript: transcript, headline: "A saved note")
	}
	private static func date(month: Int, day: Int) throws -> Date {
		guard let date = calendar.date(from: DateComponents(year: 2025, month: month, day: day)) else { throw Failure("Invalid date fixture") }
		return date
	}
	private actor Gate {
		var started = false
		var continuation: CheckedContinuation<Void, Never>?
		func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
		func release() { continuation?.resume(); continuation = nil }
	}
	private static func wait(_ condition: @MainActor () async -> Bool) async throws {
		for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
		throw Failure("Timed out waiting for controlled generation")
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ message: String) { description = message }
	}
}
#endif
