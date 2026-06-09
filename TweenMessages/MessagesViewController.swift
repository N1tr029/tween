import CoreLocation
import MapKit
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
    let rankedSpots: [RankedSpot]
    let pendingDraft: OutgoingDraft?
    let locationDenied: Bool
    let sentMessageCount: Int
    let onExpand: () -> Void
    let onImIn: () -> Void
    let onSendSpot: (RankedSpot) -> Void
    let onOpenSettings: () -> Void
    let onSendDraft: () -> Void
    let onCancelDraft: () -> Void

    var body: some View {
        if isExpanded {
            ExpandedView(
                received: received,
                cachedCoordinate: cachedCoordinate,
                isRequesting: isRequesting,
                rankedSpots: rankedSpots,
                pendingDraft: pendingDraft,
                locationDenied: locationDenied,
                sentMessageCount: sentMessageCount,
                onImIn: onImIn,
                onSendSpot: onSendSpot,
                onOpenSettings: onOpenSettings,
                onSendDraft: onSendDraft,
                onCancelDraft: onCancelDraft
            )
        } else {
            CompactView(state: received ?? .placeholder, onTap: onExpand, onImIn: onImIn)
        }
    }
}

final class MessagesViewController: MSMessagesAppViewController {

    private var hostingController: UIHostingController<RootView>?
    private var received: TweenState?
    private var isRequesting = false
    private var rankedSpots: [RankedSpot] = []
    private var rankingTask: Task<Void, Never>?
    private let locationProvider = LocationProvider()
    private var pendingDraft: OutgoingDraft?
    private var sentMessageCount: Int = 0

