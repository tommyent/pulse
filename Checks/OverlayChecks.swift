// Run: swiftc Sources/Pulse/DockGeometry.swift Sources/Pulse/Models.swift Checks/OverlayChecks.swift -o /tmp/pulse-overlay-check && /tmp/pulse-overlay-check
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
        // A throw docks where it is heading; a slow release docks to the nearest edge. The wide screen matters: from its
        // middle the top and bottom are nearer than the sides, so nearest-edge alone turned sideways throws upward.
        for air in [CGRect(x: 0, y: 0, width: 1710, height: 1070), CGRect(x: -1710, y: 400, width: 1710, height: 1070)] {
            let mid = CGPoint(x: air.midX, y: air.midY)
            func lands(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> (edge: DockEdge, point: CGPoint) {
                DockEdge.landing(from: p, velocity: CGVector(dx: dx, dy: dy), in: air)
            }
            assert(lands(mid, 1500, 200).edge == .right, "sideways throw from mid-screen reaches the far side")
            assert(lands(mid, -1500, -200).edge == .left)
            assert(lands(CGPoint(x: air.maxX - 30, y: mid.y), -900, 120).edge == .left, "a rail thrown off the right edge crosses over")
            let up = lands(CGPoint(x: mid.x, y: air.minY + 150), 120, 1500)
            assert(up.edge == .top, "bottom-to-top throw lands on top")
            assert(up.point.y == air.maxY && abs(up.point.x - (mid.x + 120 * (air.height - 150) / 1500)) < 0.5,
                   "it lands where its path meets the edge")
            assert(lands(CGPoint(x: mid.x, y: air.minY + 150), 0, 120).edge == .bottom, "a slow drop stays nearest")
            assert(lands(CGPoint(x: air.maxX - 200, y: mid.y), -150, 0).edge == .right)
            let still = lands(CGPoint(x: mid.x + 100, y: air.maxY - 50), 0, 0)
            assert(still.edge == .top && still.point == CGPoint(x: mid.x + 100, y: air.maxY - 50))
            assert(lands(CGPoint(x: air.maxX + 40, y: mid.y), 0, 0).point.x == air.maxX, "a release past the edge stays on the screen")
        }
        // Speed comes from the drag's last moments: a pause before letting go is a drop, not a throw.
        var throwing = ThrowTracker()
        for i in 0...20 { throwing.add(CGPoint(x: 100 + 10 * CGFloat(i), y: 500), at: 1 + 0.008 * Double(i)) }
        let flung = throwing.velocity(at: 1.16)
        assert(abs(flung.dx - 1250) < 1 && flung.dy == 0, "10 pt every 8 ms is 1250 pt/s, got \(flung)")
        throwing.add(CGPoint(x: 300, y: 500), at: 1.3)
        assert(throwing.velocity(at: 1.3) == .zero, "held still for 140 ms before release")
        assert(ThrowTracker().velocity(at: 5) == .zero)
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
        // Reset labels: relative under a day, weekday under six days, weekday plus date beyond.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        assert(resetLabel(now.addingTimeInterval(-1), now: now) == "Resetting…")
        assert(resetLabel(now.addingTimeInterval(5 * 60 + 30), now: now) == "Resets in 5 min")
        assert(resetLabel(now.addingTimeInterval(2 * 3600 + 38 * 60 + 10), now: now) == "Resets in 2h 38m")
        let soon = now.addingTimeInterval(3 * 86400), nextWeek = now.addingTimeInterval(7 * 86400 - 60)
        assert(!resetLabel(soon, now: now).contains(soon.formatted(.dateTime.month())), "under six days: weekday only")
        assert(resetLabel(nextWeek, now: now).contains(nextWeek.formatted(.dateTime.day())), "a week out names the date")
        assert(resetLabel(nextWeek, now: now).contains(nextWeek.formatted(.dateTime.hour().minute())), "time follows the locale")
        // The pet's transcript: content growing, twice in a row, keeps a reader at the bottom following; their own scroll decides.
        var following = true
        following = transcriptFollows(following, oldOffset: 740, offset: 740, visible: 260, content: 1100)
        following = transcriptFollows(following, oldOffset: 740, offset: 740, visible: 260, content: 1200)
        assert(following, "successive content growth keeps following")
        following = transcriptFollows(following, oldOffset: 940, offset: 600, visible: 260, content: 1200)
        assert(!following, "scrolling up stops following")
        following = transcriptFollows(following, oldOffset: 600, offset: 600, visible: 260, content: 1300)
        assert(!following, "new text never pulls back a reader who scrolled up")
        following = transcriptFollows(following, oldOffset: 600, offset: 1040, visible: 260, content: 1300)
        assert(following, "back at the bottom, it follows again")
        print("Overlay checks passed: docking, throws, expansion, displays, persistence, pop-out dismissal, reset labels and transcript following")
    }
}
