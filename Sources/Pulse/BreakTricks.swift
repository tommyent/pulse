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
    case bounce, fly, moonwalk, type, wave, ladder
    case helicopter, rappel   // up to the top of the screen, then down spinning under the propeller cap, or on a rope

    var usesPerch: Bool { self == .perch || self == .climb || self == .ladder }
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
    var idle = false        // with nothing to do it sleeps sitting, and gets up as the break ends

    /// What it does at the far end of a stroll; a bounce hops there and back, a fly flies the round trip. Jumping
    /// up on a button comes in turns instead (`BreakTricks.turns`).
    var tricks: [BreakTrick] {
        switch kind {
        case .pet: [.hop, .flip, .spin, .dance, .oops, .bounce, .fly, .moonwalk, .type, .helicopter, .rappel]
        case .crab: [.hop, .flip, .scuttle, .peek, .leapfrog, .bounce, .fly, .wave, .helicopter, .rappel]
        case .codex: [.hop, .flip, .spin, .dance, .bounce, .fly, .moonwalk, .type, .helicopter, .rappel]
        }
    }

    /// The small ones it does back home before it rests.
    var flourishes: [BreakTrick] {
        switch kind {
        case .pet: [.wave, .hop, .dance, .type]
        case .crab: [.wave, .hop, .peek]
        case .codex: [.hop, .wave, .type, .spin]
        }
    }
}

struct TrickPose: Equatable {
    enum Move: Equatable {
        case stand, walk(right: Bool, fast: Bool), dance, dizzy, wave, type
        case sleep, sit     // seated with its legs below the floor: asleep, or awake and about to get up
        case ladder         // climbing a ladder
        case jump(Double)   // 0…1 through the leap: crouch, rise, top, fall, land
        case fly(up: Bool)  // wings (the arms) up or down
        case spin(Double)   // 0…1 through the turn-around
    }
    var x: Double
    var feet: Double          // where its feet are; on a perch, the perch's top edge
    var move: Move = .stand
    var turn: Double = 0      // radians, a flip's rotation or a glide's lean
    var sunk: Double = 0      // points of it below the floor, hidden (a peek, a seated sprite's legs)
    var squash: Double = 0    // a bounce's give at the floor: 0.2 is a fifth shorter and that much wider
    var ladder: CGRect?       // a ladder it propped against a button, drawn behind it
    var rope: [CGPoint] = []  // a rope down from the top of the screen, top first, drawn behind it
    var propeller = false     // held up by its propeller cap without flapping: a spin down
    var overControl = false   // drawn over a button or the idea row: it must let clicks through
}

enum BreakTricks {
    static let cycle = 12.0
    /// Actors sharing a button take turns this long: exactly one of each one's cycles fits inside its turn, so two
    /// are never on a button at once.
    static let turn = 2 * cycle

