//
//  OnboardingView.swift
//  TweenApp
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Map-first home screen: capture the user's current location once and cache it to the shared
/// App Group container for the extension to reuse.
struct OnboardingView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var provider = LocationProvider()
    @State private var savedCoordinate = LocationCache.load()
    @State private var peerCoordinate = LocationCache.loadPeer()
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var rankedSpots: [RankedSpot] = []
    @State private var selectedPlace: MKMapItem?
    @State private var searchError: String?
    @State private var panelDetent: PanelDetent = .medium
    @State private var panelTab: HomePanelTab = .map
    @State private var position = MapCameraPosition.region(OnboardingView.defaultFramedRegion)
    @State private var lastVisibleRegion = OnboardingView.defaultFramedRegion

    /// The country-level fallback region used on a fresh launch (no cached coordinate)
    /// and as the seed for `lastVisibleRegion` before the user pans. Continental US.
    private static let defaultFramedRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
        span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 55)
    )
    @State private var mapDisplayMode: MapDisplayMode = .standard
    @State private var showsTraffic = false
    @State private var friends: [TweenFriend] = FriendRoster.load()
    @State private var editorMode: FriendEditor?
    @State private var editorName: String = ""
    @State private var pendingShare: ShareIntent?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            styledMap
                .ignoresSafeArea()

            searchBar

            VStack {
                HStack {
                    Spacer()
                    mapControls
                }
                .padding(.top, Tokens.Space.s8 + Tokens.Space.s7 + 2)
                .padding(.horizontal, Tokens.Space.s4)
                Spacer()
            }

            VStack {
                Spacer()
                bottomPanel
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear(perform: prepareInitialMap)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshSavedLocation()
        }
        .task {
            await pollSharedLocations()
        }
    }

    private var mapCanvas: some View {
        Map(position: $position, bounds: MapCameraBounds(minimumDistance: 200, maximumDistance: 2_000_000)) {
                if let coordinate = savedCoordinate {
                    Annotation("You", coordinate: coordinate) {
                        TweenPin(role: .selfDot)
                    }
                }

                if let displayPeerCoordinate {
                    Annotation("Friend", coordinate: displayPeerCoordinate) {
                        TweenPin(role: .friend)
                    }
                }

                if let savedCoordinate, let displayPeerCoordinate {
                    MapPolyline(coordinates: [savedCoordinate, displayPeerCoordinate])
                        .stroke(Tokens.Palette.pinSelf, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [7, 7]))
                }

                if let bestSpot = rankedSpots.first,
                   let bestCoordinate = bestSpot.item.placemark.location?.coordinate {
                    Annotation("Fair spot", coordinate: bestCoordinate) {
                        TweenPin(role: .midpoint)
                    }
                }

                ForEach(searchResults, id: \.self) { item in
                    if let coordinate = item.placemark.location?.coordinate {
                        Annotation(item.name ?? "Place", coordinate: coordinate) {
                            Button {
                                selectedPlace = item
                                centerMap(on: coordinate, avoidingBottomOverlay: true)
                            } label: {
                                placeAnnotation(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                lastVisibleRegion = context.region
            }
    }

    @ViewBuilder
    private var styledMap: some View {
        switch mapDisplayMode {
        case .standard:
            mapCanvas
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.cafe, .restaurant, .publicTransport]), showsTraffic: showsTraffic))
        case .satellite:
            mapCanvas
                .mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .including([.cafe, .restaurant, .publicTransport]), showsTraffic: showsTraffic))
        }
    }

    #if DEBUG
    // Slice 1 verification harness: writes a self-sentinel into the App Group and
    // displays whatever the extension wrote to peer. Delete with `git grep '#if DEBUG'`.
    private var debugCachePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEBUG · App Group")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text("self: \(formatDebug(savedCoordinate))")
                .font(.caption.monospaced())
            Text("peer: \(formatDebug(peerCoordinate))")
                .font(.caption.monospaced())
            Button("Write self sentinel (12.345678, -98.765432)") {
                LocationCache.save(CLLocationCoordinate2D(latitude: 12.345678, longitude: -98.765432))
                refreshSavedLocation()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Run ranker dry-run (SF ↔ Palo Alto, 'cafe')") {
                runRankerDryRun()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    private func formatDebug(_ coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate else { return "nil" }
        return String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    private func runRankerDryRun() {
        let a = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194) // SF
        let b = CLLocationCoordinate2D(latitude: 37.4419, longitude: -122.1430) // Palo Alto
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "cafe"
        request.resultTypes = [.pointOfInterest]
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2,
                                           longitude: (a.longitude + b.longitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
        )
        Task {
            print("[FairnessRanker dry-run] searching 'cafe' between SF and Palo Alto…")
            do {
                let response = try await MKLocalSearch(request: request).start()
                let items = Array(response.mapItems.prefix(8))
                let ranked = await FairnessRanker.rank(candidates: items, from: a, and: b)
                print("[FairnessRanker dry-run] top \(min(5, ranked.count)) of \(ranked.count) (cap \(FairnessRanker.defaultCap)):")
                for (i, spot) in ranked.prefix(5).enumerated() {
                    let name = spot.item.name ?? "?"
                    let worse = Int(spot.worseETA / 60)
                    let gap = Int(spot.fairnessGap / 60)
                    let conf = String(format: "%.2f", spot.confidence)
                    print("  \(i + 1). \(name) | worseETA \(worse)m | gap \(gap)m | confidence \(conf)")
                }
            } catch {
                print("[FairnessRanker dry-run] search failed: \(error)")
            }
        }
    }
    #endif

    private var searchBar: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            TextField("Search coffee, lunch, parks...", text: $searchText)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchPlaces() }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                    selectedPlace = nil
                    panelDetent = .medium
                    focusOnPeople()
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
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s3)
    }

    private var mapControls: some View {
        VStack(spacing: Tokens.Space.s2) {
            Menu {
                ForEach(MapDisplayMode.allCases) { mode in
                    Button {
                        setMapDisplayMode(mode)
                    } label: {
                        Label(mode.title, systemImage: mapDisplayMode == mode ? "checkmark" : mode.systemImage)
                    }
                }
            } label: {
                Image(systemName: mapDisplayMode.systemImage)
                    .font(Tokens.Typography.headline)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map style")

            Button {
                setTrafficVisible(!showsTraffic)
            } label: {
                Image(systemName: showsTraffic ? "car.fill" : "car")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(showsTraffic ? .white : Tokens.Palette.onSurface)
                    .frame(width: 42, height: 42)
                    .background(showsTraffic ? Tokens.Palette.brand : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsTraffic ? "Hide traffic" : "Show traffic")

            Divider()
                .frame(width: 28)

            Button(action: resetMap) {
                Image(systemName: "location.north.line.fill")
                    .font(Tokens.Typography.headline)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset map")
        }
        .padding(Tokens.Space.s1 + 2)
        .tweenGlass(cornerRadius: Tokens.Radius.card)
        .tweenElevation(Tokens.Elevation.floating)
        .animation(Tokens.Motion.snappy, value: mapDisplayMode)
        .animation(Tokens.Motion.snappy, value: showsTraffic)
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3 + 2) {
            VStack(alignment: .leading, spacing: Tokens.Space.s3 + 2) {
                dragHandle
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Tokens.Motion.spring) {
                            panelDetent = panelDetent == .peek ? .medium : panelDetent
                        }
                    }

                if panelDetent == .peek {
                    peekIdentity
                } else {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text("Tween")
                                .font(Tokens.Typography.display)
                            Text(headlineText)
                                .font(Tokens.Typography.headline)
                                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        }

                        Spacer()

                        Image(systemName: savedCoordinate == nil ? "mappin.and.ellipse" : "checkmark.circle.fill")
                            .font(Tokens.Typography.title)
                            .foregroundStyle(savedCoordinate == nil ? Tokens.Palette.onSurfaceMuted : Tokens.Palette.success)
                    }

                    Picker("View", selection: $panelTab) {
                        ForEach(HomePanelTab.allCases) { tab in
                            Label(tab.title, systemImage: tab.systemImage).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)

                    if panelDetent != .full, panelTab == .map {
                        statusView
                    }

                    switch panelTab {
                    case .map:
                        if !searchResults.isEmpty {
                            placeResultsList
                        } else if let searchError {
                            Label(searchError, systemImage: "exclamationmark.triangle.fill")
                                .font(Tokens.Typography.callout)
                                .foregroundStyle(Tokens.Palette.warning)
                        } else {
                            categoryChipRow
                        }
                    case .waiting:
                        waitingTab
                    }

                    if panelDetent != .full, panelTab == .map {
                        actionControls
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.top, searchResults.isEmpty ? Tokens.Space.s5 : Tokens.Space.s3 - 2)
            .padding(.bottom, searchResults.isEmpty ? Tokens.Space.s7 + 2 : Tokens.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: panelHeight, alignment: .top)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.sheet, topTrailingRadius: Tokens.Radius.sheet)
                    .fill(.regularMaterial)
                    .overlay {
                        UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.sheet, topTrailingRadius: Tokens.Radius.sheet)
                            .stroke(Tokens.Palette.glassStroke, lineWidth: 0.5)
                    }
            }
            .tweenElevation(Tokens.Elevation.sheet)
            .gesture(panelDragGesture)
            .animation(Tokens.Motion.spring, value: panelDetent)
            .alert(
                editorMode?.alertTitle ?? "",
                isPresented: Binding(
                    get: { editorMode != nil },
                    set: { if !$0 { editorMode = nil } }
                )
            ) {
                TextField("Name", text: $editorName)
                    .textInputAutocapitalization(.words)
                Button("Save", action: saveEditor)
                    .disabled(editorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { editorMode = nil }
            } message: {
                Text("Use a name you'll recognize.")
            }
            .alert(
                "Share your current location?",
                isPresented: Binding(
                    get: { pendingShare != nil },
                    set: { if !$0 { pendingShare = nil } }
                )
            ) {
                Button("Share") {
                    pendingShare = nil
                    updateMyDot()
                }
                Button("Cancel", role: .cancel) { pendingShare = nil }
            } message: {
                Text("Tween will capture your location once and use it to find a fair meetup spot.")
            }
        }
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Tokens.Palette.onSurfaceMuted.opacity(0.35))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    private var peekIdentity: some View {
        Text("Tween")
            .font(Tokens.Typography.headline)
            .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                withAnimation(Tokens.Motion.spring) {
                    if value.translation.height < -50 {
                        panelDetent = panelDetent.nextHigher
                    } else if value.translation.height > 50 {
                        panelDetent = panelDetent.nextLower
                    }
                }
            }
    }

    private static let peekHeight: CGFloat = 120

    private var panelHeight: CGFloat? {
        let screenHeight = UIScreen.main.bounds.height
        switch panelDetent {
        case .peek:
            return Self.peekHeight
        case .medium:
            return screenHeight * 0.45
        case .full:
            return screenHeight - 92
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        VStack(spacing: Tokens.Space.s2) {
            primaryCTA

            if savedCoordinate != nil {
                Button(action: leaveTween) {
                    Text("No longer in")
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .buttonStyle(.tweenSubtle)
                .disabled(isRequesting)
            }
        }
    }

    @ViewBuilder
    private var primaryCTA: some View {
        if savedCoordinate == nil {
            HStack(spacing: Tokens.Space.s2 + 2) {
                Image(systemName: "message.fill")
                    .foregroundStyle(Tokens.Palette.pinSelf)
                Text("Waiting for an iMessage “I'm in”")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        } else if peerCoordinate == nil {
            Button { pendingShare = .update } label: {
                HStack {
                    if isRequesting {
                        ProgressView().tint(.white)
                    }
                    Text("Share your location")
                }
            }
            .buttonStyle(.tweenPrimary)
            .disabled(isRequesting)
        } else {
            Button {
                withAnimation(Tokens.Motion.spring) {
                    panelDetent = .medium
                }
                searchFocused = true
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Find the fair spot")
                }
            }
            .buttonStyle(.tweenPrimary)
        }
    }

    private var categoryChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Space.s2) {
                ForEach(CategoryPreset.allCases) { preset in
                    Button {
                        searchText = preset.query
                        searchFocused = true
                    } label: {
                        HStack(spacing: Tokens.Space.s1 + 2) {
                            Image(systemName: preset.systemImage)
                            Text(preset.label)
                        }
                        .font(Tokens.Typography.callout.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.onSurface)
                        .padding(.horizontal, Tokens.Space.s3)
                        .padding(.vertical, Tokens.Space.s2)
                        .background(Tokens.Palette.surface, in: Capsule())
                        .overlay {
                            Capsule().stroke(Tokens.Palette.glassStroke, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var placeResultsList: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2 + 2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Places")
                        .font(Tokens.Typography.title)
                    Text(resultsSubtitle)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                }

                Spacer()

                Text("\(searchResults.count)")
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Tokens.Palette.onSurfaceMuted.opacity(0.12), in: Circle())
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Tokens.Space.s3) {
                    ForEach(Array(searchResults.enumerated()), id: \.element) { index, item in
                        placeResultRow(item: item, index: index)
                    }
                }
            }
            .frame(maxHeight: placeListHeight)
        }
    }

    private var waitingTab: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting")
                        .font(Tokens.Typography.title)
                    Text(waitingSubtitle)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                }
                Spacer()

                if !friends.isEmpty {
                    Text("\(friends.count)")
                        .font(Tokens.Typography.captionEmphasized)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Tokens.Palette.onSurfaceMuted.opacity(0.12), in: Circle())
                }

                Button(action: beginAdd) {
                    Image(systemName: "plus")
                        .font(Tokens.Typography.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Tokens.Palette.brand, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add person to wait on")
            }

            if friends.isEmpty {
                waitingEmptyState
            } else {
                friendList
                Button(action: imInForGroup) {
                    HStack {
                        if isRequesting { ProgressView().tint(.white) }
                        Text(savedCoordinate == nil ? "Share my location" : "I'm in")
                    }
                }
                .buttonStyle(.tweenPrimary)
                .disabled(isRequesting)
            }
        }
    }

    private var waitingEmptyState: some View {
        VStack(spacing: Tokens.Space.s3) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            Text("Add someone you're waiting on a reply from.")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
            Button(action: beginAdd) {
                Text("Add person")
            }
            .buttonStyle(.tweenPrimary)
        }
        .padding(.vertical, Tokens.Space.s4 + 2)
        .frame(maxWidth: .infinity)
    }

    private var friendList: some View {
        VStack(spacing: Tokens.Space.s2) {
            ForEach(friends) { friend in
                HStack(spacing: Tokens.Space.s2 + 2) {
                    Text(initials(for: friend))
                        .font(Tokens.Typography.captionEmphasized)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(color(for: friend), in: Circle())

                    Text(friend.name)
                        .font(Tokens.Typography.callout.weight(.semibold))

                    Spacer()

                    Menu {
                        Button("Rename") { beginRename(friend) }
                        Button("Delete", role: .destructive) { deleteFriend(friend) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(Tokens.Typography.callout.weight(.bold))
                            .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Manage \(friend.name)")
                }
                .padding(Tokens.Space.s2 + 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip + 2))
            }
        }
    }

    private var waitingSubtitle: String {
        if friends.isEmpty { return "Add the people you're waiting on" }
        if savedCoordinate == nil { return "Share your location to start" }
        if peerCoordinate == nil { return "Waiting on a reply" }
        return "You and a friend are \(distanceText) apart"
    }

    private var resultsSubtitle: String {
        if !rankedSpots.isEmpty { return "Sorted by fair travel time" }
        if savedCoordinate != nil || peerCoordinate != nil { return "Distances update as people join" }
        return "Tap a place to preview it on the map"
    }

    private var placeListHeight: CGFloat {
        switch panelDetent {
        case .peek:
            return 0
        case .medium:
            return 280
        case .full:
            return UIScreen.main.bounds.height - 230
        }
    }

    private func placeResultRow(item: MKMapItem, index: Int) -> some View {
        ResultRow(
            item: item,
            ranked: rankedSpot(for: item),
            isSelected: item == selectedPlace,
            isTopPick: index == 0 && rankedSpot(for: item) != nil,
            symbol: placeIcon(for: item),
            categoryTint: placeColor(for: item),
            typeLabel: placeTypeLabel(for: item),
            youDistance: distanceFrom(savedCoordinate, to: item),
            friendDistance: distanceFrom(peerCoordinate, to: item)
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .onTapGesture { selectPlaceOnMap(item) }
    }

    @ViewBuilder
    private var statusView: some View {
        switch provider.status {
        case .idle:
            if let savedCoordinate {
                Label(
                    formatCoordinate(latitude: savedCoordinate.latitude, longitude: savedCoordinate.longitude),
                    systemImage: "location.fill"
                )
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            }
        case .requesting:
            ProgressView("Getting your location…")
        case let .got(coordinate):
            Label(
                formatCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Tokens.Palette.success)
        case .denied:
            Label("Location access denied. Enable it in Settings to share your spot.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Palette.warning)
                .multilineTextAlignment(.center)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Palette.warning)
                .multilineTextAlignment(.center)
        }
    }

    private var isRequesting: Bool {
        if case .requesting = provider.status { return true }
        return false
    }

    private var buttonTitle: String {
        switch provider.status {
        case .got: "Update"
        case .denied, .failed: "Try again"
        default: "Update"
        }
    }

    private var headlineText: String {
        guard savedCoordinate != nil else { return "Say “I'm in” from Messages to show your dot" }
        guard peerCoordinate != nil else { return "Waiting for the other person" }
        return "Halfway ideas, \(distanceText) apart"
    }

    private var distanceText: String {
        guard let savedCoordinate, let peerCoordinate else { return "" }
        return formatDistance(from: savedCoordinate, to: peerCoordinate)
    }

    private var midpointCoordinate: CLLocationCoordinate2D? {
        guard let savedCoordinate, let peerCoordinate else { return nil }
        return CLLocationCoordinate2D(
            latitude: (savedCoordinate.latitude + peerCoordinate.latitude) / 2,
            longitude: (savedCoordinate.longitude + peerCoordinate.longitude) / 2
        )
    }

    private var displayPeerCoordinate: CLLocationCoordinate2D? {
        guard let peerCoordinate else { return nil }
        guard let savedCoordinate, sameCoordinate(savedCoordinate, peerCoordinate) else { return peerCoordinate }
        return CLLocationCoordinate2D(
            latitude: peerCoordinate.latitude + 0.002,
            longitude: peerCoordinate.longitude + 0.002
        )
    }

    private func updateMyDot() {
        provider.requestOnce { coordinate in
            guard let coordinate else { return }
            savedCoordinate = coordinate
            focusOnPeople()
        }
    }

    private func imInForGroup() {
        if savedCoordinate != nil {
            focusOnPeople()
            return
        }
        pendingShare = .initial
    }

    private func beginAdd() {
        editorName = ""
        editorMode = .add
    }

    private func beginRename(_ friend: TweenFriend) {
        editorName = friend.name
        editorMode = .rename(friend)
    }

    private func saveEditor() {
        let trimmed = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let mode = editorMode else { return }
        switch mode {
        case .add:
            friends.append(TweenFriend(name: trimmed))
        case .rename(let target):
            if let index = friends.firstIndex(where: { $0.id == target.id }) {
                friends[index].name = trimmed
            }
        }
        FriendRoster.save(friends)
        editorMode = nil
    }

    private func deleteFriend(_ friend: TweenFriend) {
        friends.removeAll { $0.id == friend.id }
        FriendRoster.save(friends)
    }

    private func initials(for friend: TweenFriend) -> String {
        let words = friend.name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private func color(for friend: TweenFriend) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]
        let bucket = abs(friend.id.uuidString.hashValue) % palette.count
        return palette[bucket]
    }

    private func selectPlaceOnMap(_ item: MKMapItem) {
        selectedPlace = item
        if let coordinate = item.placemark.location?.coordinate {
            centerMap(on: coordinate, avoidingBottomOverlay: true)
        }
        withAnimation(Tokens.Motion.spring) {
            panelDetent = .peek
        }
    }

    private func leaveTween() {
        LocationCache.clearAll()
        savedCoordinate = nil
        peerCoordinate = nil
        selectedPlace = nil
        searchResults = []
        searchError = nil
        provider = LocationProvider()
        withAnimation(Tokens.Motion.gentle) {
            position = .region(Self.defaultFramedRegion)
        }
    }

    private func setMapDisplayMode(_ mode: MapDisplayMode) {
        let preservedRegion = lastVisibleRegion
        withAnimation(Tokens.Motion.snappy) {
            mapDisplayMode = mode
        }
        restoreCamera(after: preservedRegion, refocusPlacesIfNeeded: true)
    }

    private func setTrafficVisible(_ isVisible: Bool) {
        let preservedRegion = lastVisibleRegion
        withAnimation(Tokens.Motion.snappy) {
            showsTraffic = isVisible
        }
        restoreCamera(after: preservedRegion, refocusPlacesIfNeeded: true)
    }

    private func restoreCamera(after region: MKCoordinateRegion, refocusPlacesIfNeeded: Bool = false) {
        position = .region(region)
        DispatchQueue.main.async {
            position = .region(region)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if refocusPlacesIfNeeded, !searchResults.isEmpty {
                focusOnPlacesAndPeople(animated: false)
            } else {
                position = .region(region)
            }
        }
    }

    private func resetMap() {
        if !searchResults.isEmpty {
            focusOnPlacesAndPeople()
        } else if savedCoordinate != nil || peerCoordinate != nil {
            focusOnPeople()
        } else {
            withAnimation(Tokens.Motion.gentle) {
                position = .region(Self.defaultFramedRegion)
            }
        }
    }

    private func prepareInitialMap() {
        refreshSavedLocation(forceFocus: true)
    }

    private func refreshSavedLocation(forceFocus: Bool = false) {
        friends = FriendRoster.load()
        let latestSaved = LocationCache.load()
        let latestPeer = LocationCache.loadPeer()
        let peerJustAppeared = peerCoordinate == nil && latestPeer != nil
        // Only mutate @State when the value actually changed. Optional<CLLocationCoordinate2D>
        // isn't Equatable, so SwiftUI can't dedupe identical writes — without these guards the
        // 1 s poll would re-render the Map every tick even when nothing moved.
        if !sameCoordinate(savedCoordinate, latestSaved) { savedCoordinate = latestSaved }
        if !sameCoordinate(peerCoordinate, latestPeer) { peerCoordinate = latestPeer }
        // The camera reframes only on explicit intent — first load (forceFocus) or the one-shot
        // moment a peer coordinate first appears. Routine poll-driven data refreshes must never
        // reassign `position` or the user's pan/zoom gets stomped.
        guard forceFocus || peerJustAppeared else { return }
        guard savedCoordinate != nil || peerCoordinate != nil else { return }
        focusOnPeople()
    }

    private func pollSharedLocations() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                refreshSavedLocation()
            }
        }
    }

    /// Gently pan to a coordinate at the user's *current* zoom — never shrink span.
    /// If the target is already inside the visible region with a 12 % inset, do nothing
    /// (the spot is already on-screen; re-assigning would re-animate the camera for no reason).
    private func centerMap(on coordinate: CLLocationCoordinate2D, avoidingBottomOverlay: Bool = false) {
        let span = lastVisibleRegion.span
        let insetMargin: Double = 0.12

        let latInset = span.latitudeDelta * insetMargin
        let lonInset = span.longitudeDelta * insetMargin
        let visibleCenter = lastVisibleRegion.center
        let halfLat = span.latitudeDelta / 2
        let halfLon = span.longitudeDelta / 2

        let alreadyVisible =
            abs(coordinate.latitude - visibleCenter.latitude) <= (halfLat - latInset) &&
            abs(coordinate.longitude - visibleCenter.longitude) <= (halfLon - lonInset)
        if alreadyVisible { return }

        let adjustedCenter = avoidingBottomOverlay
            ? CLLocationCoordinate2D(
                latitude: coordinate.latitude - span.latitudeDelta * 0.20,
                longitude: coordinate.longitude
            )
            : coordinate

        withAnimation(Tokens.Motion.spring) {
            position = .region(MKCoordinateRegion(center: adjustedCenter, span: span))
        }
    }

    private func focusOnPeople() {
        let coordinates = [savedCoordinate, displayPeerCoordinate].compactMap { $0 }
        guard let region = framedRegion(for: coordinates) else { return }
        withAnimation(Tokens.Motion.spring) {
            position = .region(region)
        }
    }

    private func searchPlaces() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        searchError = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest]
        if let region = region(containing: [savedCoordinate, displayPeerCoordinate].compactMap { $0 }, padding: 1.4, minimumDelta: 0.04) {
            request.region = region
        }

        let a = savedCoordinate
        let b = peerCoordinate

        Task {
            do {
                let response = try await MKLocalSearch(request: request).start()
                let items = Array(response.mapItems.prefix(6))
                await MainActor.run {
                    searchResults = items
                    rankedSpots = []
                    selectedPlace = items.first
                    searchError = items.isEmpty ? "No places found nearby" : nil
                    panelDetent = .medium
                    focusOnPlacesAndPeople()
                }
                // Fairness ranking needs both endpoints. If we have them, replace the
                // raw search order with drive-time fairness; otherwise leave as is.
                guard let a, let b, !items.isEmpty else { return }
                let ranked = await FairnessRanker.rank(candidates: items, from: a, and: b)
                await MainActor.run {
                    rankedSpots = ranked
                    let rankedItems = ranked.map(\.item)
                    let unranked = items.filter { item in !rankedItems.contains(where: { $0 == item }) }
                    searchResults = rankedItems + unranked
                    selectedPlace = searchResults.first
                }
            } catch {
                await MainActor.run {
                    searchResults = []
                    rankedSpots = []
                    selectedPlace = nil
                    searchError = "Search failed"
                }
            }
        }
    }

    private func rankedSpot(for item: MKMapItem) -> RankedSpot? {
        rankedSpots.first { $0.item == item }
    }

    private func focusOnPlacesAndPeople(animated: Bool = true) {
        var coordinates = [savedCoordinate, displayPeerCoordinate].compactMap { $0 }
        coordinates.append(contentsOf: searchResults.compactMap { $0.placemark.location?.coordinate })
        guard let region = framedRegion(for: coordinates, paddingFactor: 0.4, minimumDelta: 0.025) else { return }
        guard animated else {
            position = .region(region)
            return
        }
        withAnimation(Tokens.Motion.spring) {
            position = .region(region)
        }
    }

    private func region(
        containing coordinates: [CLLocationCoordinate2D],
        padding: Double,
        minimumDelta: CLLocationDegrees
    ) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        let minLatitude = coordinates.map(\.latitude).min() ?? first.latitude
        let maxLatitude = coordinates.map(\.latitude).max() ?? first.latitude
        let minLongitude = coordinates.map(\.longitude).min() ?? first.longitude
        let maxLongitude = coordinates.map(\.longitude).max() ?? first.longitude

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * padding, minimumDelta),
                longitudeDelta: max((maxLongitude - minLongitude) * padding, minimumDelta)
            )
        )
    }

    /// Camera-framing: union the coordinates into an MKMapRect, expand uniformly so no pin
    /// sits on the edge, then shift the center upward by a fraction of the latitude span so
    /// content stays clear of the draggable bottom panel.
    private func framedRegion(
        for coordinates: [CLLocationCoordinate2D],
        paddingFactor: Double = 0.5,
        minimumDelta: CLLocationDegrees = 0.015
    ) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let inset = -max(rect.size.width, rect.size.height) * paddingFactor
        rect = rect.insetBy(dx: inset, dy: inset)
        var region = MKCoordinateRegion(rect)
        region.span.latitudeDelta = max(region.span.latitudeDelta, minimumDelta)
        region.span.longitudeDelta = max(region.span.longitudeDelta, minimumDelta)
        region.center.latitude -= region.span.latitudeDelta * sheetBottomInsetFraction
        return region
    }

    /// Fraction of the framed region's latitude span the center shifts upward by, so the
    /// content stays above the bottom panel. Adapts to the panel detent — bigger sheet,
    /// bigger shift.
    private var sheetBottomInsetFraction: Double {
        switch panelDetent {
        case .peek:   0
        case .medium: 0.20
        case .full:   0.32
        }
    }

    private func distanceFrom(_ coordinate: CLLocationCoordinate2D?, to item: MKMapItem) -> String? {
        guard let coordinate, let destination = item.placemark.location?.coordinate else { return nil }
        return formatDistance(from: coordinate, to: destination)
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) min"
    }

    private func sameCoordinate(_ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.latitude - rhs.latitude) < 0.000001 && abs(lhs.longitude - rhs.longitude) < 0.000001
        default:
            return false
        }
    }

    private func placeDot(item: MKMapItem) -> some View {
        let isSelected = item == selectedPlace
        return ZStack {
            Circle()
                .fill((isSelected ? placeColor(for: item) : Color.white).opacity(0.95))
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.22), radius: 7, y: 3)
            Image(systemName: placeIcon(for: item))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isSelected ? .white : placeColor(for: item))
                .padding(7)
                .background(isSelected ? placeColor(for: item) : Color.clear, in: Circle())
        }
    }

    private func placeAnnotation(item: MKMapItem) -> some View {
        VStack(spacing: 5) {
            if let bubbleText = placeDistanceBubble(for: item) {
                Text(bubbleText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                    }
            }
            placeDot(item: item)
        }
    }

    private func placeDistanceBubble(for item: MKMapItem) -> String? {
        guard savedCoordinate != nil || peerCoordinate != nil else { return nil }
        let you = distanceFrom(savedCoordinate, to: item) ?? "--"
        let friend = distanceFrom(peerCoordinate, to: item) ?? "--"
        return "A \(you) · B \(friend)"
    }

    private func placeIcon(for item: MKMapItem) -> String {
        let category = placeCategoryText(for: item)
        if category.contains("coffee") || category.contains("cafe") || category.contains("starbucks") {
            return "cup.and.saucer.fill"
        }
        if category.contains("restaurant") || category.contains("food") || category.contains("pizza") || category.contains("bakery") {
            return "fork.knife"
        }
        if category.contains("park") || category.contains("recreation") || category.contains("trail") {
            return "tree.fill"
        }
        if category.contains("movie") || category.contains("theater") || category.contains("museum") || category.contains("entertainment") {
            return "ticket.fill"
        }
        if category.contains("fitness") || category.contains("gym") || category.contains("sports") {
            return "figure.run"
        }
        if category.contains("store") || category.contains("shop") || category.contains("market") {
            return "bag.fill"
        }
        if category.contains("hotel") {
            return "bed.double.fill"
        }
        if category.contains("transport") || category.contains("station") || category.contains("airport") {
            return "tram.fill"
        }
        return "mappin.circle.fill"
    }

    private func placeColor(for item: MKMapItem) -> Color {
        let category = placeCategoryText(for: item)
        if category.contains("coffee") || category.contains("cafe") || category.contains("starbucks") {
            return .brown
        }
        if category.contains("restaurant") || category.contains("food") || category.contains("pizza") || category.contains("bakery") {
            return .orange
        }
        if category.contains("park") || category.contains("recreation") || category.contains("trail") {
            return .green
        }
        if category.contains("movie") || category.contains("theater") || category.contains("museum") || category.contains("entertainment") {
            return .purple
        }
        if category.contains("fitness") || category.contains("gym") || category.contains("sports") {
            return .mint
        }
        if category.contains("store") || category.contains("shop") || category.contains("market") {
            return .pink
        }
        if category.contains("transport") || category.contains("station") || category.contains("airport") {
            return .indigo
        }
        return .blue
    }

    private func placeTypeLabel(for item: MKMapItem) -> String {
        let category = placeCategoryText(for: item)
        if category.contains("coffee") || category.contains("cafe") || category.contains("starbucks") {
            return "Coffee"
        }
        if category.contains("restaurant") || category.contains("food") || category.contains("pizza") || category.contains("bakery") {
            return "Food"
        }
        if category.contains("park") || category.contains("recreation") || category.contains("trail") {
            return "Recreation"
        }
        if category.contains("movie") || category.contains("theater") || category.contains("museum") || category.contains("entertainment") {
            return "Entertainment"
        }
        if category.contains("fitness") || category.contains("gym") || category.contains("sports") {
            return "Fitness"
        }
        if category.contains("store") || category.contains("shop") || category.contains("market") {
            return "Shopping"
        }
        if category.contains("transport") || category.contains("station") || category.contains("airport") {
            return "Transit"
        }
        return "Place"
    }

    private func placeCategoryText(for item: MKMapItem) -> String {
        [item.pointOfInterestCategory?.rawValue, item.name]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }
}

