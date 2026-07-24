@preconcurrency import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
final class JournalStore {
	private(set) var entries: [JournalEntry]
	private(set) var entryProcessingPhases: [UUID: EntryProcessingPhase] = [:]
	private(set) var namedLocations: [NamedJournalLocation] = []
	var transcriptionAlertMessage: String?
	var settings = JournalSettings.load()
	let calendarSync: CalendarSync

	let isDemoMode: Bool
	private let fileManager = FileManager.default
	private let rootURL: URL
	private let recordingsURL: URL
	private let entriesURL: URL
	private let configurationURL: URL
	private let pendingRecordingURL: URL
	@ObservationIgnored private let iCloudDriveMirror = ICloudDriveMirror()
	@ObservationIgnored private let reminderActivityManager = ReminderActivityManager()
	@ObservationIgnored private var iCloudRevision = 0
	@ObservationIgnored private var pendingICloudDeletionReferences = Set<String>()
	@ObservationIgnored private var entryProcessingTasks: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored private var entryProcessingTokens: [UUID: UUID] = [:]
	@ObservationIgnored private var pendingEntryEvaluations: [PendingEntryEvaluation] = []
	@ObservationIgnored private var entryEvaluationWorker: Task<Void, Never>?
	@ObservationIgnored private var recordingLocationTask: Task<JournalLocation?, Never>?
	@ObservationIgnored private var entryLocationTasks: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored private var isConfigurationRestorePending = false

	init() {
		isDemoMode = ProcessInfo.processInfo.arguments.contains("-demo")
		let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		rootURL = applicationSupport.appendingPathComponent("MyVoiceMemo", isDirectory: true)
		recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
		entriesURL = rootURL.appendingPathComponent("entries.json")
		configurationURL = rootURL.appendingPathComponent("config.json")
		pendingRecordingURL = rootURL.appendingPathComponent("pending-recording.json")
		calendarSync = CalendarSync(
			isDemoMode: isDemoMode,
			cacheURL: rootURL.appendingPathComponent("calendar-events.json")
		)
		pendingICloudDeletionReferences = Set(
			UserDefaults.standard.stringArray(forKey: Self.iCloudDeletionKey) ?? []
		)

		if isDemoMode {
			entries = JournalEntry.demo
			namedLocations = NamedJournalLocation.demo
			settings.calendarSyncEnabled = true
		} else {
			entries = []
			prepareStorage()
			if let configuration = loadConfiguration() {
				settings = configuration.settings
				namedLocations = configuration.locations
				settings.save()
			} else {
				isConfigurationRestorePending = true
			}
			entries = loadEntries()
			recoverUnreferencedRecordings()
			resumeInterruptedProcessing()
			if isConfigurationRestorePending {
				Task { @MainActor [weak self] in
					await self?.restoreConfigurationFromICloud()
				}
			} else {
				scheduleICloudDriveMirror()
			}
		}
	}

	func entries(inWeekContaining date: Date) -> [JournalEntry] {
		let start = date.startOfWeek()
		let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? date
		return entries.filter { $0.createdAt >= start && $0.createdAt < end }
	}

	func entry(id: UUID) -> JournalEntry? {
		entries.first { $0.id == id }
	}

	func namedLocation(for location: JournalLocation) -> NamedJournalLocation? {
		NamedLocationResolver.resolve(LocationCoordinate(location), in: namedLocations)
	}

	func displayName(for location: JournalLocation) -> String {
		namedLocation(for: location)?.name ?? location.displayName
	}

	func nearbyNamedLocations(
		to location: JournalLocation,
		excluding excludedID: UUID? = nil
	) -> [NearbyNamedLocation] {
		NamedLocationResolver.nearby(
			to: LocationCoordinate(location),
			locations: namedLocations,
			entries: entries,
			excluding: excludedID
		)
	}

	func saveNamedLocation(
		id: UUID?,
		name: String,
		address: String,
		pin: LocationCoordinate,
		for source: JournalLocation
	) {
		let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return }
		let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
		let sourceCoordinate = LocationCoordinate(source)
		let locationID = id ?? UUID()

