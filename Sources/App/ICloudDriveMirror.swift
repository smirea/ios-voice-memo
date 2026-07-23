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
		deletedAudioFilenames: Set<String>,
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

		let completedDeletions = Set(deletedAudioFilenames.filter {
			deleteExport(audioFilename: $0, from: documentsURL)
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

		let exportedAudioURL = documentsURL.appendingPathComponent(audioFilename)
		guard mirrorAudio(from: sourceAudioURL, to: exportedAudioURL) else { return }

		let metadataURL = documentsURL
			.appendingPathComponent(audioFilename)
			.deletingPathExtension()
			.appendingPathExtension("json")
		guard let metadata = try? Self.metadataEncoder.encode(entry) else { return }
		try? metadata.write(to: metadataURL, options: .atomic)
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

	private func deleteExport(audioFilename: String, from documentsURL: URL) -> Bool {
		let audioURL = documentsURL.appendingPathComponent(audioFilename)
		let metadataURL = audioURL.deletingPathExtension().appendingPathExtension("json")
		try? fileManager.removeItem(at: audioURL)
		try? fileManager.removeItem(at: metadataURL)
		return !fileManager.fileExists(atPath: audioURL.path)
			&& !fileManager.fileExists(atPath: metadataURL.path)
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
