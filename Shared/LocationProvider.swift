import CoreLocation
import Foundation
import Observation

/// Requests When-In-Use authorization and a single location fix, caches the result to the
/// shared App Group container, and publishes status for the UI.
///
/// Used by the app's onboarding and by the extension's "request in-extension" fallback when no
/// coordinate has been cached yet. The `CLLocationManager` is retained for the provider's
/// lifetime — a local manager would be released before the async callbacks arrive.
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum Status {
        case idle
        case requesting
        case denied
        case got(CLLocationCoordinate2D)
        case failed(String)
    }

    private(set) var status: Status = .idle

    private let manager = CLLocationManager()
    private var completion: ((CLLocationCoordinate2D?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Requests authorization (if needed) and a single location fix. The optional completion
    /// fires once with the coordinate, or nil if denied/failed.
    func requestOnce(completion: ((CLLocationCoordinate2D?) -> Void)? = nil) {
        self.completion = completion
        status = .requesting
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            status = .denied
            complete(with: nil)
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        @unknown default:
            status = .denied
            complete(with: nil)
        }
    }

    /// Like `requestOnce`, but a no-op when authorisation is `.notDetermined` / `.denied` /
    /// `.restricted`. Used by the app's launch-time silent refresh — never want to fire the
    /// system permission prompt without an explicit user tap.
    func requestOnceIfAuthorized(completion: ((CLLocationCoordinate2D?) -> Void)? = nil) {
        let auth = manager.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
            completion?(nil)
            return
        }
        requestOnce(completion: completion)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if case .requesting = status { manager.requestLocation() }
        case .denied, .restricted:
            status = .denied
            complete(with: nil)
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        LocationCache.save(coordinate)
        status = .got(coordinate)
        complete(with: coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = .failed(error.localizedDescription)
        complete(with: nil)
    }

    private func complete(with coordinate: CLLocationCoordinate2D?) {
        let handler = completion
        completion = nil
        handler?(coordinate)
    }
}