private enum MapDisplayMode: String, CaseIterable, Identifiable {
    case standard
    case satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Map"
        case .satellite: "Satellite"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .satellite: "map.fill"
        }
    }
}

private enum HomePanelTab: String, CaseIterable, Identifiable {
    case map
    case waiting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: "Map"
        case .waiting: "Waiting"
        }
    }

    var systemImage: String {
        switch self {
        case .map: "map"
        case .waiting: "hourglass"
        }
    }
}

private enum ShareIntent: Identifiable {
    case initial
    case update

    var id: String { String(describing: self) }
}

/// Google-Maps-style category presets. Phase-2 scope is UI-only — tapping a chip pre-fills
/// the search field but does not trigger `searchPlaces()`. Wiring lands in a later slice.
private enum CategoryPreset: String, CaseIterable, Identifiable {
    case coffee, food, drinks, gas, parks, movies, fitness

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coffee:  return "Coffee"
        case .food:    return "Food"
        case .drinks:  return "Drinks"
        case .gas:     return "Gas"
        case .parks:   return "Parks"
        case .movies:  return "Movies"
        case .fitness: return "Fitness"
        }
    }

    var query: String {
        switch self {
        case .coffee:  return "coffee"
        case .food:    return "restaurant"
        case .drinks:  return "bar"
        case .gas:     return "gas station"
        case .parks:   return "park"
        case .movies:  return "movie theater"
        case .fitness: return "gym"
        }
    }

    var systemImage: String {
        switch self {
        case .coffee:  return "cup.and.saucer.fill"
        case .food:    return "fork.knife"
        case .drinks:  return "wineglass.fill"
        case .gas:     return "fuelpump.fill"
        case .parks:   return "tree.fill"
        case .movies:  return "film.fill"
        case .fitness: return "figure.run"
        }
    }
}

