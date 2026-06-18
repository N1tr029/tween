import Contacts
import MapKit
import MessageUI
import SwiftUI

// MARK: - Contact search sheet

struct ContactSearchSheet: View {
    let existingFriends: [TweenFriend]
    let onSelect: (ContactCandidate) -> Void
    let onCancel: () -> Void

    @StateObject private var index = ContactIndex()
    @State private var query = ""

    private var filteredContacts: [ContactCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return index.contacts }
        return index.contacts.filter { $0.searchableText.contains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    TextField("Search contacts", text: $query)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Tokens.Space.s3)
                .frame(height: 48)
                .tweenGlass(cornerRadius: Tokens.Radius.chip)

                Group {
                    switch index.state {
                    case .idle, .loading:
                        VStack(spacing: Tokens.Space.s3) {
                            ProgressView()
                            Text("Indexing your contacts")
                                .font(Tokens.Typography.callout)
                                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .denied:
                        contactsPermissionState
                    case .loaded:
                        contactResults
                    case let .failed(message):
                        VStack(spacing: Tokens.Space.s3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(Tokens.Palette.warning)
                            Text(message)
                                .font(Tokens.Typography.callout)
                                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                                .multilineTextAlignment(.center)
                            Button("Try again") {
                                index.load()
                            }
                            .buttonStyle(.tweenPrimary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(Tokens.Space.s4)
            .navigationTitle("Add from Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .onAppear { index.load() }
    }

    private var contactResults: some View {
        ScrollView {
            LazyVStack(spacing: Tokens.Space.s2) {
                if filteredContacts.isEmpty {
                    VStack(spacing: Tokens.Space.s2) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        Text(query.isEmpty ? "No contacts with a phone or email" : "No matching contacts")
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    }
                    .padding(.top, Tokens.Space.s8)
                }

                ForEach(filteredContacts) { contact in
                    let alreadyAdded = existingFriends.contains {
                        $0.contactIdentifier == contact.contactIdentifier || $0.messageHandle == contact.handle
                    }
                    Button {
                        onSelect(contact)
                    } label: {
                        HStack(spacing: Tokens.Space.s3) {
                            ZStack {
                                Circle().fill(Tokens.Palette.brandMuted)
                                Text(initials(for: contact.name))
                                    .font(Tokens.Typography.captionEmphasized)
                                    .foregroundStyle(Tokens.Palette.brand)
                            }
                            .frame(width: 38, height: 38)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .font(Tokens.Typography.headline)
                                    .foregroundStyle(Tokens.Palette.onSurface)
                                Text(displayHandle(contact.handle))
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                            }
                            Spacer()
                            if alreadyAdded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Tokens.Palette.success)
                            }
                        }
                        .padding(Tokens.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                                .stroke(Tokens.Palette.glassStroke, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(alreadyAdded)
                }
            }
        }
    }

    private var contactsPermissionState: some View {
        VStack(spacing: Tokens.Space.s3) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            Text("Contacts access is off")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.onSurface)
            Text("Turn on Contacts so Tween can find the person you want to ping.")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.tweenPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func initials(for name: String) -> String {
        let letters = name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private func displayHandle(_ handle: String) -> String {
        if handle.contains("@") { return handle }
        let digits = handle.filter(\.isNumber)
        guard digits.count == 10 else { return handle }
        return "(\(digits.prefix(3))) \(digits.dropFirst(3).prefix(3))-\(digits.suffix(4))"
    }
}

// MARK: - Contact index

final class ContactIndex: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case denied
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var contacts: [ContactCandidate] = []

    private let store = CNContactStore()

    func load() {
        state = .loading
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            fetchContacts()
        case .notDetermined:
            store.requestAccess(for: .contacts) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    if granted {
                        self?.fetchContacts()
                    } else {
                        self?.state = .denied
                    }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    private func fetchContacts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var candidates: [ContactCandidate] = []

            do {
                try self.store.enumerateContacts(with: request) { contact, _ in
                    guard let handle = Self.preferredHandle(for: contact) else { return }
                    let name = Self.displayName(for: contact)
                    guard !name.isEmpty else { return }
                    candidates.append(ContactCandidate(
                        id: "\(contact.identifier)-\(handle)",
                        contactIdentifier: contact.identifier,
                        name: name,
                        handle: handle
                    ))
                }

                let sorted = candidates.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                DispatchQueue.main.async {
                    self.contacts = sorted
                    self.state = .loaded
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed("Tween couldn't read Contacts. Try again in a second.")
                }
            }
        }
    }

    private static func displayName(for contact: CNContact) -> String {
        let combined = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !combined.isEmpty { return combined }
        return contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredHandle(for contact: CNContact) -> String? {
        if let phone = contact.phoneNumbers.first?.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !phone.isEmpty {
            return phone
        }
        if let email = contact.emailAddresses.first?.value as String?,
           !email.isEmpty {
            return email
        }
        return nil
    }
}

// MARK: - Message compose sheet

struct MessageComposeSheet: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true) {
                self.onFinish(result)
            }
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDismiss()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Location share sheet

struct LocationShareSheet: View {
    let onShare: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Space.s4) {
            ZStack {
                Circle().fill(Tokens.Palette.brandMuted)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Tokens.Palette.brand)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: Tokens.Space.s2) {
                Text("Share your location")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.onSurface)
                Text("Tween needs your location once to find a fair meetup spot. We don't store it on a server — it stays on your device.")
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            VStack(spacing: Tokens.Space.s2) {
                Button(action: onShare) {
                    Text("Share my location")
                }
                .buttonStyle(.tweenPrimary)

                Button(action: onCancel) {
                    Text("Not now")
                }
                .buttonStyle(.tweenSubtle)
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tutorial card

struct TutorialCard: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Space.s4) {
            ZStack {
                Circle().fill(Tokens.Palette.brandMuted)
                Image(systemName: "star.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Tokens.Palette.brand)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: Tokens.Space.s2) {
                Text("Welcome to Tween")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.onSurface)
                Text("Find a fair meetup spot with a friend, right from your iMessage.")
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                tutorialRow(
                    icon: "map.fill",
                    text: "Find a fair midpoint to meet your friend."
                )
                tutorialRow(
                    icon: "location.fill",
                    text: "Share your location once — Tween calculates the rest."
                )
                tutorialRow(
                    icon: "paperplane.fill",
                    text: "Send the chosen spot right into your iMessage thread."
                )
            }
            .padding(.vertical, Tokens.Space.s2)

            Button(action: onGetStarted) {
                Text("Get started")
            }
            .buttonStyle(.tweenPrimary)
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet)
                .stroke(Tokens.Palette.glassStroke, lineWidth: 0.5)
        }
        .tweenElevation(Tokens.Elevation.sheet)
    }

