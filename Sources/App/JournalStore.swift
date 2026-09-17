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
	private(set) var reminderSchedulingMessage: String?
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
	private(set) var processingStates: [UUID: EntryProcessing] = [:]
	@ObservationIgnored private var processingWorker: Task<Void, Never>?
	@ObservationIgnored private var activeStage: Task<Void, Never>?
	@ObservationIgnored private var activeLease: ProcessingLease?
	@ObservationIgnored private var processingWatchdog: Task<Void, Never>?
	@ObservationIgnored private var retryWakeTask: Task<Void, Never>?
	@ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
	@ObservationIgnored private var backgroundRegistration: UUID?
	@ObservationIgnored private var storageSuspended = false
	@ObservationIgnored private var backgroundSuspended = false
	@ObservationIgnored private var capturePriorityOwners = Set<UUID>()
	@ObservationIgnored private var admissionPolicyRevision: UInt64 = 0
	private static var nextAdmissionPolicyRevision: UInt64 = 0
	@ObservationIgnored private var admittedAt: ContinuousClock.Instant?
	@ObservationIgnored private var remainingStageTime: TimeInterval = 0
	var isCapturePriorityActive: Bool { !capturePriorityOwners.isEmpty }
	private var processingSuspended: Bool { storageSuspended || backgroundSuspended || isCapturePriorityActive }
	@ObservationIgnored private var lastPartialCheckpoint = Date.distantPast
	@ObservationIgnored private var deletedEntryIDs = Set<UUID>()
	@ObservationIgnored private var committedRecords: [UUID: JournalRecord] = [:]
	@ObservationIgnored private var pendingEdits: [PendingJournalEdit] = []
	private let processingServices: ProcessingServices
	private let processingEnabled: Bool
	#if DEBUG
	var processingIdleCheckpoint: (() async -> Void)?
	var processingDeadlineOverride: TimeInterval?
	#endif
	@ObservationIgnored private var recordingLocationTask: Task<JournalLocation?, Never>?
	@ObservationIgnored private var entryLocationTasks: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored private var isConfigurationRestorePending = false
	@ObservationIgnored private let repository: JournalRepository
	@ObservationIgnored private let audioFinalizer = AudioFinalizer()
	@ObservationIgnored private var bootstrapTask: Task<Void, Never>?
	@ObservationIgnored private var persistenceTask: Task<Void, Never>?
	private let usesExternalServices: Bool

	init(storageRootURL: URL? = nil, processingServices: ProcessingServices? = nil) {
		self.processingServices = processingServices ?? .live
		processingEnabled = storageRootURL == nil || processingServices != nil
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
			if ProcessInfo.processInfo.arguments.contains("-demo-reminder-matching-unavailable") {
				reminderSchedulingMessage = "Some reminders could not be matched because on-device analysis is unavailable."
			}
			if ProcessInfo.processInfo.arguments.contains("-demo-finalization-failed") {
				for entry in entries { entryProcessingPhases[entry.id] = .finalizationFailed }
			}
			if ProcessInfo.processInfo.arguments.contains("-demo-processing-partial") || ProcessInfo.processInfo.arguments.contains("-demo-processing-failed") {
				for entry in entries {
					var job = EntryProcessing(inputRevision: 0, stage: .transcribe)
					let partial = ProcessInfo.processInfo.arguments.contains("-demo-processing-partial")
					job.status = partial ? .partial : .failed
					job.failure = "The last attempt could not finish. Your audio and previous completed results are preserved."
					if partial {
						job.partialTranscript = TranscriptionProgress(transcript: "I wanted to remember the decision we made this morning, and the next thing to follow up on was", modelName: "Apple Speech · incomplete")
						if let index = entries.firstIndex(where: { $0.id == entry.id }) {
							entries[index].transcript = ""
							entries[index].summary = nil
							entries[index].summaryModel = nil
							entries[index].headline = "Recording saved"
							entries[index].reminders = []
						}
					}
					processingStates[entry.id] = job
					entryProcessingPhases[entry.id] = job.phase
				}
			}
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
			for record in loaded.records { publish(record) }
			let issues = loaded.issues
			storageLoadMessage = issues.isEmpty ? nil : issues.joined(separator: "\n")
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
			kickProcessing()
			if usesExternalServices {
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
	func finishRecording(at url: URL, calendarEvent: JournalCalendarEvent?) async throws -> UUID {
		try await waitUntilLoaded()
		await persistenceTask?.value
		guard let entryID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
			throw RepositoryError.unavailableRecord
		}
		_ = try await repository.finishRecording(id: entryID)
		if let record = await repository.record(id: entryID) { publish(record) }
		scheduleICloudDriveMirror()
		kickProcessing()
		if usesExternalServices { attachRecordedLocation(to: entryID) }
		return entryID
	}

	func resumeStaleProcessing(now: Date = .now) {
		backgroundSuspended = false
		updateServiceAdmission()
	}

	func beginCapturePriority(owner: UUID) async {
		capturePriorityOwners.insert(owner)
		preemptProcessing()
		let revision = newAdmissionRevision()
		await synchronizeServiceAdmission(revision: revision)
	}

	func endCapturePriority(owner: UUID) async {
		guard capturePriorityOwners.remove(owner) != nil else { return }
		let revision = newAdmissionRevision()
		await synchronizeServiceAdmission(revision: revision)
	}

	private func newAdmissionRevision() -> UInt64 {
		Self.nextAdmissionPolicyRevision += 1
		admissionPolicyRevision = Self.nextAdmissionPolicyRevision
		return admissionPolicyRevision
	}

	private func updateServiceAdmission() {
		let revision = newAdmissionRevision()
		Task { await synchronizeServiceAdmission(revision: revision) }
	}

	private func synchronizeServiceAdmission(revision: UInt64) async {
		guard revision == admissionPolicyRevision else { return }
		let suspended = backgroundSuspended || isCapturePriorityActive
		await ServiceAdmission.model.setSuspended(suspended, revision: revision)
		await ServiceAdmission.speech.setSuspended(suspended, revision: revision)
		guard revision == admissionPolicyRevision else { return }
		if !processingSuspended { kickProcessing() }
	}

	private func preemptProcessing() {
		retryWakeTask?.cancel()
		retryWakeTask = nil
		processingWatchdog?.cancel()
		admittedAt = nil
		activeStage?.cancel()
		endBackgroundProcessing()
		guard let lease = activeLease else { return }
		Task {
			do { publish(try await repository.pauseProcessing(lease)) }
			catch RepositoryError.staleProcessing {}
			catch { reportProcessingStorageError(error, entryID: lease.entryID) }
		}
	}

	private func kickProcessing() {
		guard processingEnabled, !isDemoMode, !isLoading, !processingSuspended, processingWorker == nil else { return }
		retryWakeTask?.cancel()
		processingWorker = Task { [weak self] in await self?.drainProcessing() }
	}

	private func drainProcessing() async {
		defer {
			processingWorker = nil
			activeStage = nil
			activeLease = nil
			endBackgroundProcessing()
			Task { await scheduleProcessingRetry() }
		}
		let temporaryIssues = await ProcessingTemporaryFiles.shared.cleanOnce()
		if !temporaryIssues.isEmpty {
			storageLoadMessage = ([storageLoadMessage].compactMap { $0 } + temporaryIssues).joined(separator: "\n")
		}
		while !Task.isCancelled, !processingSuspended {
			let work: ProcessingWork
			do {
				guard let next = try await repository.claimProcessing() else {
					#if DEBUG
					await processingIdleCheckpoint?()
					#endif
					break
				}
				if Task.isCancelled || processingSuspended {
					if let record = try? await repository.pauseProcessing(next.lease) { publish(record) }
					break
				}
				work = next
			} catch {
				storageSuspended = true
				storageErrorMessage = "Processing could not save its progress. Your audio is preserved. " + error.localizedDescription
				break
			}
			publish(work.record)
			activeLease = work.lease
			lastPartialCheckpoint = .distantPast
			beginBackgroundProcessing()
			remainingStageTime = work.record.entry.map { ProcessingDeadline.seconds(stage: work.lease.stage, entry: $0) } ?? 300
			#if DEBUG
			if let processingDeadlineOverride { remainingStageTime = processingDeadlineOverride }
			#endif
			let task = Task { [weak self] in
				_ = await ServiceAdmission.$activity.withValue({ [weak self] active in
					await self?.serviceActivityChanged(active, lease: work.lease)
				}) {
					await self?.process(work)
				}
			}
			activeStage = task
			if work.lease.stage == .finalizeAudio { serviceActivityChanged(true, lease: work.lease) }
			await task.value
			processingWatchdog?.cancel()
			processingWatchdog = nil
			admittedAt = nil
			activeStage = nil
			activeLease = nil
			endBackgroundProcessing()
		}
	}

	private func serviceActivityChanged(_ active: Bool, lease: ProcessingLease) {
		guard activeLease == lease, !processingSuspended, activeStage?.isCancelled == false else { return }
		if let admittedAt {
			let elapsed = admittedAt.duration(to: .now).components
			remainingStageTime -= Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
		}
		admittedAt = active ? .now : nil
		processingWatchdog?.cancel()
		processingWatchdog = nil
		guard active, let task = activeStage else { return }
		let remaining = max(0, remainingStageTime)
		processingWatchdog = Task { [weak self] in
			do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
			guard let self, self.activeLease == lease, !self.processingSuspended else { return }
			do {
				self.publish(try await self.repository.failProcessing(lease,
					message: "Processing took too long. Your saved results are preserved."))
			} catch is CancellationError { return
			} catch RepositoryError.staleProcessing {
			} catch { self.reportProcessingStorageError(error, entryID: lease.entryID) }
			task.cancel()
		}
	}

	private func process(_ work: ProcessingWork) async {
		let lease = work.lease
		guard let entry = work.record.entry else { return }
		do {
			try Task.checkCancellation()
			let record: JournalRecord
			switch lease.stage {
			case .finalizeAudio:
				let request = try await repository.prepareAudioFinalization(id: entry.id)
				defer { try? fileManager.removeItem(at: request.stagingURL) }
				let prepared = try await audioFinalizer.prepare(request)
				_ = try await repository.commitFinalizedAudio(prepared, lease: lease)
				guard let saved = await repository.record(id: entry.id) else { return }
				record = saved
			case .transcribe:
				guard let url = audioURL(for: entry) else { throw RepositoryError.invalidAudio }
				let result = try await processingServices.transcribe(url, settings.preferElevenLabsTranscription, elevenLabsAPIKey) { [weak self] progress in
					Task { @MainActor [weak self] in await self?.receivePartial(progress, lease: lease) }
				}
				try Task.checkCancellation()
				record = try await repository.commitTranscription(result, lease: lease)
				transcriptionAlertMessage = result.warning
			case .reflect:
				let result: ReflectionResult
				if entry.transcript.isEmpty {
					result = ReflectionResult(headline: "No speech detected", summary: nil, modelName: "Completed transcription", outcome: .skipped)
				} else { result = await processingServices.reflect(entry.transcript, entry.duration > 20) }
				try Task.checkCancellation()
				guard result.outcome.isComplete else {
					try await failModelStage(result.outcome, lease: lease, fallback: result)
					return
				}
				record = try await repository.commitReflection(result, lease: lease)
			case .reminders:
				let result = settings.eventRemindersEnabled ? await processingServices.reminders(entry) : nil
				try Task.checkCancellation()
				if let result, !result.outcome.isComplete {
					try await failModelStage(result.outcome, lease: lease)
					return
				}
				record = try await repository.commitReminders(result, lease: lease)
			}
			publish(record)
			scheduleICloudDriveMirror()
			if record.processing?.status == .complete, usesExternalServices { Task { await refreshReminderSchedule() } }
		} catch is CancellationError {
			if let record = try? await repository.pauseProcessing(lease, canceled: !Task.isCancelled) { publish(record) }
		} catch RepositoryError.staleProcessing {
		} catch {
			do {
				let failure = error as? TranscriptionFailure
				let record = try await repository.failProcessing(lease, message: error.localizedDescription,
					partial: failure?.partial,
					kind: failure?.category == .unavailable ? .unavailable : (failure?.category == .unreadableAudio ? .unreadableAudio : .execution))
				publish(record)
			} catch RepositoryError.staleProcessing {
			} catch { reportProcessingStorageError(error, entryID: lease.entryID) }
		}
	}

	private func failModelStage(_ outcome: ModelProcessingOutcome, lease: ProcessingLease, fallback: ReflectionResult? = nil) async throws {
		let message: String
		switch outcome {
		case .cancelled: throw CancellationError()
		case .unavailable:
			message = "On-device analysis is unavailable. Your recording and completed text are preserved."
		case let .failed(reason):
			message = reason
		case .complete, .skipped: return
		}
		publish(try await repository.failProcessing(lease, message: message, fallback: fallback, kind: outcome == .unavailable ? .unavailable : .execution))
	}

	private func receivePartial(_ progress: TranscriptionProgress, lease: ProcessingLease) async {
		guard activeLease == lease, let state = processingStates[lease.entryID],
			state.attemptID == lease.attemptID, state.status == .running else { return }
		processingStates[lease.entryID]?.partialTranscript = progress
		guard Date.now.timeIntervalSince(lastPartialCheckpoint) >= 1 else { return }
		lastPartialCheckpoint = .now
		do { publish(try await repository.savePartial(progress, lease: lease)) }
		catch RepositoryError.staleProcessing {}
		catch { storageErrorMessage = "Partial transcript progress could not be saved. " + error.localizedDescription }
	}

	private func reportProcessingStorageError(_ error: Error, entryID: UUID) {
		storageSuspended = true
		entryProcessingPhases[entryID] = .failed
		storageErrorMessage = "Processing progress could not be saved. Your audio and previous results are preserved. Retry after storage is available. " + error.localizedDescription
	}

	private func scheduleProcessingRetry() async {
		guard processingEnabled, !processingSuspended, processingWorker == nil,
			let next = await repository.nextProcessingRetry(), processingWorker == nil, !processingSuspended else { return }
		retryWakeTask?.cancel()
		retryWakeTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
			guard !Task.isCancelled else { return }
			self?.kickProcessing()
		}
	}

	private func beginBackgroundProcessing() {
		guard usesExternalServices, let lease = activeLease else { return }
		let registration = UUID()
		backgroundRegistration = registration
		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Process voice memo") { [weak self] in
			Task { @MainActor [weak self] in
				guard let self, self.activeLease == lease else { return }
				self.expireBackgroundProcessing(lease: lease, registration: registration)
			}
		}
	}

	func expireBackgroundProcessing(lease: ProcessingLease, registration: UUID? = nil) {
		guard activeLease == lease, backgroundRegistration == registration else { return }
		backgroundSuspended = true
		preemptProcessing()
		updateServiceAdmission()
	}

	private func endBackgroundProcessing() {
		backgroundRegistration = nil
		guard backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}

	func reprocessEntry(id entryID: UUID) {
		Task {
			do {
				let record = try await repository.requestProcessing(id: entryID)
				publish(record)
				cancelObsoleteStage()
				storageSuspended = false
				kickProcessing()
			} catch { reportProcessingStorageError(error, entryID: entryID) }
		}
	}

	func retryProcessingEntry(id entryID: UUID) {
		Task {
			do {
				publish(try await repository.retryProcessing(id: entryID))
				cancelObsoleteStage()
				storageSuspended = false
				kickProcessing()
			} catch { reportProcessingStorageError(error, entryID: entryID) }
		}
	}

	func partialTranscript(for entryID: UUID) -> TranscriptionProgress? { processingStates[entryID]?.partialTranscript }
	func processingFailure(for entryID: UUID) -> String? {
		guard let job = processingStates[entryID], let failure = job.failure else { return nil }
		if let retry = job.retryAfter {
			return failure + " Automatic retry at " + retry.formatted(date: .omitted, time: .shortened) + "."
		}
		return failure
	}

	func publish(_ record: JournalRecord) {
		if record.state == .deleted { deletedEntryIDs.insert(record.id); entries.removeAll { $0.id == record.id } }
		if record.state != .deleted, deletedEntryIDs.contains(record.id) { return }
		guard record.revision >= (committedRecords[record.id]?.revision ?? -1) else { return }
		committedRecords[record.id] = record
		processingStates[record.id] = record.processing
		entryProcessingPhases[record.id] = record.processing?.phase
		guard record.state == .saved, var entry = record.entry else { return }
		for pending in pendingEdits where pending.entryID == record.id { pending.edit.apply(to: &entry) }
		if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
		else { entries.append(entry); entries.sort { $0.createdAt > $1.createdAt } }
	}

	private func cancelObsoleteStage() {
		guard let lease = activeLease, let current = committedRecords[lease.entryID] else { return }
		if current.processing?.requestID != lease.requestID || current.processing?.attemptID != lease.attemptID
			|| current.inputRevision != lease.inputRevision { activeStage?.cancel() }
	}

	private func attachRecordedLocation(to entryID: UUID) {
		let locationTask = recordingLocationTask ?? Task { await EntryLocationCapture.capture() }
		recordingLocationTask = nil
		entryLocationTasks[entryID]?.cancel()
		entryLocationTasks[entryID] = Task { [weak self] in
			let location = await locationTask.value
			guard !Task.isCancelled, let self else { return }
			defer { self.entryLocationTasks.removeValue(forKey: entryID) }
			guard let location, self.entries.contains(where: { $0.id == entryID }) else { return }
			self.persist(.location(location), entryID: entryID)
		}
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
				if activeLease?.entryID == entryID { activeStage?.cancel() }
				pendingEdits.removeAll { $0.entryID == entryID }
				deletedEntryIDs.insert(entryID)
				processingStates.removeValue(forKey: entryID)
				if pendingEdits.isEmpty { hasUnsavedNoteChanges = false }
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
		guard entries.contains(where: { $0.id == entryID }) else { throw ReminderFeedbackError.entryUnavailable }
		let transcription = try await processingServices.transcribe(audioURL, settings.preferElevenLabsTranscription, elevenLabsAPIKey, { _ in })
		try Task.checkCancellation()
		transcriptionAlertMessage = transcription.warning
		let text = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { throw ReminderFeedbackError.emptyTranscript }
		guard entries.contains(where: { $0.id == entryID }) else { throw ReminderFeedbackError.entryUnavailable }
		persist(.feedback(ReminderFeedback(kind: .voice, text: text)), entryID: entryID)
		await persistenceTask?.value
		guard !hasUnsavedNoteChanges else { throw RepositoryError.unsavedChanges }
		kickProcessing()
	}

	func removeReminder(entryID: UUID, reminderID: UUID) {
		guard let entry = entry(id: entryID), let reminder = entry.reminders.first(where: { $0.id == reminderID }) else { return }
		persist(.removeReminder(reminderID, ReminderFeedback(kind: .manualRemoval,
			text: "Keep removed: \(reminder.text)", focusedReminderID: reminderID)), entryID: entryID)
		if usesExternalServices { Task { await refreshReminderSchedule() } }
	}

	func weeklyReview(for date: Date) async -> WeeklyReview {
		if isDemoMode {
			var review = WeeklyReview.demo
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-demo-review-unavailable") { review.outcome = .unavailable }
			#endif
			return review
		}
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
		#if DEBUG
		if isDemoMode, ProcessInfo.processInfo.arguments.contains("-demo-reminder-matching-unavailable") { return }
		#endif
		guard settings.calendarSyncEnabled, settings.eventRemindersEnabled else {
			await reminderActivityManager.endAll()
			return
		}
		let result = await ReminderEngine.resolve(entries: entries, events: calendarSync.events, now: now)
		guard !Task.isCancelled, result.outcome != .cancelled else { return }
		switch result.outcome {
		case .unavailable: reminderSchedulingMessage = "Some reminders could not be matched because on-device analysis is unavailable."
		case let .failed(message): reminderSchedulingMessage = message
		default: reminderSchedulingMessage = nil
		}

		for entry in entries {
			for reminder in entry.reminders {
				let occurrence = result.resolvedOccurrencesByReminderID[reminder.id]
				let examples = result.examplesByReminderID[reminder.id]
				var changed = occurrence != nil && occurrence != reminder.resolvedOccurrence
				if let examples, case let .fuzzy(selector) = reminder.selector { changed = changed || examples != selector.examples }
				if changed { persist(.reminderResolution(reminder.id, occurrence, examples), entryID: entry.id) }
			}
		}
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
		queuePendingWrites()
		await persistenceTask?.value
	}

	func committedEntriesForExport() async -> [JournalEntry] {
		if isDemoMode { return entries }
		await persistenceTask?.value
		return await repository.committedEntries()
	}

	func persist(_ edit: JournalEdit, entryID: UUID) {
		guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
		edit.apply(to: &entries[index])
		guard !isDemoMode else { return }
		pendingEdits.append(PendingJournalEdit(entryID: entryID, edit: edit))
		queuePendingWrites()
	}

	private func queuePendingWrites() {
		let previous = persistenceTask
		persistenceTask = Task {
			await previous?.value
			while let pending = pendingEdits.first {
				do {
					let record = try await repository.apply(pending.edit, to: pending.entryID)
					pendingEdits.removeAll { $0.id == pending.id }
					publish(record)
					cancelObsoleteStage()
					scheduleICloudDriveMirror()
				} catch RepositoryError.unavailableRecord {
					pendingEdits.removeAll { $0.id == pending.id }
				} catch {
					hasUnsavedNoteChanges = true
					storageErrorMessage = "Note changes haven’t been saved. Try saving again. " + error.localizedDescription
					return
				}
			}
			hasUnsavedNoteChanges = false
			kickProcessing()
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

private struct PendingJournalEdit {
	let id = UUID()
	let entryID: UUID
	let edit: JournalEdit
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