    /// The trick at `cycle` from `tricks`, nil when there are none. A seeded order of them, rotated by one each
    /// round, so the same trick never comes twice in a row, across rounds too.
    static func pick(_ tricks: [BreakTrick], index: Int, cycle c: Int, seed: UInt64) -> BreakTrick? {
        guard c >= 0, !tricks.isEmpty else { return nil }
        let order = shuffled(tricks, seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        let n = order.count
        return order[(c + c / n) % n]
    }

    /// What an actor does in a cycle, nil for a plain stroll: on its turn at its button a jump up on it, a ladder up
    /// it, or a climb on to the idea (a ladder again when there's none), in that order turn by turn; otherwise its
    /// next trick.
    static func trick(_ a: TrickActor, index: Int, cycle c: Int, seed: UInt64, turn: Turn?, row: Bool) -> BreakTrick? {
        if let turn {
            let start = a.delay - a.phase + Double(c) * cycle, n = (start / Self.turn).rounded(.down)
            if start - n * Self.turn < cycle, ((Int(n) % turn.count) + turn.count) % turn.count == turn.place {
                let round = Int((n / Double(turn.count)).rounded(.down))
                return [BreakTrick.perch, .ladder, row ? .climb : .ladder][((round % 3) + 3) % 3]
            }
        }
        return pick(a.tricks, index: index, cycle: c, seed: seed)
    }

    /// The share of its height a seated sprite sinks below the floor, hidden: its legs, 16 of a Codex cell's 208 rows
    /// and 2.921 of the crab's 17 grid units.
    static func sitDrop(_ kind: TrickActor.Kind) -> Double { kind == .crab ? 2.921 / 17 : 16.0 / 208 }

    /// Seconds before the break ends that the sleepers wake: their eyes open, 0.7 s later they get up, and they've
    /// stood a second after that.
    static let wake = 4.0

    /// Every actor's pose at `t` seconds into the break, `left` seconds before it ends. `width`: the screen's, for the
    /// walking speed and how far a perch may be. Actors near a button take turns on it, so two never land on the same
    /// one.
    static func poses(_ actors: [TrickActor], t: Double, left: Double = .infinity, floor: Double, width: Double,
                      perches: [BreakPerch], seed: UInt64) -> [TrickPose] {
        let turns = turns(actors, perches: perches, reach: 0.28 * width), words = obstacles(perches)
        return actors.enumerated().map { i, a in
            let footing = turns[i].flatMap { footing(on: $0.button, for: a, clear: words, near: a.home) }
            var pose = pose(a, index: i, t: t, left: left, floor: floor, width: width, perches: perches, seed: seed, turn: turns[i], footing: footing,
                            neighbor: actors.indices.contains(i + 1) && actors[i + 1].still && actors[i + 1].kind != .pet ? actors[i + 1] : nil)
            // never past a screen edge, a flip's turned box included
            let half = (a.width * abs(cos(pose.turn)) + a.height * abs(sin(pose.turn))) / 2
            let x = min(width - half, max(half, pose.x))
            pose.rope = pose.rope.map { CGPoint(x: $0.x + x - pose.x, y: $0.y) }   // the rope moves with it
            pose.x = x
            pose.overControl = overControl(a, pose, perches)
            return pose
        }
    }

    /// True when the sprite's artwork overlaps a button or the idea, so it must let clicks through.
    static func overControl(_ a: TrickActor, _ p: TrickPose, _ perches: [BreakPerch]) -> Bool {
        perches.contains { $0.rect.intersects(spriteRect(a, p)) }
    }

    private static func pose(_ a: TrickActor, index i: Int, t: Double, left: Double, floor: Double, width: Double,
                             perches: [BreakPerch], seed: UInt64, turn: Turn?, footing: ClosedRange<Double>?,
                             neighbor: TrickActor?) -> TrickPose {
        let ground = floor - a.footMargin * a.height
        if a.idle { return sleeperPose(a, index: i, t: t, left: left, ground: ground) }
        guard !a.still, t >= a.delay else { return TrickPose(x: a.home, feet: ground) }
        let local = t - a.delay + a.phase
        let c = Int(local / cycle), k = local - Double(c) * cycle
        let row = perches.first { $0.kind == .ideaRow }?.rect
        var trick = trick(a, index: i, cycle: c, seed: seed, turn: turn, row: row != nil)
        if trick == .leapfrog, neighbor == nil { trick = nil }   // only over a neighbour standing still
        if let trick, trick.usesPerch, let turn {
            if trick == .ladder {
                return ladderPose(a, k: k, ground: ground, speed: 0.08 * width, button: turn.button, footing: footing, clear: obstacles(perches))
            }
            return perchPose(a, k: k, ground: ground, speed: 0.08 * width, button: turn.button, row: trick == .climb ? row : nil,
                             footing: footing, clear: obstacles(perches), screen: width)
        }
        return strollPose(a, k: k, ground: ground, trick: trick, flourish: pick(a.flourishes, index: i, cycle: c, seed: ~seed),
                          neighbor: neighbor, clear: perches.map(\.rect))
    }

    /// Where the sprite is drawn: its artwork's box, feet `footMargin` above its bottom.
    static func spriteRect(_ a: TrickActor, _ p: TrickPose) -> CGRect {
        CGRect(x: p.x - a.width / 2, y: p.feet + a.footMargin * a.height - a.height, width: a.width, height: a.height)
    }

    // MARK: sleepers

    /// An idle actor at home: asleep sitting, its legs below the floor and breathing slowly, until `wake` seconds
    /// before the break ends (`left`); then its eyes open, it gets up with a stretch, and stands ready for work.
    static func sleeperPose(_ a: TrickActor, index i: Int, t: Double, left: Double, ground: Double) -> TrickPose {
        let drop = sitDrop(a.kind) * a.height, awake = wake - left
        var p = TrickPose(x: a.home, feet: ground + drop, move: .sleep, sunk: drop)
        if awake < 0 { p.squash = 0.025 * sin(t * 2 * .pi / 3.6 + Double(i) * 0.9) }   // a breath every 3.6 s
        else if awake < 0.7 { p.move = .sit }
        else if let q = progress(awake, 0.7, 1) {
            p.sunk = drop * (1 - smooth(q)); p.feet = ground + p.sunk
            p.move = .stand; p.squash = -0.07 * sin(.pi * q)
        } else { p = TrickPose(x: a.home, feet: ground) }
        return p
    }

    /// How solid a sleeper is drawn: dimmed asleep and seated, brightening as it gets up, full once it stands.
    static func sleeperOpacity(_ a: TrickActor, _ p: TrickPose) -> Double {
        if p.move == .sleep || p.move == .sit { return 0.45 }
        return 0.45 + 0.55 * max(0, 1 - p.sunk / (sitDrop(a.kind) * a.height))
    }

    /// The top of its head (the crab's body), in points, for anything worn there, as it stands, sits or gets up:
    /// its artwork's top (row 30 of a Codex cell, the crab's grid line 5), lowered by a seat and a squash. A flip's
    /// turn and the Codex leap frames, drawn higher in their cells, are left to the wearer.
    static func headTop(_ a: TrickActor, _ p: TrickPose) -> Double {
        let r = spriteRect(a, p), inset = a.kind == .crab ? 1.0 / 17 : 30.0 / 208
        return Double(r.maxY) - Double(r.height) * (1 - inset) * (1 - p.squash)
    }

    /// The room kept for a hat: as wide as the head (the middle 0.8 of the sprite's width) and, above it, 9 of the
    /// crab's 24 grid units or 30% of a Codex pet's height.
    static func hatRoom(_ a: TrickActor, _ p: TrickPose) -> CGRect {
        let top = headTop(a, p), tall = hatHeight(a)
        return CGRect(x: p.x - 0.4 * a.width, y: top - tall, width: 0.8 * a.width, height: tall)
    }

    static func hatHeight(_ a: TrickActor) -> Double { a.kind == .crab ? 9.0 / 24 * a.width : 0.3 * a.height }

    /// The highest its feet go: its head and a hat 6 points under the top of the screen.
    static func ceiling(_ a: TrickActor) -> Double { (1 - a.footMargin) * a.height + hatHeight(a) + 6 }

    /// One of the Zs over a sleeper: its middle, its size (the letter's point size) and how solid it is.
    struct Snore: Equatable {
        var x: Double
        var y: Double
        var size: Double
        var opacity: Double
    }

    /// The Zs over a sleeper at `t`: three at a time, each coming off the side of its head past the hat's room,
    /// rising and drifting away, growing and fading over 3 s; staggered by `index`, so a row of sleepers doesn't
    /// puff in step. They rise no higher than 3 points under whatever of `clear` (the words and buttons) is above.
    static func snores(_ a: TrickActor, _ p: TrickPose, index: Int, t: Double, clear: [CGRect] = []) -> [Snore] {
        guard p.move == .sleep else { return [] }
        let hat = hatRoom(a, p), life = 3.0, small = 0.14 * a.height, grow = 0.1 * a.height
        let lo = Double(hat.maxX), hi = lo + 0.3 * a.width + 0.8 * (small + grow)   // where they drift, beside the hat
        let roof = clear.filter { Double($0.minX) < hi && Double($0.maxX) > lo && Double($0.maxY) <= Double(hat.maxY) }
            .map { Double($0.maxY) }.max() ?? 0
        let from = Double(hat.maxY) - 0.1 * a.height, rise = max(0, min(0.45 * a.height, from - roof - 3 - small - grow / 2))
        return (0..<3).map { n in
            let age = ((t + Double(index) * 0.77 + Double(n) * life / 3) / life).truncatingRemainder(dividingBy: 1)
            let size = small + grow * age
            return Snore(x: lo + 0.4 * size + 0.25 * a.width * age + 0.04 * a.width * sin(age * 3 * .pi),
                         y: from - rise * age, size: size,
                         opacity: 0.8 * min(1, age / 0.15) * min(1, (1 - age) / 0.4))
        }
    }

    // MARK: the two kinds of cycle

    /// 0–3 s out by `span`, 3–5 s the trick, 5–8 s back, 8.2–10.2 s a `flourish` at home, then standing until the
    /// cycle ends. A bounce hops out and back; a fly flies the round trip up to the top of the screen, past the timer,
    /// the words and the buttons, and a helicopter or a rappel goes up there too and comes down its own way. Where
    /// the screen is too short to fly, a fly flutters up at the far end and back down.
    static func strollPose(_ a: TrickActor, k: Double, ground: Double, trick: BreakTrick?, flourish: BreakTrick? = nil,
                           neighbor: TrickActor? = nil, clear: [CGRect] = []) -> TrickPose {
        let far = a.home + a.span, out = a.span >= 0
        if k < 8, let trick, let lift = flightLift(a, ground: ground) {
            if trick == .fly { return flightPose(a, k: k, ground: ground, lift: lift) }
            if trick == .helicopter { return helicopterPose(a, k: k, ground: ground, lift: lift) }
            if trick == .rappel { return rappelPose(a, k: k, ground: ground, lift: lift) }
        }
        if k < 3 { return travel(a, from: a.home, to: far, q: k / 3, ground: ground, hops: trick == .bounce) }
        if k >= 5 && k < 8 { return travel(a, from: far, to: a.home, q: (k - 5) / 3, ground: ground, hops: trick == .bounce) }
        if k >= 8 {
            let j = k - 8.2
            return slotPose(a, j: j, x: a.home, out: !out, ground: ground, trick: j >= 0 && j < 2 ? flourish : nil)
        }
        return slotPose(a, j: k - 3, x: far, out: out, ground: ground, trick: trick, neighbor: neighbor)
    }

    /// A trick in a 2-second slot at `x`, `j` seconds in. `out`: the way it walked there, for a flip's turn.
    static func slotPose(_ a: TrickActor, j: Double, x: Double, out: Bool, ground: Double, trick: BreakTrick?,
                         neighbor: TrickActor? = nil) -> TrickPose {
        var p = TrickPose(x: x, feet: ground)
        switch trick {
        case nil, .perch, .climb, .ladder:
            break
        case .fly, .helicopter, .rappel:
            // a flutter: up flapping, a moment there, and down, no longer in front of a button than a flip is
            if let q = progress(j, 0.1, 1.8) {
                p.feet = ground - 0.9 * a.height * min(1, 1.6 * sin(.pi * q))
                p.move = .fly(up: Int(j * 8) % 2 == 0)
            }
        case .hop:
            if let q = progress(j, 0.5, 0.8) { p.feet = arc(ground, ground, q, apex: 1.4 * a.height); p.move = .jump(q) }
        case .flip, .oops:
            if let q = progress(j, 0.2, 1.1) {
                p.feet = arc(ground, ground, q, apex: 2.4 * a.height)
                p.turn = (out ? -1 : 1) * 2 * .pi * smooth(q)
                p.move = .jump(q)
            } else if trick == .oops, j >= 1.3 { p.move = .dizzy }
        case .spin:
            if let q = progress(j, 0.3, 1.12) { p.move = .spin(q) }
        case .dance:
            p.move = .dance
        case .scuttle:
            // a fast dash back and forth around the far end
            let s = sin(j / 2 * 2 * .pi * 2)
            p.x = x + 0.5 * abs(a.span) * s
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
            let side: Double = n.home >= x ? 1 : -1
            let past = n.home + side * (n.width / 2 + a.width * 0.7), apex = n.height + 0.3 * a.height
            if let q = progress(j, 0.1, 0.7) { p.x = x + (past - x) * q; p.feet = arc(ground, ground, q, apex: apex); p.move = .jump(q) }
            else if j >= 0.8 && j < 1.1 { p.x = past }
            else if let q = progress(j, 1.1, 0.7) { p.x = past + (x - past) * q; p.feet = arc(ground, ground, q, apex: apex); p.move = .jump(q) }
        case .bounce:
            // three bounces on the spot, each lower and quicker than the last
            for (from, length, apex) in [(0.1, 0.7, 1.8), (0.8, 0.55, 1.0), (1.35, 0.4, 0.5)] {
                if let q = progress(j, from, length) { bounce(&p, q, apex: apex * a.height, ground: ground) }
            }
        case .moonwalk:
            // glides on outward while facing home, then walks back
            let d = (out ? 0.5 : -0.5) * abs(a.span)
            if let q = progress(j, 0.1, 1.2) { p.x = x + d * q; p.move = .walk(right: !out, fast: false) }
            else if let q = progress(j, 1.3, 0.6) { p.x = x + d * (1 - q); p.move = .walk(right: !out, fast: true) }
        case .type:
            if progress(j, 0.1, 1.8) != nil { p.move = .type }
        case .wave:
            if progress(j, 0.2, 1.6) != nil { p.move = .wave }
        }
        return p
    }

    /// Walking from `x0` to `x1` at `q` 0…1, or with `hops` bouncing there in four hops.
    static func travel(_ a: TrickActor, from x0: Double, to x1: Double, q: Double, ground: Double, hops: Bool) -> TrickPose {
        var p = TrickPose(x: x0 + (x1 - x0) * q, feet: ground, move: .walk(right: x1 >= x0, fast: false))
        if hops { bounce(&p, (q * 4).truncatingRemainder(dividingBy: 1), apex: 0.5 * a.height, ground: ground) }
        return p
    }

    /// A hop at `q` 0…1, `apex` high, giving a little at the floor as it takes off and lands.
    static func bounce(_ p: inout TrickPose, _ q: Double, apex: Double, ground: Double) {
        p.feet = arc(ground, ground, q, apex: apex)
        p.squash = 0.18 * max(0, 1 - min(q, 1 - q) / 0.12)
        p.move = .jump(q)
    }

    /// How far a flight's hover sways up and down, as a share of the sprite's height.
    static let sway = 0.08

    /// How high a fly goes: up to the top of the screen, past everything on it (it lets clicks through on the way),
    /// its hat and sway kept under the edge; nil when the screen is too short for that to read as flying.
    static func flightLift(_ a: TrickActor, ground: Double) -> Double? {
        let lift = ground - ceiling(a) - sway * a.height
        return lift >= 0.5 * a.height ? lift : nil
    }

    /// Up and out by `span` to the top of the screen, a hover, then down slowly on the spot, turning round and round
    /// under its propeller cap (a crab, with no turn-around, sways), a landing that gives and a run home, by 8 s.
    static func helicopterPose(_ a: TrickActor, k: Double, ground: Double, lift: Double) -> TrickPose {
        let far = a.home + a.span, top = ground - lift
        var p = TrickPose(x: far, feet: top)
        if k < 0.4 {
            p = TrickPose(x: a.home, feet: ground, squash: 0.16 * smooth(k / 0.4))
        } else if k < 2.6 {
            let q = (k - 0.4) / 2.2
            p.x = a.home + a.span * smooth(q); p.feet = ground - lift * (1 - (1 - q) * (1 - q)); p.move = .fly(up: Int(k * 8) % 2 == 0)
        } else if k < 3 {
            p.move = .fly(up: Int(k * 5) % 2 == 0)
        } else if let q = progress(k, 3, 3.8) {
            p.feet = top + lift * q
            p.x = far + 0.12 * a.width * sin(q * 6 * .pi)
            p.propeller = true
            if a.kind == .crab { p.turn = 0.15 * sin(k * 2 * .pi * 1.2) }
            else { p.move = .spin((k * 1.25).truncatingRemainder(dividingBy: 1)) }   // round once every 0.8 s
        } else if let q = progress(k, 6.8, 0.3) {
            p.feet = ground; p.squash = 0.16 * sin(.pi * q)
        } else {
            p = travel(a, from: far, to: a.home, q: min(1, (k - 7.1) / 0.9), ground: ground, hops: false)
            p.move = .walk(right: a.home >= far, fast: true)
        }
        return p
    }

    /// Out by `span`, a rope drops from the top of the screen, it climbs to the top hand over hand, waves, and comes
    /// back down in three bounds, kicking out and swinging back to the rope's line; the rope goes up and it runs home,
    /// by 8 s.
    static func rappelPose(_ a: TrickActor, k: Double, ground: Double, lift: Double) -> TrickPose {
        let far = a.home + a.span, top = ground - lift, steps = max(3, (lift / (0.45 * a.height)).rounded())
        let anchor = CGPoint(x: far, y: 0), floorEnd = CGPoint(x: far, y: ground)
        func hands(_ x: Double, _ feet: Double) -> CGPoint { CGPoint(x: x, y: feet - 0.6 * (1 - a.footMargin) * a.height) }
        func climb(_ q: Double) -> Double { let f = q * steps, n = f.rounded(.down); return ground - lift * (n + smooth(f - n)) / steps }
        let plan: [(Double, (Double) -> TrickPose)] = [
            (1, { q in TrickPose(x: a.home + a.span * q, feet: ground, move: .walk(right: a.span >= 0, fast: true)) }),
            (0.35, { q in TrickPose(x: far, feet: ground, rope: [anchor, CGPoint(x: far, y: ground * smooth(q))]) }),   // it drops
            (2.65, { q in TrickPose(x: far, feet: climb(q), move: .ladder, rope: [anchor, floorEnd]) }),
            (0.5, { _ in TrickPose(x: far, feet: top, move: .wave, rope: [anchor, floorEnd]) }),
            (2.5, { q in
                // three bounds, each kicking out from the rope's line and falling a third of the way
                let b = min(2, (q * 3).rounded(.down)), u = q * 3 - b, side: Double = a.span >= 0 ? 1 : -1
                let feet = top + lift * (b + u * u) / 3, x = far + side * 0.5 * a.width * sin(.pi * u)
                return TrickPose(x: x, feet: feet, move: .jump(0.5), turn: -side * 0.25 * sin(.pi * u),
                                 rope: [anchor, hands(x, feet), floorEnd])
            }),
            (0.3, { q in TrickPose(x: far, feet: ground, rope: [anchor, CGPoint(x: far, y: ground * (1 - smooth(q)))]) }),   // pulled up
            (0.7, { q in TrickPose(x: far - a.span * q, feet: ground, move: .walk(right: a.span < 0, fast: true)) }),
        ]
        return play(plan, k: k, home: TrickPose(x: a.home, feet: ground))
    }

    /// The round trip in the air: a crouch, a flapping climb out by `span` to `lift` up, a hover there, a glide home
    /// leaning into it, and a landing that gives, done by 8 s.
    static func flightPose(_ a: TrickActor, k: Double, ground: Double, lift: Double) -> TrickPose {
        let far = a.home + a.span
        let hover = ground - lift + sway * a.height * sin(k * 2 * .pi * 0.8)
        func wings(_ beats: Double) -> TrickPose.Move { .fly(up: Int(k * beats * 2) % 2 == 0) }   // beats a second
        var p = TrickPose(x: a.home, feet: ground)
        if k < 0.4 {
            p.squash = 0.16 * smooth(k / 0.4)
        } else if k < 3 {
            let q = (k - 0.4) / 2.6
            p.x = a.home + a.span * smooth(q); p.feet = ground + (hover - ground) * (1 - (1 - q) * (1 - q)); p.move = wings(4)
        } else if k < 5 {
            p.x = far; p.feet = hover; p.move = wings(2.5)
        } else if k < 7.6 {
            let q = (k - 5) / 2.6
            p.x = far - a.span * smooth(q); p.feet = hover + (ground - hover) * q * q; p.move = wings(1.25)
            p.turn = (a.span >= 0 ? -1 : 1) * 0.12 * sin(.pi * q)
        } else {
            p.squash = 0.16 * (1 - smooth((k - 7.6) / 0.4))
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
        let topMove: TrickPose.Move = a.kind == .codex ? .dance : .wave
        var steps: [(Double, (Double) -> TrickPose)] = [
            (run, { q in TrickPose(x: a.home + (x1 - a.home) * q, feet: ground, move: .walk(right: toward, fast: true)) }),
            // just enough lift to land: a higher arc would poke into the words above the buttons
            (0.6, { q in TrickPose(x: x1, feet: arc(ground, top, q, apex: (ground - top) / 4 + 0.08 * a.height), move: .jump(q)) }),
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
                (0.6, { q in TrickPose(x: beside, feet: arc(top, high, q, apex: (top - high) / 4 + 0.35 * a.height), move: .jump(q)) }),
                (0.35, { q in TrickPose(x: beside + (x2 - beside) * q, feet: high, move: .walk(right: x2 > beside, fast: false)) }),
                (1.2, { _ in TrickPose(x: x2, feet: high, move: .wave) }),
                (0.35, { q in TrickPose(x: x2 + (beside - x2) * q, feet: high, move: .walk(right: beside > x2, fast: false)) }),
                (0.5, { q in TrickPose(x: beside, feet: high + (ground - high) * q * q, move: .jump(0.5 + q / 2)) }),   // a drop
            ]
            end = beside
        } else {
            steps += [
                (0.4, { _ in TrickPose(x: x1, feet: top) }),
                (0.8, { q in TrickPose(x: x1 + (x1b - x1) * q, feet: top, move: .walk(right: x1b > x1, fast: false)) }),
                (0.5, { _ in TrickPose(x: x1b, feet: top, move: topMove) }),
                (0.8, { q in TrickPose(x: x1b + (x1 - x1b) * q, feet: top, move: .walk(right: x1 > x1b, fast: false)) }),
                (0.7, { q in TrickPose(x: x1, feet: arc(top, ground, q, apex: 0.35 * a.height), move: .jump(q)) }),
            ]
        }
        let back = abs(a.home - end) / speed
        steps.append((back, { q in TrickPose(x: end + (a.home - end) * q, feet: ground, move: .walk(right: a.home > end, fast: true)) }))
        // a climb too long for its cycle on this layout is a plain perch instead of a jump cut short
        if row != nil, steps.reduce(0, { $0 + $1.0 }) > cycle {
            return perchPose(a, k: k, ground: ground, speed: speed, button: button, row: nil, footing: footing)
        }
        return play(steps, k: k, home: TrickPose(x: a.home, feet: ground))
    }

    /// Run to the button's end nearest home, prop a ladder there, climb it a step at a time, walk on to stand and
    /// wave, climb back down, take the ladder away and run home. The ladder stands in the button's rounded end, clear
    /// of its label. A plain perch where standing at the ladder's top would touch the words in `clear`, or where it
    /// all wouldn't fit the cycle.
    static func ladderPose(_ a: TrickActor, k: Double, ground: Double, speed: Double, button: CGRect,
                           footing: ClosedRange<Double>? = nil, clear: [CGRect] = []) -> TrickPose {
        let span = footing ?? landing(-.infinity, on: button, width: a.width)...landing(.infinity, on: button, width: a.width)
        let top = Double(button.minY), end = 0.3 * Double(button.height)
        let foot = a.home < Double(button.midX) ? Double(button.minX) + end : Double(button.maxX) - end
        let x1 = min(span.upperBound, max(span.lowerBound, foot)), height = ground - top
        let wide = ladderWidth(a), steps = max(2, (height / rungPitch(a) / 2).rounded())   // two rungs a step
        func ladder(_ shown: Double) -> CGRect { CGRect(x: foot - wide / 2, y: ground - height * shown, width: wide, height: height * shown) }
        func up(_ q: Double) -> Double { let f = q * steps, n = f.rounded(.down); return ground - height * (n + smooth(f - n)) / steps }
        let run = abs(foot - a.home) / speed, toward = foot >= a.home
        let topMove: TrickPose.Move = a.kind == .codex ? .dance : .wave
        let plan: [(Double, (Double) -> TrickPose)] = [
            (run, { q in TrickPose(x: a.home + (foot - a.home) * q, feet: ground, move: .walk(right: toward, fast: true)) }),
            (0.35, { q in TrickPose(x: foot, feet: ground, ladder: ladder(smooth(q))) }),   // props it up
            (1.4, { q in TrickPose(x: foot, feet: up(q), move: .ladder, ladder: ladder(1)) }),
            (0.3, { q in TrickPose(x: foot + (x1 - foot) * q, feet: top, move: .walk(right: x1 >= foot, fast: false), ladder: ladder(1)) }),
            (0.8, { _ in TrickPose(x: x1, feet: top, move: topMove, ladder: ladder(1)) }),
            (0.3, { q in TrickPose(x: x1 + (foot - x1) * q, feet: top, move: .walk(right: foot >= x1, fast: false), ladder: ladder(1)) }),
            (1, { q in TrickPose(x: foot, feet: up(1 - q), move: .ladder, ladder: ladder(1)) }),
            (0.3, { q in TrickPose(x: foot, feet: ground, ladder: ladder(1 - smooth(q))) }),   // takes it away
            (run, { q in TrickPose(x: foot + (a.home - foot) * q, feet: ground, move: .walk(right: a.home >= foot, fast: true)) }),
        ]
        if plan.reduce(0, { $0 + $1.0 }) > cycle || clear.contains(where: { $0.intersects(spriteRect(a, TrickPose(x: foot, feet: top))) }) {
            return perchPose(a, k: k, ground: ground, speed: speed, button: button, row: nil, footing: footing)
        }
        return play(plan, k: k, home: TrickPose(x: a.home, feet: ground))
    }

    /// A ladder's width and the space between its rungs: chunky for the crab, on its grid, finer for a Codex pet.
    static func ladderWidth(_ a: TrickActor) -> Double { a.kind == .crab ? 12.0 / 24 * a.width : 0.42 * a.width }
    static func rungPitch(_ a: TrickActor) -> Double { a.kind == .crab ? 6.0 / 24 * a.width : 0.2 * a.height }

    /// The pose `k` seconds into `steps`, each a length and its pose through 0…1; `home` once they're done.
    private static func play(_ steps: [(Double, (Double) -> TrickPose)], k: Double, home: TrickPose) -> TrickPose {
        var start = 0.0
        for (length, pose) in steps {
            if k < start + length { return pose(length > 0 ? (k - start) / length : 1) }
            start += length
        }
        return home
    }

    // MARK: geometry

    /// An actor's button and its place in the line of `count` actors who take turns on it.
    struct Turn: Equatable {
        var button: CGRect
        var place: Int
        var count: Int
    }

    /// actor index → its turn: each moving actor lines up at the nearest button within `reach` of its middle where
    /// some of the top is clear of the words above, the nearest actors first.
    static func turns(_ actors: [TrickActor], perches: [BreakPerch], reach: Double) -> [Int: Turn] {
        let buttons = perches.filter { $0.kind == .button }.map(\.rect), words = obstacles(perches)
        var lines = Array(repeating: [(d: Double, actor: Int)](), count: buttons.count)
        for (i, a) in actors.enumerated() where !a.still {
            let near = buttons.indices.map { (j: $0, d: abs(a.home - Double(buttons[$0].midX))) }
                .filter { $0.d <= reach && footing(on: buttons[$0.j], for: a, clear: words, near: a.home) != nil }
                .min { $0.d < $1.d }
            if let near { lines[near.j].append((near.d, i)) }
        }
        var out: [Int: Turn] = [:]
        for (j, line) in lines.enumerated() {
            for (place, e) in line.sorted(by: { ($0.d, $0.actor) < ($1.d, $1.actor) }).enumerated() {
                out[e.actor] = Turn(button: buttons[j], place: place, count: line.count)
            }
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