		removeExactAlias(sourceCoordinate, excluding: locationID)
		if let index = namedLocations.firstIndex(where: { $0.id == locationID }) {
			namedLocations[index].name = name
			namedLocations[index].address = address.isEmpty ? nil : address
			namedLocations[index].pin = pin
			appendAlias(sourceCoordinate, at: index)
		} else {
			namedLocations.append(NamedJournalLocation(
				id: locationID,
				name: name,
				address: address.isEmpty ? nil : address,
				pin: pin,
				aliases: [sourceCoordinate]
			))
		}
		commitConfiguration()
	}

	func assign(_ source: JournalLocation, to locationID: UUID) {
		guard let index = namedLocations.firstIndex(where: { $0.id == locationID }) else { return }
		let coordinate = LocationCoordinate(source)
		removeExactAlias(coordinate, excluding: locationID)
		appendAlias(coordinate, at: index)
		commitConfiguration()
	}

	func audioURL(for entry: JournalEntry) -> URL? {
		entry.audioFilename.map { recordingsURL.appendingPathComponent($0) }
	}

	func processingPhase(for entryID: UUID) -> EntryProcessingPhase? {
		entryProcessingPhases[entryID]
	}

	@discardableResult
	func beginRecordingLocationCapture() -> Task<JournalLocation?, Never> {
		recordingLocationTask?.cancel()
		let task = Task {
			await EntryLocationCapture.capture()
		}
		recordingLocationTask = task
		return task
	}

	func destinationForNewRecording(calendarEvent: JournalCalendarEvent?) throws -> URL {
		prepareStorage()
		let url = recordingsURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
		try writePendingRecording(PendingRecording(
			filename: url.lastPathComponent,
			startedAt: .now,
			duration: 0,
			calendarEvent: calendarEvent
		))
		return url
	}

	func checkpointRecording(at url: URL, duration: TimeInterval) {
		guard var pending = loadPendingRecording(), pending.filename == url.lastPathComponent else { return }
		pending.duration = max(pending.duration, duration)
		try? writePendingRecording(pending)
	}

	func cancelRecording(at url: URL) {
		recordingLocationTask?.cancel()
		recordingLocationTask = nil
		clearPendingRecording(matching: url)
	}

	@discardableResult
	func finishRecording(
		at url: URL,
		duration: TimeInterval,
		calendarEvent: JournalCalendarEvent?
	) -> UUID {
		let entryID = UUID()
		let savedEntry = JournalEntry(
			id: entryID,
			createdAt: .now,
			duration: duration,
			transcript: "",
			headline: "Processing recording",
			audioFilename: url.lastPathComponent,
			calendarEvent: calendarEvent
		)

		entries.append(savedEntry)
		entries.sort { $0.createdAt > $1.createdAt }
		if persist() {
			clearPendingRecording(matching: url)
		}

		startProcessing(entryID: entryID, url: url)
		attachRecordedLocation(to: entryID)
		return entryID
	}

	private func startProcessing(entryID: UUID, url: URL) {
		entryProcessingTasks[entryID]?.cancel()
		let processingToken = UUID()
		entryProcessingTokens[entryID] = processingToken
		entryProcessingPhases[entryID] = .transcribing
		entryProcessingTasks[entryID] = Task { @MainActor [weak self] in
			await self?.processRecording(entryID: entryID, url: url, token: processingToken)
		}
	}

	private func resumeInterruptedProcessing() {
		for entry in entries where entry.headline == "Processing recording"
			|| entry.headline == "Recovered recording"
		{
			guard let url = audioURL(for: entry), fileManager.fileExists(atPath: url.path) else { continue }
			startProcessing(entryID: entry.id, url: url)
		}
	}

	private func attachRecordedLocation(to entryID: UUID) {
		let locationTask = recordingLocationTask ?? Task {
			await EntryLocationCapture.capture()
		}
		recordingLocationTask = nil
		entryLocationTasks[entryID]?.cancel()
		entryLocationTasks[entryID] = Task { @MainActor [weak self] in
			let location = await locationTask.value
			guard !Task.isCancelled, let self else { return }
			defer { self.entryLocationTasks.removeValue(forKey: entryID) }
			guard let location,
				let index = self.entries.firstIndex(where: { $0.id == entryID })
			else { return }
			self.entries[index].location = location
			self.persist()
		}
	}

	private func processRecording(entryID: UUID, url: URL, token: UUID) async {
		let transcription: TranscriptionResult?
		do {
			let result = try await AudioTranscriber.transcribe(
				url: url,
				preferElevenLabs: settings.preferElevenLabsTranscription
			) { [weak self] partialResult in
				Task { @MainActor [weak self] in
					self?.updatePartialTranscript(partialResult, for: entryID, token: token)
				}
			}
			transcription = result
			transcriptionAlertMessage = result.warning
		} catch {
			transcription = nil
			if settings.preferElevenLabsTranscription, !Task.isCancelled {
				transcriptionAlertMessage = error.localizedDescription
			}
		}
		let transcript = transcription?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !Task.isCancelled, entryProcessingTokens[entryID] == token else { return }
		guard let transcriptIndex = entries.firstIndex(where: { $0.id == entryID }) else {
			finishProcessing(entryID, token: token)
			return
		}

		entries[transcriptIndex].transcript = transcript.isEmpty ? "No transcript available." : transcript
		entries[transcriptIndex].summary = nil
		entries[transcriptIndex].transcriptModel = transcription?.modelName
		entryProcessingPhases[entryID] = .reflecting
		persist()

		enqueueEvaluation(entryID: entryID, transcript: transcript, token: token)
	}

	func reprocessEntry(id entryID: UUID) {
		guard let entry = entry(id: entryID), !entry.transcript.isEmpty else { return }
		entryProcessingTasks.removeValue(forKey: entryID)?.cancel()
		let token = UUID()
		entryProcessingTokens[entryID] = token
		entryProcessingPhases[entryID] = .reflecting
		enqueueEvaluation(
			entryID: entryID,
			transcript: entry.transcript,
			token: token
		)
	}

	private func enqueueEvaluation(entryID: UUID, transcript: String, token: UUID) {
		pendingEntryEvaluations.removeAll { $0.entryID == entryID }
		pendingEntryEvaluations.append(PendingEntryEvaluation(
			entryID: entryID,
			transcript: transcript,
			token: token
		))
		guard entryEvaluationWorker == nil else {
			entryProcessingPhases[entryID] = .queued
			return
		}
		entryEvaluationWorker = Task { @MainActor [weak self] in
			await self?.drainEntryEvaluations()
		}
	}

	private func drainEntryEvaluations() async {
		defer { entryEvaluationWorker = nil }
		while !Task.isCancelled, !pendingEntryEvaluations.isEmpty {
			let evaluation = pendingEntryEvaluations.removeFirst()
			guard entryProcessingTokens[evaluation.entryID] == evaluation.token else { continue }
			entryProcessingPhases[evaluation.entryID] = .reflecting
			await evaluateEntry(
				entryID: evaluation.entryID,
				transcript: evaluation.transcript,
				token: evaluation.token
			)
		}
	}

	private func evaluateEntry(entryID: UUID, transcript: String, token: UUID) async {
		guard !Task.isCancelled,
			entryProcessingTokens[entryID] == token,
			let source = entry(id: entryID)
		else { return }
		let reflection = await ReflectionEngine.reflect(
			on: transcript,
			includeSummary: source.duration > 20
		)

		guard !Task.isCancelled, entryProcessingTokens[entryID] == token else { return }
		entryProcessingPhases[entryID] = .reminders
		var reminderResult: ReminderParsingResult?
		if settings.eventRemindersEnabled {
			reminderResult = await ReminderEngine.parse(
				transcript: transcript,
				sourceEvent: source.calendarEvent,
				createdAt: source.createdAt,
				currentReminders: source.reminders,
				feedback: source.reminderFeedback
			)
		}

		guard !Task.isCancelled,
			entryProcessingTokens[entryID] == token,
			let index = entries.firstIndex(where: { $0.id == entryID })
		else { return }
		entries[index].headline = reflection.headline
		entries[index].summary = reflection.summary
		entries[index].summaryModel = reflection.modelName
		if let reminderResult {
			entries[index].reminders = reminderResult.reminders
			entries[index].reminderModel = reminderResult.modelName
		}
		persist()
		Task { @MainActor [weak self] in
			await self?.refreshReminderSchedule()
		}
		entryProcessingPhases[entryID] = .complete
		try? await Task.sleep(for: .seconds(1.4))
		guard !Task.isCancelled else { return }
		finishProcessing(entryID, token: token)
	}

	private func updatePartialTranscript(_ result: TranscriptionResult, for entryID: UUID, token: UUID) {
		guard entryProcessingTokens[entryID] == token,
			entryProcessingPhases[entryID] == .transcribing,
			let index = entries.firstIndex(where: { $0.id == entryID })
		else { return }
		entries[index].transcript = result.transcript
		entries[index].transcriptModel = result.modelName
	}

	private func finishProcessing(_ entryID: UUID, token: UUID? = nil) {
		if let token, entryProcessingTokens[entryID] != token { return }
		entryProcessingPhases.removeValue(forKey: entryID)
		entryProcessingTasks.removeValue(forKey: entryID)
		entryProcessingTokens.removeValue(forKey: entryID)
	}

	func deleteEntry(id entryID: UUID) {
		guard let entry = entries.first(where: { $0.id == entryID }) else { return }
		entryProcessingTasks.removeValue(forKey: entryID)?.cancel()
		pendingEntryEvaluations.removeAll { $0.entryID == entryID }
		entryProcessingTokens.removeValue(forKey: entryID)
		entryProcessingPhases.removeValue(forKey: entryID)
		entryLocationTasks.removeValue(forKey: entryID)?.cancel()
		if let url = audioURL(for: entry) {
			try? fileManager.removeItem(at: url)
		}
		entries.removeAll { $0.id == entryID }
		persist(deleting: [entry])
		Task { @MainActor [weak self] in
			await self?.refreshReminderSchedule()
		}
	}

	func clearJournal() {
		recordingLocationTask?.cancel()
		recordingLocationTask = nil
		for task in entryProcessingTasks.values { task.cancel() }
		for task in entryLocationTasks.values { task.cancel() }
		entryEvaluationWorker?.cancel()
		entryEvaluationWorker = nil
		entryProcessingTasks.removeAll()
		entryProcessingTokens.removeAll()
		pendingEntryEvaluations.removeAll()
		entryProcessingPhases.removeAll()
		entryLocationTasks.removeAll()
		let deletedEntries = entries
		for entry in deletedEntries where entry.audioFilename != nil {
			if let url = audioURL(for: entry) {
				try? fileManager.removeItem(at: url)
			}
		}
		entries.removeAll()
		persist(deleting: deletedEntries)
		Task { await reminderActivityManager.endAll() }
	}

	func temporaryReminderFeedbackURL() -> URL {
		fileManager.temporaryDirectory
			.appendingPathComponent("reminder-feedback-\(UUID().uuidString)")
			.appendingPathExtension("m4a")
	}

	func applyReminderFeedback(entryID: UUID, audioURL: URL) async throws {
		defer { try? fileManager.removeItem(at: audioURL) }
		guard entries.contains(where: { $0.id == entryID }) else {
			throw ReminderFeedbackError.entryUnavailable
		}
		let transcription = try await AudioTranscriber.transcribe(
			url: audioURL,
			preferElevenLabs: settings.preferElevenLabsTranscription
		)
		transcriptionAlertMessage = transcription.warning
		let feedbackText = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !feedbackText.isEmpty else { throw ReminderFeedbackError.emptyTranscript }

		guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
			throw ReminderFeedbackError.entryUnavailable
		}
		let feedback = ReminderFeedback(kind: .voice, text: feedbackText)
		entries[index].reminderFeedback.append(feedback)
		let source = entries[index]
		let result = await ReminderEngine.parse(
			transcript: source.transcript,
			sourceEvent: source.calendarEvent,
			createdAt: source.createdAt,
			currentReminders: source.reminders,
			feedback: source.reminderFeedback
		)
		guard let updatedIndex = entries.firstIndex(where: { $0.id == entryID }) else {
			throw ReminderFeedbackError.entryUnavailable
		}
		entries[updatedIndex].reminders = result.reminders
		entries[updatedIndex].reminderModel = result.modelName
		persist()
		await refreshReminderSchedule()
	}

	func removeReminder(entryID: UUID, reminderID: UUID) {
		guard let entryIndex = entries.firstIndex(where: { $0.id == entryID }),
			let reminder = entries[entryIndex].reminders.first(where: { $0.id == reminderID })
		else { return }
		entries[entryIndex].reminders.removeAll { $0.id == reminderID }
		entries[entryIndex].reminderFeedback.append(ReminderFeedback(
			kind: .manualRemoval,
			text: "Keep removed: \(reminder.text)",
			focusedReminderID: reminderID
		))
		persist()
		Task { @MainActor [weak self] in
			await self?.refreshReminderSchedule()
		}
	}

	func weeklyReview(for date: Date) async -> WeeklyReview {
		if isDemoMode { return .demo }
		return await ReflectionEngine.weeklyReview(entries: entries(inWeekContaining: date), weekStart: date.startOfWeek())
	}

	func updateSettings(_ settings: JournalSettings) {
		let calendarScopeChanged = self.settings.calendarSyncEnabled != settings.calendarSyncEnabled
			|| self.settings.includedCalendarIdentifiers != settings.includedCalendarIdentifiers
		self.settings = settings
		commitConfiguration()
		Task { await refreshCalendar(force: calendarScopeChanged) }
	}

	func setShowModelNames(_ showModelNames: Bool) {
		settings.showModelNames = showModelNames
		commitConfiguration()
	}

	func clearTranscriptionAlert() {
		transcriptionAlertMessage = nil
	}

	func requestCalendarAccess() async -> Bool {
		await calendarSync.requestAccess()
	}

	func refreshCalendar(force: Bool = false) async {
		guard settings.calendarSyncEnabled else {
			calendarSync.clear()
			await reminderActivityManager.endAll()
			return
		}
		await calendarSync.refresh(
			includedCalendarIdentifiers: settings.includedCalendarIdentifiers,
			force: force
		)
		await refreshReminderSchedule()
	}

	func refreshReminderSchedule(now: Date = .now) async {
		guard settings.calendarSyncEnabled, settings.eventRemindersEnabled else {
			await reminderActivityManager.endAll()
			return
		}
		let result = await ReminderEngine.resolve(entries: entries, events: calendarSync.events, now: now)

		var rulesChanged = false
		for entryIndex in entries.indices {
			for reminderIndex in entries[entryIndex].reminders.indices {
				let reminderID = entries[entryIndex].reminders[reminderIndex].id
				if let resolved = result.resolvedOccurrencesByReminderID[reminderID],
					entries[entryIndex].reminders[reminderIndex].resolvedOccurrence != resolved {
					entries[entryIndex].reminders[reminderIndex].resolvedOccurrence = resolved
					rulesChanged = true
				}
				if let examples = result.examplesByReminderID[reminderID],
					case var .fuzzy(selector) = entries[entryIndex].reminders[reminderIndex].selector,
					selector.examples != examples {
					selector.examples = examples
					entries[entryIndex].reminders[reminderIndex].selector = .fuzzy(selector)
					rulesChanged = true
				}
			}
		}
		if rulesChanged { persist() }
		await reminderActivityManager.synchronize(
			occurrences: result.occurrences,
			settings: settings,
			now: now
		)
	}

	private func prepareStorage() {
		do {
			try fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
			try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: rootURL.path)
			try includeInBackup(rootURL)
			try includeInBackup(recordingsURL)
		} catch {
			assertionFailure("Could not prepare local journal storage: \(error)")
		}
	}

	private func loadEntries() -> [JournalEntry] {
		guard let data = try? Data(contentsOf: entriesURL) else { return [] }
		return (try? JSONDecoder().decode([JournalEntry].self, from: data))?.sorted { $0.createdAt > $1.createdAt } ?? []
	}

	private func loadConfiguration() -> AppConfiguration? {
		guard let data = try? Data(contentsOf: configurationURL) else { return nil }
		return try? JSONDecoder().decode(AppConfiguration.self, from: data)
	}

	private func restoreConfigurationFromICloud() async {
		guard isConfigurationRestorePending else { return }
		let configuration = await iCloudDriveMirror.loadConfiguration()
		guard isConfigurationRestorePending else { return }
		if let configuration {
			settings = configuration.settings
			namedLocations = configuration.locations
		}
		isConfigurationRestorePending = false
		commitConfiguration()
		Task { await refreshCalendar(force: true) }
	}

	private func commitConfiguration() {
		isConfigurationRestorePending = false
		settings.save()
		guard !isDemoMode else { return }
		let configuration = AppConfiguration(settings: settings, locations: namedLocations)
		guard let data = try? configuration.jsonData() else { return }
		do {
			try data.write(to: configurationURL, options: [.atomic])
			try fileManager.setAttributes(
				[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
				ofItemAtPath: configurationURL.path
			)
			try includeInBackup(configurationURL)
			scheduleICloudDriveMirror()
		} catch {
			assertionFailure("Could not save the app configuration: \(error)")
		}
	}

	private func removeExactAlias(_ coordinate: LocationCoordinate, excluding locationID: UUID) {
		for index in namedLocations.indices where namedLocations[index].id != locationID {
			namedLocations[index].aliases.removeAll {
				$0.location.distance(from: coordinate.location) < 5
			}
		}
	}

	private func appendAlias(_ coordinate: LocationCoordinate, at index: Int) {
		guard !namedLocations[index].matchingCoordinates.contains(where: {
			$0.location.distance(from: coordinate.location) < 5
		}) else { return }
		namedLocations[index].aliases.append(coordinate)
	}

	@discardableResult
	private func persist(deleting deletedEntries: [JournalEntry] = []) -> Bool {
		guard !isDemoMode, let data = try? JSONEncoder().encode(entries) else { return false }
		do {
			try data.write(to: entriesURL, options: [.atomic])
			try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: entriesURL.path)
			try includeInBackup(entriesURL)
			for entry in deletedEntries {
				pendingICloudDeletionReferences.insert(entry.id.uuidString)
				if let audioFilename = entry.audioFilename {
					pendingICloudDeletionReferences.insert(audioFilename)
				}
			}
			savePendingICloudDeletions()
			scheduleICloudDriveMirror()
			return true
		} catch {
			assertionFailure("Could not save the local journal: \(error)")
			return false
		}
	}

	private func scheduleICloudDriveMirror() {
		guard !isDemoMode, !isConfigurationRestorePending else { return }
		iCloudRevision += 1
		let revision = iCloudRevision
		let entries = entries
		let recordingsURL = recordingsURL
		let configuration = AppConfiguration(settings: settings, locations: namedLocations)
		let mirror = iCloudDriveMirror
		let deletedRecordingReferences = pendingICloudDeletionReferences
		Task {
			let completedDeletions = await mirror.sync(
				entries: entries,
				recordingsURL: recordingsURL,
				configuration: configuration,
				deletedRecordingReferences: deletedRecordingReferences,
				revision: revision
			)
			pendingICloudDeletionReferences.subtract(completedDeletions)
			savePendingICloudDeletions()
		}
	}

	private func savePendingICloudDeletions() {
		if pendingICloudDeletionReferences.isEmpty {
			UserDefaults.standard.removeObject(forKey: Self.iCloudDeletionKey)
		} else {
			UserDefaults.standard.set(
				pendingICloudDeletionReferences.sorted(),
				forKey: Self.iCloudDeletionKey
			)
		}
	}

	private func recoverUnreferencedRecordings() {
		let referenced = Set(entries.compactMap(\.audioFilename))
		let pending = loadPendingRecording()
		let urls = (try? fileManager.contentsOfDirectory(
			at: recordingsURL,
			includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
			options: [.skipsHiddenFiles]
		)) ?? []
		var recoveredPendingURL: URL?
		var didRecover = false

		for url in urls where !referenced.contains(url.lastPathComponent) {
			let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
			guard (values?.fileSize ?? 0) > 0 else { continue }
			let matchingPending = pending?.filename == url.lastPathComponent ? pending : nil
			let duration = max(matchingPending?.duration ?? 0, audioDuration(at: url))
			let createdAt = matchingPending?.startedAt ?? values?.creationDate ?? .now
			entries.append(JournalEntry(
				createdAt: createdAt,
				duration: duration,
				transcript: "",
				headline: "Processing recording",
				audioFilename: url.lastPathComponent,
				calendarEvent: matchingPending?.calendarEvent
			))
			didRecover = true
			try? includeInBackup(url)
			if matchingPending != nil { recoveredPendingURL = url }
		}

		guard didRecover else { return }
		entries.sort { $0.createdAt > $1.createdAt }
		if persist(), let recoveredPendingURL {
			clearPendingRecording(matching: recoveredPendingURL)
		}
	}

	private func audioDuration(at url: URL) -> TimeInterval {
		guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
		return Double(file.length) / file.processingFormat.sampleRate
	}

	private func loadPendingRecording() -> PendingRecording? {
		guard let data = try? Data(contentsOf: pendingRecordingURL) else { return nil }
		return try? JSONDecoder().decode(PendingRecording.self, from: data)
	}

	private func writePendingRecording(_ pending: PendingRecording) throws {
		let data = try JSONEncoder().encode(pending)
		try data.write(to: pendingRecordingURL, options: [.atomic])
		try fileManager.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: pendingRecordingURL.path
		)
		try includeInBackup(pendingRecordingURL)
	}

	private func clearPendingRecording(matching url: URL) {
		guard loadPendingRecording()?.filename == url.lastPathComponent else { return }
		try? fileManager.removeItem(at: pendingRecordingURL)
	}

	private func includeInBackup(_ url: URL) throws {
		var url = url
		var values = URLResourceValues()
		values.isExcludedFromBackup = false
		try url.setResourceValues(values)
	}

	private static let iCloudDeletionKey = "pending-icloud-drive-deletions"
}

