import CoreLocation
import Foundation

/// A spot the host app has staged for sending to a chat. Persisted in the App Group so the
/// iMessage extension can pick it up next time it activates.
struct OutgoingDraft: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    /// Optional dual-ETA, in seconds. Both nil when the spot is unranked.
    let etaFromA: Double?
    let etaFromB: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Reads and writes the host→extension draft to the App Group container, mirroring
/// `LocationCache` / `FriendRoster`. The container is unencrypted — only a spot label and
/// coarse coordinate live here.
enum OutgoingDraftStore {
    static let suiteName = LocationCache.suiteName

    private enum Key {
        static let draft = "outgoingDraft"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func load() -> OutgoingDraft? {
        guard let defaults, let data = defaults.data(forKey: Key.draft) else { return nil }
        return try? JSONDecoder().decode(OutgoingDraft.self, from: data)
    }

    static func save(_ draft: OutgoingDraft) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Key.draft)
    }

    static func clear() {
        defaults?.removeObject(forKey: Key.draft)
    }
}
