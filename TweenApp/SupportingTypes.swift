import CoreLocation
import MapKit
import SwiftUI

// MARK: - Panel & tab types

enum HomePanelTab: String, CaseIterable, Identifiable {
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

enum PanelDetent: CaseIterable {
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

enum MapDisplayMode: String, CaseIterable, Identifiable {
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

enum CategoryPreset: String, CaseIterable, Identifiable {
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

enum FriendEditor: Identifiable {
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

enum ShareIntent: Identifiable {
    case initial
    case update

    var id: String { String(describing: self) }
}

struct MessagePing: Identifiable {
    let id = UUID()
    let friendID: UUID
    let recipient: String
    let body: String
}

struct ContactCandidate: Identifiable, Equatable {
    let id: String
    let contactIdentifier: String
    let name: String
    let handle: String

    var searchableText: String {
        "\(name) \(handle)".lowercased()
    }
}

// MARK: - Debug launch seed

struct DebugLaunchSeed {
    let searchText: String
    let searchResults: [MKMapItem]
    let selectedPlace: MKMapItem?
    let isSearchActive: Bool
    let panelTab: HomePanelTab
    let panelDetent: PanelDetent
    let friends: [TweenFriend]?
    let savedCoordinate: CLLocationCoordinate2D
    let peerCoordinate: CLLocationCoordinate2D
    let shouldFocusPlacesAndPeople: Bool

    static func resolve() -> DebugLaunchSeed? {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        let environmentState = ProcessInfo.processInfo.environment["TWEEN_UI_TEST_STATE"]
        guard arguments.contains("-TweenUITestState") || environmentState != nil else { return nil }

        let savedCoordinate = CLLocationCoordinate2D(latitude: 38.8568, longitude: -77.3909)
        let peerCoordinate = CLLocationCoordinate2D(latitude: 38.9586, longitude: -77.3570)
        let starbucks = mapItem(
            name: "Starbucks Coffee",
            coordinate: CLLocationCoordinate2D(latitude: 38.9575, longitude: -77.3568)
        )
        let park = mapItem(
            name: "Reston Town Center",
            coordinate: CLLocationCoordinate2D(latitude: 38.9587, longitude: -77.3589)
        )

        func has(_ flag: String, _ envValue: String) -> Bool {
            arguments.contains(flag) || environmentState == envValue
        }

        if has("-TweenUITestSearch", "Search") {
            return DebugLaunchSeed(
                searchText: "h",
                searchResults: [],
                selectedPlace: nil,
                isSearchActive: true,
                panelTab: .map,
                panelDetent: .full,
                friends: nil,
                savedCoordinate: savedCoordinate,
                peerCoordinate: peerCoordinate,
                shouldFocusPlacesAndPeople: false
            )
        }
        if has("-TweenUITestResults", "Results") {
            return DebugLaunchSeed(
                searchText: "",
                searchResults: [starbucks, park],
                selectedPlace: starbucks,
                isSearchActive: false,
                panelTab: .map,
                panelDetent: .medium,
                friends: nil,
                savedCoordinate: savedCoordinate,
                peerCoordinate: peerCoordinate,
                shouldFocusPlacesAndPeople: true
            )
        }
        if has("-TweenUITestLiveResults", "LiveResults") {
            return DebugLaunchSeed(
                searchText: "han",
                searchResults: [starbucks, park],
                selectedPlace: starbucks,
                isSearchActive: true,
                panelTab: .map,
                panelDetent: .full,
                friends: nil,
                savedCoordinate: savedCoordinate,
                peerCoordinate: peerCoordinate,
                shouldFocusPlacesAndPeople: true
            )
        }
        if has("-TweenUITestWaiting", "Waiting") {
            return DebugLaunchSeed(
                searchText: "",
                searchResults: [],
                selectedPlace: nil,
                isSearchActive: false,
                panelTab: .waiting,
                panelDetent: .medium,
                friends: [
                    TweenFriend(name: "Maya Ahmed", contactIdentifier: "debug-maya", messageHandle: "maya@example.com")
                ],
                savedCoordinate: savedCoordinate,
                peerCoordinate: peerCoordinate,
                shouldFocusPlacesAndPeople: false
            )
        }
        if has("-TweenUITestMapPin", "MapPin") {
            return DebugLaunchSeed(
                searchText: "",
                searchResults: [starbucks],
                selectedPlace: starbucks,
                isSearchActive: false,
                panelTab: .map,
                panelDetent: .peek,
                friends: nil,
                savedCoordinate: savedCoordinate,
                peerCoordinate: peerCoordinate,
                shouldFocusPlacesAndPeople: true
            )
        }
        return nil
    }

    private static func mapItem(name: String, coordinate: CLLocationCoordinate2D) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

// MARK: - Search completer

final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
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
        completer.resultTypes = [.pointOfInterest, .address, .query]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = Array(completer.results.prefix(10))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}
