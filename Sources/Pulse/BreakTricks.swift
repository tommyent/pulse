import CoreGraphics
import Foundation

/// What the break screen's pets and crabs do between strolls, as a pure function of time like the rest of the agents
/// layer: no state, so every redraw agrees. The checks compile this file on its own.

/// Something on the break screen the sprites care about, in the overlay's points (the space the agents layer draws
/// in): a button to stand on, the idea's sentence to climb onto, or other words (Reroll, Surprise me) to keep clear of.
struct BreakPerch: Equatable {
    enum Kind: Equatable { case button, ideaRow, text }
    let kind: Kind
    let rect: CGRect
}

enum BreakTrick: CaseIterable, Equatable {
    case hop, flip, spin, dance, oops, scuttle, peek, leapfrog, perch, climb

    var usesPerch: Bool { self == .perch || self == .climb }
}

/// One sprite on the floor. `home` and `span` in points: it strolls from `home` by `span` (negative is leftward) and
/// back. `footMargin`: the share of `height` below its feet in its artwork.
struct TrickActor {
    enum Kind { case pet, crab, codex }
    var kind: Kind
    var home: Double
    var span: Double
    var width: Double
    var height: Double
    var footMargin: Double
    var delay: Double = 0   // seconds before its first stroll (the pet walks in and waves first)
    var phase: Double = 0   // seconds its cycle runs ahead of the others
    var still = false       // idle, blocked or Reduce Motion: it stays where it is

    var tricks: [BreakTrick] {
        switch kind {
        case .pet: [.hop, .flip, .spin, .dance, .oops, .perch, .climb]
        case .crab: [.hop, .flip, .scuttle, .peek, .leapfrog, .perch]
        case .codex: [.hop, .flip, .spin, .dance, .perch]
        }
    }
}

struct TrickPose: Equatable {
    enum Move: Equatable {
        case stand, walk(right: Bool, fast: Bool), jump, dance, dizzy, wave
        case spin(Double)   // 0…1 through the turn-around
    }
    var x: Double
    var feet: Double          // where its feet are; on a perch, the perch's top edge
    var move: Move = .stand
    var turn: Double = 0      // radians, a flip's rotation
    var sunk: Double = 0      // points of it below the floor, hidden (a peek)
    var overControl = false   // drawn over a button or the idea row: it must let clicks through
}

enum BreakTricks {
    static let cycle = 12.0

