import CoreLocation
import Foundation

/// Reads and writes the user's captured coordinate to the shared App Group container, so the
/// iMessage extension can reuse the location the companion app captured (capture once, reuse).
///
/// Storage is the App Group `UserDefaults` suite named in CLAUDE.md. Per the hard constraints,
/// this container is unencrypted — only a coarse coordinate lives here, nothing sensitive.
///
/// Each coordinate (self + peer) is persisted as a SINGLE encoded payload per key so the
/// extension can't read a torn `lat = new, lon = old` pair mid-write. `isActive` stays a
/// separate key — it's flipped on its own by `setActive(_:)` and isn't coupled to coords.
enum LocationCache {
    /// App Group suite shared by TweenApp and TweenMessages (see CLAUDE.md).
    static let suiteName = "group.com.kavigandham.tween"

    private enum Key {
        static let isActive = "cachedIsActive"
        static let selfPayload = "cachedSelfPayload"
        static let peerPayload = "cachedPeerPayload"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    private struct Payload: Codable {
        let latitude: Double
        let longitude: Double
        let timestamp: TimeInterval
    }

    private static func loadPayload(forKey key: String) -> CLLocationCoordinate2D? {
        guard let defaults, let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude)
    }

    private static func savePayload(_ coordinate: CLLocationCoordinate2D, forKey key: String) {
        guard let defaults else { return }
        let payload = Payload(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timestamp: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }

    /// The cached coordinate, or nil if none has been stored yet.
    static func load() -> CLLocationCoordinate2D? {
        loadPayload(forKey: Key.selfPayload)
    }

    static func isActive() -> Bool {
        defaults?.bool(forKey: Key.isActive) ?? false
    }

    /// Persists the coordinate (overwriting any previous one) atomically.
    static func save(_ coordinate: CLLocationCoordinate2D, isActive: Bool = true) {
        guard let defaults else { return }
        savePayload(coordinate, forKey: Key.selfPayload)
        defaults.set(isActive, forKey: Key.isActive)
    }

    static func setActive(_ isActive: Bool) {
        guard let defaults else { return }
        defaults.set(isActive, forKey: Key.isActive)
    }

    static func loadPeer() -> CLLocationCoordinate2D? {
        loadPayload(forKey: Key.peerPayload)
    }

    static func savePeer(_ coordinate: CLLocationCoordinate2D) {
        savePayload(coordinate, forKey: Key.peerPayload)
    }

    static func clear() {
        guard let defaults else { return }
        defaults.set(false, forKey: Key.isActive)
    }

    static func clearPeer() {
        guard let defaults else { return }
        defaults.removeObject(forKey: Key.peerPayload)
    }

    static func clearAll() {
        clear()
        clearPeer()
    }
}
