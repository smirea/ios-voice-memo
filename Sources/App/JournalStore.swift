@preconcurrency import AVFAudio
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class JournalStore {
	private(set) var entries: [JournalEntry]
	private(set) var entryProcessingPhases: [UUID: EntryProcessingPhase] = [:]
	private(set) var namedLocations: [NamedJournalLocation] = []
	private(set) var elevenLabsAPIKey = ""
	private(set) var isLoading = true
	private(set) var storageLoadMessage: String?
	var storageErrorMessage: String?
	private(set) var hasUnsavedNoteChanges = false
	var transcriptionAlertMessage: String?
	var settings = JournalSettings.load()
	let calendarSync: CalendarSync

	let isDemoMode: Bool
	private let fileManager = FileManager.default
	private let rootURL: URL
	private let recordingsURL: URL
	private let configurationURL: URL
	@ObservationIgnored private let iCloudDriveMirror = ICloudDriveMirror()
	@ObservationIgnored private let reminderActivityManager = ReminderActivityManager()
	@ObservationIgnored private var iCloudRevision = 0
	@ObservationIgnored private var pendingICloudDeletionReferences = Set<String>()
	@ObservationIgnored private var entryProcessingTasks: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored private var entryProcessingTimeoutTasks: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored private var entryProcessingStartedAt: [UUID: Date] = [:]
	@ObservationIgnored private var entryBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
	@ObservationIgnored private var entryProcessingTokens: [UUID: UUID] = [:]
	@ObservationIgnored private var pendingEntryEvaluations: [PendingEntryEvaluation] = []
	@ObservationIgnored private var entryEvaluationWorker: Task<Void, Never>?
	@ObservationIgnored private var recordingLocationTask: Task<JournalLocation?, Never>?
	@ObservationIgnored private var entryLocationTasks: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored private var isConfigurationRestorePending = false
	@ObservationIgnored private let repository: JournalRepository
	@ObservationIgnored private var bootstrapTask: Task<Void, Never>?
	@ObservationIgnored private var persistenceTask: Task<Void, Never>?
	@ObservationIgnored private var persistenceRevision = 0
	private let usesExternalServices: Bool

	init(storageRootURL: URL? = nil) {
		isDemoMode = storageRootURL == nil && ProcessInfo.processInfo.arguments.contains("-demo")
		usesExternalServices = storageRootURL == nil
		let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		rootURL = storageRootURL ?? applicationSupport.appendingPathComponent("MyVoiceMemo", isDirectory: true)
		recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
		repository = JournalRepository(rootURL: rootURL)
		configurationURL = rootURL.appendingPathComponent("config.json")
		calendarSync = CalendarSync(
			isDemoMode: isDemoMode,
			cacheURL: rootURL.appendingPathComponent("calendar-events.json")
		)
		pendingICloudDeletionReferences = Set(
			usesExternalServices ? (UserDefaults.standard.stringArray(forKey: Self.iCloudDeletionKey) ?? []) : []
		)

		entries = []
		if isDemoMode {
			entries = JournalEntry.demo
			namedLocations = NamedJournalLocation.demo
			settings.calendarSyncEnabled = true
			isLoading = false
			#if DEBUG
			hasUnsavedNoteChanges = ProcessInfo.processInfo.arguments.contains("-demo-unsaved-notes")
			#endif
		} else {
			bootstrapTask = Task { [weak self] in await self?.loadJournal() }
		}
	}

	func waitUntilLoaded() async throws {
		await bootstrapTask?.value
		guard await repository.isLoaded else { throw RepositoryError.notLoaded }
	}

	private func loadJournal() async {
		defer { isLoading = false }
		do {
			let loaded = try await repository.load()
			entries = loaded.entries
			storageLoadMessage = loaded.issues.isEmpty ? nil : loaded.issues.joined(separator: "\n")
			pendingICloudDeletionReferences.formUnion(loaded.deletionReferences)
			if let configuration = loadConfiguration() {
				settings = configuration.settings
				namedLocations = configuration.locations
				elevenLabsAPIKey = configuration.elevenLabsAPIKey
				settings.save()
			} else if usesExternalServices {
				isConfigurationRestorePending = true
			}
			isLoading = false
			if usesExternalServices {
				resumeInterruptedProcessing()
				if isConfigurationRestorePending { Task { await restoreConfigurationFromICloud() } }
				else { scheduleICloudDriveMirror() }
			}
		} catch {
			storageLoadMessage = "The journal could not be opened. Original files were preserved. " + error.localizedDescription
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

	func canReprocessEntry(id entryID: UUID) -> Bool {
		guard let entry = entry(id: entryID),
			let url = audioURL(for: entry)
		else { return false }
		return fileManager.fileExists(atPath: url.path)
	}

	@discardableResult
	func beginRecordingLocationCapture() -> Task<JournalLocation?, Never> {
		guard usesExternalServices else { return Task { nil } }
		recordingLocationTask?.cancel()
		let task = Task {
			await EntryLocationCapture.capture()
		}
		recordingLocationTask = task
		return task
	}

	func destinationForNewRecording(calendarEvent: JournalCalendarEvent?) async throws -> URL {
		try await waitUntilLoaded()
		try Task.checkCancellation()
		let entry = try await repository.beginRecording(calendarEvent: calendarEvent)
		return recordingsURL.appendingPathComponent(entry.audioFilename!)
	}

	func checkpointRecording(at url: URL, duration: TimeInterval) {
		guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
		Task {
			do { try await repository.checkpoint(id: id, duration: duration) }
			catch { storageErrorMessage = error.localizedDescription }
		}
	}

	func cancelRecordingLocationCapture() {
		recordingLocationTask?.cancel()
		recordingLocationTask = nil
	}

	func cancelRecording(at url: URL) async throws {
		await persistenceTask?.value
		guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
			throw RepositoryError.unavailableRecord
		}
		_ = try await repository.delete(id: id)
		await cleanupDeletedAudio(id: id)
	}

	private func cleanupDeletedAudio(id: UUID) async {
		do { try await repository.cleanupDeletedAudio(id: id) }
		catch {
			storageErrorMessage = "Deletion was saved. Audio cleanup is pending and will retry when the app opens. " + error.localizedDescription
		}
	}

	func waitForPendingWrites() async { await persistenceTask?.value }

	@discardableResult
	func finishRecording(at url: URL, duration: TimeInterval, calendarEvent: JournalCalendarEvent?) async throws -> UUID {
		try await waitUntilLoaded()
		await persistenceTask?.value
		guard let entryID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
			throw RepositoryError.unavailableRecord
		}
		let savedEntry = try await repository.finishRecording(id: entryID, duration: duration)
		entries.removeAll { $0.id == entryID }
		entries.append(savedEntry)
		entries.sort { $0.createdAt > $1.createdAt }
		scheduleICloudDriveMirror()
		if usesExternalServices { startProcessing(entryID: entryID, url: url) }
		if usesExternalServices { attachRecordedLocation(to: entryID) }
		return entryID
	}

	private func startProcessing(
		entryID: UUID,
		url: URL,
		preserveExistingTranscriptOnFailure: Bool = false
	) {
		cancelProcessingAttempt(entryID)
		pendingEntryEvaluations.removeAll { $0.entryID == entryID }
		let processingToken = UUID()
		entryProcessingTokens[entryID] = processingToken
		entryProcessingPhases[entryID] = .transcribing
		entryProcessingStartedAt[entryID] = .now
		beginBackgroundProcessing(entryID: entryID, token: processingToken)
		entryProcessingTimeoutTasks[entryID] = Task { @MainActor [weak self] in
			try? await Task.sleep(for: Self.processingTimeout)
			guard !Task.isCancelled else { return }
			self?.retryProcessingIfCurrent(
				entryID: entryID,
				url: url,
				token: processingToken,
				preserveExistingTranscriptOnFailure: preserveExistingTranscriptOnFailure
			)
		}
		entryProcessingTasks[entryID] = Task { @MainActor [weak self] in
			await self?.processRecording(
				entryID: entryID,
				url: url,
				token: processingToken,
				preserveExistingTranscriptOnFailure: preserveExistingTranscriptOnFailure
			)
		}
	}

	func resumeStaleProcessing(now: Date = .now) {
		let staleEntryIDs = entryProcessingStartedAt.compactMap { entryID, startedAt in
			now.timeIntervalSince(startedAt) >= Self.processingTimeoutSeconds ? entryID : nil
		}
		for entryID in staleEntryIDs {
			guard let token = entryProcessingTokens[entryID],
				let entry = entry(id: entryID),
				let url = audioURL(for: entry),
				fileManager.fileExists(atPath: url.path)
			else {
				finishProcessing(entryID)
				continue
			}
			retryProcessingIfCurrent(
				entryID: entryID,
				url: url,
				token: token,
				preserveExistingTranscriptOnFailure: entry.headline != "Processing recording"
			)
		}
	}

	private func retryProcessingIfCurrent(
		entryID: UUID,
		url: URL,
		token: UUID,
		preserveExistingTranscriptOnFailure: Bool
	) {
		guard entryProcessingTokens[entryID] == token,
			entries.contains(where: { $0.id == entryID }),
			fileManager.fileExists(atPath: url.path)
		else { return }
		startProcessing(
			entryID: entryID,
			url: url,
			preserveExistingTranscriptOnFailure: preserveExistingTranscriptOnFailure
		)
	}

	private func beginBackgroundProcessing(entryID: UUID, token: UUID) {
		let identifier = UIApplication.shared.beginBackgroundTask(withName: "Process voice memo") { [weak self] in
			Task { @MainActor [weak self] in
				guard self?.entryProcessingTokens[entryID] == token else { return }
				self?.endBackgroundProcessing(entryID)
			}
		}
		if identifier != .invalid {
			entryBackgroundTasks[entryID] = identifier
		}
	}

	private func endBackgroundProcessing(_ entryID: UUID) {
		guard let identifier = entryBackgroundTasks.removeValue(forKey: entryID) else { return }
		UIApplication.shared.endBackgroundTask(identifier)
	}

	private func cancelProcessingAttempt(_ entryID: UUID) {
		entryProcessingTasks.removeValue(forKey: entryID)?.cancel()
		entryProcessingTimeoutTasks.removeValue(forKey: entryID)?.cancel()
		entryProcessingStartedAt.removeValue(forKey: entryID)
		endBackgroundProcessing(entryID)
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

	private func processRecording(
		entryID: UUID,
		url: URL,
		token: UUID,
		preserveExistingTranscriptOnFailure: Bool
	) async {
		let transcription: TranscriptionResult?
		var transcriptionError: Error?
		do {
			let result = try await AudioTranscriber.transcribe(
				url: url,
				preferElevenLabs: settings.preferElevenLabsTranscription,
				elevenLabsAPIKey: elevenLabsAPIKey
			) { [weak self] partialResult in
				guard !preserveExistingTranscriptOnFailure else { return }
				Task { @MainActor [weak self] in
					self?.updatePartialTranscript(partialResult, for: entryID, token: token)
				}
			}
			transcription = result
			transcriptionAlertMessage = result.warning
		} catch {
			transcription = nil
			transcriptionError = error
			if settings.preferElevenLabsTranscription,
				!preserveExistingTranscriptOnFailure,
				!Task.isCancelled {
				transcriptionAlertMessage = error.localizedDescription
			}
		}
		let transcript = transcription?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !Task.isCancelled, entryProcessingTokens[entryID] == token else { return }
		guard let transcriptIndex = entries.firstIndex(where: { $0.id == entryID }) else {
			finishProcessing(entryID, token: token)
			return
		}
		if preserveExistingTranscriptOnFailure, transcript.isEmpty {
			let reason = transcriptionError.map { " \($0.localizedDescription)" } ?? ""
			transcriptionAlertMessage =
				"Reprocessing could not transcribe this recording.\(reason) The existing transcript and analysis were kept."
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
		guard let entry = entry(id: entryID),
			let url = audioURL(for: entry),
			fileManager.fileExists(atPath: url.path)
		else { return }
		startProcessing(
			entryID: entryID,
			url: url,
			preserveExistingTranscriptOnFailure: true
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
		cancelProcessingAttempt(entryID)
		entryProcessingTokens.removeValue(forKey: entryID)
	}

	@discardableResult
	func deleteEntry(id entryID: UUID) async -> Bool {
		await deleteEntries(ids: [entryID])
	}

	@discardableResult
	func clearJournal() async -> Bool {
		await deleteEntries(ids: entries.map(\.id))
	}

	private func deleteEntries(ids: [UUID]) async -> Bool {
		await persistenceTask?.value
		var failedCount = 0
		for entryID in ids {
			guard entries.contains(where: { $0.id == entryID }) else { continue }
			do {
				let references = try await repository.delete(id: entryID)
				cancelProcessingAttempt(entryID)
				pendingEntryEvaluations.removeAll { $0.entryID == entryID }
				entryProcessingTokens.removeValue(forKey: entryID)
				entryProcessingPhases.removeValue(forKey: entryID)
				entryLocationTasks.removeValue(forKey: entryID)?.cancel()
				entries.removeAll { $0.id == entryID }
				pendingICloudDeletionReferences.formUnion(references)
				savePendingICloudDeletions()
				scheduleICloudDriveMirror()
				await cleanupDeletedAudio(id: entryID)
			} catch { failedCount += 1 }
		}
		if failedCount > 0 {
			storageErrorMessage = "Couldn’t delete \(failedCount == 1 ? "one note" : "\(failedCount) notes"). Their audio is still on this device. Try deleting them again."
		}
		if hasUnsavedNoteChanges, await repository.committedEntries() == entries {
			hasUnsavedNoteChanges = false
		}
		if usesExternalServices { Task { await refreshReminderSchedule() } }
		return failedCount == 0
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
			preferElevenLabs: settings.preferElevenLabsTranscription,
			elevenLabsAPIKey: elevenLabsAPIKey
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

	func setElevenLabsAPIKey(_ apiKey: String) {
		elevenLabsAPIKey = apiKey
		commitConfiguration()
	}

	func clearTranscriptionAlert() {
		transcriptionAlertMessage = nil
	}

	func requestCalendarAccess() async -> Bool {
		await calendarSync.requestAccess()
	}

	func refreshCalendar(force: Bool = false) async {
		await bootstrapTask?.value
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
			elevenLabsAPIKey = configuration.elevenLabsAPIKey
		}
		isConfigurationRestorePending = false
		commitConfiguration()
		Task { await refreshCalendar(force: true) }
	}

	private func commitConfiguration() {
		isConfigurationRestorePending = false
		settings.save()
		guard !isDemoMode else { return }
		let configuration = AppConfiguration(
			settings: settings,
			locations: namedLocations,
			elevenLabsAPIKey: elevenLabsAPIKey
		)
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

	func retrySavingChanges() async {
		persist()
		await persistenceTask?.value
	}

	func committedEntriesForExport() async -> [JournalEntry] {
		if isDemoMode { return entries }
		await persistenceTask?.value
		return await repository.committedEntries()
	}

	private func persist() {
		guard !isDemoMode else { return }
		persistenceRevision += 1
		let revision = persistenceRevision
		let snapshot = entries
		let previous = persistenceTask
		persistenceTask = Task {
			await previous?.value
			do {
				try await repository.save(snapshot)
				if persistenceRevision == revision { hasUnsavedNoteChanges = false }
				scheduleICloudDriveMirror()
			} catch {
				hasUnsavedNoteChanges = true
				storageErrorMessage = "Note changes haven’t been saved. Try saving again. " + error.localizedDescription
			}
		}
	}

	private func scheduleICloudDriveMirror() {
		guard !isDemoMode, usesExternalServices, !isLoading, !isConfigurationRestorePending else { return }
		iCloudRevision += 1
		let revision = iCloudRevision
		let recordingsURL = recordingsURL
		let configuration = AppConfiguration(
			settings: settings,
			locations: namedLocations,
			elevenLabsAPIKey: elevenLabsAPIKey
		)
		let mirror = iCloudDriveMirror
		let deletedRecordingReferences = pendingICloudDeletionReferences
		Task {
			let entries = await repository.committedEntries()
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
		guard usesExternalServices else { return }
		if pendingICloudDeletionReferences.isEmpty {
			UserDefaults.standard.removeObject(forKey: Self.iCloudDeletionKey)
		} else {
			UserDefaults.standard.set(
				pendingICloudDeletionReferences.sorted(),
				forKey: Self.iCloudDeletionKey
			)
		}
	}


	private func includeInBackup(_ url: URL) throws {
		var url = url
		var values = URLResourceValues()
		values.isExcludedFromBackup = false
		try url.setResourceValues(values)
	}

	private static let processingTimeoutSeconds: TimeInterval = 15 * 60
	private static let processingTimeout = Duration.seconds(processingTimeoutSeconds)
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
