import CoreLocation
import Foundation

struct LocationCoordinate: Codable, Hashable, Sendable {
	var latitude: Double
	var longitude: Double

	init(latitude: Double, longitude: Double) {
		self.latitude = latitude
		self.longitude = longitude
	}

	init(_ location: JournalLocation) {
		self.init(latitude: location.latitude, longitude: location.longitude)
	}

	var location: CLLocation {
		CLLocation(latitude: latitude, longitude: longitude)
	}
}

struct NamedJournalLocation: Codable, Hashable, Identifiable, Sendable {
	private enum CodingKeys: String, CodingKey {
		case id
		case name
		case address
		case pin
		case aliases
	}

	var id: UUID
	var name: String
	var address: String?
	var pin: LocationCoordinate
	var aliases: [LocationCoordinate]

	init(
		id: UUID = UUID(),
		name: String,
		address: String? = nil,
		pin: LocationCoordinate,
		aliases: [LocationCoordinate] = []
	) {
		self.id = id
		self.name = name
		self.address = address
		self.pin = pin
		self.aliases = aliases
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		name = try container.decode(String.self, forKey: .name)
		address = try container.decodeIfPresent(String.self, forKey: .address)
		pin = try container.decode(LocationCoordinate.self, forKey: .pin)
		aliases = try container.decodeIfPresent([LocationCoordinate].self, forKey: .aliases) ?? []
	}

	var matchingCoordinates: [LocationCoordinate] {
		[pin] + aliases
	}

	func matchDistance(to coordinate: LocationCoordinate) -> CLLocationDistance {
		matchingCoordinates
			.map { $0.location.distance(from: coordinate.location) }
			.min() ?? .greatestFiniteMagnitude
	}
}

struct NearbyNamedLocation: Identifiable, Equatable, Sendable {
	var location: NamedJournalLocation
	var distance: CLLocationDistance
	var useCount: Int

	var id: UUID { location.id }
}

enum NamedLocationResolver {
	static let matchRadius: CLLocationDistance = 200
	static let nearbyRadius: CLLocationDistance = 16_093.44

	static func resolve(
		_ coordinate: LocationCoordinate,
		in locations: [NamedJournalLocation]
	) -> NamedJournalLocation? {
		locations
			.compactMap { location -> (NamedJournalLocation, CLLocationDistance, Bool)? in
				let distance = location.matchDistance(to: coordinate)
				guard distance <= matchRadius else { return nil }
				let hasExactAlias = location.aliases.contains {
					$0.location.distance(from: coordinate.location) < 5
				}
				return (location, distance, hasExactAlias)
			}
			.min {
				if $0.2 != $1.2 {
					return $0.2
				}
				if $0.1 == $1.1 {
					return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
				}
				return $0.1 < $1.1
			}?
			.0
	}

	static func usageCounts(
		entries: [JournalEntry],
		locations: [NamedJournalLocation]
	) -> [UUID: Int] {
		entries.reduce(into: [:]) { counts, entry in
			guard let rawLocation = entry.location,
				let location = resolve(LocationCoordinate(rawLocation), in: locations)
			else { return }
			counts[location.id, default: 0] += 1
		}
	}

	static func nearby(
		to coordinate: LocationCoordinate,
		locations: [NamedJournalLocation],
		entries: [JournalEntry],
		excluding excludedID: UUID? = nil
	) -> [NearbyNamedLocation] {
		let counts = usageCounts(entries: entries, locations: locations)
		return locations
			.filter { $0.id != excludedID }
			.compactMap { location -> NearbyNamedLocation? in
				let distance = location.pin.location.distance(from: coordinate.location)
				guard distance <= nearbyRadius else { return nil }
				return NearbyNamedLocation(
					location: location,
					distance: distance,
					useCount: counts[location.id, default: 0]
				)
			}
			.sorted {
				let order = $0.location.name.localizedStandardCompare($1.location.name)
				return order == .orderedSame ? $0.distance < $1.distance : order == .orderedAscending
			}
	}
}

struct AppConfiguration: Codable, Equatable, Sendable {
	private enum CodingKeys: String, CodingKey {
		case schemaVersion
		case settings
		case locations
		case elevenLabsAPIKey
	}

	static let currentSchemaVersion = 2

	var schemaVersion: Int
	var settings: JournalSettings
	var locations: [NamedJournalLocation]
	var elevenLabsAPIKey: String

	init(
		schemaVersion: Int = currentSchemaVersion,
		settings: JournalSettings,
		locations: [NamedJournalLocation] = [],
		elevenLabsAPIKey: String = ""
	) {
		self.schemaVersion = schemaVersion
		self.settings = settings
		self.locations = locations
		self.elevenLabsAPIKey = elevenLabsAPIKey
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
		settings = try container.decodeIfPresent(JournalSettings.self, forKey: .settings) ?? JournalSettings()
		locations = try container.decodeIfPresent([NamedJournalLocation].self, forKey: .locations) ?? []
		elevenLabsAPIKey = try container.decodeIfPresent(String.self, forKey: .elevenLabsAPIKey) ?? ""
	}

	func jsonData() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}
}

extension NamedJournalLocation {
	static let demo: [NamedJournalLocation] = [
		NamedJournalLocation(
			name: "Lakefront Trail",
			address: "111 N Lake Shore Dr, Chicago, IL 60611",
			pin: LocationCoordinate(latitude: 41.8917, longitude: -87.6098),
			aliases: [LocationCoordinate(latitude: 41.8781, longitude: -87.6298)]
		),
		NamedJournalLocation(
			name: "Home",
			address: "1550 N Lake Shore Dr, Chicago, IL 60610",
			pin: LocationCoordinate(latitude: 41.9105, longitude: -87.6264)
		),
		NamedJournalLocation(
			name: "Theater",
			address: "170 N Dearborn St, Chicago, IL 60601",
			pin: LocationCoordinate(latitude: 41.8854, longitude: -87.6299)
		)
	]
}
