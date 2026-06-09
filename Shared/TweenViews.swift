import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Formats a coordinate for compact display, e.g. "40.7128, -74.0060".
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

    private var receivedCoordinate: CLLocationCoordinate2D? {
        state == .placeholder ? nil : state.coordinate
    }

    private var summaryText: String {
        state == .placeholder ? "meet in the middle" : state.text
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TweenMapSnapshotView(received: receivedCoordinate, cachedCoordinate: nil)

            HStack(spacing: Tokens.Space.s2) {
                Button(action: onTap) {
                    HStack(spacing: Tokens.Space.s2) {
                        ZStack {
                            Circle()
                                .fill(Tokens.Palette.brand)
                            Image(systemName: "star.fill")
                                .font(Tokens.Typography.iconBadge)
                                .foregroundStyle(.white)
                        }
                        .frame(width: 22, height: 22)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Tween")
                                .font(Tokens.Typography.captionEmphasized)
                                .foregroundStyle(Tokens.Palette.onSurface)
                            Text(summaryText)
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.up.right")
                            .font(Tokens.Typography.iconBadge)
                            .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Open Tween. \(summaryText).")
                .accessibilityHint("Expands the Tween app to pick a meetup spot.")

                Button(action: onImIn) {
                    Text("I'm in")
                        .font(Tokens.Typography.captionEmphasized)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        // Compact extension viewport — keyboard height is fixed.
                        // Tightening is preferable to truncation at AX sizes.
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, Tokens.Space.s3)
                        .frame(height: 32)
                        .background(Tokens.Palette.brand, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Tokens.Space.s3)
            .padding(.vertical, Tokens.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
                    .background(Tokens.Palette.glassStroke)
            }
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
    var pendingDraft: OutgoingDraft? = nil
    let onImIn: () -> Void
    var onSendDraft: () -> Void = {}
    var onCancelDraft: () -> Void = {}

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

            VStack(alignment: .leading, spacing: Tokens.Space.s3 + 2) {
                if let pendingDraft {
                    pendingDraftCard(pendingDraft)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text("Tween")
                            .font(Tokens.Typography.display)
                        Text(received?.text ?? "Meet in the middle")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                            .lineLimit(1)
                        if let received, let cachedCoordinate {
                            Text("\(formatDistance(from: received.coordinate, to: cachedCoordinate)) apart")
                                .font(Tokens.Typography.callout.weight(.semibold))
                                .foregroundStyle(Tokens.Palette.onSurface)
                        }
                    }

                    Spacer()

                    Image(systemName: cachedCoordinate == nil ? "location.slash" : "location.fill")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(cachedCoordinate == nil ? Tokens.Palette.onSurfaceMuted : Tokens.Palette.pinSelf)
                }

                HStack(spacing: Tokens.Space.s2 + 2) {
                    locationBadge(
                        title: "Meetup",
                        coordinate: received?.coordinate,
                        color: Tokens.Palette.pinFriend,
                        emptyText: "No meetup yet"
                    )
                    locationBadge(
                        title: "You",
                        coordinate: cachedCoordinate,
                        color: Tokens.Palette.pinSelf,
                        emptyText: "No dot yet"
                    )
                }

                if !topSpots.isEmpty {
                    fairSpotsRow
                }

                Button(action: onImIn) {
                    HStack(spacing: Tokens.Space.s2) {
                        if isRequesting { ProgressView().tint(.white) }
                        Text(cachedCoordinate == nil ? "Share location & add bubble" : "Send I'm in to chat")
                    }
                }
                .buttonStyle(.tweenPrimary)
                .disabled(isRequesting)

                Text("After the bubble appears in Messages, tap the blue send arrow.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(Tokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tweenGlass(cornerRadius: Tokens.Radius.sheet)
            .padding(Tokens.Space.s3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func pendingDraftCard(_ draft: OutgoingDraft) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2 + 2) {
            HStack(spacing: Tokens.Space.s2) {
                ZStack {
                    Circle().fill(Tokens.Palette.brand)
                    Image(systemName: "paperplane.fill")
                        .font(Tokens.Typography.iconBadge)
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send chosen spot?")
                        .font(Tokens.Typography.captionEmphasized)
                    Text("Meet at \(draft.name)")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: Tokens.Space.s2) {
                Button(action: onSendDraft) {
                    Text("Send")
                }
                .buttonStyle(.tweenPrimary)

                Button(action: onCancelDraft) {
                    Text("Cancel")
                }
                .buttonStyle(.tweenSubtle)
            }
        }
        .padding(Tokens.Space.s3)
        .background(Tokens.Palette.brandMuted, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    private var fairSpotsRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1 + 2) {
            Text("Fair meetup spots")
                .font(Tokens.Typography.captionEmphasized)
                .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Space.s2) {
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
        let isTop = rank == 1
        return HStack(spacing: Tokens.Space.s2) {
            ZStack {
                Circle()
                    .fill(isTop ? Tokens.Palette.brand : Tokens.Palette.onSurfaceMuted)
                if isTop {
                    Image(systemName: "star.fill")
                        .font(Tokens.Typography.iconBadge)
                        .foregroundStyle(.white)
                } else {
                    Text("\(rank)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.item.name ?? "Place")
                    .font(Tokens.Typography.captionEmphasized)
                    .lineLimit(1)
                Text("You \(aMin)m · Friend \(bMin)m")
                    .font(.caption2)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Tokens.Space.s2 + 2)
        .padding(.vertical, Tokens.Space.s1 + 2)
        .background(isTop ? Tokens.Palette.brandMuted : Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip + 2))
    }

    private func locationBadge(
        title: String,
        coordinate: CLLocationCoordinate2D?,
        color: Color,
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1 + 2) {
            HStack(spacing: Tokens.Space.s1 + 2) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(Tokens.Typography.captionEmphasized)
                    .foregroundStyle(Tokens.Palette.onSurfaceMuted)
            }

            Text(
                coordinate.map { formatCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
                    ?? emptyText
            )
            .font(Tokens.Typography.caption)
            .lineLimit(1)
            // Coordinate strings are fixed-format ("12.3456, -98.7654") and the badge
            // is a fixed-width grid item — tighten before truncating.
            .minimumScaleFactor(0.8)
        }
        .padding(Tokens.Space.s2 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
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
                    LinearGradient(
                        colors: [.blue.opacity(0.20), .green.opacity(0.12), .secondary.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "map")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
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
        guard let region = snapshotRegion() else { return nil }
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = UIScreen.main.scale
        options.region = region

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snapshot = try await snapshotter.start()
            return drawPins(on: snapshot)
        } catch {
            return nil
        }
    }

    private func snapshotRegion() -> MKCoordinateRegion? {
        // Fit endpoints AND ranked spots in the same frame so all pins are visible.
        let coordinates = ([received, cachedCoordinate].compactMap { $0 }) + rankedCoordinates
        guard let first = coordinates.first else { return nil }

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
            // Ranked spots: rank-1 gets the brand midpoint star; the rest are muted dots.
            for (index, coord) in rankedCoordinates.enumerated() {
                if index == 0 {
                    drawMidpointStar(at: snapshot.point(for: coord))
                } else {
                    drawSmallPin(at: snapshot.point(for: coord), color: Tokens.Palette.UIKit.onSurfaceMuted)
                }
            }
            if let received {
                drawDot(at: snapshot.point(for: received), color: Tokens.Palette.UIKit.pinFriend, isFriend: true)
            }
            if let cachedCoordinate {
                drawDot(at: snapshot.point(for: cachedCoordinate), color: Tokens.Palette.UIKit.pinSelf, isFriend: false)
            }
        }
    }

    private func drawMidpointStar(at point: CGPoint) {
        let color = Tokens.Palette.UIKit.pinMidpoint
        let halo = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        let dot = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
        color.withAlphaComponent(0.22).setFill()
        UIBezierPath(ovalIn: halo).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3)).fill()
        color.setFill()
        UIBezierPath(ovalIn: dot).fill()

        let star = UIImage(systemName: "star.fill")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let starRect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
        star?.draw(in: starRect)
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
        Tokens.Palette.UIKit.pinSelf.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.setLineDash([8, 7], count: 2, phase: 0)
        path.stroke()
    }

    /// Shape-distinguished endpoint pin: `isFriend == true` draws a rounded-rect halo so
    /// the friend pin reads differently from the self pin even in monochrome.
    private func drawDot(at point: CGPoint, color: UIColor, isFriend: Bool) {
        let halo = CGRect(x: point.x - 19, y: point.y - 19, width: 38, height: 38)
        let dot = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        color.withAlphaComponent(0.18).setFill()
        if isFriend {
            UIBezierPath(roundedRect: halo, cornerRadius: 11).fill()
        } else {
            UIBezierPath(ovalIn: halo).fill()
        }
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
        received: TweenState(text: "Lunch?", latitude: 40.7128, longitude: -74.0060),
        cachedCoordinate: CLLocationCoordinate2D(latitude: 40.7306, longitude: -73.9352),
        isRequesting: false,
        onImIn: {}
    )
}
