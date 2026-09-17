import Foundation

enum CloudProviderState: Sendable {
	case current, notDownloaded, stale, downloading, conflict
}

struct CloudProvider: Sendable {
	var discover: @Sendable (URL) async throws -> Bool
	var state: @Sendable (URL) throws -> CloudProviderState
	var requestDownload: @Sendable (URL) throws -> Void

	static let local = CloudProvider(discover: { FileManager.default.fileExists(atPath: $0.path) },
		state: { _ in .current }, requestDownload: { _ in })
	static let live = CloudProvider(
		discover: { try await CloudMetadataDiscovery().gather(configurationURL: $0) },
		state: { url in
			let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
				.ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemHasUnresolvedConflictsKey])
			if values.ubiquitousItemHasUnresolvedConflicts == true
				|| !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty { return .conflict }
			guard values.isUbiquitousItem == true else { return .current }
			if values.ubiquitousItemDownloadingError != nil { throw CloudProviderError.downloadFailed }
			if values.ubiquitousItemDownloadingStatus == .current { return .current }
			if values.ubiquitousItemIsDownloading == true { return .downloading }
			if values.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
			if values.ubiquitousItemDownloadingStatus == .downloaded { return .stale }
			throw CloudProviderError.discoveryPending
		},
		requestDownload: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }
	)

	static func referencesSameItem(_ candidate: URL, as expected: URL) -> Bool {
		// Resolving the full path can leave directory aliases intact when the final file is evicted.
		func resolved(_ url: URL) -> URL {
			url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
				.appendingPathComponent(url.lastPathComponent)
		}
		return resolved(candidate) == resolved(expected)
	}
}

enum CloudProviderError: Error { case discoveryPending, downloadFailed }

@MainActor
private final class CloudMetadataDiscovery {
	private let query = NSMetadataQuery()
	private var observer: NSObjectProtocol?
	private var timeout: Task<Void, Never>?
	private var continuation: CheckedContinuation<Bool, Error>?

	func gather(configurationURL: URL) async throws -> Bool {
		try Task.checkCancellation()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				self.continuation = continuation
				query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
				query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "config.json")
				observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
					object: query, queue: .main) { [weak self] _ in
					Task { @MainActor in
						guard let self else { return }
						let present = (0..<self.query.resultCount).contains {
							guard let url = self.query.value(ofAttribute: NSMetadataItemURLKey, forResultAt: $0) as? URL else { return false }
							return CloudProvider.referencesSameItem(url, as: configurationURL)
						}
						self.finish(.success(present))
					}
				}
				timeout = Task { [weak self] in
					do { try await Task.sleep(for: .seconds(10)) } catch { return }
					self?.finish(.failure(CloudProviderError.discoveryPending))
				}
				if !query.start() { finish(.failure(CloudProviderError.discoveryPending)) }
			}
		} onCancel: {
			Task { @MainActor in self.finish(.failure(CancellationError())) }
		}
	}

	private func finish(_ result: Result<Bool, Error>) {
		guard let continuation else { return }
		self.continuation = nil
		query.stop()
		if let observer { NotificationCenter.default.removeObserver(observer) }
		observer = nil
		timeout?.cancel()
		timeout = nil
		continuation.resume(with: result)
	}
}
