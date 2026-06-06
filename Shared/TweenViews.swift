import CoreLocation
import SwiftUI

/// Formats a coordinate for compact display, e.g. "37.3349, -122.0090".
func formatCoordinate(latitude: Double, longitude: Double) -> String {
    String(format: "%.4f, %.4f", latitude, longitude)
}

/// Compact presentation: keyboard-height, no first responder / no keyboard.
/// Tapping requests the expanded style (handled by the host).
struct CompactView: View {
    let state: TweenState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(state.text)
                    .font(.headline)
                Text(formatCoordinate(latitude: state.latitude, longitude: state.longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tap to open")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Expanded presentation: shows any received state and an "I'm in" control that sends the
/// user's cached location into the thread. When no location is cached, the same control
/// requests it in-extension first (the host wires `onImIn` to that flow).
struct ExpandedView: View {
    let received: TweenState?
    let cachedCoordinate: CLLocationCoordinate2D?
    let isRequesting: Bool
    let onImIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tween")
                .font(.largeTitle.bold())

            if let received {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Received")
                        .font(.headline)
                    LabeledContent("Message", value: received.text)
                    LabeledContent(
                        "Location",
                        value: formatCoordinate(latitude: received.latitude, longitude: received.longitude)
                    )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Your location")
                    .font(.headline)
                if let cachedCoordinate {
                    Label(
                        formatCoordinate(latitude: cachedCoordinate.latitude, longitude: cachedCoordinate.longitude),
                        systemImage: "location.fill"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label("No saved location yet", systemImage: "location.slash")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Button(action: onImIn) {
                HStack(spacing: 8) {
                    if isRequesting { ProgressView().tint(.white) }
                    Text(cachedCoordinate == nil ? "Share location & say I'm in" : "I'm in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview("Compact") {
    CompactView(state: .placeholder, onTap: {})
        .frame(height: 90)
}

#Preview("Expanded — cached") {
    ExpandedView(
        received: TweenState(text: "Lunch at Caffè Macs?", latitude: 37.3349, longitude: -122.0090),
        cachedCoordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        isRequesting: false,
        onImIn: {}
    )
}
