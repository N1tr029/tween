import SwiftUI

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
                Text(Self.coordinateText(state))
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

    static func coordinateText(_ state: TweenState) -> String {
        String(format: "%.4f, %.4f", state.latitude, state.longitude)
    }
}

/// Expanded presentation: shows the received state and lets the user send an updated message.
struct ExpandedView: View {
    let state: TweenState
    let onSend: (TweenState) -> Void

    @State private var draftText: String

    init(state: TweenState, onSend: @escaping (TweenState) -> Void) {
        self.state = state
        self.onSend = onSend
        _draftText = State(initialValue: state.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tween")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Received state")
                    .font(.headline)
                LabeledContent("Message", value: state.text)
                LabeledContent("Latitude", value: String(format: "%.4f", state.latitude))
                LabeledContent("Longitude", value: String(format: "%.4f", state.longitude))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text("Send an update")
                .font(.headline)
            TextField("Message", text: $draftText)
                .textFieldStyle(.roundedBorder)

            Button {
                // Modify the state so the round-trip is observable: edited text + nudged coordinate.
                onSend(
                    TweenState(
                        text: draftText,
                        latitude: state.latitude + 0.0010,
                        longitude: state.longitude + 0.0010
                    )
                )
            } label: {
                Text("Send update")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

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

#Preview("Expanded") {
    ExpandedView(state: .placeholder, onSend: { _ in })
}
