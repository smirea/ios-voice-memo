@preconcurrency import CoreLocation
import MapKit

@MainActor
final class EntryLocationCapture: NSObject, @preconcurrency CLLocationManagerDelegate {
	private let manager = CLLocationManager()
	private var continuation: CheckedContinuation<CLLocation?, Never>?
	private var hasRequestedLocation = false

	static func capture() async -> JournalLocation? {
		let capture = EntryLocationCapture()
		guard let location = await capture.currentLocation() else { return nil }
		let city = await reverseGeocodeCity(for: location)
		return JournalLocation(
			latitude: location.coordinate.latitude,
			longitude: location.coordinate.longitude,
			city: city
		)
	}

	override init() {
		super.init()
		manager.delegate = self
		manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
	}

	private func currentLocation() async -> CLLocation? {
		await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(returning: nil)
					return
				}
				self.continuation = continuation
				requestAuthorizationOrLocation()
			}
		} onCancel: {
			Task { @MainActor in
				self.finish(with: nil)
			}
		}
	}

	private static func reverseGeocodeCity(for location: CLLocation) async -> String? {
		guard let request = MKReverseGeocodingRequest(location: location),
			let mapItems = try? await request.mapItems
		else { return nil }
		return mapItems.lazy.compactMap(\.addressRepresentations?.cityName).first
	}

	private func requestAuthorizationOrLocation() {
		guard continuation != nil else { return }
		switch manager.authorizationStatus {
		case .notDetermined:
			manager.requestWhenInUseAuthorization()
		case .authorizedAlways, .authorizedWhenInUse:
			guard !hasRequestedLocation else { return }
			hasRequestedLocation = true
			manager.requestLocation()
		case .denied, .restricted:
			finish(with: nil)
		@unknown default:
			finish(with: nil)
		}
	}

	func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
		requestAuthorizationOrLocation()
	}

	func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		finish(with: locations.last)
	}

	func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
		finish(with: nil)
	}

	private func finish(with location: CLLocation?) {
		guard let continuation else { return }
		self.continuation = nil
		continuation.resume(returning: location)
	}
}
