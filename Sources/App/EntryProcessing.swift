import Foundation

enum ProcessingStage: String, Codable, Hashable, Sendable {
	case finalizeAudio, transcribe, reflect, reminders
	var phase: EntryProcessingPhase {
		switch self {
		case .finalizeAudio: .finalizing
		case .transcribe: .transcribing
		case .reflect: .reflecting
		case .reminders: .reminders
		}
	}
}

enum ProcessingFailureKind: String, Codable, Sendable { case unavailable, execution }

struct EntryProcessing: Codable, Hashable, Sendable {
	enum Status: String, Codable, Sendable { case queued, running, partial, failed, canceled, complete }
	var requestID = UUID()
	var requestedAt = Date.now
	var inputRevision: Int
	var stage: ProcessingStage
	var status: Status = .queued
	var attemptID: UUID?
	var completedStages: Set<ProcessingStage> = []
	var skippedStages: Set<ProcessingStage> = []
	var failureKind: ProcessingFailureKind?
	var partialTranscript: TranscriptionProgress?
	var failure: String?
	var retryAfter: Date?

	var phase: EntryProcessingPhase? {
		switch status {
		case .queued: .queued
		case .running: stage.phase
		case .partial: .partial
		case .failed: stage == .finalizeAudio ? .finalizationFailed : .failed
		case .canceled: .canceled
		case .complete: nil
		}
	}
}

struct ProcessingLease: Hashable, Sendable {
	let entryID: UUID
	let requestID: UUID
	let attemptID: UUID
	let inputRevision: Int
	let stage: ProcessingStage
}

struct ProcessingWork: Sendable {
	let lease: ProcessingLease
	let record: JournalRecord
}

enum JournalEdit: Sendable {
	case location(JournalLocation)
	case feedback(ReminderFeedback)
	case removeReminder(UUID, ReminderFeedback)
	case reminderResolution(UUID, JournalCalendarEvent?, [ReminderMatchExample]?)

	func apply(to entry: inout JournalEntry) {
		switch self {
		case let .location(value): entry.location = value
		case let .feedback(value):
			if !entry.reminderFeedback.contains(where: { $0.id == value.id }) { entry.reminderFeedback.append(value) }
		case let .removeReminder(id, feedback):
			entry.reminders.removeAll { $0.id == id }
			if !entry.reminderFeedback.contains(where: { $0.id == feedback.id }) { entry.reminderFeedback.append(feedback) }
		case let .reminderResolution(id, occurrence, examples):
			guard let index = entry.reminders.firstIndex(where: { $0.id == id }) else { return }
			if let occurrence { entry.reminders[index].resolvedOccurrence = occurrence }
			if let examples, case var .fuzzy(selector) = entry.reminders[index].selector {
				selector.examples = examples
				entry.reminders[index].selector = .fuzzy(selector)
			}
		}
	}
}

struct ProcessingServices: Sendable {
	var transcribe: @Sendable (URL, Bool, String?, @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionResult
	var reflect: @Sendable (String, Bool) async -> ReflectionResult
	var reminders: @Sendable (JournalEntry) async -> ReminderParsingResult

	static let live = ProcessingServices(
		transcribe: { url, preferred, key, update in
			try await AudioTranscriber.transcribe(url: url, preferElevenLabs: preferred, elevenLabsAPIKey: key, onUpdate: update)
		},
		reflect: { await ReflectionEngine.reflect(on: $0, includeSummary: $1) },
		reminders: { entry in
			await ReminderEngine.parse(transcript: entry.transcript, sourceEvent: entry.calendarEvent,
				createdAt: entry.createdAt, currentReminders: entry.reminders, feedback: entry.reminderFeedback)
		})
}
