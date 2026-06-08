import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Formats a coordinate for compact display, e.g. "37.3349, -122.0090".
func formatCoordinate(latitude: Double, longitude: Double) -> String {
    String(format: "%.4f, %.4f", latitude, longitude)
}

func formatDistance(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> String {
    let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
        .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    let miles = meters / 1609.344
    return miles < 0.1
        ? String(format: "%.0f ft", meters * 3.28084)
        : String(format: "%.1f mi", miles)
}

/// Compact presentation: keyboard-height, no first responder / no keyboard.
/// Tapping requests the expanded style (handled by the host).
struct CompactView: View {
    let state: TweenState
    let onTap: () -> Void
    let onImIn: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TweenMapSnapshotView(received: state.coordinate, cachedCoordinate: nil)

            HStack(spacing: 10) {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.text)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Open map")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(action: onImIn) {
                    Text("Send I'm in")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Expanded presentation: shows any received state and an "I'm in" control that sends the
/// user's cached location into the thread. When no location is cached, the same control
/// requests it in-extension first (the host wires `onImIn` to that flow).
///
/// `rankedSpots` (top-3 used) — fairness-ranked meetup candidates from `FairnessRanker`.
/// Default `[]` keeps existing callers (compact path, harness-without-ranking) building.
struct ExpandedView: View {
    let received: TweenState?
    let cachedCoordinate: CLLocationCoordinate2D?
    let isRequesting: Bool
    var rankedSpots: [RankedSpot] = []
    let onImIn: () -> Void

    private var topSpots: [RankedSpot] { Array(rankedSpots.prefix(3)) }

    var body: some View {
        ZStack(alignment: .bottom) {
            TweenMapSnapshotView(
                received: received?.coordinate,
                cachedCoordinate: cachedCoordinate,
                rankedCoordinates: topSpots.compactMap { $0.item.placemark.location?.coordinate },
                verticalFocusOffset: 0.28
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tween")
                            .font(.largeTitle.bold())
                        Text(received?.text ?? "Meet in the middle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let received, let cachedCoordinate {
                            Text("\(formatDistance(from: received.coordinate, to: cachedCoordinate)) apart")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }

                    Spacer()

                    Image(systemName: cachedCoordinate == nil ? "location.slash" : "location.fill")
                        .font(.title2)
                        .foregroundStyle(cachedCoordinate == nil ? Color.secondary : Color.blue)
                }

                HStack(spacing: 10) {
                    locationBadge(
                        title: "Meetup",
                        coordinate: received?.coordinate,
                        color: .orange,
                        emptyText: "No meetup yet"
                    )
                    locationBadge(
                        title: "You",
                        coordinate: cachedCoordinate,
                        color: .blue,
                        emptyText: "No dot yet"
                    )
                }

                if !topSpots.isEmpty {
                    fairSpotsRow
                }

                Button(action: onImIn) {
                    HStack(spacing: 8) {
                        if isRequesting { ProgressView().tint(.white) }
                        Text(cachedCoordinate == nil ? "Share location & add bubble" : "Send I'm in to chat")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .disabled(isRequesting)

                Text("After the bubble appears in Messages, tap the blue send arrow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var fairSpotsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fair meetup spots")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(topSpots.enumerated()), id: \.offset) { offset, spot in
                        fairSpotChip(rank: offset + 1, spot: spot)
                    }
                }
            }
        }
    }

    private func fairSpotChip(rank: Int, spot: RankedSpot) -> some View {
        let aMin = Int((spot.etaFromA / 60).rounded())
        let bMin = Int((spot.etaFromB / 60).rounded())
        return HStack(spacing: 8) {
            Text("\(rank)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(rank == 1 ? Color.orange : Color.secondary, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.item.name ?? "Place")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("You \(aMin)m · Friend \(bMin)m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func locationBadge(
        title: String,
        coordinate: CLLocationCoordinate2D?,
        color: Color,
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(
                coordinate.map { formatCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
                    ?? emptyText
            )
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TweenMapSnapshotView: View {
    let received: CLLocationCoordinate2D?
    let cachedCoordinate: CLLocationCoordinate2D?
    var rankedCoordinates: [CLLocationCoordinate2D] = []
    var verticalFocusOffset: CLLocationDegrees = 0

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(
                width: max(proxy.size.width, 1),
                height: max(proxy.size.height, 1)
            )

            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.tertiary.opacity(0.35))
                    ProgressView()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .task(id: snapshotKey(size: size)) {
                image = await makeSnapshot(size: size)
            }
        }
    }

    private func snapshotKey(size: CGSize) -> String {
        var parts: [String] = [
            String(format: "%.0f", size.width),
            String(format: "%.0f", size.height),
            String(format: "%.2f", verticalFocusOffset),
            received.map { formatCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ?? "nil",
            cachedCoordinate.map { formatCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ?? "nil",
        ]
        parts.append(contentsOf: rankedCoordinates.map { formatCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
        return parts.joined(separator: "|")
    }

    private func makeSnapshot(size: CGSize) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = UIScreen.main.scale
        options.region = snapshotRegion()

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snapshot = try await snapshotter.start()
            return drawPins(on: snapshot)
        } catch {
            return nil
        }
    }

    private func snapshotRegion() -> MKCoordinateRegion {
        // Fit endpoints AND ranked spots in the same frame so all pins are visible.
        let coordinates = ([received, cachedCoordinate].compactMap { $0 }) + rankedCoordinates
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
            )
        }

        let minLatitude = coordinates.map(\.latitude).min() ?? first.latitude
        let maxLatitude = coordinates.map(\.latitude).max() ?? first.latitude
        let minLongitude = coordinates.map(\.longitude).min() ?? first.longitude
        let maxLongitude = coordinates.map(\.longitude).max() ?? first.longitude

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLatitude - minLatitude) * 1.8, 0.01),
            longitudeDelta: max((maxLongitude - minLongitude) * 1.8, 0.01)
        )
        let adjustedCenter = CLLocationCoordinate2D(
            latitude: center.latitude - (span.latitudeDelta * verticalFocusOffset),
            longitude: center.longitude
        )
        return MKCoordinateRegion(center: adjustedCenter, span: span)
    }

    private func drawPins(on snapshot: MKMapSnapshotter.Snapshot) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        return renderer.image { _ in
            snapshot.image.draw(at: .zero)
            if let received, let cachedCoordinate {
                drawLine(from: snapshot.point(for: received), to: snapshot.point(for: cachedCoordinate))
            }
            // Ranked spots: small accent pins under the endpoint pins. Rank-1 stands out.
            for (index, coord) in rankedCoordinates.enumerated() {
                let color: UIColor = index == 0 ? .systemOrange : .systemGray2
                drawSmallPin(at: snapshot.point(for: coord), color: color)
            }
            if let received {
                drawDot(at: snapshot.point(for: received), color: .systemOrange)
            }
            if let cachedCoordinate {
                drawDot(at: snapshot.point(for: cachedCoordinate), color: .systemBlue)
            }
        }
    }

    private func drawSmallPin(at point: CGPoint, color: UIColor) {
        let halo = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
        let dot = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        color.withAlphaComponent(0.20).setFill()
        UIBezierPath(ovalIn: halo).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2)).fill()
        color.setFill()
        UIBezierPath(ovalIn: dot).fill()
    }

    private func drawLine(from start: CGPoint, to end: CGPoint) {
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        UIColor.systemBlue.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.setLineDash([8, 7], count: 2, phase: 0)
        path.stroke()
    }

    private func drawDot(at point: CGPoint, color: UIColor) {
        let halo = CGRect(x: point.x - 19, y: point.y - 19, width: 38, height: 38)
        let dot = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        color.withAlphaComponent(0.18).setFill()
        UIBezierPath(ovalIn: halo).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: dot.insetBy(dx: -4, dy: -4)).fill()
        color.setFill()
        UIBezierPath(ovalIn: dot).fill()
    }
}

#Preview("Compact") {
    CompactView(state: .placeholder, onTap: {}, onImIn: {})
        .frame(height: 90)
}

#Preview("Expanded — cached") {
    ExpandedView(
        received: TweenState(text: "Lunch at Caffè Macs?", latitude: 37.3349, longitude: -122.0090),
        cachedCoordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        isRequesting: false,
        onImIn: {}
    )
}
