#if DEBUG
import Foundation

@MainActor
enum CloudStateContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-cloud-state-contract-tests") else { return }
		do {
			try await noteChecks()
			try await configurationChecks()
			try await schemaAndFaultChecks()
			print("CLOUD STATE CONTRACT: durable content acknowledgments, stale receipts, finite retries, provisional overlay and explicit key intent, strict schema, and storage fault recovery passed")
			fflush(stdout)
		} catch { fatalError("CLOUD STATE CONTRACT: \(error)") }
	}

	private static func noteChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let id = UUID(), legacyID = UUID()
		let entry = JournalEntry(id: id, duration: 20, transcript: "Saved words", headline: "Saved", audioFilename: "\(legacyID).m4a")
		try await repository.save([entry])
		guard let job = await repository.cloudJobs().first else { throw Failure("Expected new export") }
		let requested = try await repository.requestProcessing(id: id)
		guard let work = try await repository.claimProcessing() else { throw Failure("Expected processing lease") }
		_ = try await repository.savePartial(TranscriptionProgress(transcript: "Incomplete words", modelName: "Fixture"), lease: work.lease)
		try expect(await repository.record(id: id)?.contentRevision == job.contentRevision,
			"Claims, requests, and partial previews must not create cloud content revisions")
		let receipt = CloudAudioReceipt(sourceFilename: entry.audioFilename!, sourceSize: 123, sourceModifiedAt: Date(timeIntervalSince1970: 123456789.1234),
			destinationDirectory: "/fixture/Documents", destinationFilename: "pair.m4a", destinationSize: 123, destinationModifiedAt: Date(timeIntervalSince1970: 123456789.5678))
		let metadata = CloudMetadataReceipt(contentRevision: job.contentRevision, destinationDirectory: "/fixture/Documents",
			destinationFilename: "pair.json", size: 321, modifiedAt: Date(timeIntervalSince1970: 123456789.9876))
		let acknowledged = try await repository.acknowledgeCloud(job: job, audioReceipt: receipt, metadataReceipt: metadata)
		try expect(acknowledged?.contentRevision == requested.contentRevision && acknowledged?.revision ?? 0 > requested.revision,
			"An acknowledgment changes the manifest revision without creating new content")
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		try expect(await restarted.cloudJobs().isEmpty, "An acknowledged export must stay complete after restart")
		let retained = await restarted.record(id: id)
		try expect(retained?.cloudAudioReceipt == receipt && retained?.cloudMetadataReceipt == metadata,
			"Successful audio and metadata identity must survive restart")
		_ = try await restarted.apply(.location(JournalLocation(latitude: 1, longitude: 2, city: "New place")), to: id)
		_ = try await restarted.acknowledgeCloud(job: job)
		guard let changed = await restarted.cloudJobs().first else { throw Failure("A stale acknowledgment erased changed content") }
		try expect(changed.contentRevision > job.contentRevision && changed.audioReceipt == receipt,
			"Metadata changes need a new export but retain the successful audio receipt")
		let manifest = root.appendingPathComponent("Records/\(id).json")
		let original = root.appendingPathComponent("saved-manifest")
		try FileManager.default.moveItem(at: manifest, to: original)
		try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
		var failed = false
		do { _ = try await restarted.acknowledgeCloud(job: changed) } catch { failed = true }
		let jobsAfterFault = await restarted.cloudJobs()
		try expect(failed && jobsAfterFault.count == 1, "A failed acknowledgment write must leave work pending")
		try FileManager.default.removeItem(at: manifest)
		try FileManager.default.moveItem(at: original, to: manifest)
		let now = Date(timeIntervalSince1970: 2_000_000_000)
		for _ in 0..<4 { _ = try await restarted.failCloud(job: changed, message: "Fixture provider unavailable", now: now) }
		try expect(await restarted.nextCloudRetry() == nil, "Repeated provider failures must exhaust finite automatic retries")
		let afterFailure = JournalRepository(rootURL: root)
		_ = try await afterFailure.load()
		try expect(await afterFailure.cloudJobs(now: .distantFuture).isEmpty, "Exhaustion must survive restart")
		try expect(await afterFailure.cloudJobs(repair: true).count == 1, "Foreground repair must remain available after exhaustion")
		_ = try await afterFailure.delete(id: id)
		_ = try await afterFailure.acknowledgeCloud(job: changed)
		try await afterFailure.cleanupDeletedAudio(id: id)
		let deletedRestart = JournalRepository(rootURL: root)
		_ = try await deletedRestart.load()
		guard let deletion = await deletedRestart.cloudJobs().first else { throw Failure("Missing durable deletion") }
		try expect(deletion.entry == nil && deletion.deletionReferences.contains(entry.audioFilename!)
			&& deletion.deletionReferences.contains(id.uuidString), "Deletion must retain canonical and legacy cloud identities after local cleanup/restart")
		_ = try await deletedRestart.acknowledgeCloud(job: deletion)
		try expect(await deletedRestart.cloudJobs().isEmpty, "Only the exact tombstone receipt may complete deletion")
		let repair = await deletedRestart.cloudJobs(repair: true)
		try expect(repair.count == 1 && repair[0].entry == nil, "Acknowledged tombstones remain available for later repair")
	}

	private static func configurationChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let baseline = AppConfiguration(settings: JournalSettings())
		let repository = ConfigurationRepository(rootURL: root)
		let initial = try await repository.load(baseline: baseline)
		try expect(initial.status == .provisional && initial.needsRestore && initial.export == nil,
			"A fresh install must remain provisional without creating exportable defaults")
		var local = baseline
		local.settings.hapticsEnabled = false
		local.elevenLabsAPIKey = "synthetic-provisional-value"
		_ = try await repository.saveLocal(local, baseline: baseline, keyEdited: true)
		let beforeClear = local
		local.elevenLabsAPIKey = ""
		_ = try await repository.saveLocal(local, baseline: beforeClear, keyEdited: true)
		_ = try await repository.applyRemote(.unavailable("Fixture provider unavailable"))
		try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path),
			"Unavailable restore and provisional edits must never create canonical defaults")
		let restarted = ConfigurationRepository(rootURL: root)
		let pending = try await restarted.load(baseline: baseline)
		try expect(pending.status == .provisional && !pending.value.settings.hapticsEnabled && !pending.needsRestore,
			"Provisional value and restoration backoff must survive restart")
		var remote = baseline
		remote.settings.showTranscripts = false
		remote.settings.includedCalendarIdentifiers = ["remote-calendar"]
		remote.elevenLabsAPIKey = "synthetic-remote-value"
		remote.locations = [NamedJournalLocation(name: "Remote place", pin: LocationCoordinate(latitude: 1, longitude: 2))]
		let restored = try await restarted.applyRemote(.available(remote))
		try expect(restored.status == .ready && !restored.value.settings.hapticsEnabled && !restored.value.settings.showTranscripts
			&& restored.value.locations == remote.locations && restored.value.elevenLabsAPIKey.isEmpty,
			"Restore must preserve remote fields while explicit empty-baseline key clear and local Haptics intent win")
		var staleEdit = local
		staleEdit.settings.showModelNames = false
		let merged = try await restarted.saveLocal(staleEdit, baseline: local)
		try expect(!merged.value.settings.showModelNames && !merged.value.settings.showTranscripts
			&& merged.value.locations == remote.locations && merged.value.settings.includedCalendarIdentifiers == remote.settings.includedCalendarIdentifiers,
			"An edit captured before restoration must only change its requested fields")
		guard let oldJob = restored.export, let newJob = merged.export else { throw Failure("Expected canonical exports") }
		_ = try await restarted.acknowledgeCloud(fingerprint: oldJob.fingerprint)
		try expect(await restarted.snapshot().export != nil, "An old config acknowledgment cannot clear a newer committed file")
		let acknowledged = try await restarted.acknowledgeCloud(fingerprint: newJob.fingerprint)
		try expect(acknowledged.revision > merged.revision, "An acknowledgment must supersede older same-content UI snapshots")
		let again = ConfigurationRepository(rootURL: root)
		let finished = try await again.load(baseline: baseline)
		try expect(finished.export == nil && !finished.needsRestore && finished.value == merged.value,
			"A canonical value and exact acknowledgment must survive restart without an export loop")
		let missingRoot = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: missingRoot) }
		let missing = ConfigurationRepository(rootURL: missingRoot)
		_ = try await missing.load(baseline: baseline)
		let create = try await missing.applyRemote(.missing)
		try expect(create.export?.mode == .createIfMissing && create.status == .provisional,
			"Confirmed absence permits conditional creation while preserving unresolved local authority")
		let raced = try await missing.applyRemote(.available(remote))
		try expect(raced.value == remote && raced.status == .ready, "A value appearing during conditional create must be restored, not replaced")
	}

	private static func schemaAndFaultChecks() async throws {
		let baseline = AppConfiguration(settings: JournalSettings())
		let invalid = ["{}", "", "{\"schemaVersion\":99,\"settings\":{}}", "{\"schemaVersion\":2,\"settings\":null}", "{\"settings\":{\"hapticsEnabled\":\"bad\"}}"]
		for text in invalid {
			let root = try temporaryRoot()
			defer { try? FileManager.default.removeItem(at: root) }
			let url = root.appendingPathComponent("config.json")
			let data = Data(text.utf8)
			try data.write(to: url)
			let repository = ConfigurationRepository(rootURL: root)
			let snapshot = try await repository.load(baseline: baseline)
			var rejected = false
			do { _ = try await repository.saveLocal(baseline) } catch { rejected = true }
			try expect(snapshot.status == .blocked && snapshot.export == nil && rejected && (try Data(contentsOf: url)) == data,
				"Damaged, unsupported, empty, and malformed local config must preserve original bytes and reject overwrite")
		}
		guard case .available = ConfigurationRead.decode(Data("{\"schemaVersion\":1,\"settings\":{}}".utf8)) else {
			throw Failure("Supported legacy settings must retain defaults for intentionally absent fields")
		}
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = ConfigurationRepository(rootURL: root)
		_ = try await repository.load(baseline: baseline)
		let canonical = root.appendingPathComponent("config.json")
		try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false)
		var failed = false
		do { _ = try await repository.applyRemote(.available(baseline)) } catch { failed = true }
		let promotionFault = await repository.snapshot()
		try expect(failed && promotionFault.status == .provisional,
			"A failed canonical promotion must retain durable provisional authority")
		try FileManager.default.removeItem(at: canonical)
		let restarted = ConfigurationRepository(rootURL: root)
		let pending = try await restarted.load(baseline: baseline)
		try expect(pending.status == .provisional, "Failed promotion must recover provisional state after restart")
		let ready = try await restarted.applyRemote(.available(baseline))
		guard let job = ready.export else { throw Failure("Expected export after successful promotion") }
		let cloud = root.appendingPathComponent("config-cloud.json")
		try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: false)
		failed = false
		do { _ = try await restarted.acknowledgeCloud(fingerprint: job.fingerprint) } catch { failed = true }
		let acknowledgmentFault = await restarted.snapshot()
		try expect(failed && acknowledgmentFault.export != nil,
			"A failed cloud acknowledgment write cannot erase pending canonical export")
		try FileManager.default.removeItem(at: cloud)
		let now = Date(timeIntervalSince1970: 2_000_000_000)
		for _ in 0..<4 {
			let current = await restarted.snapshot()
			let failed = try await restarted.failCloud(fingerprint: job.fingerprint, revision: current.revision, message: "Fixture unavailable", now: now)
			try expect(failed.revision > current.revision, "Cloud failure publication must supersede earlier same-content snapshots")
		}
		let exhausted = ConfigurationRepository(rootURL: root)
		_ = try await exhausted.load(baseline: baseline)
		let held = await exhausted.snapshot(now: .distantFuture)
		try expect(held.export == nil && held.nextRetry == nil, "Config retry exhaustion must survive restart")
		try expect(await exhausted.snapshot(repair: true).export != nil, "Explicit repair must bypass exhausted automatic config retry")
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-state-\(UUID())")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
