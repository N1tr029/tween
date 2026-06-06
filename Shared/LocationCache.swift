import CoreLocation
import Foundation

/// Reads and writes the user's captured coordinate to the shared App Group container, so the
/// iMessage extension can reuse the location the companion app captured (capture once, reuse).
///
/// Storage is the App Group `UserDefaults` suite named in CLAUDE.md. Per the hard constraints,
/// this container is unencrypted — only a coarse coordinate lives here, nothing sensitive.
enum LocationCache {
    /// App Group suite shared by TweenApp and TweenMessages (see CLAUDE.md).
    static let suiteName = "group.com.kavigandham.tween"

    private enum Key {
        static let latitude = "cachedLatitude"
        static let longitude = "cachedLongitude"
        static let timestamp = "cachedTimestamp"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// The cached coordinate, or nil if none has been stored yet.
    static func load() -> CLLocationCoordinate2D? {
        guard let defaults, defaults.object(forKey: Key.latitude) != nil else { return nil }
        return CLLocationCoordinate2D(
            latitude: defaults.double(forKey: Key.latitude),
            longitude: defaults.double(forKey: Key.longitude)
        )
    }

    /// Persists the coordinate (overwriting any previous one) with a capture timestamp.
    static func save(_ coordinate: CLLocationCoordinate2D) {
        guard let defaults else { return }
        defaults.set(coordinate.latitude, forKey: Key.latitude)
        defaults.set(coordinate.longitude, forKey: Key.longitude)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.timestamp)
    }

    static func clear() {
        guard let defaults else { return }
        [Key.latitude, Key.longitude, Key.timestamp].forEach(defaults.removeObject(forKey:))
    }
}
