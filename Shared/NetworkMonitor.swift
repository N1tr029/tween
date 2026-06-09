import Foundation
import Network
import Observation

/// Tracks whether the device has a usable network path. Wraps `NWPathMonitor` and publishes
/// a single observable `isOnline` boolean. Mirrors the `LocationProvider` lifecycle pattern
/// — own one per view and retain for its lifetime.
@Observable
final class NetworkMonitor {
    private(set) var isOnline: Bool

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tween.network-monitor")

    init() {
        // Default to true so a first-render before the monitor's initial callback doesn't
        // flash the offline banner. The first update will correct this within ~100ms.
        isOnline = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
