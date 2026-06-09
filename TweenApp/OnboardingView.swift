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
    @State private var position = MapCameraPosition.automatic
    @State private var lastVisibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
        span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 55)
    )
    @State private var mapDisplayMode: MapDisplayMode = .standard
    @State private var showsTraffic = false
    @State private var friends: [TweenFriend] = FriendRoster.load()
    @State private var editorMode: FriendEditor?
    @State private var editorName: String = ""

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
                .padding(.top, 74)
                .padding(.horizontal, 16)
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
                        mapDot(color: .blue, systemImage: "person.fill")
                    }
                }

                if let displayPeerCoordinate {
                    Annotation("Friend", coordinate: displayPeerCoordinate) {
                        mapDot(color: .orange, systemImage: "person.2.fill")
                    }
                }

                if let savedCoordinate, let displayPeerCoordinate {
                    MapPolyline(coordinates: [savedCoordinate, displayPeerCoordinate])
                        .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [7, 7]))
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
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search coffee, lunch, parks...", text: $searchText)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
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
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var mapControls: some View {
        VStack(spacing: 8) {
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
                    .font(.headline)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map style")

            Button {
                setTrafficVisible(!showsTraffic)
            } label: {
                Image(systemName: showsTraffic ? "car.fill" : "car")
                    .font(.headline)
                    .foregroundStyle(showsTraffic ? .white : .primary)
                    .frame(width: 42, height: 42)
                    .background(showsTraffic ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsTraffic ? "Hide traffic" : "Show traffic")

            Divider()
                .frame(width: 28)

            Button(action: resetMap) {
                Image(systemName: "location.north.line.fill")
                    .font(.headline)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset map")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: mapDisplayMode)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: showsTraffic)
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                if !searchResults.isEmpty {
                    dragHandle
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tween")
                            .font(.largeTitle.bold())
                        Text(headlineText)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: savedCoordinate == nil ? "mappin.and.ellipse" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(savedCoordinate == nil ? Color.secondary : Color.green)
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
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                case .group:
                    groupTab
                }

                if panelDetent != .full, panelTab == .map {
                    actionControls
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, searchResults.isEmpty ? 20 : 10)
            .padding(.bottom, searchResults.isEmpty ? 34 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: panelHeight, alignment: .top)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            .gesture(panelDragGesture)
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: panelDetent)
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
        }
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard !searchResults.isEmpty else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                    if value.translation.height < -50 {
                        panelDetent = panelDetent.nextHigher
                    } else if value.translation.height > 50 {
                        panelDetent = panelDetent.nextLower
                    }
                }
            }
    }

    private var panelHeight: CGFloat? {
        guard !searchResults.isEmpty || panelTab == .group else { return nil }
        let screenHeight = UIScreen.main.bounds.height
        switch panelDetent {
        case .compact:
            return panelTab == .group ? 360 : 238
        case .medium:
            return panelTab == .group ? min(500, screenHeight * 0.56) : min(430, screenHeight * 0.48)
        case .full:
            return screenHeight - 92
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        if savedCoordinate == nil {
            HStack(spacing: 10) {
                Image(systemName: "message.fill")
                    .foregroundStyle(.blue)
                Text("Waiting for an iMessage “I'm in”")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 10) {
                Button(action: updateMyDot) {
                    HStack {
                        if isRequesting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(buttonTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .disabled(isRequesting)

                Button(action: leaveTween) {
                    Text("No longer in")
                        .font(.headline)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .tint(.red)
                .disabled(isRequesting)
            }
        }
    }

    private var placeResultsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Places")
                        .font(.title3.weight(.bold))
                    Text(resultsSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(searchResults.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(Array(searchResults.enumerated()), id: \.element) { index, item in
                        placeResultRow(item: item, index: index)
                    }
                }
            }
            .frame(maxHeight: placeListHeight)
        }
    }

    private var groupTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group")
                        .font(.title3.weight(.bold))
                    Text(groupSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if !friends.isEmpty {
                    Text("\(friends.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }

                Button(action: beginAdd) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.blue, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add friend")
            }

            if friends.isEmpty {
                groupEmptyState
            } else {
                friendList
                Button(action: imInForGroup) {
                    HStack {
                        if isRequesting { ProgressView().tint(.white) }
                        Text(savedCoordinate == nil ? "Share location & say I'm in" : "I'm in for this group")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .disabled(isRequesting)
            }
        }
    }

    private var groupEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Add the friends you want to meet up with.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: beginAdd) {
                Text("Add friend")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 8))
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private var friendList: some View {
        VStack(spacing: 8) {
            ForEach(friends) { friend in
                HStack(spacing: 10) {
                    Text(initials(for: friend))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(color(for: friend), in: Circle())

                    Text(friend.name)
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Menu {
                        Button("Rename") { beginRename(friend) }
                        Button("Delete", role: .destructive) { deleteFriend(friend) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Manage \(friend.name)")
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var groupSubtitle: String {
        if friends.isEmpty { return "Add your set friends to start" }
        if savedCoordinate == nil { return "Share your dot, then say I'm in" }
        if peerCoordinate == nil { return "Your dot is active, waiting for friends" }
        return "You and a friend are \(distanceText) apart"
    }

    private var resultsSubtitle: String {
        if !rankedSpots.isEmpty { return "Sorted by fair travel time" }
        if savedCoordinate != nil || peerCoordinate != nil { return "Distances update as people join" }
        return "Tap a place to preview it on the map"
    }

    private var placeListHeight: CGFloat {
        switch panelDetent {
        case .compact:
            return 176
        case .medium:
            return 360
        case .full:
            return UIScreen.main.bounds.height - 230
        }
    }

    private func placeResultRow(item: MKMapItem, index: Int) -> some View {
        let isSelected = item == selectedPlace

        return
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    PlacePreviewCarousel(coordinate: item.placemark.location?.coordinate)
                        .frame(height: panelDetent == .compact ? 118 : 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 8) {
                        Image(systemName: placeIcon(for: item))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(placeColor(for: item), in: Circle())
                            .overlay {
                                Circle().stroke(.white, lineWidth: 2)
                            }

                        Text(placeTypeLabel(for: item))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(.black.opacity(0.42), in: Capsule())
                    }
                    .padding(10)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.name ?? "Place")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .frame(width: 28, height: 28)
                            .background(isSelected ? Color.blue : Color.secondary.opacity(0.15), in: Circle())
                    }

                    Text(item.placemark.title ?? "Nearby")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let ranked = rankedSpot(for: item) {
                        HStack(spacing: 8) {
                            fairnessBadge(for: ranked)
                            Text(fairnessSummary(for: ranked, index: index))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }

                        LazyVGrid(columns: metricColumns, spacing: 8) {
                            personMetric(title: "You", value: formatETA(ranked.etaFromA), color: .blue)
                            personMetric(title: "Friend", value: formatETA(ranked.etaFromB), color: .orange)
                            personMetric(title: "Gap", value: formatETA(ranked.fairnessGap), color: fairnessColor(for: ranked))
                        }
                    } else {
                        LazyVGrid(columns: metricColumns, spacing: 8) {
                            personMetric(title: "You", value: distanceFrom(savedCoordinate, to: item) ?? "--", color: .blue)
                            personMetric(title: "Friend", value: distanceFrom(peerCoordinate, to: item) ?? "--", color: .orange)
                            personMetric(title: "Middle", value: distanceFrom(midpointCoordinate, to: item) ?? "--", color: .green)
                        }
                    }

                    Button {
                        selectPlaceOnMap(item)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "scope")
                            Text(isSelected ? "Showing on map" : "Show on map")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : .blue)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(isSelected ? Color.blue : Color.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(isSelected ? 0.92 : 0.78), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.blue.opacity(0.55) : Color.secondary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 82), spacing: 8), count: 3)
    }

    private func personMetric(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private func fairnessBadge(for ranked: RankedSpot) -> some View {
        Text("\(fairnessScore(for: ranked)) fair")
            .font(.caption2.weight(.bold))
            .foregroundStyle(fairnessColor(for: ranked))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fairnessColor(for: ranked).opacity(0.14), in: Capsule())
    }

    private func fairnessSummary(for ranked: RankedSpot, index: Int) -> String {
        let worse = formatETA(ranked.worseETA)
        let gap = formatETA(ranked.fairnessGap)
        if index == 0 {
            return "Best balance · longest trip \(worse) · split gap \(gap)"
        }
        return "Longest trip \(worse) · split gap \(gap)"
    }

    private func fairnessScore(for ranked: RankedSpot) -> Int {
        let gapMinutes = ranked.fairnessGap / 60
        let worseMinutes = max(ranked.worseETA / 60, 1)
        let balancePenalty = min(45, (gapMinutes / worseMinutes) * 45)
        let longTripPenalty = min(25, worseMinutes / 3)
        let confidenceBonus = ranked.confidence * 8
        return max(1, min(100, Int((100 - balancePenalty - longTripPenalty + confidenceBonus).rounded())))
    }

    private func fairnessColor(for ranked: RankedSpot) -> Color {
        switch fairnessScore(for: ranked) {
        case 82...:
            return .green
        case 60..<82:
            return .orange
        default:
            return .red
        }
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
                .foregroundStyle(.secondary)
            }
        case .requesting:
            ProgressView("Getting your location…")
        case let .got(coordinate):
            Label(
                formatCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .denied:
            Label("Location access denied. Enable it in Settings to share your spot.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
        updateMyDot()
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
    }

    private func leaveTween() {
        LocationCache.clearAll()
        savedCoordinate = nil
        peerCoordinate = nil
        selectedPlace = nil
        searchResults = []
        searchError = nil
        provider = LocationProvider()
        withAnimation(.easeInOut(duration: 0.35)) {
            position = .automatic
        }
    }

    private func setMapDisplayMode(_ mode: MapDisplayMode) {
        let preservedRegion = lastVisibleRegion
        withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
            mapDisplayMode = mode
        }
        restoreCamera(after: preservedRegion, refocusPlacesIfNeeded: true)
    }

    private func setTrafficVisible(_ isVisible: Bool) {
        let preservedRegion = lastVisibleRegion
        withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
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
            withAnimation(.easeInOut(duration: 0.35)) {
                position = .automatic
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

    private func centerMap(on coordinate: CLLocationCoordinate2D, avoidingBottomOverlay: Bool = false) {
        let span = MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        let adjustedCenter = avoidingBottomOverlay
            ? CLLocationCoordinate2D(latitude: coordinate.latitude - span.latitudeDelta * 0.32, longitude: coordinate.longitude)
            : coordinate
        position = .region(
            MKCoordinateRegion(
                center: adjustedCenter,
                span: span
            )
        )
    }

    private func focusOnPeople() {
        let coordinates = [savedCoordinate, displayPeerCoordinate].compactMap { $0 }
        guard let region = framedRegion(for: coordinates) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
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
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
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
        case .compact: 0.13
        case .medium:  0.24
        case .full:    0.32
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

    private func mapDot(color: Color, systemImage: String) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 48, height: 48)
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                }
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
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
    case group

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: "Map"
        case .group: "Group"
        }
    }

    var systemImage: String {
        switch self {
        case .map: "map"
        case .group: "person.2.fill"
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
    case compact
    case medium
    case full

    var nextHigher: PanelDetent {
        switch self {
        case .compact: .medium
        case .medium: .full
        case .full: .full
        }
    }

    var nextLower: PanelDetent {
        switch self {
        case .compact: .compact
        case .medium: .compact
        case .full: .medium
        }
    }
}

private struct PlacePreviewCarousel: View {
    let coordinate: CLLocationCoordinate2D?

    var body: some View {
        TabView {
            ForEach(PlacePreviewVariant.allCases) { variant in
                PlaceThumbnailView(coordinate: coordinate, variant: variant)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }
}

private enum PlacePreviewVariant: String, CaseIterable, Identifiable {
    case street
    case satellite
    case area

    var id: String { rawValue }

    var mapType: MKMapType {
        switch self {
        case .street:
            return .standard
        case .satellite:
            return .hybrid
        case .area:
            return .mutedStandard
        }
    }

    var span: MKCoordinateSpan {
        switch self {
        case .street:
            return MKCoordinateSpan(latitudeDelta: 0.0035, longitudeDelta: 0.0035)
        case .satellite:
            return MKCoordinateSpan(latitudeDelta: 0.0025, longitudeDelta: 0.0025)
        case .area:
            return MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        }
    }
}

private struct PlaceThumbnailView: View {
    let coordinate: CLLocationCoordinate2D?
    let variant: PlacePreviewVariant
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [.secondary.opacity(0.16), .secondary.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "map.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: thumbnailKey) {
            image = await makeThumbnail()
        }
    }

    private var thumbnailKey: String {
        let coordinateKey = coordinate.map { formatCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ?? "nil"
        return "\(coordinateKey)-\(variant.rawValue)"
    }

    private func makeThumbnail() async -> UIImage? {
        guard let coordinate else { return nil }
        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 640, height: 320)
        options.scale = UIScreen.main.scale
        options.mapType = variant.mapType
        options.region = MKCoordinateRegion(
            center: coordinate,
            span: variant.span
        )

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            return snapshot.image
        } catch {
            return nil
        }
    }
}

#Preview {
    OnboardingView()
}