    private func tutorialRow(icon: String, text: String) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            ZStack {
                Circle().fill(Tokens.Palette.brandMuted)
                Image(systemName: icon)
                    .font(Tokens.Typography.callout.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.brand)
            }
            .frame(width: 32, height: 32)
            Text(text)
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.onSurface)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Place snapshot thumbnail

struct PlaceSnapshotThumbnail: View {
    let item: MKMapItem
    let tint: Color
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.brandMuted)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "map.fill")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(tint)
            }

            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 42)
            }

            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white, tint)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .task(id: item.hash) {
            image = await Self.snapshot(for: item, tint: UIColor(tint))
        }
        .animation(Tokens.Motion.gentle, value: image)
    }

    @MainActor
    private static func snapshot(for item: MKMapItem, tint: UIColor) async -> UIImage? {
        guard let coordinate = item.placemark.location?.coordinate else { return nil }
        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 312, height: 312)
        options.scale = UIScreen.main.scale
        options.mapType = .standard
        options.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        )

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            let renderer = UIGraphicsImageRenderer(size: options.size)
            return renderer.image { _ in
                snapshot.image.draw(at: .zero)
                let point = snapshot.point(for: coordinate)
                let halo = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
                tint.withAlphaComponent(0.22).setFill()
                UIBezierPath(ovalIn: halo).fill()
                UIColor.white.setFill()
                UIBezierPath(ovalIn: halo.insetBy(dx: 7, dy: 7)).fill()
                tint.setFill()
                UIBezierPath(ovalIn: halo.insetBy(dx: 11, dy: 11)).fill()
            }
        } catch {
            return nil
        }
    }
}

// MARK: - Result row

func matchedSymbolId(for item: MKMapItem) -> String { "spot-symbol-\(item.hash)" }
func matchedNameId(for item: MKMapItem) -> String { "spot-name-\(item.hash)" }
func matchedChipId(for item: MKMapItem) -> String { "spot-chip-\(item.hash)" }

