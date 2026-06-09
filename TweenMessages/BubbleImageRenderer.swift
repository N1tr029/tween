import CoreLocation
import MapKit
import UIKit

/// Produces the image inside the iMessage bubble. Generated at send time via
/// `MKMapSnapshotter` so the extension never holds a live MKMapView (CLAUDE.md memory
/// constraint). Image is short-lived: handed to `MSMessageTemplateLayout` and discarded.
///
/// Safe-area inset (`keepOut` below): the chat bubble's rounded-corner mask iOS applies on
/// receiver side eats ~20 pt at each corner. We keep all branding + pins outside that.
enum BubbleImageRenderer {
    static let keepOut: CGFloat = 28

    static func makeImage(
        selfCoord: CLLocationCoordinate2D?,
        peer: CLLocationCoordinate2D,
        chosenSpot: RankedSpot?,
        size: CGSize = CGSize(width: 600, height: 400)
    ) async -> UIImage? {
        let coords = ([selfCoord, peer]
            + [chosenSpot?.item.placemark.location?.coordinate])
            .compactMap { $0 }
        guard let region = framedRegion(for: coords) else { return nil }

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 3   // iPhone @3x — bubble image is rendered once and shipped, no need to query UIScreen on a background actor.
        options.region = region
        options.mapType = .standard

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            return composite(snapshot: snapshot, selfCoord: selfCoord, peer: peer, chosenSpot: chosenSpot, size: size)
        } catch {
            return nil
        }
    }

    // MARK: - Composition

    private static func composite(
        snapshot: MKMapSnapshotter.Snapshot,
        selfCoord: CLLocationCoordinate2D?,
        peer: CLLocationCoordinate2D,
        chosenSpot: RankedSpot?,
        size: CGSize
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)

            // Endpoint connection
            if let selfCoord {
                drawLine(
                    from: snapshot.point(for: selfCoord),
                    to: snapshot.point(for: peer)
                )
            }

            // Pins
            if let coordinate = chosenSpot?.item.placemark.location?.coordinate {
                drawMidpointStar(at: snapshot.point(for: coordinate))
            }
            if let selfCoord {
                drawDot(at: snapshot.point(for: selfCoord), color: Tokens.Palette.UIKit.pinSelf)
            }
            drawDot(at: snapshot.point(for: peer), color: Tokens.Palette.UIKit.pinFriend)

            // Bottom branded strip — sits above the rounded-corner keepOut.
            drawBrandedStrip(
                in: ctx.cgContext,
                size: size,
                spotName: chosenSpot?.item.name
            )
        }
    }

    private static func drawBrandedStrip(in cgContext: CGContext, size: CGSize, spotName: String?) {
        let stripHeight: CGFloat = 56
        let stripRect = CGRect(
            x: keepOut,
            y: size.height - keepOut - stripHeight,
            width: size.width - keepOut * 2,
            height: stripHeight
        )

        let bg = UIBezierPath(roundedRect: stripRect, cornerRadius: 14)
        UIColor.black.withAlphaComponent(0.55).setFill()
        bg.fill()

        // Star + wordmark on the left
        let starBg = CGRect(
            x: stripRect.minX + 10,
            y: stripRect.midY - 14,
            width: 28,
            height: 28
        )
        Tokens.Palette.UIKit.brand.setFill()
        UIBezierPath(ovalIn: starBg).fill()
        if let star = UIImage(systemName: "star.fill")?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            star.draw(in: starBg.insetBy(dx: 7, dy: 7))
        }

        let wordmark = NSAttributedString(
            string: "Tween",
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
        )
        wordmark.draw(at: CGPoint(x: starBg.maxX + 8, y: stripRect.midY - 10))

        // Right side: spot name (truncated to fit)
        let trailing = spotName ?? "Meet in the middle"
        let trailingAttr = NSAttributedString(
            string: trailing,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
        )
        let bounding = trailingAttr.boundingRect(
            with: CGSize(width: stripRect.width - 130, height: stripHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
        trailingAttr.draw(at: CGPoint(
            x: stripRect.maxX - bounding.width - 14,
            y: stripRect.midY - bounding.height / 2
        ))
    }

    // MARK: - Pin drawing (mirrors TweenViews.swift, scaled up for the bubble)

    private static func drawMidpointStar(at point: CGPoint) {
        let color = Tokens.Palette.UIKit.pinMidpoint
        let halo = CGRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56)
        let dot = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
        color.withAlphaComponent(0.22).setFill()
        UIBezierPath(ovalIn: halo).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: dot.insetBy(dx: -5, dy: -5)).fill()
        color.setFill()
        UIBezierPath(ovalIn: dot).fill()

        let star = UIImage(systemName: "star.fill")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let starRect = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
        star?.draw(in: starRect)
    }

    private static func drawDot(at point: CGPoint, color: UIColor) {
        let halo = CGRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56)
        let dot = CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26)
        color.withAlphaComponent(0.18).setFill()
        UIBezierPath(ovalIn: halo).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: dot.insetBy(dx: -5, dy: -5)).fill()
        color.setFill()
        UIBezierPath(ovalIn: dot).fill()
    }

    private static func drawLine(from start: CGPoint, to end: CGPoint) {
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        Tokens.Palette.UIKit.pinSelf.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 6
        path.lineCapStyle = .round
        path.setLineDash([12, 10], count: 2, phase: 0)
        path.stroke()
    }

    // MARK: - Region framing

    private static func framedRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        let minLat = coordinates.map(\.latitude).min() ?? first.latitude
        let maxLat = coordinates.map(\.latitude).max() ?? first.latitude
        let minLon = coordinates.map(\.longitude).min() ?? first.longitude
        let maxLon = coordinates.map(\.longitude).max() ?? first.longitude
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.015),
            longitudeDelta: max((maxLon - minLon) * 1.6, 0.015)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
