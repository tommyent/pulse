import Foundation
import CoreGraphics
import SwiftUI   // Spring

/// Transparent window space around the visible rail and card is an outside click.
func overlayClickIsOutside(_ point: CGPoint, in bounds: CGRect, rail: CGRect, card: CGRect?) -> Bool {
    // Ignore synthetic activation clicks sent to this window with out-of-window coordinates.
    bounds.contains(point) && !rail.contains(point) && card?.contains(point) != true
}

/// The pet's transcript follows new text while its reader is at the bottom. Only the reader's own scroll (the
/// offset moving) changes that: content growing, even several times in a row, or the card resizing keeps it.
func transcriptFollows(_ following: Bool, oldOffset: CGFloat, offset: CGFloat, visible: CGFloat, content: CGFloat) -> Bool {
    offset == oldOffset ? following : offset + visible >= content - 24
}

/// The pointer's velocity at release, in screen points per second. SwiftUI's `DragGesture` velocity is useless here: its
/// locations are relative to the panel, which follows the pointer, so they barely change. Only the last 80 ms count,
/// so a pause before letting go reads as a still drop.
struct ThrowTracker {
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    mutating func add(_ point: CGPoint, at time: TimeInterval) {
        samples.append((time, point))
        samples.removeAll { $0.time < time - 0.08 }
    }

    func velocity(at time: TimeInterval) -> CGVector {
        let recent = samples.filter { $0.time >= time - 0.08 }
        guard let first = recent.first, let last = recent.last, last.time - first.time > 0.005 else { return .zero }
        let dt = CGFloat(last.time - first.time)
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }
}

enum DockEdge: String, Codable, CaseIterable {
    case right, left, top, bottom

    var isVertical: Bool { self == .right || self == .left }

    func distance(from point: CGPoint, in screen: CGRect) -> CGFloat {
        switch self {
        case .right: abs(screen.maxX - point.x)
        case .left: abs(point.x - screen.minX)
        case .top: abs(screen.maxY - point.y)
        case .bottom: abs(point.y - screen.minY)
        }
    }

    /// The edge whose zone holds the point. The screen's diagonals split it into four triangles, one per edge: distances
    /// are measured as a share of the screen's width or height, so a wide screen's sides keep half of it at mid-height
    /// instead of losing their middle to the nearer top and bottom.
    /// How fast `v` moves toward this edge (negative: away from it).
    func into(_ v: CGVector) -> CGFloat {
        switch self {
        case .right: v.dx
        case .left: -v.dx
        case .top: v.dy
        case .bottom: -v.dy
        }
    }

    static func nearest(to point: CGPoint, in screen: CGRect) -> DockEdge {
        func share(_ edge: DockEdge) -> CGFloat {
            edge.distance(from: point, in: screen) / (edge.isVertical ? screen.width : screen.height)
        }
        return allCases.min { share($0) < share($1) }!
    }

    /// Released at `flickSpeed` or faster (points per second), the rail goes to the edge its path reaches first and lands
    /// where the path meets it. Slower is a drop: the edge whose zone it is in. A throw mostly along the edge the rail is
    /// on, released within `slideBand` of it, is a reposition and keeps that edge. Drops and slides coast on for a tenth of a second
    /// (UIScrollView's fast deceleration), so the glide doesn't spring back against the release velocity.
    static let flickSpeed: CGFloat = 500
    static let slideBand: CGFloat = 160

    ///
    /// Released with the pointer pinned against the `display`'s edge, or 8 pt or more past the usable screen (into the
    /// menu bar or the Dock), the rail was pushed there: the cursor stopped while the hand went on, so its speed says
    /// nothing (it may even slide along the edge). Unless it is already pulling away, it goes to that edge, and tucks into
    /// it if that is the edge it is on. The rail sits 16 pt or more inside its edge, so getting there takes a push.
    /// A fast flick into its own edge, released short of that, tucks too.
    static func landing(from point: CGPoint, velocity v: CGVector, current: DockEdge, in screen: CGRect,
                        display: CGRect = .null) -> (edge: DockEdge, point: CGPoint, tuck: Bool) {
        func clamped(_ q: CGPoint) -> CGPoint {
            CGPoint(x: min(max(q.x, screen.minX), screen.maxX), y: min(max(q.y, screen.minY), screen.maxY))
        }
        let p = clamped(point), coasted = clamped(CGPoint(x: p.x + v.dx * 0.1, y: p.y + v.dy * 0.1))
        let pinned = allCases.filter { edge in
            (edge.distance(from: point, in: display) <= 2 || edge.into(CGVector(dx: point.x - p.x, dy: point.y - p.y)) >= 8)
                && edge.into(v) >= -50
        }
        if let pushed = pinned.contains(current) ? current : pinned.first { return (pushed, p, pushed == current) }
        if current.tucks(from: point, velocity: v, in: screen) { return (current, p, true) }
        guard hypot(v.dx, v.dy) >= flickSpeed else { return (nearest(to: p, in: screen), coasted, false) }
        let along = current.isVertical ? abs(v.dy) > abs(v.dx) : abs(v.dx) > abs(v.dy)
        if along, current.distance(from: p, in: screen) <= slideBand { return (current, coasted, false) }
        let times: [(DockEdge, CGFloat)] = [
            (.right, v.dx > 0 ? (screen.maxX - p.x) / v.dx : .infinity), (.left, v.dx < 0 ? (screen.minX - p.x) / v.dx : .infinity),
            (.top, v.dy > 0 ? (screen.maxY - p.y) / v.dy : .infinity), (.bottom, v.dy < 0 ? (screen.minY - p.y) / v.dy : .infinity),
        ]
        let (edge, t) = times.min { $0.1 < $1.1 }!
        let hit = CGPoint(x: p.x + v.dx * t, y: p.y + v.dy * t)
        // land exactly on the edge, not a rounding error inside it
        switch edge {
        case .right: return (edge, CGPoint(x: screen.maxX, y: hit.y), false)
        case .left: return (edge, CGPoint(x: screen.minX, y: hit.y), false)
        case .top: return (edge, CGPoint(x: hit.x, y: screen.maxY), false)
        case .bottom: return (edge, CGPoint(x: hit.x, y: screen.minY), false)
        }
    }

