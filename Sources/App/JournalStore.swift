import Foundation
import Observation

@MainActor
@Observable
final class JournalStore {
	private(set) var entries: [JournalEntry]
	var selectedDate: Date
	var isProcessing = false
	var processingMessage = "Listening back…"
	var settings = JournalSettings.load()

	let isDemoMode: Bool
	private let fileManager = FileManager.default
	private let rootURL: URL
	private let recordingsURL: URL
	private let entriesURL: URL

	init() {
		isDemoMode = ProcessInfo.processInfo.arguments.contains("-demo")
		let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		rootURL = applicationSupport.appendingPathComponent("VoiceMemo", isDirectory: true)
		recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
		entriesURL = rootURL.appendingPathComponent("entries.json")

		if isDemoMode {
			entries = JournalEntry.demo
			selectedDate = JournalEntry.demo.map(\.createdAt).max() ?? .now
		} else {
			entries = []
			selectedDate = .now
			prepareStorage()
			entries = loadEntries()
		}
	}

	func entries(onOrBefore date: Date) -> [JournalEntry] {
		let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) ?? date
		return entries.filter { $0.createdAt < end }.sorted { $0.createdAt > $1.createdAt }
	}

	func entries(inWeekContaining date: Date) -> [JournalEntry] {
		let start = date.startOfWeek()
		let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? date
		return entries.filter { $0.createdAt >= start && $0.createdAt < end }
	}

	func entry(id: UUID) -> JournalEntry? {
		entries.first { $0.id == id }
	}

	func audioURL(for entry: JournalEntry) -> URL? {
		entry.audioFilename.map { recordingsURL.appendingPathComponent($0) }
	}

	func destinationForNewRecording() throws -> URL {
		prepareStorage()
		return recordingsURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
	}

	func finishRecording(at url: URL, duration: TimeInterval, replacing replacementID: UUID? = nil) async {
		isProcessing = true
		processingMessage = "Making a private transcript…"
		let transcript = (try? await LocalTranscriber.transcribe(url: url))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		processingMessage = "Noticing what stayed with you…"
		let reflection = await ReflectionEngine.reflect(on: transcript)

		let entry = JournalEntry(
			id: replacementID ?? UUID(),
			createdAt: replacementID.flatMap { id in entries.first { $0.id == id }?.createdAt } ?? .now,
			duration: duration,
			transcript: transcript.isEmpty ? "No transcript was available for this recording." : transcript,
			headline: reflection.headline,
			observations: reflection.observations,
			tags: reflection.tags,
			audioFilename: url.lastPathComponent
		)

		if let replacementID, let index = entries.firstIndex(where: { $0.id == replacementID }) {
			if let oldURL = audioURL(for: entries[index]), oldURL != url {
				try? fileManager.removeItem(at: oldURL)
			}
			entries[index] = entry
		} else {
			entries.append(entry)
		}
		entries.sort { $0.createdAt > $1.createdAt }
		selectedDate = entry.createdAt
		persist()
		isProcessing = false
	}

	func delete(_ entry: JournalEntry) {
		if let audioURL = audioURL(for: entry) {
			try? fileManager.removeItem(at: audioURL)
		}
		entries.removeAll { $0.id == entry.id }
		persist()
	}

	func addContext(_ context: String, to entryID: UUID) async {
		guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
		isProcessing = true
		processingMessage = "Reading that moment again…"
		let combined = entries[index].transcript + "\n\nAdditional context: " + context
		let reflection = await ReflectionEngine.reflect(on: combined)
		entries[index].context = context
		entries[index].headline = reflection.headline
		entries[index].observations = reflection.observations
		entries[index].tags = reflection.tags
		persist()
		isProcessing = false
	}

	func clearJournal() {
		for entry in entries where entry.audioFilename != nil {
			if let url = audioURL(for: entry) {
				try? fileManager.removeItem(at: url)
			}
		}
		entries.removeAll()
		persist()
	}

	func weeklyReview(for date: Date) async -> WeeklyReview {
		if isDemoMode { return .demo }
		return await ReflectionEngine.weeklyReview(entries: entries(inWeekContaining: date), weekStart: date.startOfWeek())
	}

	func updateSettings(_ settings: JournalSettings) {
		self.settings = settings
		settings.save()
	}

	private func prepareStorage() {
		do {
			try fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
			#if os(iOS)
			try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: rootURL.path)
			#endif
		} catch {
			assertionFailure("Could not prepare local journal storage: \(error)")
		}
	}

	private func loadEntries() -> [JournalEntry] {
		guard let data = try? Data(contentsOf: entriesURL) else { return [] }
		return (try? JSONDecoder().decode([JournalEntry].self, from: data))?.sorted { $0.createdAt > $1.createdAt } ?? []
	}

	private func persist() {
		guard !isDemoMode, let data = try? JSONEncoder().encode(entries) else { return }
		do {
			try data.write(to: entriesURL, options: [.atomic])
			#if os(iOS)
			try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: entriesURL.path)
			#endif
		} catch {
			assertionFailure("Could not save the local journal: \(error)")
		}
	}
}

struct JournalSettings: Codable, Equatable {
	var keepScreenAwakeWhileRecording = true
	var hapticsEnabled = true
	var showTranscripts = true

	private static let key = "journal-settings"

	static func load() -> JournalSettings {
		guard let data = UserDefaults.standard.data(forKey: key) else { return JournalSettings() }
		return (try? JSONDecoder().decode(JournalSettings.self, from: data)) ?? JournalSettings()
	}

	func save() {
		guard let data = try? JSONEncoder().encode(self) else { return }
		UserDefaults.standard.set(data, forKey: Self.key)
	}
}