enum ReminderFeedbackError: LocalizedError {
	case entryUnavailable
	case emptyTranscript

	var errorDescription: String? {
		switch self {
		case .entryUnavailable:
			"This note is no longer available."
		case .emptyTranscript:
			"No feedback could be heard. Try recording it again."
		}
	}
}

private struct PendingRecording: Codable {
	var filename: String
	var startedAt: Date
	var duration: TimeInterval
	var calendarEvent: JournalCalendarEvent?
}

private struct PendingEntryEvaluation {
	var entryID: UUID
	var transcript: String
	var token: UUID
}

struct JournalSettings: Codable, Equatable, Sendable {
	var keepScreenAwakeWhileRecording = true
	var hapticsEnabled = true
	var showTranscripts = true
	var showModelNames = true
	var preferElevenLabsTranscription = true
	var calendarSyncEnabled = false
	var includedCalendarIdentifiers: Set<String>?
	var preferredCalendarApp = PreferredCalendarApp.google
	var eventRemindersEnabled = true
	var eventReminderLiveActivitiesEnabled = true
	var eventReminderLeadMinutes = 60

	private static let key = "journal-settings"

	init() {}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		keepScreenAwakeWhileRecording = try container.decodeIfPresent(
			Bool.self,
			forKey: .keepScreenAwakeWhileRecording
		) ?? true
		hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
		showTranscripts = try container.decodeIfPresent(Bool.self, forKey: .showTranscripts) ?? true
		showModelNames = try container.decodeIfPresent(Bool.self, forKey: .showModelNames) ?? true
		preferElevenLabsTranscription = try container.decodeIfPresent(
			Bool.self,
			forKey: .preferElevenLabsTranscription
		) ?? true
		calendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarSyncEnabled) ?? false
		includedCalendarIdentifiers = try container.decodeIfPresent(
			Set<String>.self,
			forKey: .includedCalendarIdentifiers
		)
		preferredCalendarApp = try container.decodeIfPresent(
			PreferredCalendarApp.self,
			forKey: .preferredCalendarApp
		) ?? .google
		eventRemindersEnabled = try container.decodeIfPresent(
			Bool.self,
			forKey: .eventRemindersEnabled
		) ?? true
		eventReminderLiveActivitiesEnabled = try container.decodeIfPresent(
			Bool.self,
			forKey: .eventReminderLiveActivitiesEnabled
		) ?? true
		eventReminderLeadMinutes = try container.decodeIfPresent(
			Int.self,
			forKey: .eventReminderLeadMinutes
		) ?? 60
	}

	static func load() -> JournalSettings {
		guard let data = UserDefaults.standard.data(forKey: key) else { return JournalSettings() }
		return (try? JSONDecoder().decode(JournalSettings.self, from: data)) ?? JournalSettings()
	}

	func save() {
		guard let data = try? JSONEncoder().encode(self) else { return }
		UserDefaults.standard.set(data, forKey: Self.key)
	}
}
