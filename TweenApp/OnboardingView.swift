//
//  OnboardingView.swift
//  TweenApp
//

import CoreLocation
import SwiftUI

/// First-run flow: explain why Tween needs a location, request When-In-Use authorization once,
/// and cache the resulting coordinate to the shared App Group container for the extension to reuse.
struct OnboardingView: View {
    @State private var provider = LocationProvider()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            Text("Share your spot")
                .font(.largeTitle.bold())

            Text("Tween grabs your location once so you can drop it into a chat and meet in the middle. We never track you.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            statusView

            Spacer()

            Button(action: { provider.requestOnce() }) {
                Text(buttonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRequesting)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusView: some View {
        switch provider.status {
        case .idle:
            EmptyView()
        case .requesting:
            ProgressView("Getting your location…")
        case let .got(coordinate):
            Label(
                "Saved \(formatCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .denied:
            Label("Location access denied. Enable it in Settings to share your spot.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }

    private var isRequesting: Bool {
        if case .requesting = provider.status { return true }
        return false
    }

    private var buttonTitle: String {
        switch provider.status {
        case .got: "Update my location"
        case .denied, .failed: "Try again"
        default: "Share my location"
        }
    }
}

#Preview {
    OnboardingView()
}
