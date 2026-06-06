//
//  ContentView.swift
//  TweenApp
//
//  Created by Kavi Gandham on 6/6/26.
//

import SwiftUI

/// Phase 1 harness: the companion app renders the exact compact and expanded views the
/// iMessage extension uses, so they can be screenshotted on the simulator. (The live
/// in-Messages bubble round-trip is verified manually on two devices — see TESTING.md.)
struct ContentView: View {
    private let sample = TweenState(
        text: "Lunch at Caffè Macs?",
        latitude: 37.3349,
        longitude: -122.0090
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Tween — view harness")
                    .font(.title2.bold())

                section("Compact") {
                    CompactView(state: sample, onTap: {})
                        .frame(height: 90)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                section("Expanded") {
                    ExpandedView(state: sample, onSend: { _ in })
                        .frame(height: 420)
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
