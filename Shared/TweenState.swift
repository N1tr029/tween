import CoreLocation
import Foundation

/// The state carried inside a Tween message bubble.
///
/// Phase 1 carries a test string plus a placeholder coordinate. The whole state is encoded
/// into `MSMessage.url` as query items (https scheme, well under the 5000-char limit) so it
/// round-trips through the Messages thread without any server.
struct TweenState: Equatable {
    var text: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension TweenState {
    /// A neutral default shown before any real state has been received.
    static let placeholder = TweenState(
        text: "Open Tween",
        latitude: 37.3349,
        longitude: -122.0090
    )

    private enum Key {
        static let text = "t"
        static let latitude = "lat"
        static let longitude = "lon"
    }

    /// Characters allowed unescaped in a query *value*. Note this deliberately excludes the
    /// sub-delimiters `&`, `=`, `+` (and `?`, `#`, `/`) that `CharacterSet.urlQueryAllowed`
    /// permits — `URLComponents.queryItems` leaves those raw in values, which would corrupt
    /// the URL for text like "cost $10 & up". We percent-encode them ourselves instead.
    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/")
        return set
    }()

    /// Encodes the state as an https URL with query items, suitable for `MSMessage.url`.
    func encodedURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tween.app"
        components.path = "/m"
        let pairs: [(String, String)] = [
            (Key.text, text),
            (Key.latitude, String(latitude)),
            (Key.longitude, String(longitude)),
        ]
        components.percentEncodedQuery = pairs
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: Self.valueAllowed) ?? "")"
            }
            .joined(separator: "&")
        // Construction is fixed and valid (scheme/host/path + percent-encoded query),
        // so this never fails; fall back to a bare host rather than crashing.
        return components.url ?? URL(string: "https://tween.app/m")!
    }

    /// Decodes state from a message URL. Returns nil if required items are missing or invalid.
    init?(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard
            let text = value(Key.text),
            let latitude = value(Key.latitude).flatMap(Double.init),
            let longitude = value(Key.longitude).flatMap(Double.init)
        else { return nil }

        self.text = text
        self.latitude = latitude
        self.longitude = longitude
    }
}
