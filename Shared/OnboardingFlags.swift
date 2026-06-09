import Foundation

/// One-shot first-run flags persisted in the App Group container so the same value is
/// visible to both the host app and the iMessage extension. Currently just the welcome
/// tutorial, but more flags can land here as new first-run experiences ship.
enum OnboardingFlags {
    static let suiteName = LocationCache.suiteName

    private enum Key {
        static let hasSeenWelcome = "onboardingFlag_hasSeenWelcome"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static var hasSeenOnboarding: Bool {
        get { defaults?.bool(forKey: Key.hasSeenWelcome) ?? false }
        set { defaults?.set(newValue, forKey: Key.hasSeenWelcome) }
    }
}