    // MARK: - Conversation lifecycle

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        // When a recipient taps the bubble, the extension opens here with the tapped
        // message available as `selectedMessage`. Read our state back out of its URL.
        received = conversation.selectedMessage?.url.flatMap(TweenState.init(url:))
        if let selectedMessage = conversation.selectedMessage {
            cachePeerLocation(from: selectedMessage, conversation: conversation)
        }
        // Pick up a host-staged spot draft and surface a confirm UI in expanded mode.
        pendingDraft = OutgoingDraftStore.load()
        if pendingDraft != nil {
            requestPresentationStyle(.expanded)
        }
        presentUI()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        if presentationStyle == .expanded {
            kickOffRanking()
        }
        presentUI()
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
        cachePeerLocation(from: message, conversation: conversation)
        PingLog.lastIncomingReplyAt = Date()
        if presentationStyle == .expanded {
            kickOffRanking()
        }
        presentUI()
    }

    // MARK: - Fairness ranking (extension side)

    private func kickOffRanking() {
        guard let peer = received?.coordinate,
              let me = LocationCache.load() else {
            rankedSpots = []
            return
        }
        rankingTask?.cancel()
        rankingTask = Task { [weak self] in
            let candidates = await Self.searchCandidates(between: me, and: peer)
            if Task.isCancelled { return }
            let ranked = await FairnessRanker.rank(candidates: candidates, from: me, and: peer, cap: 5)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.rankedSpots = ranked
                self.presentUI()
            }
        }
    }

    private static func searchCandidates(
        between a: CLLocationCoordinate2D,
        and b: CLLocationCoordinate2D
    ) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "cafe restaurant park"
        request.resultTypes = [.pointOfInterest]
        let midpoint = CLLocationCoordinate2D(
            latitude: (a.latitude + b.latitude) / 2,
            longitude: (a.longitude + b.longitude) / 2
        )
        let latitudeSpan = max(abs(a.latitude - b.latitude) * 1.6, 0.03)
        let longitudeSpan = max(abs(a.longitude - b.longitude) * 1.6, 0.03)
        request.region = MKCoordinateRegion(
            center: midpoint,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
        do {
            let response = try await MKLocalSearch(request: request).start()
            return Array(response.mapItems.prefix(8))
        } catch {
            return []
        }
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
        let denied: Bool
        if case .denied = locationProvider.status { denied = true } else { denied = false }
        let root = RootView(
            received: received,
            cachedCoordinate: LocationCache.load(),
            isRequesting: isRequesting,
            isExpanded: presentationStyle == .expanded,
            rankedSpots: rankedSpots,
            pendingDraft: pendingDraft,
            locationDenied: denied,
            sentMessageCount: sentMessageCount,
            onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) },
            onImIn: { [weak self] in self?.handleImIn() },
            onSendSpot: { [weak self] spot in self?.sendChosenSpot(spot) },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onSendDraft: { [weak self] in self?.sendPendingDraft() },
            onCancelDraft: { [weak self] in self?.discardPendingDraft() }
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

    /// Sends a user-selected fair spot as the message payload. Reuses the existing send()
    /// path; BubbleImageRenderer already paints the right pins because we pass the chosen
    /// spot through `rankedSpots.first` semantics — see the wrapper below.
    private func sendChosenSpot(_ spot: RankedSpot) {
        guard let coordinate = spot.item.placemark.location?.coordinate else { return }
        // Reorder rankedSpots so the user's pick is at index 0; send() reads .first when
        // building the BubbleImageRenderer chosenSpot argument.
        if let index = rankedSpots.firstIndex(where: { $0.item.hash == spot.item.hash }) {
            let pick = rankedSpots.remove(at: index)
            rankedSpots.insert(pick, at: 0)
        }
        send(TweenState(
            text: "Meet at \(spot.item.name ?? "the spot")",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    private func sendPendingDraft() {
        guard let draft = pendingDraft else { return }
        OutgoingDraftStore.clear()
        pendingDraft = nil
        send(TweenState(text: "Meet at \(draft.name)", latitude: draft.latitude, longitude: draft.longitude))
    }

    private func discardPendingDraft() {
        OutgoingDraftStore.clear()
        pendingDraft = nil
        presentUI()
    }

    // MARK: - Sending

    private func send(_ newState: TweenState) {
        guard let conversation = activeConversation else { return }
        let selfCoord = LocationCache.load()
        let peer = newState.coordinate
        let chosen = rankedSpots.first
        let sessionFromTap = conversation.selectedMessage?.session

        Task { [weak self] in
            let bubbleImage = await BubbleImageRenderer.makeImage(
                selfCoord: selfCoord,
                peer: peer,
                chosenSpot: chosen
            )
            await MainActor.run {
                guard let self else { return }
                self.insertBubble(
                    into: conversation,
                    newState: newState,
                    chosen: chosen,
                    selfCoord: selfCoord,
                    peer: peer,
                    image: bubbleImage,
                    session: sessionFromTap
                )
            }
        }
    }

    private func insertBubble(
        into conversation: MSConversation,
        newState: TweenState,
        chosen: RankedSpot?,
        selfCoord: CLLocationCoordinate2D?,
        peer: CLLocationCoordinate2D,
        image: UIImage?,
        session: MSSession?
    ) {
        let layout = MSMessageTemplateLayout()
        layout.image = image
        layout.imageTitle = chosen?.item.name ?? newState.text
        layout.caption = Self.bubbleCaption(chosen: chosen, selfCoord: selfCoord, peer: peer)
        layout.subcaption = formatCoordinate(latitude: newState.latitude, longitude: newState.longitude)
        layout.trailingCaption = "Tween"

        // Reuse the tapped message's session so the existing bubble updates in place
        // (GamePigeon style); start a new session when composing fresh.
        let message = MSMessage(session: session ?? MSSession())
        message.url = newState.encodedURL()
        message.layout = layout

        conversation.insert(message) { error in
            if let error { NSLog("Tween: failed to insert message: \(error.localizedDescription)") }
        }
        sentMessageCount += 1
        requestPresentationStyle(.compact)
    }

    private static func bubbleCaption(
        chosen: RankedSpot?,
        selfCoord: CLLocationCoordinate2D?,
        peer: CLLocationCoordinate2D
    ) -> String {
        if let chosen {
            let you = Int((chosen.etaFromA / 60).rounded())
            let friend = Int((chosen.etaFromB / 60).rounded())
            let name = chosen.item.name ?? "the spot"
            return "Meet at \(name) · You \(you)m · Friend \(friend)m"
        }
        if let selfCoord {
            return "I'm in · \(formatDistance(from: selfCoord, to: peer)) apart"
        }
        return "I'm in"
    }
}
