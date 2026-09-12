import Foundation
import CoreGraphics

/// Transparent window space around the visible rail and card is an outside click.
func overlayClickIsOutside(_ point: CGPoint, in bounds: CGRect, rail: CGRect, card: CGRect?) -> Bool {
    // Ignore synthetic activation clicks sent to this window with out-of-window coordinates.
    bounds.contains(point) && !rail.contains(point) && card?.contains(point) != true
}

enum DockEdge: String, Codable, CaseIterable {
    case right, left, top, bottom

    var isVertical: Bool { self == .right || self == .left }

    static func nearest(to point: CGPoint, in screen: CGRect) -> DockEdge {
        let distances: [(DockEdge, CGFloat)] = [
            (.right, abs(screen.maxX - point.x)), (.left, abs(point.x - screen.minX)),
            (.top, abs(screen.maxY - point.y)), (.bottom, abs(point.y - screen.minY)),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    func anchor(of frame: CGRect) -> CGPoint {
        switch self {
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        case .top: CGPoint(x: frame.midX, y: frame.maxY)
        case .bottom: CGPoint(x: frame.midX, y: frame.minY)
        }
    }

    /// Clamp along the edge, and keep expansion directed into the usable screen.
    func frame(size: CGSize, anchor: CGPoint, in screen: CGRect) -> CGRect {
        let bounds = screen.insetBy(dx: 4, dy: 4)
        let size = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        let x = min(max(anchor.x - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(anchor.y - size.height / 2, bounds.minY), bounds.maxY - size.height)
        let origin: CGPoint
        switch self {
        case .right: origin = CGPoint(x: bounds.maxX - size.width, y: y)
        case .left: origin = CGPoint(x: bounds.minX, y: y)
        case .top: origin = CGPoint(x: x, y: bounds.maxY - size.height)
        case .bottom: origin = CGPoint(x: x, y: bounds.minY)
        }
        return CGRect(origin: origin, size: size)
    }
}