private enum FriendEditor: Identifiable {
    case add
    case rename(TweenFriend)

    var id: String {
        switch self {
        case .add: "add"
        case .rename(let friend): friend.id.uuidString
        }
    }

    var alertTitle: String {
        switch self {
        case .add: "Add friend"
        case .rename: "Rename friend"
        }
    }
}

private enum PanelDetent {
    case peek
    case medium
    case full

    var nextHigher: PanelDetent {
        switch self {
        case .peek: .medium
        case .medium: .full
        case .full: .full
        }
    }

    var nextLower: PanelDetent {
        switch self {
        case .peek: .peek
        case .medium: .peek
        case .full: .medium
        }
    }
}

/// Simplified search-result row: category symbol pill, name, type label, dual-ETA chip.
/// The whole row is tappable (handled by the caller); selection state shifts to a
/// brand-tinted background + thin brand border.
private struct ResultRow: View {
    let item: MKMapItem
    let ranked: RankedSpot?
    let isSelected: Bool
    let isTopPick: Bool
    let symbol: String
    let categoryTint: Color
    let typeLabel: String
    let youDistance: String?
    let friendDistance: String?

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s3) {
            ZStack {
                Circle()
                    .fill(isTopPick ? Tokens.Palette.brand : categoryTint)
                Image(systemName: symbol)
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "Place")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.onSurface)
                    .lineLimit(1)
                Text(typeLabel)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: Tokens.Space.s2)

            if let ranked {
                ETAChip(
                    selfValue: formatETA(ranked.etaFromA),
                    friendValue: formatETA(ranked.etaFromB),
                    isBalanced: isBalanced(ranked)
                )
            } else {
                ETAChip(
                    selfValue: youDistance ?? "—",
                    friendValue: friendDistance ?? "—",
                    isBalanced: false
                )
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s3)
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

    private func formatETA(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes)m"
    }

    private func isBalanced(_ spot: RankedSpot) -> Bool {
        spot.fairnessGap < 0.2 * max(spot.worseETA, 1)
    }
}

/// Dual-pill capsule showing the self ETA and the friend ETA. Tinted with the brand-muted
/// background when the row is balanced — the signal that this spot is a fair midpoint.
private struct ETAChip: View {
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

#Preview {
    OnboardingView()
}
