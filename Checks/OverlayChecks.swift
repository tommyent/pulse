// Run: swiftc Sources/Pulse/DockGeometry.swift Checks/OverlayChecks.swift -o /tmp/pulse-overlay-check && /tmp/pulse-overlay-check
import Foundation
import CoreGraphics

@main
enum OverlayChecks {
    static func main() {
        // Include a display left of the main screen and one above it.
        for screen in [CGRect(x: 0, y: 25, width: 1440, height: 875),
                       CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                       CGRect(x: 0, y: 1080, width: 1440, height: 900)] {
            for edge in DockEdge.allCases {
                let drop = edge.anchor(of: screen.insetBy(dx: 2, dy: 2))
                assert(DockEdge.nearest(to: drop, in: screen) == edge)
                let collapsed = edge.frame(size: CGSize(width: 68, height: 148), anchor: drop, in: screen)
                let expanded = edge.frame(size: CGSize(width: 440, height: 320), anchor: drop, in: screen)
                assert(screen.contains(collapsed) && screen.contains(expanded))
                assert(edge.anchor(of: collapsed) == edge.anchor(of: expanded))
                for point in [screen.origin, CGPoint(x: screen.maxX, y: screen.maxY)] {
                    assert(screen.contains(edge.frame(size: expanded.size, anchor: point, in: screen)))
                }
                assert(edge.isVertical == (edge == .left || edge == .right))
                assert((try! JSONDecoder().decode(DockEdge.self, from: JSONEncoder().encode(edge))) == edge)
            }
        }
        // The short card leaves transparent window space above and below it.
        // Rotate the layout to exercise the same dismissal rules on all four edges.
        for turns in 0..<4 {
            let rotation = CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2)
            let bounds = CGRect(x: 0, y: 0, width: 449, height: 323).applying(rotation)
            let rail = CGRect(x: 350, y: 12, width: 76, height: 300).applying(rotation)
            let card = CGRect(x: 12, y: 100, width: 320, height: 110).applying(rotation)
            for point in [CGPoint(x: 380, y: 155), CGPoint(x: 100, y: 155)] {
                assert(!overlayClickIsOutside(point.applying(rotation), in: bounds, rail: rail, card: card))
            }
            for point in [CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 270)] {
                assert(overlayClickIsOutside(point.applying(rotation), in: bounds, rail: rail, card: card))
            }
            let gap = CGPoint(x: 340, y: 155).applying(rotation)
            assert(overlayClickIsOutside(gap, in: bounds, rail: rail, card: card))
            assert(overlayClickIsOutside(CGPoint(x: 100, y: 155).applying(rotation), in: bounds, rail: rail,
                                        card: nil))
            let activationClick = CGPoint(x: -1258, y: 762).applying(rotation)
            assert(!overlayClickIsOutside(activationClick, in: bounds, rail: rail, card: card))
        }
        print("Overlay checks passed: docking, expansion, displays, persistence and pop-out dismissal")
    }
}
