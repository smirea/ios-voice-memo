@preconcurrency import MapKit
import Observation

struct MapAddressCandidate: Sendable {
	var address: String
	var coordinate: LocationCoordinate
}

@MainActor
@Observable
final class MapLocationSearch: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
	private let completer = MKLocalSearchCompleter()
	private let region: MKCoordinateRegion

	private(set) var suggestions: [MKLocalSearchCompletion] = []
	private(set) var isResolving = false

	init(center: LocationCoordinate) {
		region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(
				latitude: center.latitude,
				longitude: center.longitude
			),
			latitudinalMeters: NamedLocationResolver.nearbyRadius * 2,
			longitudinalMeters: NamedLocationResolver.nearbyRadius * 2
		)
		super.init()
		completer.delegate = self
		completer.region = region
		completer.regionPriority = .required
		completer.resultTypes = [.address, .pointOfInterest]
	}

	func search(for text: String) {
		let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard query.count >= 2 else {
			clear()
			return
		}
		completer.queryFragment = query
	}

	func clear() {
		completer.cancel()
		suggestions = []
	}

	func reverseGeocode(_ coordinate: LocationCoordinate) async -> MapAddressCandidate? {
		guard let request = MKReverseGeocodingRequest(location: coordinate.location) else { return nil }
		isResolving = true
		defer { isResolving = false }
		guard let mapItems = try? await request.mapItems else { return nil }
		return mapItems.lazy.compactMap(candidate(for:)).first
	}

	func resolve(_ completion: MKLocalSearchCompletion) async -> MapAddressCandidate? {
		isResolving = true
		defer { isResolving = false }
		let request = MKLocalSearch.Request(completion: completion)
		request.region = region
		guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
		return response.mapItems.lazy.compactMap(candidate(for:)).first
	}

	func resolveAddress(_ address: String) async -> MapAddressCandidate? {
		let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return nil }
		isResolving = true
		defer { isResolving = false }
		let request = MKLocalSearch.Request()
		request.naturalLanguageQuery = query
		request.region = region
		request.resultTypes = .address
		guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
		return response.mapItems.lazy.compactMap(candidate(for:)).first
	}

	func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
		suggestions = Array(completer.results.prefix(6))
	}

	func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
		suggestions = []
	}

	private func candidate(for mapItem: MKMapItem) -> MapAddressCandidate? {
		guard let rawAddress = mapItem.addressRepresentations?
			.fullAddress(includingRegion: false, singleLine: true)?
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!rawAddress.isEmpty
		else { return nil }
		let address = rawAddress
			.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
		return MapAddressCandidate(
			address: address,
			coordinate: LocationCoordinate(
				latitude: mapItem.location.coordinate.latitude,
				longitude: mapItem.location.coordinate.longitude
			)
		)
	}
}
