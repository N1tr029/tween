import CoreLocation
import Messages
import SwiftUI
import UIKit

/// Switches between compact and expanded SwiftUI views and wires their actions
/// back to the Messages controller.
private struct RootView: View {
    let received: TweenState?
    let cachedCoordinate: CLLocationCoordinate2D?
    let isRequesting: Bool
    let isExpanded: Bool
    let onExpand: () -> Void
    let onImIn: () -> Void

    var body: some View {
        if isExpanded {
            ExpandedView(
                received: received,
                cachedCoordinate: cachedCoordinate,
                isRequesting: isRequesting,
                onImIn: onImIn
            )
            #if DEBUG
            .overlay(alignment: .top) { DebugCacheOverlay() }
            #endif
        } else {
            CompactView(state: received ?? .placeholder, onTap: onExpand, onImIn: onImIn)
        }
    }
}

#if DEBUG
// Slice 1 verification harness: writes a peer-sentinel into the App Group and
// displays whatever the app wrote to self. 1 Hz refresh via TimelineView so a
// fresh value from the other process becomes visible without re-expanding.
// Delete with `git grep '#if DEBUG'`.
private struct DebugCacheOverlay: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            let selfCoord = LocationCache.load()
            let peerCoord = LocationCache.loadPeer()
            VStack(alignment: .leading, spacing: 6) {
                Text("DEBUG · App Group")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("self: \(formatDebug(selfCoord))")
                    .font(.caption.monospaced())
                Text("peer: \(formatDebug(peerCoord))")
                    .font(.caption.monospaced())
                Button("Write peer sentinel (21.654321, 87.654321)") {
                    LocationCache.savePeer(CLLocationCoordinate2D(latitude: 21.654321, longitude: 87.654321))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    private func formatDebug(_ coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate else { return "nil" }
        return String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }
}
#endif

final class MessagesViewController: MSMessagesAppViewController {

    private var hostingController: UIHostingController<RootView>?
    private var received: TweenState?
    private var isRequesting = false
    private let locationProvider = LocationProvider()

    // MARK: - Conversation lifecycle

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        // When a recipient taps the bubble, the extension opens here with the tapped
        // message available as `selectedMessage`. Read our state back out of its URL.
        received = conversation.selectedMessage?.url.flatMap(TweenState.init(url:))
        if let selectedMessage = conversation.selectedMessage {
            cachePeerLocation(from: selectedMessage, conversation: conversation)
        }
        presentUI()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        presentUI()
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
        cachePeerLocation(from: message, conversation: conversation)
        presentUI()
    }

    private func cachePeerLocation(from message: MSMessage, conversation: MSConversation) {
        guard
            let state = message.url.flatMap(TweenState.init(url:))
        else { return }

        received = state
        LocationCache.savePeer(state.coordinate)
    }

    // MARK: - UI

    private func presentUI() {
        let root = RootView(
            received: received,
            cachedCoordinate: LocationCache.load(),
            isRequesting: isRequesting,
            isExpanded: presentationStyle == .expanded,
            onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) },
            onImIn: { [weak self] in self?.handleImIn() }
        )

        if let hostingController {
            hostingController.rootView = root
            return
        }

        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    // MARK: - "I'm in"

    private func handleImIn() {
        // Reuse the location the app already captured; only request in-extension if none exists.
        if let coordinate = LocationCache.load() {
            sendImIn(coordinate)
            return
        }
        isRequesting = true
        presentUI()
        locationProvider.requestOnce { [weak self] coordinate in
            guard let self else { return }
            self.isRequesting = false
            if let coordinate {
                self.sendImIn(coordinate)
            } else {
                self.presentUI() // reflect denied / no-location state
            }
        }
    }

    private func sendImIn(_ coordinate: CLLocationCoordinate2D) {
        send(TweenState(text: "I'm in", latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    // MARK: - Sending

    private func send(_ newState: TweenState) {
        guard let conversation = activeConversation else { return }

        let layout = MSMessageTemplateLayout()
        layout.caption = newState.text
        layout.subcaption = formatCoordinate(latitude: newState.latitude, longitude: newState.longitude)

        // Reuse the tapped message's session so the existing bubble updates in place
        // (GamePigeon style); start a new session when composing fresh.
        let message = MSMessage(session: conversation.selectedMessage?.session ?? MSSession())
        message.url = newState.encodedURL()
        message.layout = layout

        conversation.insert(message) { error in
            if let error { NSLog("Tween: failed to insert message: \(error.localizedDescription)") }
        }
        requestPresentationStyle(.compact)
    }
}
