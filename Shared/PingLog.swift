import Foundation

/// Per-friend last-pinged timestamps and a single global last-reply timestamp, persisted
/// in the App Group container so the host app and the iMessage extension share state.
///
/// Attribution caveat: the iMessage extension can record *that* a reply arrived but not
/// *which* friend it came from — `MSMessage.url` carries only coordinates, not contact info.
/// So per-friend `pingedAt` is precise (the user owns those events), but `lastIncomingReplyAt`
/// is global. The UI resolves the ambiguity by surfacing the reply on whichever friend was
/// pinged most recently within a recency window.
enum PingLog {
    static let suiteName = LocationCache.suiteName

    private enum Key {
        static let pingedAt = "pingLog_pingedAt"
        static let lastReplyAt = "pingLog_lastIncomingReplyAt"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// All per-friend timestamps. Returns an empty dictionary when unset.
    static func loadAll() -> [UUID: Date] {
        guard let defaults, let data = defaults.data(forKey: Key.pingedAt) else { return [:] }
        guard let raw = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        var out: [UUID: Date] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { out[id] = value }
        }
        return out
    }

    static func pingedAt(_ id: UUID) -> Date? {
        loadAll()[id]
    }

    static func setPingedAt(_ id: UUID, date: Date = Date()) {
        var current = loadAll()
        current[id] = date
        save(current)
    }

    static func clearPing(_ id: UUID) {
        var current = loadAll()
        current.removeValue(forKey: id)
        save(current)
    }

    private static func save(_ map: [UUID: Date]) {
        guard let defaults else { return }
        var raw: [String: Date] = [:]
        for (id, date) in map { raw[id.uuidString] = date }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Key.pingedAt)
    }

    static var lastIncomingReplyAt: Date? {
        get {
            guard let defaults, defaults.object(forKey: Key.lastReplyAt) != nil else { return nil }
            return Date(timeIntervalSince1970: defaults.double(forKey: Key.lastReplyAt))
        }
        set {
            guard let defaults else { return }
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastReplyAt)
            } else {
                defaults.removeObject(forKey: Key.lastReplyAt)
            }
        }
    }
}

/// Short relative-time strings for ping/reply subtitles. Kept here next to `PingLog` because
/// it's the only consumer today; promote to its own file if the format finds more uses.
enum RelativeTime {
    /// Returns a punchy short-form age: "just now", "5m ago", "3h ago", "yesterday", "5d ago".
    static func formatShort(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h ago" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "yesterday" : "\(days)d ago"
    }
}
