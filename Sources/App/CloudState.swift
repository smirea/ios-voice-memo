import Foundation

struct CloudRetryState: Codable, Equatable, Sendable {
	var attempts: Int
	var retryAfter: Date?
	var message: String

	static func failed(previous: Self?, message: String, now: Date) -> Self {
		let attempts = min(4, max(0, previous?.attempts ?? 0)) + 1
		let delays: [TimeInterval] = [5, 30, 180]
		return Self(attempts: attempts, retryAfter: attempts <= delays.count ? now.addingTimeInterval(delays[attempts - 1]) : nil,
			message: message)
	}

	func isDue(at now: Date) -> Bool { retryAfter.map { $0 <= now } == true }
}

struct CloudAudioReceipt: Codable, Equatable, Sendable {
	var sourceFilename: String
	var sourceSize: Int64
	var sourceModifiedAt: Date
	var sourceFileNumber: UInt64? = nil
	var destinationDirectory: String
	var destinationFilename: String
	var destinationSize: Int64
	var destinationModifiedAt: Date
	var destinationFileNumber: UInt64? = nil
}

struct CloudNoteJob: Sendable {
	var id: UUID
	var contentRevision: Int
	var entry: JournalEntry?
	var deletionReferences: Set<String>
	var audioReceipt: CloudAudioReceipt?
	var metadataReceipt: CloudMetadataReceipt? = nil
}

enum ConfigurationRead: Sendable {
	case available(AppConfiguration)
	case missing
	case unavailable(String)
	case damaged(String)
	case unsupported(Int)
	case conflict
}

struct CloudConfigurationJob: Sendable {
	enum Mode: Sendable { case replace, createIfMissing }
	var value: AppConfiguration
	var data: Data
	var fingerprint: String
	var mode: Mode
}

struct ConfigurationSnapshot: Sendable {
	enum Status: Sendable { case provisional, ready, blocked }
	var value: AppConfiguration
	var revision: Int
	var status: Status
	var export: CloudConfigurationJob?
	var needsRestore: Bool
	var issue: String?
	var nextRetry: Date?
}

enum ConfigurationSchemaError: Error {
	case unsupported(Int)
}

struct CloudNoteReceipt: Sendable {
	var job: CloudNoteJob
	var audioReceipt: CloudAudioReceipt?
	var metadataReceipt: CloudMetadataReceipt? = nil
}

extension ConfigurationRead {
	static func decode(_ data: Data) -> Self {
		do { return .available(try JSONDecoder().decode(AppConfiguration.self, from: data)) }
		catch ConfigurationSchemaError.unsupported(let version) { return .unsupported(version) }
		catch { return .damaged("The configuration could not be read. Its original file was preserved.") }
	}
}

struct CloudMetadataReceipt: Codable, Equatable, Sendable {
	var contentRevision: Int
	var destinationDirectory: String
	var destinationFilename: String
	var size: Int64
	var modifiedAt: Date
	var fileNumber: UInt64? = nil
}
