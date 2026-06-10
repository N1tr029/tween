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
    /// Keep-out inset for the rounded-corner mask Messages applies on the receiver side.
    static let keepOut: CGFloat = 28
    /// Bottom branded strip dimensions and inner element sizes — these are pixel values
    /// in the 600×400 @3x canvas, not points on the device grid.
    private static let stripHeight: CGFloat = 56
    private static let stripCornerRadius: CGFloat = 14
    private static let stripInsetTop: CGFloat = 10
    private static let starBadgeSize: CGFloat = 28
    private static let starInset: CGFloat = 7
    private static let wordmarkOffset: CGFloat = 8
    private static let wordmarkFontSize: CGFloat = 17
    private static let trailingFontSize: CGFloat = 14
    /// Self / friend / midpoint pin sizes — same ratios as the SwiftUI TweenPin, scaled up
    /// for the bubble canvas.
    private static let pinHaloSize: CGFloat = 56
    private static let midpointDotSize: CGFloat = 36
    private static let midpointStarSize: CGFloat = 22
    private static let endpointDotSize: CGFloat = 26

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
            return fallbackImage(selfCoord: selfCoord, peer: peer, chosenSpot: chosenSpot, size: size)
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
                drawDot(at: snapshot.point(for: selfCoord), color: Tokens.Palette.UIKit.pinSelf, isFriend: false)
            }
            drawDot(at: snapshot.point(for: peer), color: Tokens.Palette.UIKit.pinFriend, isFriend: true)

            // Bottom branded strip — sits above the rounded-corner keepOut.
            drawBrandedStrip(
                in: ctx.cgContext,
                size: size,
                spotName: stripTitle(selfCoord: selfCoord, peer: peer, chosenSpot: chosenSpot)
            )
        }
    }

    private static func fallbackImage(
        selfCoord: CLLocationCoordinate2D?,
        peer: CLLocationCoordinate2D,
        chosenSpot: RankedSpot?,
        size: CGSize
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let colors = [
                UIColor(red: 0.90, green: 0.96, blue: 0.95, alpha: 1).cgColor,
                UIColor(red: 0.76, green: 0.89, blue: 0.88, alpha: 1).cgColor,
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])
            ctx.cgContext.drawLinearGradient(
                gradient!,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )

            drawMapGrid(in: rect)

            let selfPoint = CGPoint(x: size.width * 0.32, y: size.height * 0.44)
            let peerPoint = selfCoord == nil
                ? CGPoint(x: size.width * 0.50, y: size.height * 0.42)
                : CGPoint(x: size.width * 0.68, y: size.height * 0.44)
            let spotPoint = CGPoint(x: size.width * 0.50, y: size.height * 0.30)

            if selfCoord != nil {
                drawLine(from: selfPoint, to: peerPoint)
                if chosenSpot != nil {
                    drawLine(from: selfPoint, to: spotPoint)
                    drawLine(from: peerPoint, to: spotPoint)
                    drawMidpointStar(at: spotPoint)
                }
                drawDot(at: selfPoint, color: Tokens.Palette.UIKit.pinSelf, isFriend: false)
            }
            drawDot(at: peerPoint, color: Tokens.Palette.UIKit.pinFriend, isFriend: true)

            drawBrandedStrip(
                in: ctx.cgContext,
                size: size,
                spotName: stripTitle(selfCoord: selfCoord, peer: peer, chosenSpot: chosenSpot)
            )
        }
    }

    private static func stripTitle(
        selfCoord: CLLocationCoordinate2D?,
        peer: CLLocationCoordinate2D,
        chosenSpot: RankedSpot?
    ) -> String {
        if let spotName = chosenSpot?.item.name {
            return spotName
        }
        if let selfCoord {
            return "\(shortDistance(from: selfCoord, to: peer)) apart"
        }
        return "I'm in"
    }

    private static func shortDistance(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> String {
        let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        if meters < 1609 {
            return "\(Int((meters / 10).rounded() * 10)) m"
        }
        return String(format: "%.1f mi", meters / 1609.344)
    }

    private static func drawMapGrid(in rect: CGRect) {
        UIColor.white.withAlphaComponent(0.34).setStroke()
        for offset in stride(from: -rect.height, through: rect.width, by: 72) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
            path.lineWidth = 3
            path.stroke()
        }
        UIColor.white.withAlphaComponent(0.24).setStroke()
        for y in stride(from: rect.minY + 34, through: rect.maxY, by: 68) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y + 22))
            path.lineWidth = 2
            path.stroke()
        }
    }

    private static func drawBrandedStrip(in cgContext: CGContext, size: CGSize, spotName: String?) {
        let stripRect = CGRect(
            x: keepOut,
            y: size.height - keepOut - stripHeight,
            width: size.width - keepOut * 2,
            height: stripHeight
        )

        let bg = UIBezierPath(roundedRect: stripRect, cornerRadius: stripCornerRadius)
        UIColor.black.withAlphaComponent(0.55).setFill()
        bg.fill()

        // Star + wordmark on the left
        let starBg = CGRect(
            x: stripRect.minX + stripInsetTop,
            y: stripRect.midY - starBadgeSize / 2,
            width: starBadgeSize,
            height: starBadgeSize
        )
        Tokens.Palette.UIKit.brand.setFill()
        UIBezierPath(ovalIn: starBg).fill()
        if let star = UIImage(systemName: "star.fill")?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            star.draw(in: starBg.insetBy(dx: starInset, dy: starInset))
        }

        let wordmark = NSAttributedString(
            string: "Tween",
            attributes: [
                .font: UIFont.systemFont(ofSize: wordmarkFontSize, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
        )
        wordmark.draw(at: CGPoint(x: starBg.maxX + wordmarkOffset, y: stripRect.midY - wordmarkFontSize / 1.7))

        // Right side: spot name (truncated to fit)
        let trailing = spotName ?? "Meet in the middle"
        let trailingAttr = NSAttributedString(
            string: trailing,
            attributes: [
                .font: UIFont.systemFont(ofSize: trailingFontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
        )
        let bounding = trailingAttr.boundingRect(
            with: CGSize(width: stripRect.width - 130, height: stripHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
        trailingAttr.draw(at: CGPoint(
            x: stripRect.maxX - bounding.width - stripInsetTop - 4,
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

    /// Shape-distinguished endpoint pin — `isFriend == true` draws a rounded-rect halo so
    /// the bubble image remains legible in color-blind palettes.
    private static func drawDot(at point: CGPoint, color: UIColor, isFriend: Bool) {
        let halo = CGRect(x: point.x - pinHaloSize / 2, y: point.y - pinHaloSize / 2, width: pinHaloSize, height: pinHaloSize)
        let dot = CGRect(x: point.x - endpointDotSize / 2, y: point.y - endpointDotSize / 2, width: endpointDotSize, height: endpointDotSize)
        color.withAlphaComponent(0.18).setFill()
        if isFriend {
            UIBezierPath(roundedRect: halo, cornerRadius: pinHaloSize * 0.30).fill()
        } else {
            UIBezierPath(ovalIn: halo).fill()
        }
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
