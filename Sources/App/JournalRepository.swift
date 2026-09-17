import AVFAudio
import Foundation

struct JournalRecord: Codable, Sendable {
	enum State: String, Codable { case recording, saved, deleted }
	private enum CodingKeys: String, CodingKey {
		case schemaVersion, id, entry, state, ownedAudioFilenames, inputRevision
	}
	var schemaVersion = 1
	let id: UUID
	var entry: JournalEntry?
	var state: State
	var ownedAudioFilenames: Set<String>
	var inputRevision: Int = 0

	init(entry: JournalEntry, state: State = .saved, ownedAudioFilenames: Set<String> = []) {
		id = entry.id
		self.entry = entry
		self.state = state
		self.ownedAudioFilenames = ownedAudioFilenames.union(entry.audioFilename.map { [$0] } ?? [])
	}

	init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
		id = try values.decode(UUID.self, forKey: .id)
		entry = try values.decodeIfPresent(JournalEntry.self, forKey: .entry)
		state = try values.decode(State.self, forKey: .state)
		ownedAudioFilenames = try values.decode(Set<String>.self, forKey: .ownedAudioFilenames)
		inputRevision = try values.decodeIfPresent(Int.self, forKey: .inputRevision) ?? 0
	}
}

struct JournalLoad: Sendable {
	var entries: [JournalEntry]
	var issues: [String]
	var deletionReferences: Set<String>
}

