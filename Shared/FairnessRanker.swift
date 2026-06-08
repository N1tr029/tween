import CoreLocation
import Foundation
import MapKit

/// One candidate meetup spot scored by drive-time fairness between two people.
struct RankedSpot {
    let item: MKMapItem
    let etaFromA: TimeInterval
    let etaFromB: TimeInterval
    /// 0...1. Proxy for "how established / well-known" the place is.
    /// MKMapItem has no rating on iOS; this stands in until we have a real signal.
    let confidence: Double

    /// The longer commute of the two — the "worse" of A and B's drive time.
    /// This is the primary thing we minimize: a spot is fair if neither party drives much.
    var worseETA: TimeInterval { max(etaFromA, etaFromB) }

    /// Absolute difference between A and B's drive times. Lower = more balanced.
    var fairnessGap: TimeInterval { abs(etaFromA - etaFromB) }
}

/// Ranks candidate `MKMapItem`s by drive-time fairness, with a small confidence kicker
/// that lets a slightly-farther but more-established place outrank a closer unknown one.
///
/// Primary score: `worseETA - W * confidence`, where W is `confidenceWeightSeconds`.
/// A confidence of 1.0 can outrank a closer spot by up to W seconds of worseETA.
///
/// No memo for now — the dry-run harness runs this once per tap and the production
/// path will run it once per `searchPlaces()` result set. Add caching if Slice 3
/// extension-side use shows recompute pressure.
enum FairnessRanker {
    /// Hard cap on candidates we'll fire MKDirections requests for. Apple rate-limits
    /// directions at ~50/min; 8 candidates × 2 routes = 16 keeps headroom for re-queries.
    static let defaultCap = 8

    /// Seconds-equivalent weight on the confidence kicker. A high-confidence place
    /// can outrank a closer one by up to this many seconds of worse drive time.
    static let confidenceWeightSeconds: TimeInterval = 120

    static func rank(
        candidates: [MKMapItem],
        from a: CLLocationCoordinate2D,
        and b: CLLocationCoordinate2D,
        cap: Int = defaultCap
    ) async -> [RankedSpot] {
        let limited = Array(candidates.prefix(cap))

        let ranked = await withTaskGroup(of: RankedSpot?.self, returning: [RankedSpot].self) { group in
            for item in limited {
                group.addTask { await route(for: item, from: a, and: b) }
            }
            var collected: [RankedSpot] = []
            for await spot in group {
                if let spot { collected.append(spot) }
            }
            return collected
        }

        return ranked.sorted { score($0) < score($1) }
    }

    private static func route(
        for item: MKMapItem,
        from a: CLLocationCoordinate2D,
        and b: CLLocationCoordinate2D
    ) async -> RankedSpot? {
        guard let destination = item.placemark.location?.coordinate else { return nil }
        async let etaA = eta(from: a, to: destination)
        async let etaB = eta(from: b, to: destination)
        let (resolvedA, resolvedB) = await (etaA, etaB)
        guard let etaA = resolvedA, let etaB = resolvedB else { return nil }
        return RankedSpot(
            item: item,
            etaFromA: etaA,
            etaFromB: etaB,
            confidence: confidence(for: item)
        )
    }

    private static func eta(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        do {
            return try await MKDirections(request: request).calculateETA().expectedTravelTime
        } catch {
            return nil
        }
    }

    private static func confidence(for item: MKMapItem) -> Double {
        var score = 0.0
        if item.pointOfInterestCategory != nil { score += 0.3 }
        if item.phoneNumber != nil { score += 0.3 }
        if item.url != nil { score += 0.2 }
        if item.name?.isEmpty == false { score += 0.2 }
        return min(1.0, score)
    }

    private static func score(_ spot: RankedSpot) -> Double {
        spot.worseETA - confidenceWeightSeconds * spot.confidence
    }
}
