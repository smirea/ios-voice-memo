import Foundation

struct CloudServices: Sendable {
	var sync: @Sendable ([CloudNoteJob], URL, CloudConfigurationJob?, Set<String>, Int) async -> ICloudMirrorResult
	var loadConfiguration: @Sendable () async -> ConfigurationRead

	static var live: Self {
		let mirror = ICloudDriveMirror()
		return Self(sync: { jobs, recordingsURL, configuration, references, revision in
			await mirror.sync(jobs: jobs, recordingsURL: recordingsURL, configuration: configuration,
				deletedRecordingReferences: references, revision: revision)
		}, loadConfiguration: { await mirror.loadConfiguration() })
	}
}
