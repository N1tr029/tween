//
//  ContentView.swift
//  TweenApp
//
//  Created by Kavi Gandham on 6/6/26.
//

import CoreLocation
import SwiftUI

struct ContentView: View {
    var body: some View {
        // Launch with the "HARNESS" argument to render the extension's views for screenshots;
        // the real app shows onboarding.
        if CommandLine.arguments.contains("HARNESS") {
            ViewHarness()
        } else {
            OnboardingView()
        }
    }
}

/// Dev-only: renders the exact compact and expanded views the iMessage extension hosts, so they
/// can be screenshotted on the simulator (the live in-Messages flow is a two-device check).
private struct ViewHarness: View {
    private let received = TweenState(text: "Lunch at Caffè Macs?", latitude: 37.3349, longitude: -122.0090)
    private let cached = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Tween — view harness")
                    .font(.title2.bold())

                section("Compact") {
                    CompactView(state: received, onTap: {})
                        .frame(height: 90)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                section("Expanded — I'm in") {
                    ExpandedView(received: received, cachedCoordinate: cached, isRequesting: false, onImIn: {})
                        .frame(height: 430)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

#Preview {
    ContentView()
}
