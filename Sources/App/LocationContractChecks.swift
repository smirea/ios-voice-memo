#if DEBUG
import Foundation

enum LocationContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-location-contract-tests") else { return }
		do {
			try await run()
			print("LOCATION CONTRACT: 13 checks passed")
		} catch {
			fatalError("LOCATION CONTRACT: \(error)")
		}
	}

	private static func run() async throws {
		let origin = LocationCoordinate(latitude: 41.8781, longitude: -87.6298)
		let close = LocationCoordinate(latitude: 41.8790, longitude: -87.6298)
		let edge = LocationCoordinate(latitude: 41.87988, longitude: -87.6298)
		let outside = LocationCoordinate(latitude: 41.8801, longitude: -87.6298)
		let homeID = UUID()
		let gymID = UUID()
		let home = NamedJournalLocation(
			id: homeID,
			name: "Home",
			address: "1 Main St",
			pin: origin
		)
		let remotePinWithAlias = NamedJournalLocation(
			id: gymID,
			name: "Gym",
			address: "2 Main St",
			pin: LocationCoordinate(latitude: 41.9, longitude: -87.7),
			aliases: [close]
		)

		try expect(NamedLocationResolver.resolve(close, in: [home])?.id == homeID, "A coordinate inside 200 m must match")
		try expect(NamedLocationResolver.resolve(edge, in: [home])?.id == homeID, "The 200 m boundary must match")
		try expect(NamedLocationResolver.resolve(outside, in: [home]) == nil, "A coordinate beyond 200 m must not match")
		try expect(
			NamedLocationResolver.resolve(close, in: [remotePinWithAlias])?.id == gymID,
			"Aliases must match independently of the canonical pin"
		)

		let nearer = NamedJournalLocation(
			name: "Nearer",
			pin: LocationCoordinate(latitude: 41.8783, longitude: -87.6298)
		)
		try expect(
			NamedLocationResolver.resolve(origin, in: [home, nearer])?.id == homeID,
			"The nearest overlapping place must win"
		)

		let sameA = NamedJournalLocation(id: UUID(), name: "Alpha", pin: origin)
		let sameZ = NamedJournalLocation(id: UUID(), name: "Zulu", pin: origin)
		try expect(
			NamedLocationResolver.resolve(origin, in: [sameZ, sameA])?.id == sameA.id,
			"Equal-distance matches must be deterministic"
		)
		let explicitlyAssigned = NamedJournalLocation(
			name: "Zulu",
			pin: outside,
			aliases: [origin]
		)
		try expect(
			NamedLocationResolver.resolve(origin, in: [sameA, explicitlyAssigned])?.id == explicitlyAssigned.id,
			"An exact assigned alias must beat an overlapping canonical pin"
		)

		let entryA = JournalEntry(
			duration: 1,
			transcript: "",
			headline: "",
			location: JournalLocation(latitude: origin.latitude, longitude: origin.longitude, city: nil)
		)
		let entryB = JournalEntry(
			duration: 1,
			transcript: "",
			headline: "",
			location: JournalLocation(latitude: close.latitude, longitude: close.longitude, city: nil)
		)
		let counts = NamedLocationResolver.usageCounts(
			entries: [entryA, entryB],
			locations: [home, remotePinWithAlias]
		)
		try expect(counts[homeID] == 1 && counts[gymID] == 1, "Each note must count toward exactly one resolved place")

		let alpha = NamedJournalLocation(
			name: "Alpha",
			pin: LocationCoordinate(latitude: 41.87, longitude: -87.63)
		)
		let zulu = NamedJournalLocation(
			name: "Zulu",
			pin: LocationCoordinate(latitude: 41.88, longitude: -87.63)
		)
		let far = NamedJournalLocation(
			name: "Far",
			pin: LocationCoordinate(latitude: 42.1, longitude: -87.63)
		)
		let nearby = NamedLocationResolver.nearby(
			to: origin,
			locations: [zulu, far, alpha],
			entries: []
		)
		try expect(nearby.map(\.location.name) == ["Alpha", "Zulu"], "Nearby places must be name-sorted and limited to 10 miles")
		try expect(
			NamedLocationResolver.nearby(
				to: origin,
				locations: [home, alpha],
				entries: [],
				excluding: homeID
			).map(\.id) == [alpha.id],
			"The edited place must be excluded from alternatives"
		)

		var settings = JournalSettings()
		settings.showModelNames = false
		let configuration = AppConfiguration(settings: settings, locations: [remotePinWithAlias])
		let decoded = try JSONDecoder().decode(AppConfiguration.self, from: configuration.jsonData())
		try expect(decoded == configuration, "Config JSON must round-trip settings, addresses, pins, and aliases")

		let legacy = try JSONDecoder().decode(
			AppConfiguration.self,
			from: Data(#"{"settings":{}}"#.utf8)
		)
		try expect(legacy.locations.isEmpty, "Older config JSON must default missing location data")

		let temporaryRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("location-contract-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: temporaryRoot) }
		let recordings = temporaryRoot.appendingPathComponent("Recordings", isDirectory: true)
		try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
		let mirror = ICloudDriveMirror(containerURL: temporaryRoot)
		_ = await mirror.sync(
			entries: [],
			recordingsURL: recordings,
			configuration: configuration,
			deletedRecordingReferences: [],
			revision: 1
		)
		let restoredConfiguration = await mirror.loadConfiguration()
		try expect(restoredConfiguration == configuration, "The iCloud mirror must restore config.json without any notes")
	}

	private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
		guard condition() else { throw Failure(message: message) }
	}

	private struct Failure: Error, CustomStringConvertible {
		var message: String
		var description: String { message }
	}
}
#endif