struct ResultRow: View {
    let item: MKMapItem
    let ranked: RankedSpot?
    let isSelected: Bool
    let isTopPick: Bool
    let symbol: String
    let categoryTint: Color
    let typeLabel: String
    let youDistance: String?
    let friendDistance: String?
    let namespace: Namespace.ID

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            PlaceSnapshotThumbnail(item: item, tint: isTopPick ? Tokens.Palette.brand : categoryTint)

            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    ZStack {
                        Circle()
                            .fill(isTopPick ? Tokens.Palette.brand : categoryTint)
                        Image(systemName: symbol)
                            .font(Tokens.Typography.captionEmphasized)
                            .foregroundStyle(.white)
                    }
                    .frame(width: 32, height: 32)
                    .matchedGeometryEffect(id: matchedSymbolId(for: item), in: namespace)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name ?? "Place")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.onSurface)
                            .lineLimit(2)
                            .matchedGeometryEffect(id: matchedNameId(for: item), in: namespace)
                        Text(displayAddress)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                            .lineLimit(2)
                    }
                }

                HStack(spacing: Tokens.Space.s2) {
                    Text(typeLabel)
                        .font(Tokens.Typography.captionEmphasized)
                        .foregroundStyle(categoryTint)
                        .lineLimit(1)

                    Spacer(minLength: Tokens.Space.s1)

                    etaChip
                        .matchedGeometryEffect(id: matchedChipId(for: item), in: namespace)
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s3)
        .frame(minHeight: 128)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(isSelected ? Tokens.Palette.brandMuted : Tokens.Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .stroke(
                    isSelected ? Tokens.Palette.brand.opacity(0.55) : Tokens.Palette.glassStroke,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
    }

    @ViewBuilder
    private var etaChip: some View {
        if let ranked {
            ETAChip(
                selfValue: formatETA(ranked.etaFromA),
                friendValue: formatETA(ranked.etaFromB),
                isBalanced: isBalanced(ranked)
            )
        } else {
            ETAChip(
                selfValue: youDistance ?? "-",
                friendValue: friendDistance ?? "-",
                isBalanced: false
            )
        }
    }

    private var displayAddress: String {
        let placemark = item.placemark
        let parts = [
            placemark.subThoroughfare,
            placemark.thoroughfare,
            placemark.locality,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }

        if let title = placemark.title, title != item.name {
            return title
        }

        return "Address unavailable"
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes)m"
    }

    private func isBalanced(_ spot: RankedSpot) -> Bool {
        spot.fairnessGap < 0.2 * max(spot.worseETA, 1)
    }
}

// MARK: - Spot detail

struct SpotDetail: View {
    let item: MKMapItem
    let ranked: RankedSpot?
    let symbol: String
    let categoryTint: Color
    let typeLabel: String
    let youDistance: String?
    let friendDistance: String?
    let namespace: Namespace.ID
    let onShowOnMap: () -> Void
    let onSendToChat: () -> Void
    let onCopyLink: () -> Void
    let onOpenInAppleMaps: () -> Void
    let onOpenInGoogleMaps: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                ZStack {
                    Circle()
                        .fill(ranked != nil ? Tokens.Palette.brand : categoryTint)
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                .matchedGeometryEffect(id: matchedSymbolId(for: item), in: namespace)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "Place")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.onSurface)
                        .lineLimit(2)
                        .matchedGeometryEffect(id: matchedNameId(for: item), in: namespace)
                    Text(typeLabel)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                }

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close detail")
            }

            if let address = item.placemark.title {
                Text(address)
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                ETAChip(
                    selfValue: ranked.map { formatETA($0.etaFromA) } ?? (youDistance ?? "\u{2014}"),
                    friendValue: ranked.map { formatETA($0.etaFromB) } ?? (friendDistance ?? "\u{2014}"),
                    isBalanced: ranked.map(isBalanced) ?? false
                )
                .scaleEffect(1.2)
                .matchedGeometryEffect(id: matchedChipId(for: item), in: namespace)
                Spacer()
            }
            .padding(.vertical, Tokens.Space.s2)

            VStack(spacing: Tokens.Space.s2) {
                Button(action: onSendToChat) {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text("Send to chat")
                    }
                }
                .buttonStyle(.tweenPrimary)

                Button(action: onCopyLink) {
                    HStack {
                        Image(systemName: "link")
                        Text("Copy link")
                    }
                }
                .buttonStyle(.tweenSubtle)

                Button(action: onShowOnMap) {
                    HStack {
                        Image(systemName: "scope")
                        Text("Show on map")
                    }
                }
                .buttonStyle(.tweenSubtle)

                Button(action: onOpenInAppleMaps) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("Open in Apple Maps")
                    }
                }
                .buttonStyle(.tweenSubtle)

                Button(action: onOpenInGoogleMaps) {
                    HStack {
                        Image(systemName: "globe")
                        Text("Open in Google Maps")
                    }
                }
                .buttonStyle(.tweenSubtle)
            }
        }
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes)m"
    }

    private func isBalanced(_ spot: RankedSpot) -> Bool {
        spot.fairnessGap < 0.2 * max(spot.worseETA, 1)
    }
}

// MARK: - ETA chip

struct ETAChip: View {
    let selfValue: String
    let friendValue: String
    let isBalanced: Bool

    var body: some View {
        HStack(spacing: Tokens.Space.s1 + 2) {
            etaPill(value: selfValue, color: Tokens.Palette.pinSelf)
            etaPill(value: friendValue, color: Tokens.Palette.pinFriend)
        }
        .padding(.horizontal, Tokens.Space.s1 + 2)
        .padding(.vertical, Tokens.Space.s1)
        .background {
            Capsule()
                .fill(isBalanced ? Tokens.Palette.brandMuted : Color.clear)
        }
    }

    private func etaPill(value: String, color: Color) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(value)
                .font(Tokens.Typography.captionEmphasized)
                .foregroundStyle(Tokens.Palette.onSurface)
                .lineLimit(1)
        }
    }
}
