// Run: swiftc Sources/Pulse/DockGeometry.swift Sources/Pulse/Models.swift Checks/OverlayChecks.swift -o /tmp/pulse-overlay-check && /tmp/pulse-overlay-check
import Foundation
import CoreGraphics
import SwiftUI

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
            func lands(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat, on current: DockEdge) -> (edge: DockEdge, point: CGPoint) {
                DockEdge.landing(from: p, velocity: CGVector(dx: dx, dy: dy), current: current, in: air)
            }
            // the owner's case: a rail from the top, dragged to mid-screen and thrown sideways, reaches the far side
            assert(lands(mid, 1500, 200, on: .top).edge == .right, "sideways throw from mid-screen reaches the far side")
            assert(lands(mid, -1500, -200, on: .bottom).edge == .left)
            assert(lands(CGPoint(x: air.maxX - 30, y: mid.y), -900, 120, on: .right).edge == .left, "a rail thrown off the right edge crosses over")
            let up = lands(CGPoint(x: mid.x, y: air.minY + 150), 120, 1500, on: .bottom)
            assert(up.edge == .top, "bottom-to-top throw lands on top")
            assert(up.point.y == air.maxY && abs(up.point.x - (mid.x + 120 * (air.height - 150) / 1500)) < 0.5,
                   "it lands where its path meets the edge")
            assert(lands(CGPoint(x: mid.x, y: air.minY + 150), 0, 120, on: .top).edge == .bottom, "a slow drop stays nearest")
            assert(lands(CGPoint(x: air.maxX - 200, y: mid.y), -150, 0, on: .left).edge == .right)
            let still = lands(CGPoint(x: mid.x + 100, y: air.maxY - 50), 0, 0, on: .right)
            assert(still.edge == .top && still.point == CGPoint(x: mid.x + 100, y: air.maxY - 50))
            assert(lands(CGPoint(x: air.maxX + 40, y: mid.y), 0, 0, on: .right).point.x == air.maxX, "a release past the edge stays on the screen")
            // Slow drops use diagonal zones: each edge owns the triangle between it and the screen's centre, so a rail drawn
            // in from a side goes back to it until past the centre line (at mid-height), however wide the screen.
            for h in [0.35, 0.5, 0.65] as [CGFloat] {
                let y = air.minY + air.height * h
                assert(lands(CGPoint(x: air.maxX - air.width * 0.3, y: y), 40, 0, on: .right).edge == .right, "30% in from the right at \(h) docks right")
                assert(lands(CGPoint(x: air.minX + air.width * 0.3, y: y), -40, 0, on: .left).edge == .left, "30% in from the left at \(h) docks left")
            }
            assert(lands(CGPoint(x: air.maxX - air.width * 0.6, y: mid.y), 0, 0, on: .right).edge == .left, "60% in from the right docks left")
            assert(lands(CGPoint(x: mid.x, y: air.maxY - air.height * 0.1), 0, 0, on: .right).edge == .top, "near the top centre docks top")
            assert(lands(CGPoint(x: mid.x + 200, y: air.minY + air.height * 0.1), 0, 0, on: .left).edge == .bottom)
            // Sliding the rail along its own edge and letting go while moving is a reposition: it keeps the edge and coasts.
            let slid = lands(CGPoint(x: air.maxX - 60, y: mid.y), 150, -1500, on: .right)
            assert(slid.edge == .right && abs(slid.point.y - (mid.y - 150)) < 0.5, "a fast slide down the right edge stays right")
            assert(lands(CGPoint(x: mid.x, y: air.maxY - 80), 1800, -300, on: .top).edge == .top, "a slide along the top stays on top")
            assert(lands(CGPoint(x: air.maxX - 60, y: mid.y), 150, -1500, on: .top).edge == .bottom, "the same throw near another edge goes where it heads")
            assert(lands(CGPoint(x: air.maxX - 300, y: mid.y), 150, -1500, on: .right).edge == .bottom, "pulled out of its edge, it is thrown")
        }
        // Tuck: a fast throw into the edge the rail is on, released near it, tucks the rail. An ordinary drop near the
        // edge, a slide along it, a throw from further out, toward another edge or away never does. Rotated to all edges.
        for (edge, near, into, along) in [(DockEdge.right, CGPoint(x: 1650, y: 500), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
                                          (.left, CGPoint(x: 60, y: 500), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
                                          (.top, CGPoint(x: 800, y: 1010), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
                                          (.bottom, CGPoint(x: 800, y: 60), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0))] {
            let air = CGRect(x: 0, y: 0, width: 1710, height: 1070)
            func v(_ i: CGFloat, _ a: CGFloat) -> CGVector { CGVector(dx: into.dx * i + along.dx * a, dy: into.dy * i + along.dy * a) }
            assert(edge.tucks(from: near, velocity: v(1500, 300), in: air), "\(edge): a throw into its own edge tucks")
            assert(!edge.tucks(from: near, velocity: v(150, 0), in: air), "\(edge): an ordinary drop near the edge doesn't")
            assert(!edge.tucks(from: near, velocity: v(300, 1500), in: air), "\(edge): a slide along the edge doesn't")
            assert(!edge.tucks(from: near, velocity: v(-1500, 0), in: air), "\(edge): a throw away from the edge doesn't")
            let far = CGPoint(x: near.x - into.dx * 300, y: near.y - into.dy * 300)
            assert(!edge.tucks(from: far, velocity: v(1500, 0), in: air), "\(edge): a throw from 300 pt out re-docks instead")
            for other in DockEdge.allCases where other != edge {
                assert(!other.tucks(from: near, velocity: v(1500, 300), in: air), "\(edge): only the rail's own edge tucks")
            }
            // the tucked frame leaves exactly 7 pt of the rail (12 pt inside its frame) on screen, at the same spot along the edge
            let docked = edge.frame(size: edge.isVertical ? CGSize(width: 68, height: 228) : CGSize(width: 228, height: 68), anchor: near, in: air)
            let tucked = edge.tucked(docked, in: air)
            let rail = tucked.insetBy(dx: 12, dy: 12)
            assert(rail.intersection(air).width * rail.intersection(air).height == 7 * (edge.isVertical ? rail.height : rail.width),
                   "\(edge): 7 pt of the rail stay on screen, got \(rail.intersection(air))")
            assert(edge.isVertical ? tucked.midY == docked.midY : tucked.midX == docked.midX, "\(edge): tucking keeps its spot along the edge")
        }
        // Speed comes from the drag's last moments: a pause before letting go is a drop, not a throw.
        var throwing = ThrowTracker()
        for i in 0...20 { throwing.add(CGPoint(x: 100 + 10 * CGFloat(i), y: 500), at: 1 + 0.008 * Double(i)) }
        let flung = throwing.velocity(at: 1.16)
        assert(abs(flung.dx - 1250) < 1 && flung.dy == 0, "10 pt every 8 ms is 1250 pt/s, got \(flung)")
        throwing.add(CGPoint(x: 300, y: 500), at: 1.3)
        assert(throwing.velocity(at: 1.3) == .zero, "held still for 140 ms before release")
        assert(ThrowTracker().velocity(at: 5) == .zero)
        // A flick into the screen edge pins the pointer there before the hand lets go: the speed is the one it arrived with.
        var pinned = ThrowTracker()
        for i in 0...5 { pinned.add(CGPoint(x: 1660 + 10 * CGFloat(i), y: 500), at: 2 + 0.008 * Double(i)) }
        for i in 1...15 { pinned.add(CGPoint(x: 1710, y: 500), at: 2.04 + 0.008 * Double(i)) }
        assert(abs(pinned.velocity(at: 2.16, pinned: true).dx - 1250) < 1, "arrived at 1250 pt/s, got \(pinned.velocity(at: 2.16, pinned: true))")
        assert(pinned.velocity(at: 2.16) == .zero, "not against the display's edge, the same samples are a drop")
        pinned.add(CGPoint(x: 1710, y: 500), at: 2.5)
        assert(pinned.velocity(at: 2.5, pinned: true) == .zero, "held at the edge for over a quarter second, it's a drop")
        // Each spring settles on its spot, and a hard throw never carries the rail through the screen edge.
        for name in ["snappy", "smooth", "bouncy"] {
            for (edge, from, v) in [(DockEdge.right, CGPoint(x: 900, y: 500), CGVector(dx: 4000, dy: 300)),
                                    (.top, CGPoint(x: 900, y: 100), CGVector(dx: -200, dy: 3000)),
                                    (.left, CGPoint(x: 60, y: 500), CGVector(dx: 0, dy: -1500)), (.bottom, CGPoint(x: 900, y: 40), .zero)] {
                let target = edge.frame(size: CGSize(width: 68, height: 148), anchor: edge.anchor(of: CGRect(x: 0, y: 0, width: 1710, height: 1070)),
                                        in: CGRect(x: 0, y: 0, width: 1710, height: 1070))
                var glide = RailGlide(center: AnimatablePair(from.x, from.y), velocity: AnimatablePair(v.dx, v.dy), target: target,
                                      edge: edge, spring: railSpring(name))
                func beyond() -> CGFloat {
                    switch edge {
                    case .right: glide.center.first - target.midX
                    case .left: target.midX - glide.center.first
                    case .top: glide.center.second - target.midY
                    case .bottom: target.midY - glide.center.second
                    }
                }
                let wall = max(16, beyond())   // a rail released past the wall only eases back from there
                var settled = false
                while !settled {
                    settled = glide.step(1.0 / 120)
                    assert(beyond() <= wall + 0.001, "\(name) \(edge): \(beyond()) pt through the wall")
                }
                assert(glide.elapsed < 1.5, "\(name) \(edge) took \(glide.elapsed) s")
                assert(abs(glide.center.first - target.midX) < 0.5 && abs(glide.center.second - target.midY) < 0.5)
            }
        }
        // Released hanging past the edge (the pointer at the screen's bottom, a tall rail below it), the rail eases back in:
        // the wall starts where the rail is instead of snapping it 64 pt in one frame, as the owner's logs showed.
        let bottomSpot = CGRect(x: 442, y: 4, width: 262, height: 84)
        var hanging = RailGlide(center: AnimatablePair(652, -34), velocity: AnimatablePair(217, 0), target: bottomSpot, edge: .bottom,
                                spring: railSpring("bouncy"))
        var last = hanging.center, settledHanging = false
        while !settledHanging {
            settledHanging = hanging.step(1.0 / 120)
            assert(hypot(hanging.center.first - last.first, hanging.center.second - last.second) < 12, "no jump: \(last) -> \(hanging.center)")
            last = hanging.center
        }
        assert(abs(hanging.center.second - bottomSpot.midY) < 0.5 && hanging.elapsed < 1.5)
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
        print("Overlay checks passed: docking, throws, tucks, glides, expansion, displays, persistence, pop-out dismissal, reset labels and transcript following")
    }
}
