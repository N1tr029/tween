//
//  OnboardingView.swift
//  TweenApp
//

import CoreLocation
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
    @State private var isSearchingPlaces = false
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
    static let defaultFramedRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
        span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 55)
    )

    /// Neighbourhood-scale span used when we open at the user's cached location.
    private static let neighbourhoodSpan = MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)

    init() {
        let seed = DebugLaunchSeed.resolve()

        let cached = seed?.savedCoordinate ?? LocationCache.load()
        let initialRegion = cached.map {
            MKCoordinateRegion(center: $0, span: Self.neighbourhoodSpan)
        } ?? Self.defaultFramedRegion
        _position = State(initialValue: .region(initialRegion))
        _lastVisibleRegion = State(initialValue: initialRegion)

        guard let seed else { return }

        // Seed every relevant @State backing storage *before* the first body render so
        // the .sheet host captures the seeded values on initial presentation. Setting
        // these later (e.g. in .onAppear) races the UIHostingController and the sheet
        // ends up showing empty content for the seeded UI-test launch modes.
        _searchText          = State(initialValue: seed.searchText)
        _searchResults       = State(initialValue: seed.searchResults)
        _selectedPlace       = State(initialValue: seed.selectedPlace)
        _isSearchActive      = State(initialValue: seed.isSearchActive)
        _panelTab            = State(initialValue: seed.panelTab)
        _panelDetent         = State(initialValue: seed.panelDetent)
        _selectedSheetDetent = State(initialValue: Self.sheetDetent(for: seed.panelDetent))
        _savedCoordinate     = State(initialValue: seed.savedCoordinate)
        _peerCoordinate      = State(initialValue: seed.peerCoordinate)
        _isUserIn            = State(initialValue: true)
        _showTutorial        = State(initialValue: false)
        if let friends = seed.friends {
            _friends         = State(initialValue: friends)
        }
        _pendingDebugSeed    = State(initialValue: seed)
        _didDebugLaunch      = State(initialValue: true)
    }
    @State private var mapDisplayMode: MapDisplayMode = .standard
    @State private var showsTraffic = false
    @State private var friends: [TweenFriend] = FriendRoster.load()
    @State private var editorMode: FriendEditor?
    @State private var editorName: String = ""
    @State private var showContactSearch = false
    @State private var pendingPing: MessagePing?
    @State private var pingError: String?
    @State private var locationError: String?
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
    @State private var placesSearchTask: Task<Void, Never>?
    @State private var isApplyingProgrammaticSearch = false
    @State private var lastCompleterRegionCenter: CLLocationCoordinate2D?
    @StateObject private var searchCompleter = SearchCompleter()
    @State private var isSearchActive = false
    @State private var didCollapseWithPanelDrag = false
    @State private var selectedSheetDetent: PresentationDetent = .medium
    @FocusState private var searchFocused: Bool
    @Namespace private var spotTransition
    @State private var pendingDebugSeed: DebugLaunchSeed?
    /// `true` for the entire lifetime of a `-TweenUITest*` launch — `pendingDebugSeed` is
    /// consumed after the side-effects pass, but this flag stays set so all subsequent
    /// disk-read paths (refreshSavedLocation, pollSharedLocations, silentlyRefresh…)
    /// keep their hands off the user's real caches. Without it, the 1Hz poll clobbers
    /// the in-memory @State seeded by `init()` with empty/stale cache contents.
    @State private var didDebugLaunch = false

    var body: some View {
        ZStack(alignment: .top) {
            styledMap
                .ignoresSafeArea()
                .ignoresSafeArea(.keyboard)
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

            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .sheet(isPresented: .constant(true)) {
                    bottomPanel
                        .presentationDetents(Self.sheetDetents, selection: $selectedSheetDetent)
                        .presentationBackground(.regularMaterial)
                        .presentationCornerRadius(34)
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        .presentationContentInteraction(.scrolls)
                        .interactiveDismissDisabled()
                        .presentationDragIndicator(.visible)
                }

        }
        // Tutorial is presented as a fullScreenCover (not a ZStack overlay) so it lays
        // on top of any active sheet — the info button lives inside the bottom sheet, so
        // tapping it while another sheet (e.g. contact search) is open would otherwise
        // mount the tutorial behind that sheet and "do nothing" visually.
        .fullScreenCover(isPresented: $showTutorial) {
            tutorialOverlay
                .presentationBackground(.clear)
        }
        .onAppear {
            prepareInitialMap()
            applyDebugLaunchSideEffectsIfNeeded()
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
            withAnimation(Tokens.Motion.spring) {
                panelDetent = .full
                livePanelHeight = nil
                panelDragStartHeight = nil
            }
        }
        .onChange(of: panelDetent) { _, newDetent in
            let target = Self.sheetDetent(for: newDetent)
            if selectedSheetDetent != target {
                selectedSheetDetent = target
            }
            // Dismiss the keyboard whenever the sheet leaves .full — including the
            // .medium → .peek drag, where leaving focus mounted would strand the
            // keyboard over a 120pt sheet.
            guard newDetent != .full, searchFocused else { return }
            searchFocused = false
        }
        .onChange(of: selectedSheetDetent) { _, detent in
            let target = Self.panelDetent(for: detent)
            guard panelDetent != target else { return }
            panelDetent = target
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
        .alert(
            "Location unavailable",
            isPresented: Binding(
                get: { locationError != nil },
                set: { if !$0 { locationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { locationError = nil }
        } message: {
            Text(locationError ?? "")
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
                refreshSearchCompleterRegionIfNeeded(context.region)
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

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                    rankedSpots = []
                    selectedPlace = nil
                    searchError = nil
                    isSearchingPlaces = false
                    searchCompleter.queryFragment = ""
                    if isSearchActive || searchFocused {
                        isSearchActive = true
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
            if panelTab != .map {
                panelTab = .map
            }
            isSearchActive = true
            searchFocused = true
            if panelDetent != .full {
                withAnimation(Tokens.Motion.spring) {
                    panelDetent = .full
                    livePanelHeight = nil
                    panelDragStartHeight = nil
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            // commitSearch / selectCategory mutate searchText to drive `searchPlaces` directly.
            // If we ran updateSearchSuggestions here too, two MKLocalSearches would race for
            // the same query — the slower one stomps the faster one's results. Skip when the
            // programmatic path is in flight; the typed path still flows normally.
            guard !isApplyingProgrammaticSearch else { return }
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isSearchActive = true
                if panelDetent != .full {
                    withAnimation(Tokens.Motion.spring) {
                        panelDetent = .full
                        livePanelHeight = nil
                        panelDragStartHeight = nil
                    }
                }
            }
            updateSearchSuggestions(for: newValue)
        }
    }

    /// Updates Apple-Maps-style suggestions while typing, then fills the list with nearby
    /// place results after a short debounce so the sheet feels alive without spamming MapKit.
    private func updateSearchSuggestions(for input: String) {
        searchTask?.cancel()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            rankedSpots = []
            selectedPlace = nil
            searchError = nil
            isSearchingPlaces = false
            searchCompleter.queryFragment = ""
            return
        }
        isSearchActive = true
        searchResults = []
        rankedSpots = []
        selectedPlace = nil
        detailItem = nil
        searchError = nil
        let region = activeSearchRegion
        searchCompleter.region = region
        searchCompleter.queryFragment = trimmed
        isSearchingPlaces = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                rankedSpots = []
                selectedPlace = nil
                detailItem = nil
                searchError = nil
            }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.resultTypes = [.pointOfInterest, .address]
            request.region = region

            let response = try? await MKLocalSearch(request: request).start()
            let items = Array(response?.mapItems.prefix(8) ?? [])

            await MainActor.run {
                guard trimmedSearchText == trimmed, isSearchModeVisible else { return }
                rankedSpots = []
                searchResults = items
                selectedPlace = items.first
                isSearchingPlaces = false
                searchError = nil
            }
        }
    }

    /// Re-anchor the live search completer on the user's current map view, so suggestions
    /// follow a pan. Throttled to 10% of the current span to avoid hammering
    /// MKLocalSearchCompleter on every camera frame during a continuous pan.
    private func refreshSearchCompleterRegionIfNeeded(_ region: MKCoordinateRegion) {
        guard isSearchModeVisible, !trimmedSearchText.isEmpty else { return }
        let center = region.center
        if let last = lastCompleterRegionCenter,
           abs(last.latitude - center.latitude) < region.span.latitudeDelta * 0.1,
           abs(last.longitude - center.longitude) < region.span.longitudeDelta * 0.1 {
            return
        }
        lastCompleterRegionCenter = center
        searchCompleter.region = region
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
        let isShowingCommittedResults = panelTab == .map && !isLiveSearchVisible && (!displayedSearchResults.isEmpty)

        return VStack(alignment: .leading, spacing: 0) {
            sheetHeader
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.top, searchResults.isEmpty ? Tokens.Space.s3 : Tokens.Space.s2)

            if panelDetent == .peek {
                VStack(spacing: Tokens.Space.s2) {
                    searchBar
                    peekSummary
                }
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s3 + 2) {
                            if !monitor.isOnline {
                                offlineBanner
                            }

                            if isLiveSearchVisible && !isShowingDetail {
                                Color.clear
                                    .frame(height: Tokens.Space.s2)
                            }

                            if !isShowingDetail {
                                searchBar
                                    .id("sheet-search")
                                if panelTab == .map && !isLiveSearchVisible && trimmedSearchText.isEmpty && displayedSearchResults.isEmpty {
                                    categoryChipRow
                                }
                                if isLiveSearchVisible {
                                    liveSearchContent
                                }
                            }

                            if !isLiveSearchVisible && !isShowingDetail {
                                if !isShowingCommittedResults {
                                    panelTitleRow
                                }
                                panelPicker
                            }

                            if panelDetent != .full,
                               panelTab == .map,
                               !isShowingDetail,
                               !isShowingCommittedResults,
                               trimmedSearchText.isEmpty {
                                statusView
                            }

                            if !isLiveSearchVisible {
                                panelContent
                                    .id(panelTab)
                            }
                        }
                        .padding(.horizontal, Tokens.Space.s5)
                        .padding(.top, Tokens.Space.s2)
                        .padding(.bottom, scrollContentBottomPadding)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.immediately)
                    .contentTransition(.identity)
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(Tokens.Motion.spring, value: shouldShowActionControls)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(panelExitDragGesture)
        .animation(Tokens.Motion.spring, value: monitor.isOnline)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [Self.inviteMessage], onDismiss: { showShareSheet = false })
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
                onFinish: { result in
                    // Stamp the ping log only when the message actually went out.
                    // Cancelled / failed composes leave the friend's subtitle untouched.
                    if result == .sent {
                        PingLog.setPingedAt(ping.friendID)
                        pingTick = Date()
                    }
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
        HStack {
            Spacer()

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
        .frame(height: 48)
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
        HStack(spacing: 0) {
            panelPickerButton(.map)
            panelPickerButton(.waiting)
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map and Waiting tabs")
    }

    private func panelPickerButton(_ tab: HomePanelTab) -> some View {
        let isSelected = panelTab == tab

        return Button {
            withAnimation(Tokens.Motion.spring) {
                panelTab = tab
                if tab == .waiting {
                    isSearchActive = false
                    searchFocused = false
                }
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

    private var keyboardPanelPicker: some View {
        HStack(spacing: 0) {
            keyboardPanelButton(.map)
            keyboardPanelButton(.waiting)
        }
        .padding(4)
        .frame(width: max(0, UIScreen.main.bounds.width - 40), height: 50)
        .tweenGlass(cornerRadius: Tokens.Radius.chip)
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
        if panelTab == .waiting {
            waitingTab
        } else if let detailItem {
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
        } else if selectedPlace != nil {
            placeResultsList
        } else if searchError != nil {
            searchErrorCard
        } else {
            mapEmptyState
        }
    }

    private var shouldShowActionControls: Bool {
        !isLiveSearchVisible &&
        !searchFocused &&
        panelDetent != .full &&
        panelTab == .map &&
        detailItem == nil &&
        selectedPlace == nil &&
        trimmedSearchText.isEmpty &&
        searchResults.isEmpty &&
        searchError == nil
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedSearchResults: [MKMapItem] {
        if !searchResults.isEmpty { return searchResults }
        if let selectedPlace { return [selectedPlace] }
        return []
    }

    private var isSearchModeVisible: Bool {
        guard panelTab == .map else { return false }
        return detailItem == nil && (isSearchActive || searchFocused)
    }

    private var isLiveSearchVisible: Bool {
        isSearchModeVisible
    }

    private var panelExitDragGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { value in
                guard !didCollapseWithPanelDrag else { return }
                guard isMostlyVerticalDownwardDrag(value) else { return }
                didCollapseWithPanelDrag = true
                collapsePanelForMapInteraction()
            }
            .onEnded { value in
                defer { didCollapseWithPanelDrag = false }
                guard !didCollapseWithPanelDrag else { return }
                guard isMostlyVerticalDownwardDrag(value) else { return }
                collapsePanelForMapInteraction()
            }
    }

    private func isMostlyVerticalDownwardDrag(_ value: DragGesture.Value) -> Bool {
        guard panelDetent == .full else { return false }
        guard value.translation.height > 70 else { return false }
        return abs(value.translation.width) < value.translation.height
    }

    private func clearSearchModeState() {
        searchText = ""
        searchResults = []
        rankedSpots = []
        selectedPlace = nil
        detailItem = nil
        searchError = nil
        isSearchingPlaces = false
        searchCompleter.queryFragment = ""
    }

    private var scrollContentBottomPadding: CGFloat {
        let keyboardPadding = keyboardHeight > 0 ? keyboardHeight + Tokens.Space.s4 : 0
        let basePadding = shouldShowActionControls ? Tokens.Space.s3 : bottomSafeAreaInset + Tokens.Space.s4
        return max(basePadding, keyboardPadding)
    }

    private func togglePanelDetent() {
        let shouldClearSearch = isSearchModeVisible
        withAnimation(Tokens.Motion.spring) {
            switch panelDetent {
            case .peek:
                panelDetent = .medium
            case .medium:
                panelDetent = .full
            case .full:
                if shouldClearSearch {
                    clearSearchModeState()
                }
                isSearchActive = false
                searchFocused = false
                detailItem = nil
                panelTab = .map
                panelDetent = .peek
            }
        }
    }

    private func collapsePanelForMapInteraction() {
        guard searchFocused || isSearchActive || panelDetent != .peek || livePanelHeight != nil else { return }
        let shouldClearSearch = isSearchModeVisible

        withAnimation(Tokens.Motion.spring) {
            searchFocused = false
            isSearchActive = false
            if shouldClearSearch {
                clearSearchModeState()
            }
            detailItem = nil
            panelTab = .map
            panelDetent = .peek
            livePanelHeight = nil
            panelDragStartHeight = nil
        }
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
        // 30pt + .onEnded only: a tap with finger drift up to ~25pt no longer collapses
        // the sheet, so pin-button taps reach `selectPlaceFromMap`/`openDetail` without
        // a competing collapse animation. The collapse only fires after the user lifts.
        DragGesture(minimumDistance: 30)
            .onEnded { _ in
                guard panelDetent != .peek else { return }
                collapsePanelForMapInteraction()
            }
    }

    private static let peekHeight: CGFloat = 120
    private static var sheetPeekDetent: PresentationDetent { .height(peekHeight) }
    private static var sheetDetents: Set<PresentationDetent> { [sheetPeekDetent, .medium, .large] }

    private static func sheetDetent(for detent: PanelDetent) -> PresentationDetent {
        switch detent {
        case .peek: sheetPeekDetent
        case .medium: .medium
        case .full: .large
        }
    }

    private static func panelDetent(for detent: PresentationDetent) -> PanelDetent {
        if detent == sheetPeekDetent { return .peek }
        if detent == .large { return .full }
        return .medium
    }

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

        // Only snap to .full on the keyboard's appear transition. Frame changes mid-session
        // (predictive bar toggle, IME swap, orientation, autofill bar) must not stomp a
        // user-initiated drag down to .medium.
        let keyboardJustAppeared = keyboardHeight == 0 && height > 0

        withAnimation(.easeOut(duration: duration)) {
            keyboardHeight = height
            if keyboardJustAppeared, searchFocused {
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
                    panelDetent = .full
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
    private var liveSearchContent: some View {
        if !searchResults.isEmpty {
            livePlaceResultsList
        } else if !searchCompleter.suggestions.isEmpty || !isSearchingPlaces {
            searchSuggestionsList
        } else {
            liveSearchLoadingList
        }
    }

    private var liveSearchLoadingList: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s3) {
                ProgressView()
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Searching nearby")
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.onSurface)
                    Text(trimmedSearchText)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, Tokens.Space.s3)
            .padding(.vertical, Tokens.Space.s3)
        }
        .background(Tokens.Palette.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .stroke(Tokens.Palette.glassStroke, lineWidth: 1)
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
        beginProgrammaticSearch()
        if let suggestion {
            searchText = suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title) \(suggestion.subtitle)"
        }
        searchFocused = false
        isSearchActive = false
        searchCompleter.queryFragment = ""
        withAnimation(Tokens.Motion.spring) {
            panelTab = .map
            panelDetent = .medium
        }
        searchPlaces(query: suggestion?.title)
    }

    private func selectCategory(_ preset: CategoryPreset) {
        selectedCategory = preset
        beginProgrammaticSearch()
        searchText = preset.query
        searchFocused = false
        isSearchActive = false
        searchCompleter.queryFragment = ""
        withAnimation(Tokens.Motion.spring) {
            panelDetent = .medium
            panelTab = .map
        }
        searchPlaces(query: preset.query)
    }

    /// Latch the programmatic-search flag for one runloop so the synchronous searchText
    /// mutation can fire `.onChange(of: searchText)` once and be skipped by its guard. The
    /// flag lifts on the next main-loop tick, restoring the typed-path behavior.
    private func beginProgrammaticSearch() {
        isApplyingProgrammaticSearch = true
        DispatchQueue.main.async {
            isApplyingProgrammaticSearch = false
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

                Text("\(displayedSearchResults.count)")
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Tokens.Palette.onSurfaceMuted.opacity(0.12), in: Circle())
            }

            VStack(spacing: Tokens.Space.s3) {
                ForEach(Array(displayedSearchResults.enumerated()), id: \.element) { index, item in
                    placeResultRow(item: item, index: index)
                        .id(placeListID(for: item))
                }
            }
        }
    }

    private var livePlaceResultsList: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text("Results")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.onSurface)

            VStack(spacing: 0) {
                ForEach(Array(searchResults.enumerated()), id: \.element) { index, item in
                    livePlaceResultRow(item: item, index: index)
                    if index < searchResults.count - 1 {
                        Divider()
                            .padding(.leading, 58)
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

    private func livePlaceResultRow(item: MKMapItem, index: Int) -> some View {
        Button {
            openDetail(item)
        } label: {
            HStack(spacing: Tokens.Space.s3) {
                ZStack {
                    Circle()
                        .fill(index == 0 ? Tokens.Palette.brand : placeColor(for: item).opacity(0.86))
                    Image(systemName: placeIcon(for: item))
                        .font(Tokens.Typography.callout.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name ?? "Place")
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.onSurface)
                        .lineLimit(1)
                    Text(livePlaceSubtitle(for: item))
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            }
            .padding(.horizontal, Tokens.Space.s3)
            .padding(.vertical, Tokens.Space.s2 + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("live-place-row-\(item.name ?? "Place")")
    }

    private func livePlaceSubtitle(for item: MKMapItem) -> String {
        let distance = distanceFrom(savedCoordinate ?? peerCoordinate, to: item)
        let category = placeTypeLabel(for: item)
        let address = compactAddress(for: item)
        return [category, distance, address]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func compactAddress(for item: MKMapItem) -> String? {
        let placemark = item.placemark
        let parts = [placemark.locality, placemark.administrativeArea]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return placemark.title == item.name ? nil : placemark.title
    }

    private var mapEmptyState: some View {
        VStack(spacing: Tokens.Space.s3) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Tokens.Palette.brand)
            Text("Search for coffee, food, parks…")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.onSurface)
                .multilineTextAlignment(.center)
            Text("Type in the search bar or pick a category to find places near the midpoint.")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.surface.opacity(0.66), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .stroke(Tokens.Palette.glassStroke, lineWidth: 1)
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
            Text("Waiting for friends to join")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.onSurface)
                .multilineTextAlignment(.center)
            Text("Add someone from Contacts or share your spot so Tween can find a fair meetup.")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
            groupLocationButton
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.surface.opacity(0.66), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .stroke(Tokens.Palette.glassStroke, lineWidth: 1)
        }
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
            guard let coordinate else {
                // Surface the failure instead of silently dismissing the share sheet.
                // The user just tapped "Share my location" expecting their dot to land;
                // staying quiet leaves them thinking it worked.
                if case .denied = provider.status {
                    locationError = "Tween needs your location to set your dot. Re-enable Location Services for Tween in Settings."
                } else {
                    locationError = "Couldn't capture your location. Try again in a moment."
                }
                return
            }
            isUserIn = true
            savedCoordinate = coordinate
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
    }

    private func deleteFriend(_ friend: TweenFriend) {
        friends.removeAll { $0.id == friend.id }
        FriendRoster.save(friends)
        PingLog.clearPing(friend.id)
        pingTick = Date()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            requestedPlaceScrollID = id
        }
    }

    private func openDetail(_ item: MKMapItem) {
        if let coordinate = item.placemark.location?.coordinate {
            centerMap(on: coordinate, avoidingBottomOverlay: true)
        }
        withAnimation(Tokens.Motion.spring) {
            isSearchActive = false
            searchFocused = false
            detailItem = item
            selectedPlace = item
            panelTab = .map
            panelDetent = .medium
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
    }

    private func closeDetail() {
        withAnimation(Tokens.Motion.spring) {
            detailItem = nil
            isSearchActive = false
            searchFocused = false
            panelTab = .map
            panelDetent = searchResults.isEmpty ? .peek : .medium
        }
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
        guard !didDebugLaunch else { return }
        provider.requestOnceIfAuthorized(activate: isUserIn) { coordinate in
            guard !userClearedLocation else { return }
            guard let coordinate else { return }
            savedCoordinate = coordinate
            focusOnPeople()
        }
    }

    private func refreshSavedLocation(forceFocus: Bool = false) {
        // Skip entirely for a -TweenUITest* launch: the seeded @State is the source of
        // truth, and `applyDebugLaunchSideEffectsIfNeeded` deliberately doesn't pollute
        // the real LocationCache / FriendRoster. Reading either would clobber the seed.
        guard !didDebugLaunch else { return }
        // NOTE: friends are NOT reloaded from FriendRoster on poll. Friend changes are
        // user-driven (add/rename/remove), which already update @State + FriendRoster
        // together. Reloading every second clobbers in-memory state without ever
        // picking up a meaningful change.
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

        // Cancel any in-flight committed-search task so its late completion can't clobber
        // the new query's results, detent, or focus.
        placesSearchTask?.cancel()

        searchError = nil
        isSearchingPlaces = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest]
        request.region = activeSearchRegion

        let a = savedCoordinate
        let b = peerCoordinate

        placesSearchTask = Task {
            do {
                let response = try await MKLocalSearch(request: request).start()
                let items = Array(response.mapItems.prefix(6))
                await MainActor.run {
                    guard !Task.isCancelled, trimmedSearchText == query else { return }
                    searchResults = items
                    rankedSpots = []
                    selectedPlace = items.first
                    searchError = items.isEmpty ? "No places found nearby" : nil
                    isSearchingPlaces = false
                    isSearchActive = false
                    searchFocused = false
                    panelDetent = .medium
                    focusOnPlacesAndPeople()
                }
                // Fairness ranking needs both endpoints. If we have them, replace the
                // raw search order with drive-time fairness; otherwise leave as is.
                guard let a, let b, !items.isEmpty else { return }
                let ranked = await FairnessRanker.rank(candidates: items, from: a, and: b)
                await MainActor.run {
                    guard !Task.isCancelled, trimmedSearchText == query else { return }
                    rankedSpots = ranked
                    let rankedItems = ranked.map(\.item)
                    let unranked = items.filter { item in !rankedItems.contains(where: { $0 == item }) }
                    searchResults = rankedItems + unranked
                    selectedPlace = searchResults.first
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, trimmedSearchText == query else { return }
                    searchResults = []
                    rankedSpots = []
                    selectedPlace = nil
                    isSearchingPlaces = false
                    selectedCategory = nil
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

    /// Runs the post-render side effects for a UI-test launch. The seeded @State itself is
    /// already applied by `init()` (see DebugLaunchSeed). Crucially we do NOT persist the
    /// seeded friends/coordinates to FriendRoster / LocationCache — that pollution survives
    /// the test process and shows up in the user's real roster afterwards (the "Maya Ahmed
    /// debug-maya" ghost). `refreshSavedLocation` / `silentlyRefreshLocationIfAuthorized`
    /// already guard on `pendingDebugSeed`, so prepareInitialMap can't read empty caches
    /// and clobber the in-memory seeded state. Consuming `pendingDebugSeed` guarantees this
    /// runs at most once even on scene re-activation.
    private func applyDebugLaunchSideEffectsIfNeeded() {
        guard let seed = pendingDebugSeed else { return }
        pendingDebugSeed = nil

        OnboardingFlags.hasSeenOnboarding = true
        if seed.shouldFocusPlacesAndPeople {
            focusOnPlacesAndPeople()
        }
        pingTick = Date()
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

// Supporting types and views (HomePanelTab, PanelDetent, MapDisplayMode,
// CategoryPreset, SearchCompleter, ResultRow, SpotDetail, ETAChip,
// TutorialCard, LocationShareSheet, ContactSearchSheet, etc.) have been
// moved to SupportingTypes.swift and SupportingViews.swift.

#Preview {
    OnboardingView()
}
