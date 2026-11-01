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
            func lands(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat, on current: DockEdge) -> (edge: DockEdge, point: CGPoint, tuck: Bool) {
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
            // a break's countdown beside the rail makes the frame thicker inward: the rail's outer side, and so the sliver, stay put
            let thick = edge.frame(size: edge.isVertical ? CGSize(width: 330, height: 228) : CGSize(width: 228, height: 241), anchor: near, in: air)
            let thickTucked = edge.tucked(thick, in: air)
            assert(edge.anchor(of: thickTucked) == edge.anchor(of: tucked), "\(edge): the tucked outer edge doesn't depend on what's beside the rail")
        }
        // The owner's own drags on a 1710 x 1107 pt screen (menu bar 34 pt, Dock hidden), recorded 2026-11-01: the last
        // 100 ms of each (time, x, y with y up) and the edge it started on. Before the pinned rule, every tuck here failed,
        // and the 19.37 s drag, slid sideways along the bottom, went to the left edge instead.
        let display = CGRect(x: 0, y: 0, width: 1710, height: 1107), usable = CGRect(x: 0, y: 0, width: 1710, height: 1073)
        let recorded: [(DockEdge, String, [(Double, CGFloat, CGFloat)])] = [
            (.top, "right", [(2.422, 1177, 561), (2.442, 1190, 557), (2.454, 1199, 555), (2.471, 1205, 554), (2.488, 1209, 554), (2.504, 1213, 553), (2.522, 1213, 553)]),
            (.right, "tuck", [(5.172, 1710, 654), (5.189, 1710, 668), (5.204, 1710, 672), (5.221, 1710, 669), (5.238, 1710, 660), (5.254, 1710, 651), (5.270, 1710, 643), (5.271, 1710, 643)]),
            (.right, "top", [(7.356, 1609, 636), (7.371, 1570, 658), (7.389, 1525, 688), (7.405, 1478, 723), (7.421, 1439, 754), (7.439, 1412, 776), (7.455, 1395, 789), (7.455, 1395, 789)]),
            (.top, "tuck", [(10.256, 1030, 998), (10.271, 1030, 1027), (10.288, 1030, 1070), (10.306, 1030, 1107), (10.326, 1033, 1107), (10.338, 1043, 1107), (10.354, 1060, 1107), (10.355, 1060, 1107)]),
            (.top, "left", [(13.854, 328, 695), (13.872, 123, 690), (13.889, 0, 671), (13.908, 0, 645), (13.922, 0, 627), (13.938, 0, 618), (13.939, 0, 618)]),
            (.left, "tuck", [(16.105, 0, 669), (16.122, 0, 662), (16.138, 0, 652), (16.155, 0, 645), (16.172, 0, 640), (16.188, 0, 636), (16.188, 0, 636)]),
            (.left, "tuck", [(17.570, 0, 612), (17.620, 0, 605), (17.638, 0, 598), (17.656, 0, 593), (17.656, 0, 593)]),
            (.left, "bottom", [(19.820, 656, 0), (19.838, 650, 0), (19.855, 647, 0), (19.904, 647, 0)]),
            (.left, "bottom", [(22.471, 537, 0), (22.506, 539, 0), (22.524, 545, 0), (22.539, 551, 0), (22.555, 551, 0)]),
            (.bottom, "tuck", [(25.388, 547, 0), (25.404, 549, 0), (25.405, 549, 0)]),
        ]
        for (current, want, samples) in recorded {
            var hand = ThrowTracker()
            for (t, x, y) in samples { hand.add(CGPoint(x: x, y: y), at: t) }
            let (t, x, y) = samples.last!
            let got = DockEdge.landing(from: CGPoint(x: x, y: y), velocity: hand.velocity(at: t), current: current, in: usable, display: display)
            assert(want == "tuck" ? got.tuck && got.edge == current : !got.tuck && got.edge.rawValue == want,
                   "the owner's drag at \(samples[0].0) s from \(current): wanted \(want), got \(got)")
        }
        // Pinned against another edge, the rail docks there; pinned against its own, it tucks; anywhere short of the
        // display's edge, slow, it docks as before.
        for edge in DockEdge.allCases {
            let onEdge = edge.anchor(of: display)
            for other in DockEdge.allCases {
                let got = DockEdge.landing(from: onEdge, velocity: .zero, current: other, in: usable, display: display)
                assert(got.edge == edge && got.tuck == (other == edge), "pinned at \(edge) from \(other): \(got)")
            }
            let short = edge.anchor(of: usable.insetBy(dx: 30, dy: 30))
            assert(!DockEdge.landing(from: short, velocity: .zero, current: edge, in: usable, display: display).tuck)
        }
        // Pushed into the menu bar short of the display's top (the owner's 05:22:50 push stopped at 1104 of 1107): 8 pt past
        // the usable screen is a push too. From another edge it docks there instead.
        assert(DockEdge.landing(from: CGPoint(x: 1118, y: 1104), velocity: .zero, current: .top, in: usable, display: display).tuck)
        let intoMenuBar = DockEdge.landing(from: CGPoint(x: 900, y: 1084), velocity: .zero, current: .left, in: usable, display: display)
        assert(intoMenuBar.edge == .top && !intoMenuBar.tuck)
        assert(!DockEdge.landing(from: CGPoint(x: 900, y: 1078), velocity: .zero, current: .top, in: usable, display: display).tuck,
               "5 pt into the menu bar is still an ordinary drop")
        // Already pulling away from the edge at release, it isn't a push.
        assert(!DockEdge.landing(from: CGPoint(x: 1710, y: 500), velocity: CGVector(dx: -900, dy: 0), current: .right, in: usable,
                                 display: display).tuck)
        // Sliding along the edge with the pointer pinned against it is still a push: three of the owner's tucks above slid at
        // about 330-430 pt/s, so a rule that checks for a slide first would lose them.
        // Speed comes from the drag's last moments: a pause before letting go is a drop, not a throw.
        var throwing = ThrowTracker()
        for i in 0...20 { throwing.add(CGPoint(x: 100 + 10 * CGFloat(i), y: 500), at: 1 + 0.008 * Double(i)) }
        let flung = throwing.velocity(at: 1.16)
        assert(abs(flung.dx - 1250) < 1 && flung.dy == 0, "10 pt every 8 ms is 1250 pt/s, got \(flung)")
        throwing.add(CGPoint(x: 300, y: 500), at: 1.3)
        assert(throwing.velocity(at: 1.3) == .zero, "held still for 140 ms before release")
        assert(ThrowTracker().velocity(at: 5) == .zero)
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
        // A tuck slides in on its own spring, without bouncing back out of the edge (the sliver would bob).
        let tuckTarget = DockEdge.right.tucked(CGRect(x: 1638, y: 400, width: 68, height: 228), in: CGRect(x: 0, y: 0, width: 1710, height: 1070))
        var tucking = RailGlide(center: AnimatablePair(1672, 514), velocity: AnimatablePair(0, 0), target: tuckTarget, edge: .right,
                                spring: tuckSpring)
        var furthest = tucking.center.first
        while !tucking.step(1.0 / 120) {
            assert(tucking.center.first >= furthest - 0.01, "a tuck never comes back out: \(tucking.center.first) after \(furthest)")
            furthest = max(furthest, tucking.center.first)
        }
        assert(tucking.elapsed < 1)
        // A fast tuck (a sliver pulled out and flicked straight back, up to the 3200 pt/s cap) stops at its tucked spot and
        // never goes further in: the 7 pt sliver must not vanish. Sol measured a 16 pt overshoot before. Every edge.
        let tuckScreen = CGRect(x: 0, y: 0, width: 1710, height: 1070)
        for edge in DockEdge.allCases {
            let size = edge.isVertical ? CGSize(width: 84, height: 262) : CGSize(width: 262, height: 84)
            let docked = edge.frame(size: size, anchor: edge.anchor(of: tuckScreen.insetBy(dx: 0, dy: 300)), in: tuckScreen)
            let spot = edge.tucked(docked, in: tuckScreen)
            let push = CGVector(dx: edge == .right ? 3200 : edge == .left ? -3200 : 0, dy: edge == .top ? 3200 : edge == .bottom ? -3200 : 0)
            var flick = RailGlide(center: AnimatablePair(docked.midX, docked.midY), velocity: AnimatablePair(push.dx, push.dy),
                                  target: spot, edge: edge, spring: tuckSpring, slack: 0)
            func depth() -> CGFloat { edge.into(CGVector(dx: flick.center.first - spot.midX, dy: flick.center.second - spot.midY)) }
            var done = false
            while !done {
                done = flick.step(1.0 / 120)
                assert(depth() <= 0.001, "\(edge): a fast tuck went \(depth()) pt past its spot")
            }
            assert(abs(depth()) < 0.5 && flick.elapsed < 1, "\(edge): settles on its spot")
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
        // The docking display is found from the rail's own band, never from where most of the panel lies: tucked at the
        // edge display A shares with B, 49 pt of the 84 pt panel sit on B, yet it belongs to A. Docked, the same.
        let displayA = CGRect(x: 0, y: 0, width: 1710, height: 1107), displayB = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        let dockedOnA = DockEdge.right.frame(size: CGSize(width: 84, height: 262), anchor: CGPoint(x: 1710, y: 500), in: displayA)
        for frame in [dockedOnA, DockEdge.right.tucked(dockedOnA, in: displayA)] {
            let point = DockEdge.right.railPoint(of: frame)
            assert(displayA.contains(point) && !displayB.contains(point), "the rail's band is on A: \(point) for \(frame)")
        }
        let tuckedLeftOfB = DockEdge.left.tucked(DockEdge.left.frame(size: CGSize(width: 330, height: 262), anchor: CGPoint(x: 1710, y: 500),
                                                                     in: displayB), in: displayB)
        assert(displayB.contains(DockEdge.left.railPoint(of: tuckedLeftOfB)), "a thicker frame (a countdown inside) doesn't change it")
        // What stays visible: a rail at rest or tucked shows only on its docking display's usable area; dragged freely it
        // shows wherever a display's usable area is (across a shared edge, on both); entirely off them, nothing.
        let crossing = CGRect(x: 1680, y: 400, width: 84, height: 262)
        assert(visibleParts(of: crossing, in: [displayA]) == [CGRect(x: 1680, y: 400, width: 30, height: 262)])
        assert(visibleParts(of: crossing, in: [displayA, displayB])?.count == 2, "dragged across the shared edge: drawn on both")
        assert(visibleParts(of: dockedOnA, in: [displayA]) == nil, "fully on its display: no mask")
        assert(visibleParts(of: CGRect(x: 2000, y: 400, width: 84, height: 262), in: [displayA]) == [], "off its display: hidden, not unmasked")
        // After a glide lands, the pointer decides what hover missed while it moved (exits during a glide are dropped).
        // Left during a peek: the peek ends. Still on the peeked rail: it counts as hovered. A tucked sliver never expands,
        // and an open pet card keeps the rail out.
        assert(hoverAfterLanding(pointerInside: false, peeking: true, tuckedAway: false, petVisible: false) == .collapse)
        assert(hoverAfterLanding(pointerInside: true, peeking: true, tuckedAway: false, petVisible: false) == .hover)
        assert(hoverAfterLanding(pointerInside: true, peeking: false, tuckedAway: true, petVisible: false) == .leave)
        assert(hoverAfterLanding(pointerInside: false, peeking: true, tuckedAway: false, petVisible: true) == .leave)
        assert(hoverAfterLanding(pointerInside: false, peeking: false, tuckedAway: false, petVisible: false) == .collapse)
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
