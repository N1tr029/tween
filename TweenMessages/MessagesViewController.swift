import Messages
import SwiftUI
import UIKit

/// Switches between compact and expanded SwiftUI views and wires their actions
/// back to the Messages controller.
private struct RootView: View {
    let state: TweenState
    let isExpanded: Bool
    let onExpand: () -> Void
    let onSend: (TweenState) -> Void

    var body: some View {
        if isExpanded {
            ExpandedView(state: state, onSend: onSend)
        } else {
            CompactView(state: state, onTap: onExpand)
        }
    }
}

final class MessagesViewController: MSMessagesAppViewController {

    private var hostingController: UIHostingController<RootView>?
    private var state: TweenState = .placeholder

    // MARK: - Conversation lifecycle

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        // When a recipient taps the bubble, the extension opens here with the tapped
        // message available as `selectedMessage`. Read our state back out of its URL.
        loadState(from: conversation)
        presentUI(for: presentationStyle)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        presentUI(for: presentationStyle)
    }

    // MARK: - State

    private func loadState(from conversation: MSConversation) {
        if let url = conversation.selectedMessage?.url, let decoded = TweenState(url: url) {
            state = decoded
        } else {
            state = .placeholder
        }
    }

    // MARK: - UI

    private func presentUI(for style: MSMessagesAppPresentationStyle) {
        let root = RootView(
            state: state,
            isExpanded: style == .expanded,
            onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) },
            onSend: { [weak self] newState in self?.send(newState) }
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

    // MARK: - Sending

    private func send(_ newState: TweenState) {
        guard let conversation = activeConversation else { return }

        let layout = MSMessageTemplateLayout()
        layout.caption = newState.text
        layout.subcaption = CompactView.coordinateText(newState)

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
