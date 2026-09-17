#if DEBUG
import Foundation

@MainActor
enum ICloudStoreContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-icloud-store-contract-tests") else { return }
		do {
			try await coalescingChecks()
			try await snapshotChecks()
			try await repairAndCaptureChecks()
			try await bootstrapChecks()
			try await failedBootstrapChecks()
			print("ICLOUD STORE CONTRACT: latest-only coalescing, snapshot recapture, scoped deletion receipts, same-revision repair, capture wake, and coherent bootstrap passed")
			fflush(stdout)
		} catch { fatalError("ICLOUD STORE CONTRACT: \(error)") }
	}

	private static func coalescingChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entries = try await seed(root, count: 2)
		let probe = Probe()
		let store = makeStore(root, probe)
		do {
			try await store.waitUntilLoaded()
			try await wait { await probe.count == 1 }
			for index in 0..<20 {
				store.persist(.location(JournalLocation(latitude: 1, longitude: 2, city: "Fixture city \(index)")), entryID: entries[0].id)
			}
			var settings = store.settings
			settings.hapticsEnabled = false
			store.updateSettings(settings)
			await store.waitForPendingWrites()
			try expect(await probe.count == 1, "A held pass must coalesce changes instead of starting overlapping mirrors")
			try expect(await store.deleteEntry(id: entries[1].id), "Fixture deletion must commit")
			await probe.release(completed: [entries[1].id.uuidString])
			try await wait { await probe.count == 2 }
			let latest = await probe.call(1)
			try expect(latest.entries.count == 1 && latest.entries.first?.id == entries[0].id
				&& latest.entries.first?.location?.city == "Fixture city 19" && latest.configuration?.settings.hapticsEnabled == false,
				"The next pass must capture only the latest committed note and configuration")
			try expect(latest.references.contains(entries[1].id.uuidString)
				&& latest.references.contains(entries[1].audioFilename!),
				"A stale acknowledgment cannot consume deletion references absent from its submitted snapshot")
			try expect(latest.revision > (await probe.call(0)).revision, "A changed snapshot must carry a newer coalescer revision")
			await probe.release()
			await store.waitForICloudMirrorForContract()
			let finalCount = await probe.count
			let maximumActive = await probe.maximumActive
			try expect(finalCount == 2 && maximumActive == 1,
				"A burst must drain to one latest pass with one active worker")
		} catch {
			await probe.releaseAll()
			await store.waitForICloudMirrorForContract()
			throw error
		}
	}

	private static func snapshotChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entries = try await seed(root, count: 2)
		let probe = Probe(held: false)
		let snapshot = SnapshotGate()
		let store = makeStore(root, probe)
		store.mirrorSnapshotCheckpoint = { await snapshot.wait() }
		do {
			try await store.waitUntilLoaded()
			try await wait { await snapshot.started }
			store.persist(.location(JournalLocation(latitude: 3, longitude: 4, city: "After snapshot")), entryID: entries[0].id)
			await store.waitForPendingWrites()
			try expect(await store.deleteEntry(id: entries[1].id), "Fixture deletion at snapshot boundary must save")
			await snapshot.release()
			await store.waitForICloudMirrorForContract()
			try expect(await probe.count == 1, "An obsolete repository snapshot must be recaptured before calling the mirror")
			let call = await probe.call(0)
			try expect(call.entries.count == 1 && call.entries[0].location?.city == "After snapshot"
				&& call.references.contains(entries[1].id.uuidString),
				"The mirror must not combine old entries with a newer deletion/configuration snapshot")
		} catch {
			await snapshot.release()
			await store.waitForICloudMirrorForContract()
			throw error
		}
	}

	private static func repairAndCaptureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try await seed(root)
		let probe = Probe()
		let store = makeStore(root, probe)
		let owner = UUID()
		do {
			try await store.waitUntilLoaded()
			try await wait { await probe.count == 1 }
			store.resumeStaleProcessing()
			store.resumeStaleProcessing()
			await probe.release(fail: true)
			try await wait { await probe.count == 2 }
			let firstRevision = await probe.call(0).revision
			try expect(await probe.call(1).revision == firstRevision,
				"Foreground repair requested while active must survive without a content revision change")
			await probe.release(fail: true)
			await store.waitForICloudMirrorForContract()
			try await Task.sleep(for: .milliseconds(25))
			try expect(await probe.count == 2, "A failed pass must not create a tight automatic retry loop")
			store.resumeStaleProcessing()
			try await wait { await probe.count == 3 }
			try expect(await probe.call(2).revision == firstRevision, "A later same-revision repair must remain eligible")
			await probe.release()
			await store.waitForICloudMirrorForContract()
			await store.beginCapturePriority(owner: owner)
			var settings = store.settings
			settings.hapticsEnabled.toggle()
			store.updateSettings(settings)
			store.resumeStaleProcessing()
			try await Task.sleep(for: .milliseconds(25))
			try expect(await probe.count == 3, "Capture priority must retain pending cloud work without starting it")
			await store.endCapturePriority(owner: owner)
			try await wait { await probe.count == 4 }
			try expect(await probe.call(3).revision > firstRevision, "Capture release must wake the retained latest snapshot")
			await probe.release()
			await store.waitForICloudMirrorForContract()
			try expect(await probe.maximumActive == 1, "Repair and capture release must not create a second mirror worker")
		} catch {
			await store.endCapturePriority(owner: owner)
			await probe.releaseAll()
			await store.waitForICloudMirrorForContract()
			throw error
		}
	}

	private static func bootstrapChecks() async throws {
		let root = try temporaryRoot()
		let recordsURL = root.appendingPathComponent("Records")
		defer {
			try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordsURL.path)
			try? FileManager.default.removeItem(at: root)
		}
		let entries = try await seed(root, count: 4)
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		_ = try await repository.requestProcessing(id: entries[1].id)
		_ = try await repository.requestProcessing(id: entries[2].id)
		guard let failed = try await repository.claimProcessing(excluding: [entries[1].id]) else { throw Failure("Expected fixture failure stage") }
		_ = try await repository.failProcessing(failed.lease, message: "Fixture unavailable", kind: .unavailable)
		guard let oldDeleted = await repository.record(id: entries[3].id) else { throw Failure("Expected saved deletion fixture") }
		_ = try await repository.delete(id: entries[3].id)
		let legacy = makeEntry()
		try await repository.save([legacy])
		let damagedURL = recordsURL.appendingPathComponent("\(UUID()).json")
		let damaged = Data("preserved invalid record".utf8)
		try damaged.write(to: damagedURL)
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordsURL.path)
		let probe = Probe(held: false)
		let store = makeStore(root, probe)
		try await store.waitUntilLoaded()
		await store.waitForICloudMirrorForContract()
		try expect(store.entries.count == 4 && store.entry(id: entries[3].id) == nil && store.entry(id: legacy.id) != nil,
			"Bulk projection must retain readable notes and exclude tombstones")
		try expect(store.processingStates[entries[0].id]?.status == .complete
			&& store.processingPhase(for: entries[0].id) == nil
			&& store.processingPhase(for: entries[1].id) == .queued
			&& store.processingPhase(for: entries[2].id) == .failed
			&& store.processingStates[legacy.id] == nil,
			"Bulk projection must preserve complete/queued/failed states and uncommitted legacy migration")
		try expect(store.storageLoadMessage != nil && (try Data(contentsOf: damagedURL)) == damaged,
			"Bulk loading must preserve corrupt originals and report independent migration faults")
		store.publish(oldDeleted)
		try expect(store.entry(id: entries[3].id) == nil, "Loaded tombstones must reject a late saved receipt")
		try expect(await probe.count == 1, "Bootstrap must issue one coherent initial mirror rather than per-record work")
		let call = await probe.call(0)
		try expect(call.entries.count == 4 && !call.entries.contains(where: { $0.id == entries[3].id })
			&& call.references.contains(entries[3].id.uuidString),
			"The first mirror must see the full committed library and all loaded tombstones")
	}

	private static func failedBootstrapChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		try Data([1]).write(to: root.appendingPathComponent("Records"))
		let probe = Probe(held: false)
		let store = makeStore(root, probe)
		var failed = false
		do { try await store.waitUntilLoaded() } catch { failed = true }
		try expect(failed && store.storageLoadMessage != nil, "Unreadable journal fixture must fail bootstrap")
		store.resumeStaleProcessing()
		await store.waitForICloudMirrorForContract()
		try await Task.sleep(for: .milliseconds(25))
		try expect(await probe.count == 0, "Foreground repair must never mirror an unopened empty library/default configuration")
	}

	private static func makeStore(_ root: URL, _ probe: Probe) -> JournalStore {
		JournalStore(storageRootURL: root, cloudServices: CloudServices(sync: { jobs, _, configuration, references, revision in
			await probe.sync(jobs, configuration, references, revision)
		}, loadConfiguration: { .unavailable("Unexpected fixture restore") }))
	}
	private struct Call: Sendable {
		var jobs: [CloudNoteJob]
		var entries: [JournalEntry] { jobs.compactMap(\.entry) }
		var configuration: AppConfiguration?
		var references: Set<String>
		var revision: Int
	}
	private actor Probe {
		private var calls: [Call] = []
		private var held: Bool
		private var active = 0
		private(set) var maximumActive = 0
		private var continuation: CheckedContinuation<ICloudMirrorResult, Never>?
		init(held: Bool = true) { self.held = held }
		var count: Int { calls.count }
		func call(_ index: Int) -> Call { calls[index] }
		func sync(_ jobs: [CloudNoteJob], _ configuration: CloudConfigurationJob?, _ references: Set<String>, _ revision: Int) async -> ICloudMirrorResult {
			let allReferences = jobs.reduce(into: references) { $0.formUnion($1.deletionReferences) }
			calls.append(Call(jobs: jobs, configuration: configuration?.value, references: allReferences, revision: revision))
			active += 1
			maximumActive = max(maximumActive, active)
			defer { active -= 1 }
			if !held { return ICloudMirrorResult(completedJobs: jobs.map { CloudNoteReceipt(job: $0) }, completedDeletions: references, configurationExported: configuration != nil) }
			return await withCheckedContinuation { continuation = $0 }
		}
		func release(completed: Set<String>? = nil, fail: Bool = false) {
			let last = calls.last
			continuation?.resume(returning: ICloudMirrorResult(completedJobs: fail ? [] : (last?.jobs ?? []).map { CloudNoteReceipt(job: $0) },
				completedDeletions: completed ?? (fail ? [] : last?.references ?? []),
				exportedEntries: fail ? [] : last?.entries ?? [], configurationExported: !fail,
				failures: fail ? ["Fixture cloud unavailable"] : []))
			continuation = nil
		}
		func releaseAll() { held = false; release() }
	}
	private actor SnapshotGate {
		private var released = false
		private(set) var started = false
		private var continuation: CheckedContinuation<Void, Never>?
		func wait() async {
			guard !released else { return }
			started = true
			await withCheckedContinuation { continuation = $0 }
		}
		func release() { released = true; continuation?.resume(); continuation = nil }
	}
	private static func seed(_ root: URL, count: Int = 1) async throws -> [JournalEntry] {
		try AppConfiguration(settings: JournalSettings()).jsonData().write(to: root.appendingPathComponent("config.json"))
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entries = (0..<count).map { _ in makeEntry() }
		try await repository.save(entries)
		_ = try await JournalRepository(rootURL: root).load()
		return entries
	}
	private static func makeEntry() -> JournalEntry {
		let id = UUID()
		return JournalEntry(id: id, duration: 30, transcript: "Completed fixture transcript", headline: "Saved fixture",
			audioFilename: "\(id.uuidString).m4a")
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-store-\(UUID())")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func wait(_ condition: () async -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !(await condition()) {
			guard ContinuousClock.now < deadline else { throw Failure("Timed out at a mirror ownership boundary") }
			try await Task.sleep(for: .milliseconds(1))
		}
	}
	private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