    /// The trick an actor does in a cycle, nil for a plain stroll. A seeded order of its tricks, rotated by one each
    /// round, so the same trick never comes twice in a row, across rounds too.
    static func pick(_ actor: TrickActor, index: Int, cycle c: Int, seed: UInt64) -> BreakTrick? {
        guard c >= 0 else { return nil }
        let order = shuffled(actor.tricks, seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        let n = order.count
        return order[(c + c / n) % n]
    }

    /// Every actor's pose at `t` seconds into the break. `width`: the screen's, for the walking speed and how far a
    /// perch may be. Each button belongs to the moving actor nearest it, so two never land on the same one.
    static func poses(_ actors: [TrickActor], t: Double, floor: Double, width: Double, perches: [BreakPerch],
                      seed: UInt64) -> [TrickPose] {
        let owned = owners(actors, perches: perches, reach: 0.28 * width)
        return actors.enumerated().map { i, a in
            let footing = owned[i].flatMap { footing(on: $0, for: a, clear: obstacles(perches), near: a.home) }
            var pose = pose(a, index: i, t: t, floor: floor, width: width, perches: perches, seed: seed, button: owned[i], footing: footing,
                            neighbor: actors.indices.contains(i + 1) && actors[i + 1].still && actors[i + 1].kind != .pet ? actors[i + 1] : nil)
            // never past a screen edge, a flip's turned box included
            let half = (a.width * abs(cos(pose.turn)) + a.height * abs(sin(pose.turn))) / 2
            pose.x = min(width - half, max(half, pose.x))
            pose.overControl = overControl(a, pose, perches)
            return pose
        }
    }

    /// True when the sprite's artwork overlaps a button or the idea, so it must let clicks through.
    static func overControl(_ a: TrickActor, _ p: TrickPose, _ perches: [BreakPerch]) -> Bool {
        perches.contains { $0.rect.intersects(spriteRect(a, p)) }
    }

    private static func pose(_ a: TrickActor, index i: Int, t: Double, floor: Double, width: Double, perches: [BreakPerch],
                             seed: UInt64, button: CGRect?, footing: ClosedRange<Double>?, neighbor: TrickActor?) -> TrickPose {
        let ground = floor - a.footMargin * a.height
        guard !a.still, t >= a.delay else { return TrickPose(x: a.home, feet: ground) }
        let local = t - a.delay + a.phase
        let c = Int(local / cycle), k = local - Double(c) * cycle
        var trick = pick(a, index: i, cycle: c, seed: seed)
        let row = perches.first { $0.kind == .ideaRow }?.rect
        if let tr = trick, tr.usesPerch {
            if button == nil { trick = nil } else if tr == .climb, row == nil { trick = .perch }
        }
        if trick == .leapfrog, neighbor == nil { trick = nil }   // only over a neighbour standing still
        if let trick, trick.usesPerch, let button {
            return perchPose(a, k: k, ground: ground, speed: 0.08 * width, button: button, row: trick == .climb ? row : nil,
                             footing: footing, clear: obstacles(perches), screen: width)
        }
        return strollPose(a, k: k, ground: ground, trick: trick, neighbor: neighbor)
    }

    /// Where the sprite is drawn: its artwork's box, feet `footMargin` above its bottom.
    static func spriteRect(_ a: TrickActor, _ p: TrickPose) -> CGRect {
        CGRect(x: p.x - a.width / 2, y: p.feet + a.footMargin * a.height - a.height, width: a.width, height: a.height)
    }

    // MARK: the two kinds of cycle

    /// 0–3 s out by `span`, 3–5 s the trick, 5–8 s back, then standing until the cycle ends.
    static func strollPose(_ a: TrickActor, k: Double, ground: Double, trick: BreakTrick?, neighbor: TrickActor? = nil) -> TrickPose {
        let far = a.home + a.span, out = a.span >= 0
        if k < 3 { return TrickPose(x: a.home + a.span * k / 3, feet: ground, move: .walk(right: out, fast: false)) }
        if k >= 5 && k < 8 { return TrickPose(x: far - a.span * (k - 5) / 3, feet: ground, move: .walk(right: !out, fast: false)) }
        if k >= 8 { return TrickPose(x: a.home, feet: ground) }
        let j = k - 3   // 0…2 s at the far end
        var p = TrickPose(x: far, feet: ground)
        switch trick {
        case nil: break
        case .hop:
            if let q = progress(j, 0.6, 0.6) { p.feet = arc(ground, ground, q, apex: 0.6 * a.height); p.move = .jump }
        case .flip, .oops:
            if let q = progress(j, 0.3, 0.9) {
                p.feet = arc(ground, ground, q, apex: 1.1 * a.height)
                p.turn = (out ? -1 : 1) * 2 * .pi * smooth(q)
                p.move = .jump
            } else if trick == .oops, j >= 1.2 { p.move = .dizzy }
        case .spin:
            if let q = progress(j, 0.3, 1.12) { p.move = .spin(q) }
        case .dance:
            p.move = .dance
        case .scuttle:
            // a fast dash back and forth around the far end
            let s = sin(j / 2 * 2 * .pi * 2)
            p.x = far + 0.5 * abs(a.span) * s
            p.move = .walk(right: cos(j / 2 * 2 * .pi * 2) > 0, fast: true)
        case .peek:
            // sinks below the floor, waits, pops back up
            let down = a.height * (1 - a.footMargin)
            if let q = progress(j, 0.2, 0.5) { p.sunk = down * smooth(q) }
            else if j >= 0.7 && j < 1.3 { p.sunk = down }
            else if let q = progress(j, 1.3, 0.3) { p.sunk = down * (1 - smooth(q)) }
            p.feet = ground + p.sunk
        case .leapfrog:
            // over the still neighbour, a moment past it, and back
            guard let n = neighbor else { break }
            let side: Double = n.home >= far ? 1 : -1
            let past = n.home + side * (n.width / 2 + a.width * 0.7), apex = n.height + 0.3 * a.height
            if let q = progress(j, 0.1, 0.7) { p.x = far + (past - far) * q; p.feet = arc(ground, ground, q, apex: apex); p.move = .jump }
            else if j >= 0.8 && j < 1.1 { p.x = past }
            else if let q = progress(j, 1.1, 0.7) { p.x = past + (far - past) * q; p.feet = arc(ground, ground, q, apex: apex); p.move = .jump }
        case .perch, .climb:
            break
        }
        return p
    }

    /// Run to below the button, jump onto it and stroll along its top, jump down and run home. A climb goes on up
    /// to the idea: along the buttons' top line to beside the idea's end, straight up, onto its top, and off the same
    /// end before dropping, so it never passes through the words.
    /// `footing`: the stretch of the button's top it may stand on (`footing(on:…)`); nil is all of it. A climb that
    /// can't get beside the idea on screen (`screen` wide), or whose walk there would pass the words in `clear`, is
    /// a plain perch.
    static func perchPose(_ a: TrickActor, k: Double, ground: Double, speed: Double, button: CGRect, row: CGRect?,
                          footing: ClosedRange<Double>? = nil, clear: [CGRect] = [], screen: Double = .infinity) -> TrickPose {
        let span = footing ?? landing(-.infinity, on: button, width: a.width)...landing(.infinity, on: button, width: a.width)
        let x1 = min(span.upperBound, max(span.lowerBound, a.home)), top = Double(button.minY)
        let x1b = x1 - span.lowerBound < span.upperBound - x1 ? span.upperBound : span.lowerBound   // the stretch's other end
        let run = abs(x1 - a.home) / speed, toward = x1 >= a.home
        let topMove: TrickPose.Move = a.kind == .pet ? .wave : a.kind == .codex ? .dance : .stand
        var steps: [(Double, (Double) -> TrickPose)] = [
            (run, { q in TrickPose(x: a.home + (x1 - a.home) * q, feet: ground, move: .walk(right: toward, fast: true)) }),
            // just enough lift to land: a higher arc would poke into the words above the buttons
            (0.6, { q in TrickPose(x: x1, feet: arc(ground, top, q, apex: (ground - top) / 4 + 0.08 * a.height), move: .jump) }),
        ]
        var end = x1
        if let row {
            let high = Double(row.minY), right = a.home >= Double(row.midX)
            let x2 = landing(right ? .infinity : -.infinity, on: row, width: a.width)   // the end nearest home
            let beside = right ? Double(row.maxX) + a.width / 2 + 4 : Double(row.minX) - a.width / 2 - 4
            let walk = CGRect(x: min(x1, beside) - a.width / 2, y: top + a.footMargin * a.height - a.height,
                              width: abs(beside - x1) + a.width, height: a.height)
            if beside - a.width / 2 < 0 || beside + a.width / 2 > screen || clear.contains(where: { $0.intersects(walk.insetBy(dx: 1, dy: 1)) }) {
                return perchPose(a, k: k, ground: ground, speed: speed, button: button, row: nil, footing: footing)
            }
            // along the buttons' top line to beside the idea, straight up there, then onto its top
            let side = abs(beside - x1) / speed
            steps += [
                (0.6, { _ in TrickPose(x: x1, feet: top) }),
                (side, { q in TrickPose(x: x1 + (beside - x1) * q, feet: top, move: .walk(right: beside > x1, fast: true)) }),
                (0.6, { q in TrickPose(x: beside, feet: arc(top, high, q, apex: (top - high) / 4 + 0.35 * a.height), move: .jump) }),
                (0.35, { q in TrickPose(x: beside + (x2 - beside) * q, feet: high, move: .walk(right: x2 > beside, fast: false)) }),
                (1.2, { _ in TrickPose(x: x2, feet: high, move: a.kind == .crab ? .stand : .wave) }),
                (0.35, { q in TrickPose(x: x2 + (beside - x2) * q, feet: high, move: .walk(right: beside > x2, fast: false)) }),
                (0.5, { q in TrickPose(x: beside, feet: high + (ground - high) * q * q, move: .jump) }),   // a drop
            ]
            end = beside
        } else {
            steps += [
                (0.4, { _ in TrickPose(x: x1, feet: top) }),
                (0.8, { q in TrickPose(x: x1 + (x1b - x1) * q, feet: top, move: .walk(right: x1b > x1, fast: false)) }),
                (0.5, { _ in TrickPose(x: x1b, feet: top, move: topMove) }),
                (0.8, { q in TrickPose(x: x1b + (x1 - x1b) * q, feet: top, move: .walk(right: x1 > x1b, fast: false)) }),
                (0.7, { q in TrickPose(x: x1, feet: arc(top, ground, q, apex: 0.35 * a.height), move: .jump) }),
            ]
        }
        let back = abs(a.home - end) / speed
        steps.append((back, { q in TrickPose(x: end + (a.home - end) * q, feet: ground, move: .walk(right: a.home > end, fast: true)) }))
        // a climb too long for its cycle on this layout is a plain perch instead of a jump cut short
        if row != nil, steps.reduce(0, { $0 + $1.0 }) > cycle {
            return perchPose(a, k: k, ground: ground, speed: speed, button: button, row: nil, footing: footing)
        }
        var start = 0.0
        for (length, pose) in steps {
            if k < start + length { return pose(length > 0 ? (k - start) / length : 1) }
            start += length
        }
        return TrickPose(x: a.home, feet: ground)
    }

    // MARK: geometry

    /// actor index → the button it may jump on: the closest actor-and-button pairs first, each actor and button
    /// used once, only moving actors, only within `reach` of the button's middle, and only where some of its top is
    /// clear of the words above.
    static func owners(_ actors: [TrickActor], perches: [BreakPerch], reach: Double) -> [Int: CGRect] {
        let buttons = perches.filter { $0.kind == .button }.map(\.rect), words = obstacles(perches)
        var pairs: [(d: Double, actor: Int, button: Int)] = []
        for (i, a) in actors.enumerated() where !a.still {
            for (j, b) in buttons.enumerated() {
                let d = abs(a.home - Double(b.midX))
                if d <= reach, footing(on: b, for: a, clear: words, near: a.home) != nil { pairs.append((d, i, j)) }
            }
        }
        var out: [Int: CGRect] = [:], used: Set<Int> = []
        for p in pairs.sorted(by: { ($0.d, $0.actor) < ($1.d, $1.actor) }) where out[p.actor] == nil && !used.contains(p.button) {
            out[p.actor] = buttons[p.button]
            used.insert(p.button)
        }
        return out
    }

    /// The words a sprite keeps clear of: the idea and the quiet buttons under it.
    static func obstacles(_ perches: [BreakPerch]) -> [CGRect] { perches.filter { $0.kind != .button }.map(\.rect) }

    /// The stretch of a button's top where a sprite's middle can stand without its artwork covering any of
    /// `clear`: the stretch nearest `x`, nil when there's none.
    static func footing(on b: CGRect, for a: TrickActor, clear: [CGRect], near x: Double) -> ClosedRange<Double>? {
        let lo = landing(-.infinity, on: b, width: a.width), hi = landing(.infinity, on: b, width: a.width)
        let bottom = Double(b.minY) + a.footMargin * a.height, top = bottom - a.height
        let blocked = clear.filter { Double($0.maxY) > top && Double($0.minY) < bottom }
            .map { (Double($0.minX) - a.width / 2, Double($0.maxX) + a.width / 2) }
            .sorted { $0.0 < $1.0 }
        var free: [ClosedRange<Double>] = [], start = lo
        for (from, to) in blocked {
            if from > start { free.append(start...min(from, hi)) }
            start = max(start, to)
            if start > hi { break }
        }
        if start <= hi { free.append(start...hi) }
        func distance(_ r: ClosedRange<Double>) -> Double { x < r.lowerBound ? r.lowerBound - x : x > r.upperBound ? x - r.upperBound : 0 }
        return free.min { distance($0) < distance($1) }
    }

    /// Where on a perch a sprite lands: as near `x` as it can while standing fully on it.
    static func landing(_ x: Double, on r: CGRect, width: Double) -> Double {
        let lo = Double(r.minX) + width / 2, hi = Double(r.maxX) - width / 2
        return lo > hi ? Double(r.midX) : min(hi, max(lo, x))
    }

    /// Feet height along a jump from `y0` to `y1` (screen points, down is larger) at `q` 0…1, `apex` above the line.
    static func arc(_ y0: Double, _ y1: Double, _ q: Double, apex: Double) -> Double {
        y0 + (y1 - y0) * q - apex * 4 * q * (1 - q)
    }

    /// 0…1 through a span of `length` seconds that starts at `from`, nil outside it.
    static func progress(_ t: Double, _ from: Double, _ length: Double) -> Double? {
        t >= from && t < from + length ? (t - from) / length : nil
    }

    static func smooth(_ q: Double) -> Double { q * q * (3 - 2 * q) }

    /// How far a floating ring drifts each way, as a share of its diameter.
    static let floatDrift = 0.15

    /// Where floating rings `d` across go, in points: two columns down each side and a row along the top, 1.5 rings
    /// apart so drifting neighbours never meet. A spot is kept only where the ring, its drift and its shadow stay on
    /// screen, above `floorTop` (the floor's sprites) and clear of `obstacles` (the words and buttons). The sides'
    /// top rows come first, then the top row from the outside in, two sides to one top.
    static func floatSpots(width: Double, ring d: Double, obstacles: [CGRect], floorTop: Double) -> [CGPoint] {
        let step = 1.5 * d, reach = d / 2 + floatDrift * d + 0.18 * d   // ring, drift, shadow (radius 0.12 d, 0.05 d down)
        func fits(_ p: CGPoint) -> Bool {
            let box = CGRect(x: p.x - reach, y: p.y - reach, width: 2 * reach, height: 2 * reach)
            return box.minX >= 0 && box.maxX <= width && box.minY >= 0 && box.maxY <= floorTop && !obstacles.contains { $0.intersects(box) }
        }
        let inset = reach + 0.2 * d
        var sides: [CGPoint] = [], y = inset + step
        while y + reach <= floorTop {
            for col in 0..<2 {
                let x = inset + Double(col) * step
                sides += [CGPoint(x: x, y: y), CGPoint(x: width - x, y: y)]
            }
            y += step
        }
        var top: [CGPoint] = [], x = inset + 2 * step
        while x <= width - inset - 2 * step + 0.001 { top.append(CGPoint(x: x, y: inset)); x += step }
        top.sort { abs($0.x - width / 2) > abs($1.x - width / 2) }
        let left = sides.filter(fits), above = top.filter(fits)
        var out: [CGPoint] = [], i = 0, j = 0
        while i < left.count || j < above.count {
            for _ in 0..<2 where i < left.count { out.append(left[i]); i += 1 }
            if j < above.count { out.append(above[j]); j += 1 }
        }
        return out
    }

    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var rng = SplitMix(state: seed)
        return items.shuffled(using: &rng)
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
