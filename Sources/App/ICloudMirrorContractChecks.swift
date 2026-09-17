#if DEBUG
import Foundation

@MainActor
enum ICloudMirrorContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-icloud-mirror-contract-tests") else { return }
		do {
			try await incrementalExport(count: 100)
			try await incrementalExport(count: 400)
			try await missingPairAndSourceChanges()
			try await externalMetadataReplacement()
			try await blockedDocuments()
			try await blockedRename()
			try await authoritativeDeletion()
			try await directoryDeletionFailure()
			print("ICLOUD MIRROR CONTRACT: incremental exports, pair repair, source receipts, external replacement repair, same-revision retries, safe renames, and authoritative deletion passed")
			fflush(stdout)
		} catch {
			fatalError("ICLOUD MIRROR CONTRACT: \(error)")
		}
	}

	private static func incrementalExport(count: Int) async throws {
		let fixture = try Fixture(count: count)
		defer { fixture.remove() }
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud)
		let initialStart = ContinuousClock.now
		let initial = await fixture.sync(mirror)
		let initialDuration = initialStart.duration(to: .now)
		try expect(initial.failures.isEmpty && Set(initial.exportedEntries) == Set(fixture.entries) && initial.configurationExported,
			"Initial export must acknowledge original source entries and the synthetic configuration")
		try await counts(mirror, notes: count, copies: count, configuration: 1)
		let json = try fixture.exportURL(for: fixture.entries[0], extension: "json")
		let originalModification = try modificationDate(json)
		await mirror.resetOperationCounts()
		let unchangedStart = ContinuousClock.now
		let unchanged = await fixture.sync(mirror)
		let unchangedDuration = unchangedStart.duration(to: .now)
		try expect(unchanged.failures.isEmpty, "An unchanged same-revision pass must succeed")
		try await counts(mirror)
		try expect(try modificationDate(json) == originalModification, "Unchanged JSON must retain its modification date")
		await mirror.resetOperationCounts()
		_ = await fixture.sync(mirror, revision: 2)
		try await counts(mirror)
		var edited = fixture.entries
		edited[0].headline = "One changed title"
		await mirror.resetOperationCounts()
		let editedStart = ContinuousClock.now
		let result = await fixture.sync(mirror, entries: edited, revision: 3)
		let editedDuration = editedStart.duration(to: .now)
		try expect(result.failures.isEmpty && result.exportedEntries.contains(edited[0]), "A metadata edit must acknowledge its exact original source snapshot")
		try await counts(mirror, notes: 1)
		try expect(try decodeEntry(json).headline == edited[0].headline, "A metadata edit must update the exported JSON")
		print("ICLOUD MIRROR PERFORMANCE \(count) notes: initial \(initialDuration) [1 scan, \(count) JSON, \(count) copies, 1 config]; unchanged \(unchangedDuration) [1 scan, 0 writes/copies]; one edit \(editedDuration) [1 scan, 1 JSON, 0 copies]")
	}

	private static func missingPairAndSourceChanges() async throws {
		let fixture = try Fixture(count: 1)
		defer { fixture.remove() }
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud)
		_ = await fixture.sync(mirror)
		let entry = fixture.entries[0]
		let json = try fixture.exportURL(for: entry, extension: "json")
		let audio = json.deletingPathExtension().appendingPathExtension("m4a")
		try FileManager.default.removeItem(at: json)
		await mirror.resetOperationCounts()
		let metadataRepair = await fixture.sync(mirror)
		try expect(metadataRepair.failures.isEmpty && FileManager.default.fileExists(atPath: json.path), "A missing JSON partner must be repaired at the same revision")
		try await counts(mirror, notes: 1)
		try FileManager.default.removeItem(at: audio)
		await mirror.resetOperationCounts()
		let audioRepair = await fixture.sync(mirror)
		try expect(audioRepair.failures.isEmpty && FileManager.default.fileExists(atPath: audio.path), "A missing audio partner must be repaired at the same revision")
		try await counts(mirror, copies: 1)

		let source = fixture.recordings.appendingPathComponent(entry.audioFilename!)
		let nextModification = try modificationDate(source).addingTimeInterval(10)
		let changedAudio = Data(repeating: 42, count: 1_024)
		try changedAudio.write(to: source)
		try FileManager.default.setAttributes([.modificationDate: nextModification], ofItemAtPath: source.path)
		await mirror.resetOperationCounts()
		let replaced = await fixture.sync(mirror)
		try expect(replaced.failures.isEmpty && Data(contentsOf: audio) == changedAudio, "A changed source signature must replace equal-sized destination audio")
		try await counts(mirror, copies: 1)
		try replaceExternally(audio, byte: 17)
		await mirror.resetOperationCounts()
		let externalRepair = await fixture.sync(mirror)
		try expect(externalRepair.failures.isEmpty && Data(contentsOf: audio) == changedAudio, "Replacing cloud audio externally must invalidate its cached copy receipt")
		try await counts(mirror, copies: 1)
		try Data(repeating: 19, count: 1_024).write(to: audio)
		let restartedMirror = ICloudDriveMirror(containerURL: fixture.cloud)
		let restarted = await fixture.sync(restartedMirror)
		let restartedCounts = await restartedMirror.operationCounts
		try expect(restarted.failures.isEmpty && restartedCounts.audioCopies == 1 && Data(contentsOf: audio) == changedAudio,
			"A fresh mirror without a successful copy receipt must not trust equal file sizes")
	}

	private static func externalMetadataReplacement() async throws {
		let fixture = try Fixture(count: 1)
		defer { fixture.remove() }
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud)
		_ = await fixture.sync(mirror)
		let json = try fixture.exportURL(for: fixture.entries[0], extension: "json")
		let configuration = fixture.documents.appendingPathComponent("config.json")
		for (url, noteWrites, configurationWrites) in [(json, 1, 0), (configuration, 0, 1)] {
			let original = try Data(contentsOf: url)
			try replaceExternally(url, byte: 120)
			try expect(try Data(contentsOf: url).count == original.count, "The replacement fixture must keep its previous byte count")
			await mirror.resetOperationCounts()
			let result = await fixture.sync(mirror)
			try expect(result.failures.isEmpty && result.exportedEntries == fixture.entries && result.configurationExported,
				"An external metadata replacement must be repaired and acknowledged at the same revision")
			try expect(try Data(contentsOf: url) == original, "External metadata must be replaced with the committed local snapshot")
			try await counts(mirror, notes: noteWrites, configuration: configurationWrites)
		}
	}

	private static func blockedDocuments() async throws {
		let fixture = try Fixture(count: 1)
		defer { fixture.remove() }
		try Data("blocked".utf8).write(to: fixture.documents)
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud)
		let reference = UUID().uuidString
		let failed = await fixture.sync(mirror, deleted: [reference])
		try expect(!failed.failures.isEmpty && failed.exportedEntries.isEmpty && !failed.configurationExported && failed.completedDeletions.isEmpty,
			"An inaccessible Documents directory must not acknowledge any export or deletion")
		try FileManager.default.removeItem(at: fixture.documents)
		let retry = await fixture.sync(mirror, deleted: [reference])
		try expect(retry.failures.isEmpty && retry.exportedEntries == fixture.entries && retry.configurationExported && retry.completedDeletions.contains(reference),
			"Repairing Documents must allow the identical revision to export and acknowledge deletion")
		_ = try fixture.exportURL(for: fixture.entries[0], extension: "m4a")
		_ = try fixture.exportURL(for: fixture.entries[0], extension: "json")
	}

	private static func blockedRename() async throws {
		let fixture = try Fixture(count: 1)
		defer { fixture.remove() }
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud)
		_ = await fixture.sync(mirror)
		let oldJSON = try fixture.exportURL(for: fixture.entries[0], extension: "json")
		let oldAudio = oldJSON.deletingPathExtension().appendingPathExtension("m4a")
		let originalJSON = try Data(contentsOf: oldJSON)
		let originalAudio = try Data(contentsOf: oldAudio)
		let newJSON = fixture.documents.appendingPathComponent(oldJSON.lastPathComponent.replacingOccurrences(of: "_Unknown__", with: "_Chicago__"))
		let newAudio = newJSON.deletingPathExtension().appendingPathExtension("m4a")
		try FileManager.default.createDirectory(at: newJSON, withIntermediateDirectories: true)
		var renamed = fixture.entries[0]
		renamed.location = JournalLocation(latitude: 41.88, longitude: -87.63, city: "Chicago")
		await mirror.resetOperationCounts()
		let failed = await fixture.sync(mirror, entries: [renamed], revision: 2)
		try expect(!failed.failures.isEmpty && failed.exportedEntries.isEmpty, "A blocked new JSON path must leave the city rename unacknowledged")
		try await counts(mirror, copies: 1)
		try expect(try Data(contentsOf: oldJSON) == originalJSON && Data(contentsOf: oldAudio) == originalAudio,
			"A failed city rename must retain the previous complete pair")
		try FileManager.default.removeItem(at: newJSON)
		await mirror.resetOperationCounts()
		let retry = await fixture.sync(mirror, entries: [renamed], revision: 2)
		try expect(retry.failures.isEmpty && retry.exportedEntries == [renamed], "A city rename must retry at the same revision after its JSON path is repaired")
		try await counts(mirror, notes: 1, removals: 2)
		try expect(!FileManager.default.fileExists(atPath: oldJSON.path) && !FileManager.default.fileExists(atPath: oldAudio.path),
			"The obsolete pair must be cleaned only after its replacement is complete")
		try expect(try Data(contentsOf: newAudio) == originalAudio && decodeEntry(newJSON).location?.city == "Chicago",
			"Both members of the renamed pair must contain the current snapshot")
	}

	private static func authoritativeDeletion() async throws {
		let fixture = try Fixture(count: 1)
		defer { fixture.remove() }
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud)
		_ = await fixture.sync(mirror)
		let entry = fixture.entries[0]
		let json = try fixture.exportURL(for: entry, extension: "json")
		let audio = json.deletingPathExtension().appendingPathExtension("m4a")
		let legacyID = UUID().uuidString
		let legacyFiles = ["\(legacyID).m4a", "2026-01-02_old-city__\(legacyID).json"].map { fixture.documents.appendingPathComponent($0) }
		let protectedFiles = ["config.json", "old-city__\(legacyID).json", "notes__not-a-uuid.json", "prefix\(entry.id.uuidString).json", "\(entry.id.uuidString)-backup.m4a", "unrelated.txt"]
			.map { fixture.documents.appendingPathComponent($0) }
		for url in legacyFiles + Array(protectedFiles.dropFirst()) { try Data("preserve".utf8).write(to: url) }
		let protectedContents = try protectedFiles.map { try Data(contentsOf: $0) }
		await mirror.resetOperationCounts()
		let references: Set<String> = [entry.id.uuidString, "\(legacyID).m4a", "not-a-uuid.m4a", "config.json"]
		let result = await fixture.sync(mirror, deleted: references, revision: 2)
		try expect(!result.failures.isEmpty && result.exportedEntries.isEmpty && result.completedDeletions == [entry.id.uuidString, "\(legacyID).m4a"],
			"Deletion must dominate a same-batch entry and acknowledge its exact generated identities")
		try expect(([json, audio] + legacyFiles).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Deletion must remove all generated pairs without resurrecting the input entry")
		try expect(try protectedFiles.map { try Data(contentsOf: $0) } == protectedContents, "Generated-file matching must preserve config and unrelated suffix lookalikes")
		try await counts(mirror, removals: 4)
	}

	private static func directoryDeletionFailure() async throws {
		let fixture = try Fixture(count: 0)
		defer { fixture.remove() }
		let reference = UUID().uuidString
		let blocked = fixture.documents.appendingPathComponent("\(reference).m4a", isDirectory: true)
		try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
		let child = blocked.appendingPathComponent("keep.txt")
		try Data("preserve".utf8).write(to: child)
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud)
		let failed = await fixture.sync(mirror, deleted: [reference])
		try expect(!failed.failures.isEmpty && failed.completedDeletions.isEmpty && FileManager.default.fileExists(atPath: child.path),
			"A generated-looking directory must be preserved and its deletion left pending")
		try FileManager.default.removeItem(at: blocked)
		try Data("audio".utf8).write(to: blocked)
		let retry = await fixture.sync(mirror, deleted: [reference])
		try expect(retry.failures.isEmpty && retry.completedDeletions == [reference] && !FileManager.default.fileExists(atPath: blocked.path),
			"Repairing a generated directory must allow deletion to retry at the identical revision")
	}

	private static func counts(_ mirror: ICloudDriveMirror, notes: Int = 0, copies: Int = 0, configuration: Int = 0, removals: Int = 0) async throws {
		let actual = await mirror.operationCounts
		try expect(actual.directoryScans == 1 && actual.noteWrites == notes && actual.audioCopies == copies
			&& actual.configurationWrites == configuration && actual.removals == removals,
			"Expected one directory scan, \(notes) note writes, \(copies) copies, \(configuration) config writes, \(removals) removals; got \(actual)")
	}

	private static func decodeEntry(_ url: URL) throws -> JournalEntry {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode(JournalEntry.self, from: Data(contentsOf: url))
	}

	private static func modificationDate(_ url: URL) throws -> Date {
		try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
	}

	private static func replaceExternally(_ url: URL, byte: UInt8) throws {
		let nextModification = try modificationDate(url).addingTimeInterval(10)
		let size = try Data(contentsOf: url).count
		try Data(repeating: byte, count: size).write(to: url, options: .atomic)
		try FileManager.default.setAttributes([.modificationDate: nextModification], ofItemAtPath: url.path)
	}

	private static func expect(_ condition: Bool, _ message: String) throws {
		if !condition { throw Failure(message: message) }
	}

	private struct Failure: Error, CustomStringConvertible {
		var message: String
		var description: String { message }
	}

	private struct Fixture {
		let root: URL
		let cloud: URL
		let recordings: URL
		let entries: [JournalEntry]
		var documents: URL { cloud.appendingPathComponent("Documents", isDirectory: true) }

		init(count: Int) throws {
			root = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-mirror-contract-\(UUID().uuidString)", isDirectory: true)
			cloud = root.appendingPathComponent("Cloud", isDirectory: true)
			recordings = root.appendingPathComponent("Recordings", isDirectory: true)
			try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
			try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
			let fixtureRecordings = recordings
			entries = try (0..<count).map { index in
				let id = UUID()
				let filename = "\(id.uuidString).m4a"
				try Data(repeating: UInt8(index % 251), count: 1_024).write(to: fixtureRecordings.appendingPathComponent(filename))
				return JournalEntry(id: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), duration: 30,
					transcript: "Fixture transcript \(index)", headline: "Fixture \(index)", audioFilename: filename)
			}
		}

		func sync(_ mirror: ICloudDriveMirror, entries: [JournalEntry]? = nil, deleted: Set<String> = [], revision: Int = 1) async -> ICloudMirrorResult {
			await mirror.sync(entries: entries ?? self.entries, recordingsURL: recordings,
				configuration: AppConfiguration(settings: JournalSettings(), elevenLabsAPIKey: ""), deletedRecordingReferences: deleted, revision: revision)
		}

		func exportURL(for entry: JournalEntry, extension suffix: String) throws -> URL {
			let files = try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
			guard let url = files.first(where: { $0.pathExtension == suffix && $0.deletingPathExtension().lastPathComponent.hasSuffix("__\(entry.id.uuidString)") })
			else { throw Failure(message: "Missing generated \(suffix) export for a fixture entry") }
			return url
		}

		func remove() { try? FileManager.default.removeItem(at: root) }
	}
}
#endif
