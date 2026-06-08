//
//  ContentView.swift
//  TweenApp
//
//  Created by Kavi Gandham on 6/6/26.
//

import CoreLocation
import MapKit
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
    private let received = TweenState(text: "Lunch at Caffè Macs?", latitude: 37.7749, longitude: -122.4194)   // SF
    private let cached = CLLocationCoordinate2D(latitude: 37.4419, longitude: -122.1430)                       // Palo Alto
    private let rankedSpots: [RankedSpot] = ViewHarness.makeFakeRankedSpots()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Tween — view harness")
                    .font(.title2.bold())

                section("Compact") {
                    CompactView(state: received, onTap: {}, onImIn: {})
                        .frame(height: 90)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                section("Expanded — I'm in") {
                    ExpandedView(received: received, cachedCoordinate: cached, isRequesting: false, onImIn: {})
                        .frame(height: 430)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                section("Expanded — ranked spots") {
                    ExpandedView(
                        received: received,
                        cachedCoordinate: cached,
                        isRequesting: false,
                        rankedSpots: rankedSpots,
                        onImIn: {}
                    )
                    .frame(height: 500)
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

    /// Hand-rolled ranked spots roughly midway between SF and Palo Alto. Fake ETAs since
    /// the harness doesn't actually run MKDirections; this is for layout/screenshot only.
    private static func makeFakeRankedSpots() -> [RankedSpot] {
        let entries: [(name: String, lat: Double, lon: Double, etaA: Double, etaB: Double, conf: Double)] = [
            ("Blue Bottle SFO",  37.5950, -122.3960, 1320, 1080, 1.0),  // rank 1: 22m/18m, fair, top confidence
            ("Caffè Centro",     37.6100, -122.3700, 1500,  900, 0.8),  // rank 2: 25m/15m
            ("Park View Cafe",   37.5400, -122.3000, 1800, 1620, 0.6),  // rank 3: 30m/27m, slightly farther but high conf
        ]
        return entries.map { entry in
            let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: entry.lat, longitude: entry.lon))
            let item = MKMapItem(placemark: placemark)
            item.name = entry.name
            return RankedSpot(item: item, etaFromA: entry.etaA, etaFromB: entry.etaB, confidence: entry.conf)
        }
    }
}

#Preview {
    ContentView()
}