actor JournalRepository {
	private let rootURL: URL
	private let recordsURL: URL
	private let recordingsURL: URL
	private let fileManager = FileManager.default
	private var records: [UUID: JournalRecord] = [:]
	private var reservedIDs = Set<UUID>()
	private var didLoad = false
	private var loadIssues: [String] = []

	init(rootURL: URL) {
		self.rootURL = rootURL
		recordsURL = rootURL.appendingPathComponent("Records", isDirectory: true)
		recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
	}

	var isLoaded: Bool { didLoad }

	func load() throws -> JournalLoad {
		guard !didLoad else { return snapshot(issues: loadIssues) }
		records.removeAll()
		reservedIDs.removeAll()
		try prepareDirectories()
		var issues: [String] = []
		let urls = try fileManager.contentsOfDirectory(at: recordsURL, includingPropertiesForKeys: nil)
		for url in urls where url.pathExtension == "json" {
			guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
				issues.append("An unrecognized note record was preserved.")
				continue
			}
			reservedIDs.insert(id)
			do {
				let record = try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: url))
				guard record.id == id, record.schemaVersion == 1,
					(record.state == .deleted ? record.entry == nil : record.entry?.id == id),
					record.ownedAudioFilenames.allSatisfy(Self.isFilename),
					record.entry?.audioFilename.map(Self.isFilename) ?? true
				else { throw RepositoryError.invalidRecord }
				records[id] = record
			} catch {
				issues.append("Note \(id.uuidString.prefix(8)) could not be read. Its original files were preserved.")
			}
		}
		try migrateLegacyEntries(issues: &issues)
		migratePendingRecording(issues: &issues)
		try recoverRecordings(issues: &issues)
		didLoad = true
		loadIssues = issues
		return snapshot(issues: issues)
	}

	func beginRecording(calendarEvent: JournalCalendarEvent?) throws -> JournalEntry {
		try requireLoaded()
		let id = UUID()
		let entry = JournalEntry(id: id, duration: 0, transcript: "", headline: "Processing recording",
			audioFilename: "\(id.uuidString).m4a", calendarEvent: calendarEvent)
		try write(JournalRecord(entry: entry, state: .recording,
			ownedAudioFilenames: ["\(id.uuidString).m4a", "\(id.uuidString).caf"]))
		return entry
	}

	func checkpoint(id: UUID, duration: TimeInterval) throws {
		guard var record = records[id], record.state == .recording else { return }
		let elapsed = max(record.entry?.duration ?? 0, duration)
		record.entry?.duration = elapsed
		try write(record)
	}

	func finishRecording(id: UUID, duration: TimeInterval) throws -> JournalEntry {
		try requireLoaded()
		guard var record = records[id], record.state != .deleted, var entry = record.entry else {
			throw RepositoryError.unavailableRecord
		}
		entry.duration = duration
		record.entry = entry
		record.state = .saved
		try write(record)
		return entry
	}

	func save(_ entries: [JournalEntry]) throws {
		try requireLoaded()
		for entry in entries {
			if records[entry.id]?.state == .deleted { continue }
			if reservedIDs.contains(entry.id), records[entry.id] == nil { throw RepositoryError.invalidRecord }
			if records[entry.id]?.entry == entry { continue }
			var record = records[entry.id] ?? JournalRecord(entry: entry)
			record.entry = entry
			if let filename = entry.audioFilename { record.ownedAudioFilenames.insert(filename) }
			try write(record)
		}
	}

	func delete(id: UUID) throws -> Set<String> {
		try requireLoaded()
		guard var record = records[id] else { throw RepositoryError.unavailableRecord }
		record.state = .deleted
		record.entry = nil
		try write(record)
		return record.ownedAudioFilenames.union([id.uuidString])
	}

	func cleanupDeletedAudio(id: UUID) throws {
		guard let record = records[id], record.state == .deleted else { return }
		for filename in record.ownedAudioFilenames {
			do { try fileManager.removeItem(at: recordingsURL.appendingPathComponent(filename)) }
			catch where Self.isMissing(error) {}
		}
	}

	func record(id: UUID) -> JournalRecord? { records[id] }

	private func snapshot(issues: [String]) -> JournalLoad {
		JournalLoad(
			entries: records.values.filter { $0.state == .saved }.compactMap(\.entry).sorted { $0.createdAt > $1.createdAt },
			issues: issues,
			deletionReferences: records.values.filter { $0.state == .deleted }.reduce(into: []) {
				$0.formUnion($1.ownedAudioFilenames)
				$0.insert($1.id.uuidString)
			})
	}

	private func migrateLegacyEntries(issues: inout [String]) throws {
		let marker = rootURL.appendingPathComponent("records-migration-v1.complete")
		if let data = try readIfPresent(marker) {
			guard data == Data("1".utf8) else { throw RepositoryError.invalidRecord }
			return
		}
		let legacy = rootURL.appendingPathComponent("entries.json")
		let data: Data?
		do { data = try readIfPresent(legacy) }
		catch {
			issues.append("The previous journal could not be read. Its original files were preserved.")
			return
		}
		guard let data else {
			try Data("1".utf8).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			return
		}
		let objects: [Any]
		do {
			guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
				throw RepositoryError.invalidRecord
			}
			objects = array
		} catch {
			issues.append("The previous journal is damaged. Its original files were preserved; automatic audio recovery is paused.")
			return
		}
		var complete = true
		for (index, object) in objects.enumerated() {
			do {
				let entry = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
				guard entry.audioFilename.map(Self.isFilename) ?? true else { throw RepositoryError.invalidRecord }
				if !reservedIDs.contains(entry.id) { try write(JournalRecord(entry: entry)) }
				else if records[entry.id] == nil { complete = false }
			} catch {
				complete = false
				if let raw = object as? [String: Any], let value = raw["id"] as? String, let id = UUID(uuidString: value) {
					reservedIDs.insert(id)
				}
				issues.append("Previous note \(index + 1) could not be migrated. Its original data was preserved.")
			}
		}
		if complete {
			try Data("1".utf8).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		}
	}

	private func migratePendingRecording(issues: inout [String]) {
		do {
			guard let data = try readIfPresent(rootURL.appendingPathComponent("pending-recording.json")) else { return }
			let pending = try JSONDecoder().decode(LegacyPendingRecording.self, from: data)
			guard Self.isFilename(pending.filename) else { throw RepositoryError.invalidRecord }
			guard !records.values.contains(where: { $0.ownedAudioFilenames.contains(pending.filename) }) else { return }
			let id = UUID(uuidString: URL(fileURLWithPath: pending.filename).deletingPathExtension().lastPathComponent) ?? UUID()
			guard !reservedIDs.contains(id), issues.isEmpty else { return }
			let entry = JournalEntry(id: id, createdAt: pending.startedAt, duration: pending.duration,
				transcript: "", headline: "Recovered recording", audioFilename: pending.filename, calendarEvent: pending.calendarEvent)
			try write(JournalRecord(entry: entry, state: .recording))
		} catch {
			issues.append("Interrupted recording metadata could not be read. Its original files were preserved.")
		}
	}

	private func recoverRecordings(issues: inout [String]) throws {
		for record in Array(records.values) where record.state == .recording {
			guard let entry = record.entry else { continue }
			var readable: (String, TimeInterval)?
			var hasUnreadableAudio = false
			let filenames = record.ownedAudioFilenames.sorted {
				$0.hasSuffix(".m4a") && !$1.hasSuffix(".m4a")
			}
			for filename in filenames {
				do {
					readable = (filename, try Self.audioDuration(at: recordingsURL.appendingPathComponent(filename)))
					break
				} catch { if !Self.isMissing(error) { hasUnreadableAudio = true } }
			}
			guard let (filename, duration) = readable else {
				if hasUnreadableAudio { issues.append("A recording could not be recovered. Its audio and metadata were preserved.") }
				else { _ = try deleteLoaded(id: record.id) }
				continue
			}
			var recovered = record
			recovered.entry?.audioFilename = filename
			recovered.entry?.duration = max(entry.duration, duration)
			recovered.entry?.headline = "Recovered recording"
			recovered.state = .saved
			try write(recovered)
		}
		for record in records.values where record.state == .deleted {
			do { try cleanupDeletedAudio(id: record.id) }
			catch { issues.append("Deleted audio cleanup is pending and will be retried.") }
		}
		guard issues.isEmpty else { return }
		let urls = try fileManager.contentsOfDirectory(at: recordingsURL,
			includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
		let owned = records.values.reduce(into: Set<String>()) { $0.formUnion($1.ownedAudioFilenames) }
		let groups = Dictionary(grouping: urls.filter {
			["m4a", "caf"].contains($0.pathExtension.lowercased()) && !owned.contains($0.lastPathComponent)
		}, by: { $0.deletingPathExtension().lastPathComponent })
		for (stem, group) in groups {
			let id = UUID(uuidString: stem) ?? UUID()
			guard !reservedIDs.contains(id) else { continue }
			let candidates = group.sorted { $0.pathExtension == "m4a" && $1.pathExtension != "m4a" }
			guard let candidate = candidates.compactMap({ url -> (URL, TimeInterval)? in
				guard let duration = try? Self.audioDuration(at: url) else { return nil }
				return (url, duration)
			}).first else {
				issues.append("Unrecognized audio could not be recovered. The original file was preserved.")
				continue
			}
			let createdAt = try candidate.0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .now
			let entry = JournalEntry(id: id, createdAt: createdAt, duration: candidate.1, transcript: "",
				headline: "Recovered recording", audioFilename: candidate.0.lastPathComponent)
			try write(JournalRecord(entry: entry, ownedAudioFilenames: Set(group.map(\.lastPathComponent))))
		}
	}

	private func deleteLoaded(id: UUID) throws -> Set<String> {
		guard var record = records[id] else { throw RepositoryError.unavailableRecord }
		record.entry = nil
		record.state = .deleted
		try write(record)
		return record.ownedAudioFilenames
	}

	private func write(_ record: JournalRecord) throws {
		guard record.ownedAudioFilenames.allSatisfy(Self.isFilename),
			record.entry?.audioFilename.map(Self.isFilename) ?? true else { throw RepositoryError.invalidRecord }
		let data = try JSONEncoder().encode(record)
		try data.write(to: recordsURL.appendingPathComponent("\(record.id.uuidString).json"),
			options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		records[record.id] = record
		reservedIDs.insert(record.id)
	}

	private func prepareDirectories() throws {
		for directory in [rootURL, recordsURL, recordingsURL] {
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
			try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
			var url = directory
			var values = URLResourceValues()
			values.isExcludedFromBackup = false
			try url.setResourceValues(values)
		}
	}

	private func requireLoaded() throws {
		guard didLoad else { throw RepositoryError.notLoaded }
	}

	private func readIfPresent(_ url: URL) throws -> Data? {
		do { return try Data(contentsOf: url) }
		catch where Self.isMissing(error) { return nil }
	}

	private static func audioDuration(at url: URL) throws -> TimeInterval {
		_ = try url.resourceValues(forKeys: [.fileSizeKey])
		let file = try AVAudioFile(forReading: url)
		guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw RepositoryError.invalidAudio }
		return Double(file.length) / file.processingFormat.sampleRate
	}

	private static func isFilename(_ value: String) -> Bool {
		!value.isEmpty && value != "." && value != ".." && URL(fileURLWithPath: value).lastPathComponent == value
	}

	private static func isMissing(_ error: Error) -> Bool {
		let error = error as NSError
		return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
	}
}

private struct LegacyPendingRecording: Decodable {
	var filename: String
	var startedAt: Date
	var duration: TimeInterval
	var calendarEvent: JournalCalendarEvent?
}

enum RepositoryError: LocalizedError {
	case invalidRecord, invalidAudio, unavailableRecord, notLoaded
	var errorDescription: String? {
		switch self {
		case .invalidRecord: "The note metadata could not be read safely. Original files were preserved."
		case .invalidAudio: "The recording could not be read. Its original audio was preserved."
		case .unavailableRecord: "This recording is no longer available."
		case .notLoaded: "The journal could not be opened. Original files were preserved."
		}
	}
}
