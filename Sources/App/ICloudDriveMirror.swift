import Foundation

struct ICloudMirrorResult: Sendable {
	var completedDeletions: Set<String> = []
	var exportedEntries: [JournalEntry] = []
	var configurationExported = false
	var failures: [String] = []
}

actor ICloudDriveMirror {
	static let containerIdentifier = "iCloud.com.stefan.myvoicememo"

	private struct FileSignature: Equatable {
		var size: Int64
		var modified: Date
		var fileNumber: UInt64?
	}
	private struct IndexedFile {
		var url: URL
		var signature: FileSignature?
	}
	private struct ExportIndex {
		var files: [String: IndexedFile] = [:]
		var exports: [UUID: Set<String>] = [:]
		mutating func insert(_ file: IndexedFile) {
			let name = file.url.lastPathComponent
			files[name] = file
			if let id = ICloudDriveMirror.exportID(for: file.url) { exports[id, default: []].insert(name) }
		}
		mutating func remove(_ name: String) {
			guard let file = files.removeValue(forKey: name), let id = ICloudDriveMirror.exportID(for: file.url) else { return }
			exports[id]?.remove(name)
		}
	}
	private struct AudioReceipt {
		var sourceURL: URL
		var source: FileSignature
		var destination: FileSignature
	}
	private struct MetadataReceipt {
		var entry: JournalEntry
		var url: URL
		var signature: FileSignature
	}
	private struct ConfigurationReceipt {
		var configuration: AppConfiguration
		var url: URL
		var signature: FileSignature
	}
	private enum MirrorError: Error { case invalidFile, invalidReference }

	private let fileManager = FileManager.default
	private let containerURL: URL?
	private var latestRevision = 0
	private var audioReceipts: [URL: AudioReceipt] = [:]
	private var metadataReceipts: [UUID: MetadataReceipt] = [:]
	private var configurationReceipt: ConfigurationReceipt?

	#if DEBUG
	struct OperationCounts: Sendable {
		var directoryScans = 0
		var noteWrites = 0
		var configurationWrites = 0
		var audioCopies = 0
		var removals = 0
	}
	private(set) var operationCounts = OperationCounts()
	func resetOperationCounts() { operationCounts = OperationCounts() }
	#endif

	init(containerURL: URL? = nil) { self.containerURL = containerURL }

	func sync(
		entries: [JournalEntry],
		recordingsURL: URL,
		configuration: AppConfiguration,
		deletedRecordingReferences: Set<String>,
		revision: Int
	) -> ICloudMirrorResult {
		var result = ICloudMirrorResult()
		guard revision >= latestRevision else { return result }
		latestRevision = revision
		guard let documentsURL = documentsURL() else {
			result.failures.append("iCloud Drive is unavailable.")
			return result
		}
		var index: ExportIndex
		do {
			try Task.checkCancellation()
			try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
			index = try scan(documentsURL)
		} catch {
			result.failures.append("iCloud Drive exports could not be read. Pending changes will be retried.")
			return result
		}

		let deletedIDs = Set(deletedRecordingReferences.compactMap(Self.referenceID))
		for reference in deletedRecordingReferences.sorted() {
			do {
				try Task.checkCancellation()
				if let id = Self.referenceID(reference) {
					try removeExports(for: [id], keeping: [], index: &index)
					metadataReceipts[id] = nil
				} else if !Self.isStagingReference(reference) {
					throw MirrorError.invalidReference
				}
				result.completedDeletions.insert(reference)
			} catch {
				result.failures.append("An iCloud Drive deletion could not be completed. It remains pending.")
			}
		}

		do {
			try export(configuration, documentsURL: documentsURL, index: &index)
			result.configurationExported = true
		} catch {
			result.failures.append("The saved configuration could not be exported to iCloud Drive.")
		}
		for entry in entries {
			guard !deletedIDs.contains(entry.id),
				entry.audioFilename.flatMap(Self.referenceID).map({ !deletedIDs.contains($0) }) ?? true,
				entry.audioFilename.map({ URL(fileURLWithPath: $0).pathExtension.lowercased() == "m4a" }) == true
			else { continue }
			do {
				try export(entry, recordingsURL: recordingsURL, documentsURL: documentsURL, index: &index)
				result.exportedEntries.append(entry)
			} catch {
				result.failures.append("Recording \(entry.id.uuidString) could not be exported completely to iCloud Drive.")
			}
		}
		let currentIDs = Set(entries.map(\.id)).subtracting(deletedIDs)
		metadataReceipts = metadataReceipts.filter { currentIDs.contains($0.key) }
		audioReceipts = audioReceipts.filter { url, _ in
			url.deletingLastPathComponent() == documentsURL
				&& Self.exportID(for: url).map(currentIDs.contains) == true
				&& index.files[url.lastPathComponent]?.signature != nil
		}
		return result
	}

	private func scan(_ documentsURL: URL) throws -> ExportIndex {
		#if DEBUG
		operationCounts.directoryScans += 1
		#endif
		let urls = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
		var index = ExportIndex()
		for url in urls where url.lastPathComponent == "config.json" || Self.exportID(for: url) != nil {
			index.insert(try indexedFile(at: url))
		}
		return index
	}

	private func indexedFile(at url: URL) throws -> IndexedFile {
		let attributes = try fileManager.attributesOfItem(atPath: url.path)
		guard attributes[.type] as? FileAttributeType == .typeRegular,
			let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date
		else { return IndexedFile(url: url, signature: nil) }
		return IndexedFile(url: url, signature: FileSignature(size: size.int64Value, modified: modified,
			fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value))
	}

	private func export(_ configuration: AppConfiguration, documentsURL: URL, index: inout ExportIndex) throws {
		try Task.checkCancellation()
		let url = documentsURL.appendingPathComponent("config.json")
		if let receipt = configurationReceipt, receipt.configuration == configuration, receipt.url == url,
			index.files[url.lastPathComponent]?.signature == receipt.signature { return }
		try requireRegularDestination(url, index: index)
		try configuration.jsonData().write(to: url, options: .atomic)
		#if DEBUG
		operationCounts.configurationWrites += 1
		#endif
		let file = try indexedFile(at: url)
		guard let signature = file.signature else { throw MirrorError.invalidFile }
		index.insert(file)
		configurationReceipt = ConfigurationReceipt(configuration: configuration, url: url, signature: signature)
	}

	private func export(_ entry: JournalEntry, recordingsURL: URL, documentsURL: URL, index: inout ExportIndex) throws {
		try Task.checkCancellation()
		guard let filename = entry.audioFilename, URL(fileURLWithPath: filename).lastPathComponent == filename else {
			throw MirrorError.invalidFile
		}
		let sourceURL = recordingsURL.appendingPathComponent(filename)
		guard let source = try indexedFile(at: sourceURL).signature, source.size > 0 else { throw MirrorError.invalidFile }
		let audioURL = documentsURL.appendingPathComponent(exportStem(for: entry) + ".m4a")
		try mirrorAudio(from: sourceURL, signature: source, to: audioURL, index: &index)
		let metadataURL = audioURL.deletingPathExtension().appendingPathExtension("json")
		let receipt = metadataReceipts[entry.id]
		if receipt?.entry != entry || receipt?.url != metadataURL || receipt?.signature != index.files[metadataURL.lastPathComponent]?.signature {
			try requireRegularDestination(metadataURL, index: index)
			var exported = entry
			exported.audioFilename = audioURL.lastPathComponent
			try exported.jsonData().write(to: metadataURL, options: .atomic)
			#if DEBUG
			operationCounts.noteWrites += 1
			#endif
			let file = try indexedFile(at: metadataURL)
			guard let signature = file.signature else { throw MirrorError.invalidFile }
			index.insert(file)
			metadataReceipts[entry.id] = MetadataReceipt(entry: entry, url: metadataURL, signature: signature)
		}
		var ids: Set<UUID> = [entry.id]
		if let legacyID = Self.referenceID(filename) { ids.insert(legacyID) }
		try removeExports(for: ids, keeping: [audioURL.lastPathComponent, metadataURL.lastPathComponent], index: &index)
	}

	private func mirrorAudio(from sourceURL: URL, signature: FileSignature, to destinationURL: URL, index: inout ExportIndex) throws {
		if let receipt = audioReceipts[destinationURL], receipt.sourceURL == sourceURL, receipt.source == signature,
			index.files[destinationURL.lastPathComponent]?.signature == receipt.destination { return }
		try Task.checkCancellation()
		try requireRegularDestination(destinationURL, index: index)
		let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).upload")
		defer { try? fileManager.removeItem(at: stagingURL) }
		try fileManager.copyItem(at: sourceURL, to: stagingURL)
		#if DEBUG
		operationCounts.audioCopies += 1
		#endif
		try Task.checkCancellation()
		guard try indexedFile(at: sourceURL).signature == signature else { throw MirrorError.invalidFile }
		if index.files[destinationURL.lastPathComponent] != nil {
			_ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
		} else {
			try fileManager.moveItem(at: stagingURL, to: destinationURL)
		}
		let file = try indexedFile(at: destinationURL)
		guard let destination = file.signature else { throw MirrorError.invalidFile }
		index.insert(file)
		audioReceipts[destinationURL] = AudioReceipt(sourceURL: sourceURL, source: signature, destination: destination)
	}

	private func requireRegularDestination(_ url: URL, index: ExportIndex) throws {
		if let file = index.files[url.lastPathComponent], file.signature == nil { throw MirrorError.invalidFile }
	}

	private func removeExports(for ids: Set<UUID>, keeping names: Set<String>, index: inout ExportIndex) throws {
		let obsolete = ids.reduce(into: Set<String>()) { $0.formUnion(index.exports[$1] ?? []) }.subtracting(names)
		for name in obsolete.sorted() {
			try Task.checkCancellation()
			guard let file = index.files[name], file.signature != nil else { throw MirrorError.invalidFile }
			do {
				try fileManager.removeItem(at: file.url)
				#if DEBUG
				operationCounts.removals += 1
				#endif
			} catch where Self.isMissing(error) {}
			index.remove(name)
			audioReceipts[file.url] = nil
		}
	}

	nonisolated private static func referenceID(_ reference: String) -> UUID? {
		guard URL(fileURLWithPath: reference).lastPathComponent == reference else { return nil }
		let url = URL(fileURLWithPath: reference)
		guard url.pathExtension.isEmpty || ["aac", "caf", "m4a", "json"].contains(url.pathExtension.lowercased()) else { return nil }
		return canonicalUUID(url.deletingPathExtension().lastPathComponent)
	}

	nonisolated private static func canonicalUUID(_ text: String) -> UUID? {
		guard let id = UUID(uuidString: text), id.uuidString.caseInsensitiveCompare(text) == .orderedSame else { return nil }
		return id
	}

	nonisolated private static func exportID(for url: URL) -> UUID? {
		guard ["m4a", "json"].contains(url.pathExtension.lowercased()) else { return nil }
		let stem = url.deletingPathExtension().lastPathComponent
		if let id = canonicalUUID(stem) { return id }
		guard stem.count > 38, stem.dropLast(36).hasSuffix("__"), let id = canonicalUUID(String(stem.suffix(36))) else { return nil }
		let prefix = String(stem.dropLast(38))
		guard prefix.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}_.+$"#, options: .regularExpression) != nil else { return nil }
		return id
	}

	nonisolated private static func isStagingReference(_ reference: String) -> Bool {
		guard reference.hasPrefix("."), reference.hasSuffix(".finalizing.m4a") else { return false }
		let stem = String(reference.dropFirst().dropLast(".finalizing.m4a".count))
		return stem.count == 73 && stem.dropFirst(36).hasPrefix("-")
			&& canonicalUUID(String(stem.prefix(36))) != nil && canonicalUUID(String(stem.suffix(36))) != nil
	}

	nonisolated private static func isMissing(_ error: Error) -> Bool {
		let error = error as NSError
		return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
	}

	func loadConfiguration() async -> AppConfiguration? {
		guard let url = documentsURL()?.appendingPathComponent("config.json") else { return nil }
		var startedDownload = false
		for _ in 0..<20 {
			if fileManager.fileExists(atPath: url.path) {
				if !startedDownload,
					(try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
					try? fileManager.startDownloadingUbiquitousItem(at: url)
					startedDownload = true
				}
				if let data = try? Data(contentsOf: url),
					let configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
					return configuration
				}
			}
			try? await Task.sleep(for: .milliseconds(250))
		}
		return nil
	}

	private func documentsURL() -> URL? {
		if let containerURL {
			return containerURL.appendingPathComponent("Documents", isDirectory: true)
		}
		return fileManager
			.url(forUbiquityContainerIdentifier: Self.containerIdentifier)?
			.appendingPathComponent("Documents", isDirectory: true)
	}


	private func exportStem(for entry: JournalEntry) -> String {
		let components = Calendar.current.dateComponents([.year, .month, .day], from: entry.createdAt)
		let date = String(
			format: "%04d-%02d-%02d",
			components.year ?? 0,
			components.month ?? 0,
			components.day ?? 0
		)
		return "\(date)_\(cityComponent(for: entry))__\(entry.id.uuidString)"
	}

	private func cityComponent(for entry: JournalEntry) -> String {
		let city = entry.location?.city?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let city, !city.isEmpty else { return "Unknown" }
		let invalidCharacters = CharacterSet(charactersIn: "/\\:?*\"<>|")
			.union(.controlCharacters)
			.union(.newlines)
		let sanitized = city.unicodeScalars.map {
			invalidCharacters.contains($0) ? "-" : String($0)
		}.joined()
		let collapsed = sanitized.replacingOccurrences(
			of: "-+",
			with: "-",
			options: .regularExpression
		)
		let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
		return trimmed.isEmpty ? "Unknown" : String(trimmed.prefix(48))
	}


}
