//
//  OnboardingView.swift
//  TweenApp
//

import CoreLocation
import Contacts
import MapKit
import Combine
import MessageUI
import SwiftUI
import UIKit

/// Map-first home screen: capture the user's current location once and cache it to the shared
/// App Group container for the extension to reuse.
struct OnboardingView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var provider = LocationProvider()
    @State private var savedCoordinate = LocationCache.load()
    @State private var peerCoordinate = LocationCache.loadPeer()
    @State private var isUserIn = LocationCache.isActive()
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var rankedSpots: [RankedSpot] = []
    @State private var selectedPlace: MKMapItem?
    @State private var searchError: String?
    @State private var panelDetent: PanelDetent = .medium
    @State private var panelTab: HomePanelTab = .map
    @State private var position: MapCameraPosition
    @State private var lastVisibleRegion: MKCoordinateRegion
    @State private var livePanelHeight: CGFloat?
    @State private var panelDragStartHeight: CGFloat?
    @State private var userClearedLocation = false
    @State private var requestedPlaceScrollID: String?
    @State private var keyboardHeight: CGFloat = 0

    /// The country-level fallback region used on a fresh launch (no cached coordinate)
    /// and as the seed for `lastVisibleRegion` before the user pans. Continental US.
    fileprivate static let defaultFramedRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
        span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 55)
    )

    /// Neighbourhood-scale span used when we open at the user's cached location.
    private static let neighbourhoodSpan = MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)

    init() {
        let cached = LocationCache.load()
        let initialRegion = cached.map {
            MKCoordinateRegion(center: $0, span: Self.neighbourhoodSpan)
        } ?? Self.defaultFramedRegion
        _position = State(initialValue: .region(initialRegion))
        _lastVisibleRegion = State(initialValue: initialRegion)
    }
    @State private var mapDisplayMode: MapDisplayMode = .standard
    @State private var showsTraffic = false
    @State private var friends: [TweenFriend] = FriendRoster.load()
    @State private var editorMode: FriendEditor?
    @State private var editorName: String = ""
    @State private var showContactSearch = false
    @State private var pendingPing: MessagePing?
    @State private var pingError: String?
    @State private var copyConfirmation: String?
    @State private var pendingShare: ShareIntent?
    @State private var detailItem: MKMapItem?
    @State private var selectedCategory: CategoryPreset?
    @State private var showTutorial = !OnboardingFlags.hasSeenOnboarding
    @State private var showShareSheet = false
    @State private var monitor = NetworkMonitor()
    @State private var pingTick = Date()
    @State private var lastReplyAt: Date? = PingLog.lastIncomingReplyAt
    @State private var searchTask: Task<Void, Never>?
    @StateObject private var searchCompleter = SearchCompleter()
    @State private var isSearchActive = false
    @State private var panelContentRevision = 0
    @FocusState private var searchFocused: Bool
    @Namespace private var spotTransition
    @State private var didApplyDebugLaunchState = false

    var body: some View {
        ZStack(alignment: .top) {
            styledMap
                .ignoresSafeArea()
                .simultaneousGesture(mapCollapseGesture)

            VStack {
                HStack {
                    Spacer()
                    mapControls
                }
                .padding(.top, Tokens.Space.s8 + Tokens.Space.s5)
                .padding(.horizontal, Tokens.Space.s4)
                Spacer()
            }

            NativePanelSheet(panelDetent: $panelDetent, contentRevision: $panelContentRevision) {
                bottomPanel
            }
            .id(panelContentRevision)

            if showTutorial {
                tutorialOverlay
            }
        }
        .onAppear {
            prepareInitialMap()
            applyDebugLaunchStateIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshSavedLocation()
        }
        .task {
            await pollSharedLocations()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onChange(of: searchFocused) { _, focused in
            guard focused else { return }
            isSearchActive = true
            refreshPanelContent()
            withAnimation(Tokens.Motion.spring) {
                panelDetent = .full
                livePanelHeight = nil
                panelDragStartHeight = nil
            }
        }
        .onReceive(searchCompleter.$suggestions) { _ in
            refreshPanelContent()
        }
        .alert(
            "Can't send ping",
            isPresented: Binding(
                get: { pingError != nil },
                set: { if !$0 { pingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { pingError = nil }
        } message: {
            Text(pingError ?? "")
        }
        .alert(
            "Copied",
            isPresented: Binding(
                get: { copyConfirmation != nil },
                set: { if !$0 { copyConfirmation = nil } }
            )
        ) {
            Button("OK", role: .cancel) { copyConfirmation = nil }
        } message: {
            Text(copyConfirmation ?? "")
        }
    }

    private var mapCanvas: some View {
        Map(position: $position, bounds: MapCameraBounds(minimumDistance: 200, maximumDistance: 2_000_000)) {
                if let coordinate = savedCoordinate {
                    Annotation("You", coordinate: coordinate) {
                        TweenPin(role: isUserIn ? .selfActive : .selfDot)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                if let displayPeerCoordinate {
                    Annotation("Friend", coordinate: displayPeerCoordinate) {
                        TweenPin(role: .friend)
                            .transition(.scale.combined(with: .opacity))
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
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                ForEach(searchResults, id: \.self) { item in
                    if let coordinate = item.placemark.location?.coordinate {
                        Annotation(item.name ?? "Place", coordinate: coordinate) {
                            Button {
                                selectPlaceFromMap(item)
                            } label: {
                                placeAnnotation(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name ?? "Place")
                            .accessibilityIdentifier("map-place-\(item.name ?? "Place")")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                lastVisibleRegion = context.region
            }
            .animation(Tokens.Motion.spring, value: searchResults.count)
            .animation(Tokens.Motion.spring, value: savedCoordinate?.latitude)
            .animation(Tokens.Motion.spring, value: displayPeerCoordinate?.latitude)
            .animation(Tokens.Motion.spring, value: rankedSpots.first?.item.hash)
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

    private var topSearchStack: some View {
        VStack(spacing: Tokens.Space.s2) {
            searchBar
            categoryChipRow
        }
        .padding(.top, Tokens.Space.s3)
    }

    private var searchBar: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            TextField("Search coffee, lunch, parks...", text: $searchText)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { commitSearch() }
                .toolbar {
                    ToolbarItem(placement: .keyboard) {
                        if searchFocused {
                            keyboardPanelPicker
                        }
                    }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                    rankedSpots = []
                    selectedPlace = nil
                    searchError = nil
                    searchCompleter.queryFragment = ""
                    if isSearchActive || searchFocused {
                        isSearchActive = true
                        refreshPanelContent()
                        withAnimation(Tokens.Motion.spring) { panelDetent = .full }
                    } else {
                        panelDetent = .medium
                        focusOnPeople()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                }
                .accessibilityLabel("Clear search")
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .frame(height: 48)
        .contentShape(Rectangle())
        .tweenGlass(cornerRadius: Tokens.Radius.chip)
        .onTapGesture {
            isSearchActive = true
            refreshPanelContent()
            searchFocused = true
            if panelDetent == .peek {
                withAnimation(Tokens.Motion.spring) { panelDetent = .medium }
            }
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isSearchActive = true
            }
            refreshPanelContent()
            updateSearchSuggestions(for: newValue)
        }
    }

    /// Updates lightweight Apple-Maps-style suggestions while typing. Full place search only
    /// happens when the user submits or taps a suggestion.
    private func updateSearchSuggestions(for input: String) {
        searchTask?.cancel()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            rankedSpots = []
            selectedPlace = nil
            searchError = nil
            searchCompleter.queryFragment = ""
            refreshPanelContent()
            return
        }
        isSearchActive = true
        searchResults = []
        rankedSpots = []
        selectedPlace = nil
        detailItem = nil
        searchError = nil
        refreshPanelContent()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = []
                rankedSpots = []
                selectedPlace = nil
                detailItem = nil
                searchError = nil
                searchCompleter.region = activeSearchRegion
                searchCompleter.queryFragment = trimmed
                refreshPanelContent()
            }
        }
    }

    private var mapControls: some View {
        VStack(spacing: Tokens.Space.s2 + 2) {
            Menu {
                ForEach(MapDisplayMode.allCases) { mode in
                    Button {
                        setMapDisplayMode(mode)
                    } label: {
                        Label(mode.title, systemImage: mapDisplayMode == mode ? "checkmark" : mode.systemImage)
                    }
                }
            } label: {
                mapControlLabel(
                    icon: mapDisplayMode.systemImage,
                    text: mapDisplayMode == .satellite ? "Sat" : "Map",
                    isActive: false,
                    iconValue: mapDisplayMode
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map style. Current: \(mapDisplayMode.title)")

            Button {
                setTrafficVisible(!showsTraffic)
            } label: {
                mapControlLabel(
                    icon: showsTraffic ? "car.fill" : "car",
                    text: "Traffic",
                    isActive: showsTraffic,
                    iconValue: showsTraffic
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsTraffic ? "Hide traffic" : "Show traffic")

            Divider()
                .frame(width: 28)

            Button(action: resetMap) {
                mapControlLabel(
                    icon: "location.north.line.fill",
                    text: "Reset",
                    isActive: false,
                    iconValue: searchResults.count
                )
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

    private func mapControlLabel(
        icon: String,
        text: String,
        isActive: Bool,
        iconValue: some Hashable
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(Tokens.Typography.headline)
                .foregroundStyle(isActive ? .white : Tokens.Palette.onSurface)
                .symbolEffect(.bounce, value: iconValue)
            Text(text)
                .font(Tokens.Typography.caption.weight(.semibold))
                .foregroundStyle(isActive ? .white : Tokens.Palette.onSurfaceMuted)
        }
        .frame(width: 46, height: 46)
        .background(isActive ? Tokens.Palette.brand : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
    }

    private var bottomPanel: some View {
        let isShowingDetail = panelTab == .map && detailItem != nil

        return VStack(alignment: .leading, spacing: 0) {
            sheetHeader
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.top, searchResults.isEmpty ? Tokens.Space.s3 : Tokens.Space.s2)

            if panelDetent == .peek {
                peekSummary
                    .padding(.horizontal, Tokens.Space.s5)
                    .padding(.bottom, Tokens.Space.s4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s3 + 2) {
                            if !monitor.isOnline {
                                offlineBanner
                            }

                            if isSearchModeVisible && !isShowingDetail {
                                Color.clear
                                    .frame(height: Tokens.Space.s4)
                            }

                            if !isShowingDetail {
                                searchBar
                                    .id("sheet-search")
                                categoryChipRow
                                searchSuggestionsList
                            }

                            if !isSearchModeVisible && !isShowingDetail {
                                panelTitleRow
                                panelPicker
                            }

                            if panelDetent != .full, panelTab == .map, !isShowingDetail {
                                statusView
                            }

                            if !isSearchModeVisible {
                                panelContent
                            }
                        }
                        .padding(.horizontal, Tokens.Space.s5)
                        .padding(.top, Tokens.Space.s2)
                        .padding(.bottom, scrollContentBottomPadding)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .animation(nil, value: panelTab)
                    .onChange(of: requestedPlaceScrollID) { _, id in
                        guard let id else { return }
                        withAnimation(Tokens.Motion.spring) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChange(of: searchFocused) { _, focused in
                        guard focused else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo("sheet-search", anchor: .top)
                        }
                    }
                }

                if shouldShowActionControls {
                    VStack(spacing: 0) {
                        Divider()
                            .opacity(0.35)
                        actionControls
                            .padding(.horizontal, Tokens.Space.s5)
                            .padding(.top, Tokens.Space.s3)
                            .padding(.bottom, bottomSafeAreaInset + Tokens.Space.s3)
                    }
                    .background(.regularMaterial)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Tokens.Motion.spring, value: monitor.isOnline)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [Self.inviteMessage])
        }
        .sheet(isPresented: $showContactSearch) {
            ContactSearchSheet(
                existingFriends: friends,
                onSelect: addContactFriend,
                onCancel: { showContactSearch = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingPing) { ping in
            MessageComposeSheet(
                recipients: [ping.recipient],
                body: ping.body,
                onFinish: {
                    pendingPing = nil
                }
            )
        }
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
        .sheet(item: $pendingShare) { _ in
            LocationShareSheet(
                onShare: {
                    pendingShare = nil
                    updateMyDot()
                },
                onCancel: { pendingShare = nil }
            )
            .presentationDetents([.height(440)])
            .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.selection, trigger: detailItem)
        .sensoryFeedback(.impact(weight: .light), trigger: selectedPlace)
    }

    private var sheetHeader: some View {
        HStack(spacing: Tokens.Space.s2) {
            Color.clear
                .frame(width: 40, height: 40)

            Spacer()

            dragZone

            Spacer()

            if searchFocused {
                Color.clear
                    .frame(width: 40, height: 40)
            } else {
                Button(action: togglePanelDetent) {
                    Image(systemName: panelDetent == .full ? "chevron.down" : "chevron.up")
                        .font(Tokens.Typography.headline.weight(.bold))
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        .frame(width: 40, height: 40)
                        .background(Tokens.Palette.surface.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(panelDetent == .full ? "Collapse sheet" : "Expand sheet")
            }
        }
        .frame(height: 54)
    }

    private var panelTitleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Tween")
                    .font(Tokens.Typography.display)
                Text(headlineText)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                withAnimation(Tokens.Motion.spring) { showTutorial = true }
            } label: {
                Image(systemName: "info.circle")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About Tween")

            Image(systemName: isUserIn ? "checkmark.circle.fill" : "location.circle.fill")
                .font(Tokens.Typography.title)
                .foregroundStyle(isUserIn ? Tokens.Palette.success : Tokens.Palette.pinSelf)
        }
    }

    private var panelPicker: some View {
        Picker("View", selection: $panelTab) {
            ForEach(HomePanelTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: panelTab) { _, tab in
            guard tab == .waiting else { return }
            isSearchActive = false
            searchFocused = false
            refreshPanelContent()
        }
    }

    private var keyboardPanelPicker: some View {
        HStack(spacing: 0) {
            keyboardPanelButton(.map)
            keyboardPanelButton(.waiting)
        }
        .padding(4)
        .frame(width: max(0, UIScreen.main.bounds.width - 40), height: 50)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map and Waiting tabs")
    }

    private func keyboardPanelButton(_ tab: HomePanelTab) -> some View {
        let isSelected = panelTab == tab

        return Button {
            withAnimation(Tokens.Motion.spring) {
                panelTab = tab
                if tab == .waiting {
                    isSearchActive = false
                    searchFocused = false
                }
                refreshPanelContent()
            }
        } label: {
            Text(tab.title)
                .font(Tokens.Typography.headline.weight(.semibold))
                .foregroundStyle(isSelected ? Tokens.Palette.onSurface : Tokens.Palette.onSurfaceMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                        .fill(isSelected ? Tokens.Palette.onSurface.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panelTab {
        case .map:
            if let detailItem {
                SpotDetail(
                    item: detailItem,
                    ranked: rankedSpot(for: detailItem),
                    symbol: placeIcon(for: detailItem),
                    categoryTint: placeColor(for: detailItem),
                    typeLabel: placeTypeLabel(for: detailItem),
                    youDistance: distanceFrom(savedCoordinate, to: detailItem),
                    friendDistance: distanceFrom(peerCoordinate, to: detailItem),
                    namespace: spotTransition,
                    onShowOnMap: { showOnMap(detailItem) },
                    onSendToChat: { sendToChat(detailItem) },
                    onCopyLink: { copyLink(for: detailItem) },
                    onOpenInAppleMaps: { openInAppleMaps(detailItem) },
                    onOpenInGoogleMaps: { openInGoogleMaps(detailItem) },
                    onClose: closeDetail
                )
            } else if !searchResults.isEmpty {
                placeResultsList
            } else if searchError != nil {
                searchErrorCard
            } else if savedCoordinate == nil && peerCoordinate == nil {
                freshLaunchHero
            } else {
                EmptyView()
            }
        case .waiting:
            waitingTab
        }
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Tokens.Palette.onSurfaceMuted.opacity(0.35))
            .frame(width: 42, height: 5)
    }

    private var dragZone: some View {
        dragHandle
            .frame(width: 150, height: 48)
            .contentShape(Rectangle())
            .onTapGesture(perform: togglePanelDetent)
    }

    private var shouldShowActionControls: Bool {
        !isSearchModeVisible &&
        !searchFocused &&
        panelDetent != .full &&
        panelTab == .map &&
        detailItem == nil &&
        searchResults.isEmpty &&
        searchError == nil
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchModeVisible: Bool {
        guard panelTab == .map else { return false }
        if isSearchActive || searchFocused { return true }
        return !trimmedSearchText.isEmpty && searchResults.isEmpty && detailItem == nil
    }

    private func refreshPanelContent() {
        panelContentRevision &+= 1
    }

    private var scrollContentBottomPadding: CGFloat {
        let keyboardPadding = keyboardHeight > 0 ? keyboardHeight + Tokens.Space.s4 : 0
        let basePadding = shouldShowActionControls ? Tokens.Space.s3 : bottomSafeAreaInset + Tokens.Space.s4
        return max(basePadding, keyboardPadding)
    }

    private func togglePanelDetent() {
        withAnimation(Tokens.Motion.spring) {
            switch panelDetent {
            case .peek:
                panelDetent = .medium
            case .medium:
                panelDetent = .full
            case .full:
                isSearchActive = false
                searchFocused = false
                detailItem = nil
                panelTab = .map
                panelDetent = .peek
            }
        }
        refreshPanelContent()
    }

    private func collapsePanelForMapInteraction() {
        guard searchFocused || isSearchActive || panelDetent != .peek || livePanelHeight != nil else { return }

        withAnimation(Tokens.Motion.spring) {
            searchFocused = false
            isSearchActive = false
            detailItem = nil
            panelTab = .map
            panelDetent = .peek
            livePanelHeight = nil
            panelDragStartHeight = nil
        }
        refreshPanelContent()
    }

    private var offlineBanner: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Tokens.Palette.warning)
            Text("Offline — search needs a connection")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.onSurface)
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                .stroke(Tokens.Palette.warning.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var inviteFriendsRow: some View {
        Button {
            showShareSheet = true
        } label: {
            HStack(spacing: Tokens.Space.s3) {
                ZStack {
                    Circle().fill(Tokens.Palette.brandMuted)
                    Image(systemName: "person.badge.plus")
                        .font(Tokens.Typography.callout.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.brand)
                }
                .frame(width: 36, height: 36)
                Text("Invite friends to Tween")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.onSurface)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Tokens.Typography.iconBadge)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
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
        .accessibilityLabel("Invite friends to Tween")
    }

    @ViewBuilder
    private var peekSummary: some View {
        if let item = selectedPlace, let ranked = rankedSpot(for: item) {
            HStack(spacing: Tokens.Space.s2) {
                ZStack {
                    Circle().fill(Tokens.Palette.brand)
                    Image(systemName: "star.fill")
                        .font(Tokens.Typography.iconBadge)
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
                Text(item.name ?? "Picked spot")
                    .font(Tokens.Typography.captionEmphasized)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Space.s2)
                ETAChip(
                    selfValue: formatPeekETA(ranked.etaFromA),
                    friendValue: formatPeekETA(ranked.etaFromB),
                    isBalanced: ranked.fairnessGap < 0.2 * max(ranked.worseETA, 1)
                )
            }
            .padding(.horizontal, Tokens.Space.s2)
        } else if savedCoordinate != nil && peerCoordinate != nil {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Tokens.Palette.brand)
                Text("Tap to find a fair spot")
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurface)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(Tokens.Typography.iconBadge)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            }
            .padding(.horizontal, Tokens.Space.s3)
        } else if savedCoordinate != nil {
            HStack(spacing: Tokens.Space.s2) {
                Circle()
                    .fill(Tokens.Palette.pinSelf)
                    .frame(width: 8, height: 8)
                Text("Waiting for a reply")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                Spacer()
                Text("Tween")
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            }
            .padding(.horizontal, Tokens.Space.s3)
        } else {
            HStack(spacing: Tokens.Space.s2) {
                Text("Tween")
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                Text("· tap to start")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func formatPeekETA(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes)m"
    }

    private var mapCollapseGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { _ in
                collapsePanelForMapInteraction()
            }
    }

    private static let peekHeight: CGFloat = 120

    private var panelInteractiveHeight: CGFloat {
        livePanelHeight ?? height(for: panelDetent)
    }

    private var panelHeight: CGFloat? {
        height(for: panelDetent)
    }

    private func height(for detent: PanelDetent) -> CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        switch detent {
        case .peek:
            return Self.peekHeight
        case .medium:
            if detailItem != nil { return screenHeight * 0.62 }
            if !searchResults.isEmpty { return screenHeight * 0.58 }
            return screenHeight * 0.48
        case .full:
            if keyboardHeight > 0 {
                return min(screenHeight * 0.68, keyboardHeight + 420)
            }
            return screenHeight - 120
        }
    }

    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    private func updateKeyboardHeight(from notification: Notification) {
        guard
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }

        let screenHeight = UIScreen.main.bounds.height
        let height = max(0, screenHeight - endFrame.minY)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25

        withAnimation(.easeOut(duration: duration)) {
            keyboardHeight = height
            if height > 0, searchFocused {
                panelDetent = .full
                livePanelHeight = nil
                panelDragStartHeight = nil
            }
        }
    }

    private func nearestPanelDetent(to height: CGFloat) -> PanelDetent {
        PanelDetent.allCases.min {
            abs(self.height(for: $0) - height) < abs(self.height(for: $1) - height)
        } ?? panelDetent
    }

    private func clampedPanelHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, self.height(for: .peek)), self.height(for: .full))
    }

    @ViewBuilder
    private var actionControls: some View {
        VStack(spacing: Tokens.Space.s2) {
            primaryCTA
                .animation(Tokens.Motion.spring, value: isRequesting)
                .animation(Tokens.Motion.spring, value: savedCoordinate?.latitude)
                .animation(Tokens.Motion.spring, value: peerCoordinate?.latitude)
        }
    }

    @ViewBuilder
    private var primaryCTA: some View {
        if !isUserIn {
            Button(action: updateMyDot) {
                HStack(spacing: Tokens.Space.s2) {
                    if isRequesting {
                        ProgressView()
                            .tint(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text("I'm in")
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(.tweenPrimary)
            .disabled(isRequesting)
        } else if peerCoordinate == nil {
            Button(action: leaveTween) {
                HStack(spacing: Tokens.Space.s2) {
                    if isRequesting {
                        ProgressView()
                            .tint(Tokens.Palette.brand)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text("No longer in")
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(.tweenSubtle)
            .disabled(isRequesting)
        } else {
            Button {
                withAnimation(Tokens.Motion.spring) {
                    panelDetent = .medium
                }
                searchFocused = true
            } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.bounce, value: peerCoordinate?.latitude)
                    Text("Find the fair spot")
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(.tweenPrimary)
        }
    }

    private var freshLaunchHero: some View {
        VStack(spacing: Tokens.Space.s2) {
            ZStack {
                Circle()
                    .fill(Tokens.Palette.brandMuted)
                Image(systemName: "star.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Tokens.Palette.brand)
            }
            .frame(width: 48, height: 48)

            Text("Where do you want to meet?")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.onSurface)
                .multilineTextAlignment(.center)

            Text("Share your location to start, or pick a category.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, Tokens.Space.s3)
        .frame(maxWidth: .infinity)
    }

    private var locationDeniedCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2 + 2) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Tokens.Palette.warning)
                Text("Location turned off")
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurface)
            }
            Text("Tween needs your location to find a fair meetup spot. Re-enable it in Settings.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
            }
            .buttonStyle(.tweenPrimary)
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .stroke(Tokens.Palette.warning.opacity(0.35), lineWidth: 1)
        }
    }

    private var searchErrorCard: some View {
        VStack(spacing: Tokens.Space.s2 + 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Tokens.Palette.warning)
            Text(searchError ?? "Something went wrong")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.onSurface)
                .multilineTextAlignment(.center)
            Button {
                searchPlaces()
            } label: {
                Text("Try again")
            }
            .buttonStyle(.tweenPrimary)
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    private var categoryChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Space.s2) {
                ForEach(CategoryPreset.allCases) { preset in
                    let isSelected = selectedCategory == preset
                    Button { selectCategory(preset) } label: {
                        HStack(spacing: Tokens.Space.s1 + 2) {
                            Image(systemName: preset.systemImage)
                            Text(preset.label)
                        }
                        .font(Tokens.Typography.callout.weight(.semibold))
                        .foregroundStyle(isSelected ? Tokens.Palette.brand : Tokens.Palette.onSurface)
                        .padding(.horizontal, Tokens.Space.s3)
                        .padding(.vertical, Tokens.Space.s2)
                        .background(isSelected ? Tokens.Palette.brandMuted : Tokens.Palette.surface, in: Capsule())
                        .overlay {
                            Capsule().stroke(isSelected ? Tokens.Palette.brand.opacity(0.55) : Tokens.Palette.glassStroke, lineWidth: isSelected ? 1.2 : 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(Tokens.Motion.snappy, value: isSelected)
                }
            }
            .padding(.horizontal, Tokens.Space.s4)
        }
    }

    @ViewBuilder
    private var searchSuggestionsList: some View {
        let trimmed = trimmedSearchText
        if isSearchModeVisible, !trimmed.isEmpty, searchResults.isEmpty, detailItem == nil {
            VStack(spacing: 0) {
                if searchCompleter.suggestions.isEmpty {
                    suggestionRow(
                        icon: "magnifyingglass",
                        title: "Search for “\(trimmed)”",
                        subtitle: "Press return to search nearby"
                    ) {
                        commitSearch()
                    }
                } else {
                    ForEach(searchCompleter.suggestions.prefix(8), id: \.self) { suggestion in
                        suggestionRow(
                            icon: icon(for: suggestion),
                            title: suggestion.title,
                            subtitle: suggestion.subtitle.isEmpty ? "Search Nearby" : suggestion.subtitle
                        ) {
                            commitSearch(suggestion)
                        }
                    }
                }
            }
            .background(Tokens.Palette.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .stroke(Tokens.Palette.glassStroke, lineWidth: 1)
            }
        }
    }

    private func suggestionRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s3) {
                ZStack {
                    Circle().fill(Tokens.Palette.onSurfaceMuted.opacity(0.16))
                    Image(systemName: icon)
                        .font(Tokens.Typography.callout.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.onSurface)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, Tokens.Space.s3)
            .padding(.vertical, Tokens.Space.s2 + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 60)
        }
    }

    private func icon(for suggestion: MKLocalSearchCompletion) -> String {
        let text = "\(suggestion.title) \(suggestion.subtitle)".lowercased()
        if text.contains("coffee") || text.contains("starbucks") || text.contains("cafe") { return "cup.and.saucer.fill" }
        if text.contains("cinema") || text.contains("movie") || text.contains("theater") { return "film.fill" }
        if text.contains("restaurant") || text.contains("food") { return "fork.knife" }
        if text.contains("pharmacy") { return "cross.case.fill" }
        return "magnifyingglass"
    }

    private func commitSearch(_ suggestion: MKLocalSearchCompletion? = nil) {
        searchTask?.cancel()
        if let suggestion {
            searchText = suggestion.title
        }
        searchFocused = false
        isSearchActive = false
        searchCompleter.queryFragment = ""
        refreshPanelContent()
        withAnimation(Tokens.Motion.spring) {
            panelTab = .map
            panelDetent = .medium
        }
        searchPlaces(query: suggestion?.title)
    }

    private func selectCategory(_ preset: CategoryPreset) {
        selectedCategory = preset
        searchText = preset.query
        searchFocused = false
        isSearchActive = false
        searchCompleter.queryFragment = ""
        refreshPanelContent()
        withAnimation(Tokens.Motion.spring) {
            panelDetent = .medium
            panelTab = .map
        }
        searchPlaces(query: preset.query)
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

            VStack(spacing: Tokens.Space.s3) {
                ForEach(Array(searchResults.enumerated()), id: \.element) { index, item in
                    placeResultRow(item: item, index: index)
                        .id(placeListID(for: item))
                }
            }
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
                inviteFriendsRow
            } else {
                friendList
                inviteFriendsRow
                groupLocationButton
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
            groupLocationButton
        }
        .padding(.vertical, Tokens.Space.s4 + 2)
        .frame(maxWidth: .infinity)
    }

    private var groupLocationButton: some View {
        Button(action: toggleGroupLocation) {
            HStack(spacing: Tokens.Space.s2) {
                if isRequesting {
                    ProgressView()
                        .tint(isUserIn ? Tokens.Palette.brand : .white)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(isUserIn ? "No longer in" : "I'm in")
                    .contentTransition(.numericText())
            }
        }
        .buttonStyle(isUserIn ? .tweenSubtle : .tweenPrimary)
        .disabled(isRequesting)
        .animation(Tokens.Motion.spring, value: isRequesting)
        .animation(Tokens.Motion.spring, value: isUserIn)
    }

    private var friendList: some View {
        VStack(spacing: Tokens.Space.s3) {
            if showReplyBanner { replyBanner }
            ForEach(friends) { friend in
                HStack(spacing: Tokens.Space.s3) {
                    Text(initials(for: friend))
                        .font(Tokens.Typography.captionEmphasized)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(color(for: friend), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.name)
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.onSurface)
                        Text(friendSubtitle(for: friend))
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(pingStatusColor(for: friend))
                    }

                    Spacer()

                    Menu {
                        Button("Ping", systemImage: "paperplane.fill") { pingFriend(friend) }
                            .disabled(friend.messageHandle == nil)
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
                .padding(Tokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(Tokens.Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .stroke(Tokens.Palette.glassStroke, lineWidth: 1)
                }
            }
        }
    }

    private var replyBanner: some View {
        HStack(spacing: Tokens.Space.s2) {
            ZStack {
                Circle().fill(Tokens.Palette.brand)
                Image(systemName: "paperplane.fill")
                    .font(Tokens.Typography.iconBadge)
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            if let lastReplyAt {
                Text("Someone replied \(RelativeTime.formatShort(since: lastReplyAt))")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.onSurface)
            }
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Palette.brandMuted, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        .accessibilityElement(children: .combine)
    }

    private var showReplyBanner: Bool {
        guard let lastReplyAt else { return false }
        return Date().timeIntervalSince(lastReplyAt) < 3600
    }

    private enum PingStatus {
        case pinged(Date)
        case replied(Date)
        case never
    }

    private func pingStatus(for friend: TweenFriend) -> PingStatus {
        let pinged = PingLog.pingedAt(friend.id)
        if let reply = lastReplyAt, let p = pinged, reply > p, Date().timeIntervalSince(reply) < 3600 {
            return .replied(reply)
        }
        if let p = pinged { return .pinged(p) }
        return .never
    }

    private func pingStatusText(for friend: TweenFriend) -> String {
        switch pingStatus(for: friend) {
        case let .replied(date): return "Replied \(RelativeTime.formatShort(since: date))"
        case let .pinged(date):  return "Pinged \(RelativeTime.formatShort(since: date))"
        case .never:             return "Not yet pinged"
        }
    }

    private func friendSubtitle(for friend: TweenFriend) -> String {
        guard let handle = friend.messageHandle, !handle.isEmpty else {
            return "Add from Contacts to ping"
        }
        return "\(pingStatusText(for: friend)) · \(displayHandle(handle))"
    }

    private func pingStatusColor(for friend: TweenFriend) -> Color {
        switch pingStatus(for: friend) {
        case .replied: return Tokens.Palette.brand
        default:       return Tokens.Palette.onSurfaceMuted
        }
    }

    private var waitingSubtitle: String {
        if friends.isEmpty { return "Add the people you're waiting on" }
        if !isUserIn { return savedCoordinate == nil ? "Share your location to start" : "Tap I'm in when you're ready" }
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
        Button {
            openDetail(item)
        } label: {
            ResultRow(
                item: item,
                ranked: rankedSpot(for: item),
                isSelected: item == selectedPlace,
                isTopPick: index == 0 && rankedSpot(for: item) != nil,
                symbol: placeIcon(for: item),
                categoryTint: placeColor(for: item),
                typeLabel: placeTypeLabel(for: item),
                youDistance: distanceFrom(savedCoordinate, to: item),
                friendDistance: distanceFrom(peerCoordinate, to: item),
                namespace: spotTransition
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityIdentifier("place-row-\(item.name ?? "Place")")
        .accessibilityLabel(item.name ?? "Place")
    }

    private func placeListID(for item: MKMapItem) -> String {
        let coordinate = item.placemark.location?.coordinate
        let latitude = coordinate.map { String(format: "%.6f", $0.latitude) } ?? "nil"
        let longitude = coordinate.map { String(format: "%.6f", $0.longitude) } ?? "nil"
        return "\(item.name ?? "place")|\(latitude)|\(longitude)"
    }

    @ViewBuilder
    private var statusView: some View {
        switch provider.status {
        case .idle:
            if savedCoordinate != nil {
                Label(
                    isUserIn ? "You're in" : "Your location is ready",
                    systemImage: isUserIn ? "checkmark.circle.fill" : "location.fill"
                )
                .foregroundStyle(isUserIn ? Tokens.Palette.success : Tokens.Palette.onSurfaceMuted)
            }
        case .requesting:
            ProgressView("Getting your location…")
        case .got:
            Label(
                "Location updated",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Tokens.Palette.success)
        case .denied:
            locationDeniedCard
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
        guard savedCoordinate != nil else { return "Share your location to show your dot" }
        guard isUserIn else { return "Tap “I'm in” to turn your dot green" }
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
        userClearedLocation = false
        provider.requestOnce(activate: true) { coordinate in
            guard let coordinate else { return }
            isUserIn = true
            savedCoordinate = coordinate
            refreshPanelContent()
            focusOnPeople()
        }
    }

    private func imInForGroup() {
        // Stamp every roster member with the current time so the Waiting tab reads
        // "Pinged just now" — gives the tab its weight.
        for friend in friends {
            PingLog.setPingedAt(friend.id)
        }
        pingTick = Date()
        if savedCoordinate != nil {
            LocationCache.setActive(true)
            isUserIn = true
            refreshPanelContent()
            focusOnPeople()
            return
        }
        updateMyDot()
    }

    private func toggleGroupLocation() {
        if !isUserIn {
            imInForGroup()
        } else {
            leaveTween()
        }
    }

    private func pingFriend(_ friend: TweenFriend) {
        guard let recipient = friend.messageHandle, !recipient.isEmpty else {
            pingError = "Add \(friend.name) from Contacts so Tween has a Messages address."
            return
        }
        guard MFMessageComposeViewController.canSendText() else {
            pingError = "Messages isn't available on this device."
            return
        }

        PingLog.setPingedAt(friend.id)
        pingTick = Date()
        refreshPanelContent()
        ensureLocationForPing { coordinate in
            let state = TweenState(
                text: "I'm in",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            pendingPing = MessagePing(
                friendID: friend.id,
                recipient: recipient,
                body: Self.pingMessageBody(with: state)
            )
        }
    }

    private func ensureLocationForPing(_ completion: @escaping (CLLocationCoordinate2D) -> Void) {
        if let savedCoordinate {
            completion(savedCoordinate)
            return
        }

        userClearedLocation = false
        provider.requestOnce { coordinate in
            guard let coordinate else {
                pingError = "Share your location first so Tween can send an I'm in ping."
                return
            }
            savedCoordinate = coordinate
            refreshPanelContent()
            completion(coordinate)
        }
    }

    private static func pingMessageBody(with state: TweenState) -> String {
        """
        I'm in on Tween.

        Open the Tween iMessage app in this chat and tap "I'm in" to share your dot back.
        \(state.encodedURL().absoluteString)
        """
    }

    private func displayHandle(_ handle: String) -> String {
        if handle.contains("@") { return handle }
        let digits = handle.filter(\.isNumber)
        guard digits.count == 10 else { return handle }
        let area = digits.prefix(3)
        let middle = digits.dropFirst(3).prefix(3)
        let last = digits.suffix(4)
        return "(\(area)) \(middle)-\(last)"
    }

    private func beginAdd() {
        showContactSearch = true
    }

    private func beginRename(_ friend: TweenFriend) {
        editorName = friend.name
        editorMode = .rename(friend)
    }

    private func saveEditor() {
        let trimmed = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let mode = editorMode else { return }
        switch mode {
        case .rename(let target):
            if let index = friends.firstIndex(where: { $0.id == target.id }) {
                friends[index].name = trimmed
            }
        }
        FriendRoster.save(friends)
        editorMode = nil
        refreshPanelContent()
    }

    private func addContactFriend(_ contact: ContactCandidate) {
        let friend = TweenFriend(
            name: contact.name,
            contactIdentifier: contact.contactIdentifier,
            messageHandle: contact.handle
        )
        if let existingIndex = friends.firstIndex(where: { $0.contactIdentifier == contact.contactIdentifier }) {
            friends[existingIndex] = friend
        } else if let existingIndex = friends.firstIndex(where: { $0.messageHandle == contact.handle }) {
            friends[existingIndex] = friend
        } else {
            friends.append(friend)
        }
        FriendRoster.save(friends)
        showContactSearch = false
        refreshPanelContent()
    }

    private func deleteFriend(_ friend: TweenFriend) {
        friends.removeAll { $0.id == friend.id }
        FriendRoster.save(friends)
        PingLog.clearPing(friend.id)
        pingTick = Date()
        refreshPanelContent()
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
        refreshPanelContent()
    }

    private func selectPlaceFromMap(_ item: MKMapItem) {
        isSearchActive = false
        searchFocused = false
        detailItem = item
        selectedPlace = item
        panelTab = .map
        let id = placeListID(for: item)
        requestedPlaceScrollID = nil
        if let coordinate = item.placemark.location?.coordinate {
            centerMap(on: coordinate, avoidingBottomOverlay: true)
        }
        withAnimation(Tokens.Motion.spring) {
            panelDetent = .medium
        }
        DispatchQueue.main.async {
            refreshPanelContent()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            requestedPlaceScrollID = id
        }
    }

    private func openDetail(_ item: MKMapItem) {
        withAnimation(Tokens.Motion.spring) {
            isSearchActive = false
            searchFocused = false
            detailItem = item
            selectedPlace = item
            refreshPanelContent()
        }
    }

    private func showOnMap(_ item: MKMapItem) {
        if let coordinate = item.placemark.location?.coordinate {
            centerMap(on: coordinate, avoidingBottomOverlay: true)
        }
        withAnimation(Tokens.Motion.spring) {
            detailItem = nil
            selectedPlace = item
            panelDetent = .peek
        }
        refreshPanelContent()
    }

    private func closeDetail() {
        withAnimation(Tokens.Motion.spring) {
            detailItem = nil
            isSearchActive = false
            searchFocused = false
            panelTab = .map
            panelDetent = searchResults.isEmpty ? .peek : .medium
        }
        refreshPanelContent()
    }

    private func openInAppleMaps(_ item: MKMapItem) {
        guard item.placemark.location?.coordinate != nil else { return }

        let destination = clonedMapItem(from: item)
        var routeItems: [MKMapItem] = [MKMapItem.forCurrentLocation()]

        if let peerCoordinate {
            let pickupPlacemark = MKPlacemark(coordinate: peerCoordinate)
            let pickup = MKMapItem(placemark: pickupPlacemark)
            pickup.name = "Pickup"
            routeItems.append(pickup)
        }

        routeItems.append(destination)

        let didOpen = MKMapItem.openMaps(
            with: routeItems,
            launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving,
                MKLaunchOptionsMapTypeKey: NSNumber(value: MKMapType.standard.rawValue)
            ]
        )

        if !didOpen, let url = mapsURL(for: item) {
            UIApplication.shared.open(url)
        }
    }

    private func openInGoogleMaps(_ item: MKMapItem) {
        guard let url = googleMapsURL(for: item) else { return }
        UIApplication.shared.open(url)
    }

    private func clonedMapItem(from item: MKMapItem) -> MKMapItem {
        guard let coordinate = item.placemark.location?.coordinate else { return item }
        let clone = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        clone.name = item.name
        return clone
    }

    private func mapsURL(for item: MKMapItem) -> URL? {
        guard let coordinate = item.placemark.location?.coordinate else { return nil }
        let label = (item.name ?? "Destination").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Destination"
        let destination = "\(coordinate.latitude),\(coordinate.longitude)"
        let query: String
        if let peerCoordinate {
            query = "saddr=Current%20Location&daddr=\(peerCoordinate.latitude),\(peerCoordinate.longitude)%20to:\(destination)&dirflg=d"
        } else {
            query = "saddr=Current%20Location&daddr=\(destination)&q=\(label)&dirflg=d"
        }
        return URL(string: "https://maps.apple.com/?\(query)")
    }

    private func googleMapsURL(for item: MKMapItem) -> URL? {
        guard let coordinate = item.placemark.location?.coordinate else { return nil }
        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        var queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: "Current Location"),
            URLQueryItem(name: "destination", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "travelmode", value: "driving")
        ]

        if let peerCoordinate {
            queryItems.append(URLQueryItem(name: "waypoints", value: "\(peerCoordinate.latitude),\(peerCoordinate.longitude)"))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    /// Stages the chosen spot in the App Group container and opens Messages. The iMessage
    /// extension picks the draft up in its next `willBecomeActive` and surfaces a
    /// "Send chosen spot?" confirm in the expanded view.
    private func sendToChat(_ item: MKMapItem) {
        guard let coordinate = item.placemark.location?.coordinate else { return }
        let ranked = rankedSpot(for: item)
        let draft = OutgoingDraft(
            name: item.name ?? "the spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            etaFromA: ranked?.etaFromA,
            etaFromB: ranked?.etaFromB
        )
        OutgoingDraftStore.save(draft)
        if let url = URL(string: "messages://") {
            UIApplication.shared.open(url)
        }
    }

    private func copyLink(for item: MKMapItem) {
        guard let coordinate = item.placemark.location?.coordinate else { return }
        let state = TweenState(
            text: "Meet at \(item.name ?? "this spot")",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        UIPasteboard.general.string = Self.groupShareText(
            placeName: item.name ?? "this spot",
            state: state
        )
        copyConfirmation = "Tween link copied. Paste it into any group chat."
    }

    private static func groupShareText(placeName: String, state: TweenState) -> String {
        """
        Meet at \(placeName) on Tween.

        Open the Tween iMessage app in this chat and tap "I'm in" so everyone can compare dots.
        \(state.encodedURL().absoluteString)
        """
    }

    private func leaveTween() {
        userClearedLocation = false
        LocationCache.setActive(false)
        LocationCache.clearPeer()
        isUserIn = false
        peerCoordinate = nil
        selectedPlace = nil
        searchResults = []
        rankedSpots = []
        searchError = nil
        provider = LocationProvider()
        refreshPanelContent()
        withAnimation(Tokens.Motion.spring) { panelDetent = .medium }
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
        silentlyRefreshLocationIfAuthorized()
    }

    /// Fire a one-shot location request at launch when permission is already granted, so
    /// the map smoothly updates from "where I was last time" to "where I am now." Never
    /// triggers the system permission prompt — that stays a deliberate user tap.
    private func silentlyRefreshLocationIfAuthorized() {
        guard !userClearedLocation else { return }
        provider.requestOnceIfAuthorized(activate: isUserIn) { coordinate in
            guard !userClearedLocation else { return }
            guard let coordinate else { return }
            savedCoordinate = coordinate
            focusOnPeople()
        }
    }

    private func refreshSavedLocation(forceFocus: Bool = false) {
        friends = FriendRoster.load()
        let latestReply = PingLog.lastIncomingReplyAt
        if latestReply != lastReplyAt { lastReplyAt = latestReply }
        let latestSaved = LocationCache.load()
        let latestPeer = LocationCache.loadPeer()
        let latestIsUserIn = LocationCache.isActive()
        if userClearedLocation, latestSaved == nil, latestPeer == nil { return }
        if latestSaved != nil || latestPeer != nil { userClearedLocation = false }
        let peerJustAppeared = peerCoordinate == nil && latestPeer != nil
        // Only mutate @State when the value actually changed. Optional<CLLocationCoordinate2D>
        // isn't Equatable, so SwiftUI can't dedupe identical writes — without these guards the
        // 1 s poll would re-render the Map every tick even when nothing moved.
        if !sameCoordinate(savedCoordinate, latestSaved) { savedCoordinate = latestSaved }
        if !sameCoordinate(peerCoordinate, latestPeer) { peerCoordinate = latestPeer }
        if isUserIn != latestIsUserIn { isUserIn = latestIsUserIn }
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

    private var activeSearchRegion: MKCoordinateRegion {
        if let region = region(containing: [savedCoordinate, displayPeerCoordinate].compactMap { $0 }, padding: 1.4, minimumDelta: 0.04) {
            return region
        }
        return lastVisibleRegion
    }

    private func searchPlaces(query explicitQuery: String? = nil) {
        let query = (explicitQuery ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        searchError = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest]
        request.region = activeSearchRegion

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
                    isSearchActive = false
                    searchFocused = false
                    refreshPanelContent()
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
                    refreshPanelContent()
                }
            } catch {
                await MainActor.run {
                    searchResults = []
                    rankedSpots = []
                    selectedPlace = nil
                    searchError = "Search failed"
                    refreshPanelContent()
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
                .fill((isSelected ? Tokens.Palette.brand : Color.white).opacity(0.95))
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(isSelected ? 0.32 : 0.22), radius: isSelected ? 10 : 7, y: 3)
                .overlay {
                    Circle().stroke(Tokens.Palette.brand.opacity(isSelected ? 1 : 0), lineWidth: 2)
                }
            Image(systemName: placeIcon(for: item))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isSelected ? .white : placeColor(for: item))
                .padding(7)
                .background(isSelected ? Tokens.Palette.brand : Color.clear, in: Circle())
        }
        .scaleEffect(isSelected ? 1.18 : 1)
        .animation(Tokens.Motion.spring, value: isSelected)
    }

    private func placeAnnotation(item: MKMapItem) -> some View {
        VStack(spacing: 5) {
            if let bubbleText = placeDistanceBubble(for: item) {
                Text(bubbleText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                    }
                    .accessibilityLabel(placeDistanceAccessibilityLabel(for: item))
            }
            placeDot(item: item)
                .accessibilityHidden(true)
        }
    }

    private func placeDistanceBubble(for item: MKMapItem) -> String? {
        guard savedCoordinate != nil || peerCoordinate != nil else { return nil }
        let you = distanceFrom(savedCoordinate, to: item) ?? "--"
        let friend = distanceFrom(peerCoordinate, to: item) ?? "--"
        return "A \(you) · B \(friend)"
    }

    /// Human-readable accessibility label for the distance bubble — VoiceOver should never
    /// have to decode "A 0.4mi · B 0.6mi".
    private func placeDistanceAccessibilityLabel(for item: MKMapItem) -> String {
        let you = distanceFrom(savedCoordinate, to: item) ?? "unknown"
        let friend = distanceFrom(peerCoordinate, to: item) ?? "unknown"
        return "You are \(you) from this place, friend is \(friend)."
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

    private func applyDebugLaunchStateIfNeeded() {
        guard !didApplyDebugLaunchState else { return }
        didApplyDebugLaunchState = true

        let arguments = Set(ProcessInfo.processInfo.arguments)
        guard arguments.contains("-TweenUITestState") else { return }

        OnboardingFlags.hasSeenOnboarding = true
        showTutorial = false
        userClearedLocation = false
        savedCoordinate = CLLocationCoordinate2D(latitude: 38.8568, longitude: -77.3909)
        peerCoordinate = CLLocationCoordinate2D(latitude: 38.9586, longitude: -77.3570)
        isUserIn = true
        LocationCache.save(savedCoordinate!)
        LocationCache.savePeer(peerCoordinate!)
        LocationCache.setActive(true)

        let starbucks = debugMapItem(
            name: "Starbucks Coffee",
            coordinate: CLLocationCoordinate2D(latitude: 38.9575, longitude: -77.3568)
        )
        let park = debugMapItem(
            name: "Reston Town Center",
            coordinate: CLLocationCoordinate2D(latitude: 38.9587, longitude: -77.3589)
        )

        if arguments.contains("-TweenUITestSearch") {
            searchText = "h"
            searchResults = []
            rankedSpots = []
            selectedPlace = nil
            detailItem = nil
            searchError = nil
            isSearchActive = true
            panelTab = .map
            panelDetent = .full
        } else if arguments.contains("-TweenUITestResults") {
            searchText = "starbucks"
            searchResults = [starbucks, park]
            rankedSpots = []
            selectedPlace = starbucks
            detailItem = nil
            searchError = nil
            isSearchActive = false
            panelTab = .map
            panelDetent = .medium
            focusOnPlacesAndPeople()
        } else if arguments.contains("-TweenUITestWaiting") {
            friends = [
                TweenFriend(name: "Maya Ahmed", contactIdentifier: "debug-maya", messageHandle: "maya@example.com")
            ]
            FriendRoster.save(friends)
            isSearchActive = false
            searchText = ""
            panelTab = .waiting
            panelDetent = .medium
            pingTick = Date()
            refreshPanelContent()
        } else if arguments.contains("-TweenUITestMapPin") {
            searchText = "starbucks"
            searchResults = [starbucks]
            rankedSpots = []
            selectedPlace = starbucks
            detailItem = nil
            searchError = nil
            isSearchActive = false
            panelTab = .map
            panelDetent = .peek
            focusOnPlacesAndPeople()
        }
        refreshPanelContent()
    }

    private func debugMapItem(name: String, coordinate: CLLocationCoordinate2D) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
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

// MARK: - Tutorial overlay + invite share sheet

extension OnboardingView {
    static let inviteMessage =
        "Let's meet in the middle. Try Tween: https://github.com/kavigandham/tween"

    var tutorialOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture { dismissTutorial() }

            TutorialCard(onGetStarted: dismissTutorial)
                .padding(Tokens.Space.s4)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
        .animation(Tokens.Motion.spring, value: showTutorial)
    }

    private func dismissTutorial() {
        OnboardingFlags.hasSeenOnboarding = true
        withAnimation(Tokens.Motion.spring) {
            showTutorial = false
        }
    }
}

/// First-launch welcome card. Single screen, dismissable, re-openable from the panel's
/// info button. Three bullet rows summarise what Tween does end-to-end.
private struct TutorialCard: View {
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

/// Branded pre-permission location-share confirmation. Replaces the Phase 1 system alert
/// with a tokenized half-sheet that explains *why* the location is needed and *where* it
/// stays — meant to read as trustworthy before iOS's own permission prompt fires.
private struct LocationShareSheet: View {
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

/// Thin SwiftUI wrapper around `UIActivityViewController` for the invite-friend share sheet.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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

private struct MessagePing: Identifiable {
    let id = UUID()
    let friendID: UUID
    let recipient: String
    let body: String
}

private struct ContactCandidate: Identifiable, Equatable {
    let id: String
    let contactIdentifier: String
    let name: String
    let handle: String

    var searchableText: String {
        "\(name) \(handle)".lowercased()
    }
}

private struct ContactSearchSheet: View {
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

private final class ContactIndex: ObservableObject {
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

private struct MessageComposeSheet: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: () -> Void

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
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true) {
                self.onFinish()
            }
        }
    }
}

private final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []

    var region: MKCoordinateRegion = OnboardingView.defaultFramedRegion {
        didSet { completer.region = region }
    }

    var queryFragment: String = "" {
        didSet {
            completer.queryFragment = queryFragment
            if queryFragment.isEmpty {
                suggestions = []
            }
        }
    }

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .query]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = Array(completer.results.prefix(10))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
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
    case rename(TweenFriend)

    var id: String {
        switch self {
        case .rename(let friend): friend.id.uuidString
        }
    }

    var alertTitle: String {
        switch self {
        case .rename: "Rename friend"
        }
    }
}

private enum PanelDetent: CaseIterable {
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

private struct NativePanelSheet<SheetContent: View>: View {
    @Binding var panelDetent: PanelDetent
    @Binding var contentRevision: Int
    @State private var selectedDetent: PresentationDetent = .medium
    @ViewBuilder let content: () -> SheetContent

    private static var peekDetent: PresentationDetent { .height(120) }
    private static var detents: Set<PresentationDetent> { [Self.peekDetent, .medium, .large] }

    init(
        panelDetent: Binding<PanelDetent>,
        contentRevision: Binding<Int>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) {
        _panelDetent = panelDetent
        _contentRevision = contentRevision
        _selectedDetent = State(initialValue: Self.sheetDetent(for: panelDetent.wrappedValue))
        self.content = content
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .sheet(isPresented: .constant(true)) {
                content()
                    .id(contentRevision)
                    .presentationDetents(Self.detents, selection: $selectedDetent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.scrolls)
                    .interactiveDismissDisabled()
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: panelDetent) { _, detent in
                let target = Self.sheetDetent(for: detent)
                guard selectedDetent != target else { return }
                selectedDetent = target
            }
            .onChange(of: selectedDetent) { _, detent in
                let target = Self.panelDetent(for: detent)
                guard panelDetent != target else { return }
                panelDetent = target
            }
    }

    private static func sheetDetent(for detent: PanelDetent) -> PresentationDetent {
        switch detent {
        case .peek: Self.peekDetent
        case .medium: .medium
        case .full: .large
        }
    }

    private static func panelDetent(for detent: PresentationDetent) -> PanelDetent {
        if detent == Self.peekDetent { return .peek }
        if detent == .large { return .full }
        return .medium
    }
}

private struct PlaceSnapshotThumbnail: View {
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

/// Stable matched-geometry IDs shared between ResultRow and SpotDetail. The key is the
/// MKMapItem's `hash` so the same item morphs into the same detail no matter where it sits
/// in the list.
private func matchedSymbolId(for item: MKMapItem) -> String { "spot-symbol-\(item.hash)" }
private func matchedNameId(for item: MKMapItem) -> String { "spot-name-\(item.hash)" }
private func matchedChipId(for item: MKMapItem) -> String { "spot-chip-\(item.hash)" }

/// Detail card that takes over the bottom panel when a result is selected. Composed from
/// the same primitives as ResultRow so matchedGeometryEffect can morph between them.
private struct SpotDetail: View {
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
                    selfValue: ranked.map { formatETA($0.etaFromA) } ?? (youDistance ?? "—"),
                    friendValue: ranked.map { formatETA($0.etaFromB) } ?? (friendDistance ?? "—"),
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