    /// A throw into this edge (the rail's own), released within `slideBand` of it, tucks the rail in. A slower release
    /// is a drop and a throw mostly along the edge is a slide; neither tucks.
    func tucks(from point: CGPoint, velocity v: CGVector, in screen: CGRect) -> Bool {
        hypot(v.dx, v.dy) >= Self.flickSpeed && into(v) > (isVertical ? abs(v.dy) : abs(v.dx))
            && distance(from: point, in: screen) <= Self.slideBand
    }

    /// The docked frame pushed out past this edge until only `sliver` points of the rail stay on screen, at the same spot
    /// along the edge. The rail's outer side is always 12 pt inside the frame and, collapsed, it is 44 pt thick, so this
    /// holds whatever sits beside it (a break's countdown makes the frame thicker on the inside only).
    func tucked(_ frame: CGRect, sliver: CGFloat = 7, in screen: CGRect) -> CGRect {
        let overhang = 12 + 44 - sliver   // the frame's outer side, past the screen's edge
        return switch self {
        case .right: frame.offsetBy(dx: screen.maxX + overhang - frame.maxX, dy: 0)
        case .left: frame.offsetBy(dx: screen.minX - overhang - frame.minX, dy: 0)
        case .top: frame.offsetBy(dx: 0, dy: screen.maxY + overhang - frame.maxY)
        case .bottom: frame.offsetBy(dx: 0, dy: screen.minY - overhang - frame.minY)
        }
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

/// The drop's spring: bouncy, the owner's pick. The hidden `railSpring` default keeps the others to compare:
/// `defaults write io.github.tommyent.pulse railSpring snappy` (or smooth) takes effect at the next drop.
func railSpring(_ name: String? = UserDefaults.standard.string(forKey: "railSpring")) -> Spring {
    switch name {
    case "snappy": .snappy(duration: 0.35)
    case "smooth": .smooth(duration: 0.5)
    default: .bouncy(duration: 0.55)
    }
}

/// Tucking and peeking slide without a bounce: a bouncing tuck would bob the sliver back out of the edge.
let tuckSpring = Spring.smooth(duration: 0.35)
/// The rings move into a new layout quickly and without overshoot, so they don't run into each other mid-air.
let morphSpring = Spring.smooth(duration: 0.28)

/// A dropped rail's flight: its centre springs to the docked frame's centre, starting at the throw's velocity.
struct RailGlide {
    var center: AnimatablePair<CGFloat, CGFloat>
    var velocity: AnimatablePair<CGFloat, CGFloat>
    var target: CGRect
    let edge: DockEdge
    let spring: Spring
    var elapsed: TimeInterval = 0
    var startDepth: CGFloat? = nil   // how far toward the edge it began: a rail released past the wall starts the wall there

    /// Advances by `dt` seconds; true once it has settled on the target (or given up after two seconds).
    mutating func step(_ dt: TimeInterval) -> Bool {
        let normal: (x: CGFloat, y: CGFloat) = switch edge {
        case .right: (1, 0)
        case .left: (-1, 0)
        case .top: (0, 1)
        case .bottom: (0, -1)
        }
        func depth(_ p: AnimatablePair<CGFloat, CGFloat>) -> CGFloat { p.first * normal.x + p.second * normal.y }
        if startDepth == nil { startDepth = depth(center) }
        elapsed += dt
        let goal = AnimatablePair(target.midX, target.midY)
        spring.update(value: &center, velocity: &velocity, target: goal, deltaTime: dt)
        // The screen edge is a wall: the rail may press up to it (16 pt past its spot: the panel's margin and padding),
        // then bounces back by the spring's own bounce. One released further out eases back in rather than snapping.
        let past = depth(center) - max(depth(goal) + 16, startDepth ?? 0)
        if past > 0 {
            center.first -= past * normal.x
            center.second -= past * normal.y
            let into = velocity.first * normal.x + velocity.second * normal.y
            if into > 0 {
                velocity.first -= (1 + spring.bounce) * into * normal.x
                velocity.second -= (1 + spring.bounce) * into * normal.y
            }
        }
        let still = hypot(center.first - goal.first, center.second - goal.second) < 0.5 && hypot(velocity.first, velocity.second) < 10
        return still || elapsed >= 2
    }
}
