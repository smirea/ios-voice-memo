import Foundation

actor ICloudDriveMirror {
	static let containerIdentifier = "iCloud.com.stefan.myvoicememo"

	private let fileManager = FileManager.default
	private let containerURL: URL?
	private var latestRevision = 0

	init(containerURL: URL? = nil) {
		self.containerURL = containerURL
	}

	func sync(
		entries: [JournalEntry],
		recordingsURL: URL,
		deletedRecordingReferences: Set<String>,
		revision: Int
	) -> Set<String> {
		let shouldExport = revision > latestRevision
		if shouldExport { latestRevision = revision }
		guard let documentsURL = documentsURL() else { return [] }

		do {
			try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
		} catch {
			return []
		}

		let completedDeletions = Set(deletedRecordingReferences.filter {
			deleteExports(matching: $0, from: documentsURL)
		})

		guard shouldExport else {
			return completedDeletions
		}

		for entry in entries {
			export(entry, recordingsURL: recordingsURL, documentsURL: documentsURL)
		}
		return completedDeletions
	}

	private func documentsURL() -> URL? {
		if let containerURL {
			return containerURL.appendingPathComponent("Documents", isDirectory: true)
		}
		return fileManager
			.url(forUbiquityContainerIdentifier: Self.containerIdentifier)?
			.appendingPathComponent("Documents", isDirectory: true)
	}

	private func export(_ entry: JournalEntry, recordingsURL: URL, documentsURL: URL) {
		guard let audioFilename = entry.audioFilename else { return }
		let sourceAudioURL = recordingsURL.appendingPathComponent(audioFilename)
		guard fileManager.fileExists(atPath: sourceAudioURL.path) else { return }

		let exportedAudioFilename = "\(exportStem(for: entry)).\(sourceAudioURL.pathExtension.lowercased())"
		let exportedAudioURL = documentsURL.appendingPathComponent(exportedAudioFilename)
		guard mirrorAudio(from: sourceAudioURL, to: exportedAudioURL) else { return }

		let metadataURL = exportedAudioURL.deletingPathExtension().appendingPathExtension("json")
		var exportedEntry = entry
		exportedEntry.audioFilename = exportedAudioFilename
		guard let metadata = try? Self.metadataEncoder.encode(exportedEntry) else { return }
		do {
			try metadata.write(to: metadataURL, options: .atomic)
		} catch {
			return
		}

		removeObsoleteExports(
			for: entry,
			keeping: [exportedAudioURL, metadataURL],
			from: documentsURL
		)
	}

	private func mirrorAudio(from sourceURL: URL, to destinationURL: URL) -> Bool {
		let sourceSize = fileSize(at: sourceURL)
		if fileManager.fileExists(atPath: destinationURL.path),
			sourceSize > 0,
			sourceSize == fileSize(at: destinationURL)
		{
			return true
		}

		let stagingURL = destinationURL
			.deletingLastPathComponent()
			.appendingPathComponent(".\(UUID().uuidString).upload")
		defer { try? fileManager.removeItem(at: stagingURL) }

		do {
			try fileManager.copyItem(at: sourceURL, to: stagingURL)
			if fileManager.fileExists(atPath: destinationURL.path) {
				_ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
			} else {
				try fileManager.moveItem(at: stagingURL, to: destinationURL)
			}
			return true
		} catch {
			return false
		}
	}

	private func deleteExports(matching reference: String, from documentsURL: URL) -> Bool {
		for url in exportURLs(matching: reference, from: documentsURL) {
			try? fileManager.removeItem(at: url)
		}
		return exportURLs(matching: reference, from: documentsURL).isEmpty
	}

	private func removeObsoleteExports(for entry: JournalEntry, keeping keptURLs: Set<URL>, from documentsURL: URL) {
		let references = [entry.id.uuidString, entry.audioFilename].compactMap { $0 }
		let keptPaths = Set(keptURLs.map(\.standardizedFileURL.path))
		for reference in references {
			for url in exportURLs(matching: reference, from: documentsURL)
			where !keptPaths.contains(url.standardizedFileURL.path) {
				try? fileManager.removeItem(at: url)
			}
		}
	}

	private func exportURLs(matching reference: String, from documentsURL: URL) -> [URL] {
		let referenceStem = URL(fileURLWithPath: reference).deletingPathExtension().lastPathComponent
		let suffix = "__\(referenceStem)"
		let urls = (try? fileManager.contentsOfDirectory(
			at: documentsURL,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		)) ?? []
		return urls.filter { url in
			guard ["m4a", "json"].contains(url.pathExtension.lowercased()) else { return false }
			let stem = url.deletingPathExtension().lastPathComponent
			return stem == referenceStem || stem.hasSuffix(suffix)
		}
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

	private func fileSize(at url: URL) -> Int64 {
		let attributes = try? fileManager.attributesOfItem(atPath: url.path)
		return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
	}

	private static let metadataEncoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return encoder
	}()
}
