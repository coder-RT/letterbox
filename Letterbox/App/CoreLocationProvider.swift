import CoreLocation
import Foundation
import LetterboxDomain

/// CoreLocation adapter for the `LocationProvider` port: one coarse fix on request.
/// The manager lives on the main thread, so its delegate callbacks arrive there too;
/// all mutable state is touched only on main, which is what the unchecked Sendable relies on.
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager: CLLocationManager
    private var waiting: [CheckedContinuation<Coordinate, Error>] = []

    @MainActor
    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentCoordinate() async throws -> Coordinate {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.waiting.append(continuation)
                self.request()
            }
        }
    }

    private func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.failure(LocationError.denied))
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<Coordinate, Error>) {
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0.resume(with: result) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !waiting.isEmpty, manager.authorizationStatus != .notDetermined else { return }
        request()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(.success(Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(LocationError.unavailable))
    }
}
