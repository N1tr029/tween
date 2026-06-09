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
    @State private var position = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
            span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
        )
    )

    var body: some View {
        ZStack(alignment: .top) {
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
                                placeDot(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.cafe, .restaurant, .publicTransport])))
            .ignoresSafeArea()

            VStack(spacing: 8) {
                searchBar
                #if DEBUG
                debugCachePanel
                #endif
            }

            VStack {
                Spacer()
                bottomPanel
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
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

                if panelDetent != .full {
                    statusView
                }

                if !searchResults.isEmpty {
                    placeResultsList
                } else if let searchError {
                    Label(searchError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                if panelDetent != .full {
                    actionControls
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, searchResults.isEmpty ? 20 : 10)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: panelHeight, alignment: .top)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            .gesture(panelDragGesture)
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
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    if value.translation.height < -50 {
                        panelDetent = panelDetent.nextHigher
                    } else if value.translation.height > 50 {
                        panelDetent = panelDetent.nextLower
                    }
                }
            }
    }

    private var panelHeight: CGFloat? {
        guard !searchResults.isEmpty else { return nil }
        let screenHeight = UIScreen.main.bounds.height
        switch panelDetent {
        case .compact:
            return 238
        case .medium:
            return min(430, screenHeight * 0.48)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Options")
                    .font(.headline)
                Spacer()
                Text("\(searchResults.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(searchResults.enumerated()), id: \.element) { index, item in
                        placeResultRow(item: item, index: index)
                    }
                }
            }
            .frame(maxHeight: placeListHeight)
        }
    }

    private var placeListHeight: CGFloat {
        switch panelDetent {
        case .compact:
            return 102
        case .medium:
            return 220
        case .full:
            return UIScreen.main.bounds.height - 250
        }
    }

    private func placeResultRow(item: MKMapItem, index: Int) -> some View {
        let isSelected = item == selectedPlace

        return Button {
            selectedPlace = item
            if let coordinate = item.placemark.location?.coordinate {
                centerMap(on: coordinate, avoidingBottomOverlay: true)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    PlaceThumbnailView(coordinate: item.placemark.location?.coordinate)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Image(systemName: placeIcon(for: item))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(placeColor(for: item), in: Circle())
                        .overlay {
                            Circle().stroke(.white, lineWidth: 2)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name ?? "Place")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.placemark.title ?? "Nearby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let ranked = rankedSpot(for: item) {
                        HStack(spacing: 8) {
                            distanceChip("You", formatETA(ranked.etaFromA))
                            distanceChip("Friend", formatETA(ranked.etaFromB))
                            distanceChip("Gap", formatETA(ranked.fairnessGap))
                        }
                    } else {
                        HStack(spacing: 8) {
                            distanceChip("You", distanceFrom(savedCoordinate, to: item))
                            distanceChip("Friend", distanceFrom(peerCoordinate, to: item))
                            distanceChip("Middle", distanceFrom(midpointCoordinate, to: item))
                        }
                    }
                }
                Spacer(minLength: 0)

                Text("\(index + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 26, height: 26)
                    .background(isSelected ? Color.green : Color.secondary.opacity(0.15), in: Circle())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func distanceChip(_ label: String, _ distance: String?) -> some View {
        Group {
            if let distance {
                Text("\(label) \(distance)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
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

    private func leaveTween() {
        LocationCache.clearAll()
        savedCoordinate = nil
        peerCoordinate = nil
        selectedPlace = nil
        searchResults = []
        searchError = nil
        provider = LocationProvider()
        withAnimation(.easeInOut(duration: 0.35)) {
            position = MapCameraPosition.region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                    span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
                )
            )
        }
    }

    private func prepareInitialMap() {
        refreshSavedLocation(forceFocus: true)
    }

    private func refreshSavedLocation(forceFocus: Bool = false) {
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
        withAnimation(.easeInOut(duration: 0.45)) {
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

    private func focusOnPlacesAndPeople() {
        var coordinates = [savedCoordinate, displayPeerCoordinate].compactMap { $0 }
        coordinates.append(contentsOf: searchResults.compactMap { $0.placemark.location?.coordinate })
        guard let region = framedRegion(for: coordinates, paddingFactor: 0.4, minimumDelta: 0.025) else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
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

    private func placeCategoryText(for item: MKMapItem) -> String {
        [item.pointOfInterestCategory?.rawValue, item.name]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
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

private struct PlaceThumbnailView: View {
    let coordinate: CLLocationCoordinate2D?
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
        coordinate.map { formatCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ?? "nil"
    }

    private func makeThumbnail() async -> UIImage? {
        guard let coordinate else { return nil }
        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 112, height: 112)
        options.scale = UIScreen.main.scale
        options.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
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
