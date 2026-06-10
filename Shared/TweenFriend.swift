import Foundation

/// A friend in the user's local Tween roster. Identity is local-only — there is no server.
/// When a friend comes from Contacts we keep the contact identifier and a Messages-capable
/// handle so the host app can open a pre-addressed ping composer.
struct TweenFriend: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var contactIdentifier: String?
    var messageHandle: String?

    init(
        id: UUID = UUID(),
        name: String,
        contactIdentifier: String? = nil,
        messageHandle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.contactIdentifier = contactIdentifier
        self.messageHandle = messageHandle
    }
}

/// Reads and writes the local friend roster to the shared App Group container, mirroring
/// `LocationCache`. The container is unencrypted — only friend display names live here.
enum FriendRoster {
    static let suiteName = LocationCache.suiteName

    private enum Key {
        static let friends = "cachedFriends"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func load() -> [TweenFriend] {
        guard let defaults, let data = defaults.data(forKey: Key.friends) else { return [] }
        return (try? JSONDecoder().decode([TweenFriend].self, from: data)) ?? []
    }

    static func save(_ friends: [TweenFriend]) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(friends) else { return }
        defaults.set(data, forKey: Key.friends)
    }

    static func clear() {
        defaults?.removeObject(forKey: Key.friends)
    }
}
