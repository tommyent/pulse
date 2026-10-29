import AVFoundation
import SwiftUI

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - the countdown beside the rail

/// A capsule with a tail pointing at the rail.
struct PillShape: Shape {
    static let tailWidth: CGFloat = 7
    var edge: Edge = .trailing
    var maxRadius: CGFloat = .infinity   // a taller pill keeps round corners instead of turning into a stadium
    func path(in rect: CGRect) -> Path {
        let t = Self.tailWidth
        let body: CGRect
        var tail = Path()
        switch edge {
        case .trailing:
            body = CGRect(x: 0, y: 0, width: rect.width - t, height: rect.height)
            tail.move(to: CGPoint(x: body.maxX - 4, y: rect.midY - 8)); tail.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); tail.addLine(to: CGPoint(x: body.maxX - 4, y: rect.midY + 8))
        case .leading:
            body = CGRect(x: t, y: 0, width: rect.width - t, height: rect.height)
            tail.move(to: CGPoint(x: body.minX + 4, y: rect.midY - 8)); tail.addLine(to: CGPoint(x: 0, y: rect.midY)); tail.addLine(to: CGPoint(x: body.minX + 4, y: rect.midY + 8))
        case .top:
            body = CGRect(x: 0, y: t, width: rect.width, height: rect.height - t)
            tail.move(to: CGPoint(x: rect.midX - 8, y: body.minY + 4)); tail.addLine(to: CGPoint(x: rect.midX, y: 0)); tail.addLine(to: CGPoint(x: rect.midX + 8, y: body.minY + 4))
        case .bottom:
            body = CGRect(x: 0, y: 0, width: rect.width, height: rect.height - t)
            tail.move(to: CGPoint(x: rect.midX - 8, y: body.maxY - 4)); tail.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); tail.addLine(to: CGPoint(x: rect.midX + 8, y: body.maxY - 4))
        }
        tail.closeSubpath()
        return Path(roundedRect: body, cornerRadius: min(body.height / 2, maxRadius)).union(tail)
    }
}

/// The 30-second countdown: the seconds in a ring that empties, and the break's length beside it. A click starts
/// the break, the × skips it; otherwise it starts by itself.
struct BreakPill: View {
    @ObservedObject var controller: BreakController
    var tail: Edge = .trailing
    var onFrame: ((CGRect) -> Void)? = nil   // beside the rail, so the rail can tell a click here from a click away

    var body: some View {
        if case let .countdown(kind, endsAt) = controller.phase {
            let bar = Color(rgb: BreakColor.pair(controller.settings.color).bar)
            HStack(spacing: 6) {
                Button { controller.startNow() } label: {
                    HStack(spacing: 9) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, endsAt.timeIntervalSince(context.date))
                            ZStack {
                                Circle().stroke(Color.primary.opacity(0.14), lineWidth: 4)
                                Circle().trim(from: 0, to: left / BreakSchedule.countdown)
                                    .stroke(bar, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 1), value: left)
                                Text("\(Int(left.rounded(.up)))")
                                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            }
                            .frame(width: 38, height: 38)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Break in \(Int(left.rounded(.up))) seconds")
                        }
                        Text(breakLengthLabel(controller.settings.length(kind)))
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .help("Click to start the break now. It starts by itself when the ring is empty.")
                .accessibilityHint("Starts the break now")
                Button { controller.skip(why: "countdown dismissed") } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Skip this break")
                .accessibilityLabel("Skip this break")
            }
            .buttonStyle(.plain)
            .padding(.leading, 7).padding(.trailing, 12)
            .frame(height: 52)
            .padding(Edge.Set(tail), PillShape.tailWidth)
            .glassCard(in: PillShape(edge: tail))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame?($0) }
            .transition(.scale(scale: 0.5, anchor: UnitPoint(edge: tail)).combined(with: .opacity))
        }
    }
}

private extension UnitPoint {
    init(edge: Edge) {
        switch edge {
        case .trailing: self = .trailing
        case .leading: self = .leading
        case .top: self = .top
        case .bottom: self = .bottom
        }
    }
}

// MARK: - the overlay

struct BreakOverlayView: View {
    @ObservedObject var controller: BreakController
    let size: CGSize
    var agents = false   // this screen shows the agents (the main one)
    var holidayScreen = false   // a holiday's video plays here (the main screen)
    var showPet = true
    var petOnRight = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var perches: [BreakPerch] = []   // where the agents can jump up, in this view's points

    var body: some View {
        let s = min(1.3, max(0.7, size.width / 1440))   // the mockup's sizes, scaled to this screen
        let holiday = holidayScreen ? controller.holiday : nil
        let colors = holiday.map { (glow: $0.glow, bar: $0.bar) } ?? BreakColor.pair(controller.settings.color)
        ZStack {
            if holiday != nil {
                Color(white: 0.043)
                if let still = controller.holidayStill {
                    Image(nsImage: still).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
                } else if let player = controller.holidayPlayer {
                    HolidayVideo(player: player).transition(.opacity)
                }
                // keeps the band at the bottom readable over a bright frame
                LinearGradient(stops: [.init(color: Color(white: 0.02).opacity(0.88), location: 0),
                                       .init(color: Color(white: 0.02).opacity(0.55), location: 0.28),
                                       .init(color: .clear, location: 0.5)], startPoint: .bottom, endPoint: .top)
                BreakGlow(rgb: colors.glow, size: size, plain: false)
                band(s, bar: colors.bar)
            } else {
                BreakGlow(rgb: colors.glow, size: size)
                VStack(spacing: 0) {
                    title(size: 50 * s, s).perch(.text)   // words the floating rings keep clear of
                    clock(s, digits: 172 * s, bar: 368 * s, color: colors.bar, align: .center).perch(.text).padding(.top, 34 * s)
                    label(s).padding(.top, 20 * s)
                    ideaLine(s, width: 760 * s, font: 22 * s, top: 46 * s, bar: colors.bar)
                    buttons(s).padding(.top, 72 * s)
                }
                .foregroundStyle(.white)
            }
            if agents {
                BreakAgentsLayer(rex: controller.rex, size: size, start: controller.breakStarted,
                                 showPet: showPet, petOnRight: petOnRight, still: reduceMotion, perches: perches,
                                 week: controller.settings.holidays
                                     ? BreakHatWeek.on(controller.breakStarted, simulated: UserDefaults.standard.simulatedHoliday) : nil,
                                 dressed: controller.settings.partyMode,
                                 left: { [controller] in controller.remaining($0).left })
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named(BreakPerchKey.space))
        .onPreferenceChange(BreakPerchKey.self) { perches = $0 }
        .environment(\.colorScheme, .dark)
    }

    /// On a holiday the countdown, the idea and the buttons share a band along the bottom, so the video's story
    /// plays uncovered above it. The band sits above the pets' floor.
    private func band(_ s: CGFloat, bar: UInt32) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 28 * s) {
                VStack(alignment: .leading, spacing: 0) {
                    title(size: 22 * s, s)
                    clock(s, digits: 92 * s, bar: 240 * s, color: bar, align: .leading).padding(.top, 6 * s)
                    label(s).padding(.top, 12 * s)
                }
                .perch(.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                ideaLine(s, width: 480 * s, font: 19 * s, top: 0, bar: bar)
                buttons(s * 0.85).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 60 * s)
            .padding(.bottom, size.width * 0.095)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 10 * s)
    }

    private func title(size: CGFloat, _ s: CGFloat) -> some View {
        Text("Time to take a break")
            .font(.system(size: size, weight: .medium))
            .tracking(-size * 0.014)
    }

    private func clock(_ s: CGFloat, digits: CGFloat, bar: CGFloat, color: UInt32, align: HorizontalAlignment) -> some View {
        let paused = controller.phase.isPaused
        return TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let r = controller.remaining(context.date)
            VStack(alignment: align, spacing: 0) {
                Text(Self.clock(r.left))
                    .font(.system(size: digits, weight: .bold).monospacedDigit())
                    .tracking(-digits * 0.029)
                    .foregroundStyle(paused ? Color(white: 0.55) : .white)
                ProgressView(value: max(0, min(1, r.left / r.total)))
                    .tint(paused ? Color.secondary : Color(rgb: color))
                    .frame(width: bar)
                    .padding(.top, digits * 0.27)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(paused ? "Paused, \(Self.clock(r.left)) left" : "\(Self.clock(r.left)) left in your break")
        }
    }

    private func label(_ s: CGFloat) -> some View {
        Text(controller.phase.isPaused ? "paused" : "left in your break")
            .font(.system(size: 17 * s))
            .tracking(0.8 * s)
            .foregroundStyle(Color(white: 0.5))
    }

    private func buttons(_ s: CGFloat) -> some View {
        let paused = controller.phase.isPaused
        return HStack(spacing: 16 * s) {
            Button("Back to Work") { controller.backToWork() }
                .buttonStyle(.borderedProminent)
                .help("End the break early")
                .perch(.button)
                .background {
                    // Escape skips the break; the history keeps it apart from ending it early
                    Button("Skip this break") { controller.skip() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            Button { paused ? controller.resume() : controller.pause() } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .perch(.button)
            Button("Snooze 5 min") { controller.snooze() }
                .buttonStyle(.bordered)
                .perch(.button)
        }
        .controlSize(.large)
        .fixedSize()
    }

    /// `top`: the space above it, only while it shows, so a hidden idea leaves the layout as it was.
    @ViewBuilder private func ideaLine(_ s: CGFloat, width: CGFloat, font: CGFloat, top: CGFloat, bar: UInt32) -> some View {
        if case let .shown(shown) = controller.idea {
            VStack(spacing: 14 * s) {
                Text("\(Text(Image(systemName: "sparkle")).foregroundStyle(Color(rgb: bar)))  \(Text(shown.name.isEmpty ? "" : shown.name + ". ").bold())\(shown.text)")
                .font(.system(size: font))
                .multilineTextAlignment(.center)
                .perch(.ideaRow)   // measured on the words themselves, not the wider frame
                .frame(maxWidth: width)
                .foregroundStyle(Color(white: 0.92))
                HStack(spacing: 26 * s) {
                    Button { controller.reroll() } label: { Label("Reroll", systemImage: "arrow.clockwise") }
                        .help("Another idea at your level")
                    Button { controller.surprise() } label: { Label("Surprise me", systemImage: "dice") }
                        .help("An idea from any level")
                }
                .buttonStyle(.borderless)
                .perch(.text)
            }
            .padding(.top, top)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Collects the frames the agents can jump up on, in the overlay's coordinate space.
private struct BreakPerchKey: PreferenceKey {
    static let space = "break"
    static let defaultValue: [BreakPerch] = []
    static func reduce(value: inout [BreakPerch], nextValue: () -> [BreakPerch]) { value += nextValue() }
}

private extension View {
    func perch(_ kind: BreakPerch.Kind) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: BreakPerchKey.self, value: [BreakPerch(kind: kind, rect: g.frame(in: .named(BreakPerchKey.space)))])
        })
    }
}

/// The holiday's video, filling the screen without controls.
private struct HolidayVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let view = NSView()
        view.layer = layer   // layer-hosting: the player layer is the view's own layer
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view.layer as? AVPlayerLayer)?.player = player }
}

/// The dark screen with the colour glowing at its edges and softly behind the timer. Each glow is a band from just
/// outside the screen to a little inside it, blurred inward, like an inset shadow.
private struct BreakGlow: View {
    let rgb: UInt32
    let size: CGSize
    var plain = true   // false over a holiday video: the edges only

    var body: some View {
        let u = size.width / 100, glow = Color(rgb: rgb)
        ZStack {
            if plain {
                Color(white: 0.043)
                RadialGradient(colors: [glow.opacity(0.24), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 23 * u)
            }
            band(glow.opacity(0.16), inset: 3 * u, blur: 20 * u)
            band(glow.opacity(0.48), inset: 1.2 * u, blur: 7 * u)
            band(glow.opacity(0.9), inset: 0.25 * u, blur: 1.6 * u)
            Rectangle().strokeBorder(Color(rgb: BreakColor.mix(rgb, white: 0.3)).opacity(0.7), lineWidth: 1)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    /// `blur` and `inset` follow CSS box-shadow's blur and spread.
    private func band(_ color: Color, inset: CGFloat, blur: CGFloat) -> some View {
        EdgeBand(inset: inset, outset: blur * 2)
            .fill(color, style: FillStyle(eoFill: true))
            .blur(radius: blur / 2)
    }
}

private struct EdgeBand: Shape {
    var inset: CGFloat
    var outset: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect.insetBy(dx: -outset, dy: -outset))
        p.addRect(rect.insetBy(dx: inset, dy: inset))
        return p
    }
}

// MARK: - the agents

/// The Claude mark drawn as rectangles on its 24-unit grid, so it can walk: opposite legs lift in turn, the body
/// bobs and the arms swing. Frame 0 and 2 stand; 1 and 3 lift a pair.
struct ClaudeCrab: View {
    static let color = Color(rgb: 0xD97757)
    var frame = 0
    var blink = false
    var sleepy = false   // eyes nearly shut
    var raise: (left: CGFloat, right: CGFloat) = (0, 0)   // grid units each arm is lifted: flapping, waving, climbing

    var body: some View {
        Canvas { context, size in
            let u = size.width / 24
            let lift: [CGFloat] = [[0, 0, 0, 0], [1.3, 0, 1.3, 0], [0, 0, 0, 0], [0, 1.3, 0, 1.3]][frame % 4]
            let bob: CGFloat = frame % 2 == 1 ? -0.5 : 0
            let arm: CGFloat = frame % 4 == 1 ? -0.6 : frame % 4 == 3 ? 0.6 : 0
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * u, y: (y - 4) * u, width: w * u, height: h * u)   // the mark's grid starts at y = 4
            }
            var p = Path()
            p.addRect(r(3, 5 + bob, 18, 12.079))
            p.addRect(r(0, 10.95 + bob + arm - raise.left, 3, 3.1))
            p.addRect(r(21, 10.95 + bob - arm - raise.right, 3, 3.1))
            for (i, x) in [4.487, 7.488, 15, 18].enumerated() { p.addRect(r(CGFloat(x), 17.079 + bob, 1.513, 2.921 - lift[i])) }
            // the eyes are holes in the body
            let eyeH: CGFloat = blink ? 0.5 : sleepy ? 0.9 : 2.847, eyeY = 8.102 + bob + (blink ? 1.8 : sleepy ? 1.9 : 0)
            p.addRect(r(6, eyeY, 1.488, eyeH))
            p.addRect(r(16.51, eyeY, 1.49, eyeH))
            context.fill(p, with: .color(Self.color), style: FillStyle(eoFill: true))
        }
        .aspectRatio(24 / 17, contentMode: .fit)
    }
}

/// The pet and the agents Rex reports, around the edges of the break screen: the pet, the Claude crabs and small
/// Codex pets along the bottom in staggered sizes; other apps (no sprite of their own), and the agents the floor
/// has no room for, float as rings. A blocked
/// agent stands still with a "!", an idle one dimmed, asleep until the break's last seconds.
struct BreakAgentsLayer: View {
    @ObservedObject var rex: RexAgents
    @ObservedObject private var pet = CodexPetSession.shared
    let size: CGSize
    let start: Date
    let showPet: Bool
    let petOnRight: Bool
    let still: Bool
    var perches: [BreakPerch] = []
    var week: BreakHatWeek? = nil   // the holiday week the floor dresses up for
    var dressed = true              // Party mode: hats, costumes and props; off, the agents wear nothing
    /// Seconds left in the break at a moment; it holds still while the break is paused.
    var left: (Date) -> TimeInterval = { _ in .infinity }

    private static let petFrames: [CodexPetSprite.State: [CGImage]] = Bundle.pulseResources
        .url(forResource: "Resources/codex-pet", withExtension: "webp")
        .map(CodexPetSprite.frames(from:)) ?? [:]

    private static let lanes = 24   // the rest float as rings

    /// Neighbours differ in size, so a crowded floor reads as a crowd; the bigger ones are drawn in front.
    private static func stagger(_ i: Int) -> Double { [1, 0.72, 0.86][i % 3] }

    var body: some View {
        let (spots, shown, helpers, more) = cast()
        let cast = actors(shown.walkers), first = showPet ? 1 : 0
        let seed = UInt64(bitPattern: Int64(start.timeIntervalSinceReferenceDate * 1000))   // new tricks each break
        let outfits = shown.walkers.map {
            !dressed ? BreakOutfit() : BreakOutfit.pick(asleep: $0.idle && !$0.done, finished: $0.done, crowd: shown.walkers.count, week: week,
                             roll: BreakOutfit.roll(id: $0.id, seed: seed))
        }
        let rings = Array(shown.floaters.enumerated())
        let moving = rings.filter { !$0.element.blocked && !$0.element.idle && !still }
        ZStack(alignment: .topLeading) {
            // rings that stand still are drawn once, outside the frame-by-frame redraw
            ForEach(rings.filter { r in !moving.contains { $0.offset == r.offset } }, id: \.element.id) { i, agent in
                floaterView(agent, at: spots[i], slot: i, t: 0)
            }
            // with no spot left on a very short screen, the top-right corner
            if more > 0 { moreRing(more, at: spots.last ?? CGPoint(x: size.width - ring, y: ring)) }
            // with Reduce Motion, a redraw a second so the sleepers are up at the end, without the getting up
            TimelineView(.animation(minimumInterval: still ? 1 : 1.0 / 24)) { context in
                let t = still ? 0 : context.date.timeIntervalSince(start), l = left(context.date)
                let poses = BreakTricks.poses(cast, t: t, left: still ? (l > BreakTricks.wake ? .infinity : 0) : l, floor: floor,
                                              width: size.width, perches: perches, seed: seed)
                ZStack(alignment: .topLeading) {
                    ladders(cast, poses)
                    if showPet { petView(t, poses[0], cast[0]) }
                    ForEach(Array(shown.walkers.enumerated()), id: \.element.id) { i, agent in
                        walkerView(agent, cast[first + i], poses[first + i], t: t, outfit: outfits[i]).zIndex(Self.stagger(i))
                    }
                    snores(cast, poses, first: first, t: t).zIndex(2)
                    ForEach(moving, id: \.element.id) { i, agent in floaterView(agent, at: spots[i], slot: i, t: t) }
                    ForEach(0..<helpers, id: \.self) { i in helperView(at: spots[shown.floaters.count + i], slot: shown.floaters.count + i, t: t) }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var u: CGFloat { size.width / 100 }
    private var floor: CGFloat { size.height - 1.2 * u }
    /// The floor's sprites grow with the overlay's text (its `s`), not the screen's width, so they fit its gaps on
    /// any screen; at 1440 points wide it equals `u`.
    private var unit: CGFloat { min(1.3, max(0.7, size.width / 1440)) * 14.4 }
    private var ring: CGFloat { 5 * unit }

    /// Who walks, who floats in which spot, how many helpers fit, and how many don't (the last spot then says so).
    private func cast() -> (spots: [CGPoint], shown: (walkers: [BreakAgent], floaters: [BreakAgent], hidden: [BreakAgent]), helpers: Int, more: Int) {
        let spots = BreakTricks.floatSpots(width: size.width, ring: ring, obstacles: perches.map(\.rect), floorTop: floor - 8 * unit)
        let c = BreakAgent.crowd(rex.agents, lanes: Self.lanes, spots: spots.count, helpers: pet.helpersWorking)
        return (spots, c.shown, c.helpers, c.more)
    }

    private func sprite(_ state: CodexPetSprite.State, _ t: Double) -> some View {
        let frames = Self.petFrames[state] ?? []
        return Group {
            if frames.isEmpty { BrandIcon(account: .codex, size: 4 * u) }
            else {
                Image(decorative: frames[still ? 0 : CodexPetSprite.frame(state, at: t) % frames.count], scale: 1)
                    .resizable().interpolation(.none).scaledToFit()
            }
        }
    }

    /// Lanes 13% of the width apart, closer once more than 5 share the floor; the last stops short of the pet.
    private func laneStart(_ lane: Int, of n: Int) -> Double {
        let step = min(13, 60 / Double(max(1, n - 1)))
        return petOnRight ? 4.0 + Double(lane) * step : 88.0 - Double(lane) * step
    }

    /// The pet first, then Claude and Codex agents in their lanes on the side away from it. Idle and blocked agents
    /// stand still.
    private func actors(_ walkers: [BreakAgent]) -> [TrickActor] {
        var out: [TrickActor] = []
        if showPet {
            let w = 7 * unit
            out.append(TrickActor(kind: .pet, home: (petOnRight ? 82 : 18) * u, span: -6 * u, width: w, height: w * 208 / 192,
                                  footMargin: CodexPetSprite.footMargin(.idle), delay: 4.8, still: still))
        }
        for (lane, agent) in walkers.enumerated() {
            let codex = agent.app == .codex, w = (codex ? 5 : 5.6) * unit * Self.stagger(lane)
            out.append(TrickActor(kind: codex ? .codex : .crab, home: laneStart(lane, of: walkers.count) * u, span: 8 * u, width: w,
                                  height: codex ? w * 208 / 192 : w * 17 / 24,
                                  footMargin: codex ? CodexPetSprite.footMargin(.idle) : 1.0 / 17,   // the crab's legs end 1/17 up
                                  // a finished agent celebrates instead of sleeping
                                  phase: Double(lane) * 3.1, still: still || (agent.idle && !agent.done) || agent.blocked,
                                  idle: agent.idle && !agent.done))
        }
        return out
    }

    /// A pose's Codex sprite row, its frame when the pose picks one (a turn-around, a leap, a wing beat, a seat), and
    /// how fast it plays.
    private static func petState(_ move: TrickPose.Move, blocked: Bool) -> (state: CodexPetSprite.State, frame: Int?, speed: Double) {
        switch move {
        case .stand: (blocked ? .waiting : .idle, nil, 1)
        case .sleep: (.idle, CodexPetSprite.asleep, 1)
        case .sit: (.idle, 0, 1)
        case .ladder: (.turn, CodexPetSprite.back, 1)
        case let .walk(right, fast): (right ? .walkRight : .walkLeft, nil, fast ? 2 : 1)
        case let .jump(q): (.jump, CodexPetSprite.leap(q), 1)
        case let .fly(up): (.jump, CodexPetSprite.flap(up: up), 1)
        case .dance: (.happy, nil, 1)
        case .dizzy: (.oops, nil, 1)
        case .wave: (.waving, nil, 1)
        case .type: (.running, nil, 1)   // the row where it sits at its laptop
        case let .spin(q): { let f = CodexPetSprite.spin(q); return (f.state, f.frame, 1) }()
        }
    }

    /// The sheet's frame for a pose; nil when the sheet didn't load.
    private func petFrame(_ move: TrickPose.Move, t: Double, blocked: Bool) -> CGImage? {
        let (state, frame, speed) = Self.petState(move, blocked: blocked)
        let frames = Self.petFrames[state] ?? []
        return frames.isEmpty ? nil : frames[(frame ?? (still ? 0 : CodexPetSprite.frame(state, at: t * speed))) % frames.count]
    }

    private func petImage(_ move: TrickPose.Move, t: Double, blocked: Bool) -> some View {
        Group {
            if let image = petFrame(move, t: t, blocked: blocked) { Image(decorative: image, scale: 1).resizable().interpolation(.none) }
            else { BrandIcon(account: .codex, size: 4 * u) }
        }
    }

    /// What a sprite wears in this pose: everyone swaps to the propeller cap to fly or spin down, and puts the prop away.
    private static func worn(_ outfit: BreakOutfit, _ p: TrickPose) -> BreakOutfit {
        if case .fly = p.move { return BreakOutfit(hat: .propeller, wear: outfit.wear) }
        return p.propeller ? BreakOutfit(hat: .propeller, wear: outfit.wear) : outfit
    }

    /// Walks in from the rail's side and waves, then strolls and does tricks: hops, bounces, flips, spins, dances,
    /// moonwalks, types, flies, and jumps up on a button or the idea row.
    private func petView(_ t: Double, _ pose: TrickPose, _ a: TrickActor) -> some View {
        var p = pose
        if !still, t < 3.2 {
            let enter = (petOnRight ? 104.0 : -4.0) * u
            p.x = enter + (a.home - enter) * t / 3.2
            p.move = .walk(right: !petOnRight, fast: false)
        } else if !still, t < 4.8 { p.move = .wave }
        p.overControl = BreakTricks.overControl(a, p, perches)
        let margin = CodexPetSprite.footMargin(Self.petState(p.move, blocked: false).state)
        let frame = petFrame(p.move, t: t, blocked: false), worn = dressed ? Self.worn(BreakOutfit.pet(week), p) : BreakOutfit()
        return petImage(p.move, t: t, blocked: false)
            .frame(width: a.width, height: a.height)
            .overlay(alignment: .topLeading) { if let frame { PetOutfit(outfit: worn, width: a.width, frame: frame) } }
            .scaleEffect(x: 1 + p.squash, y: 1 - p.squash, anchor: .bottom)
            .rotationEffect(.radians(p.turn))
            .position(x: p.x, y: p.feet + margin * a.height - a.height / 2)
            .allowsHitTesting(!p.overControl)   // over a button it lets the click through
            .help(pet.helpersWorking > 0 ? "Codex pet · \(pet.helpersWorking) helper\(pet.helpersWorking == 1 ? "" : "s") working" : "Codex pet")
    }

    /// Claude agents as crabs, Codex agents as small Codex pets. Working ones stroll and do tricks, a blocked one
    /// stands with a "!", idle ones sleep dimmed and get up as the break ends.
    private func walkerView(_ agent: BreakAgent, _ a: TrickActor, _ p: TrickPose, t: Double, outfit: BreakOutfit) -> some View {
        let codex = agent.app == .codex, local = t + a.phase
        let margin = codex ? CodexPetSprite.footMargin(Self.petState(p.move, blocked: agent.blocked).state) : a.footMargin
        let crabFrame: Int = switch p.move {
        case let .walk(_, fast): Int(t * (fast ? 16 : 8)) % 4
        case .jump: 1
        case .dance, .ladder: Int(t * 10) % 4
        default: 0
        }
        let arms: (left: CGFloat, right: CGFloat) = switch p.move {
        case let .fly(up): up ? (6.5, 6.5) : (-1.5, -1.5)
        case .wave: (0, Int(t * 6) % 2 == 0 ? 6.5 : 4.8)
        case .ladder: crabFrame == 1 ? (4, 0) : crabFrame == 3 ? (0, 4) : (2, 2)   // a claw up each step
        default: (0, 0)
        }
        let beat = local.truncatingRemainder(dividingBy: 1), worn = dressed ? Self.worn(outfit, p) : outfit
        // where ClaudeCrab draws its body's top and its right claw's tip this frame
        let bob: CGFloat = crabFrame % 2 == 1 ? -0.5 : 0, swing: CGFloat = crabFrame % 4 == 1 ? -0.6 : crabFrame % 4 == 3 ? 0.6 : 0
        let frame = codex ? petFrame(p.move, t: local, blocked: agent.blocked) : nil
        return Group {
            if codex { petImage(p.move, t: local, blocked: agent.blocked) }
            else {
                ClaudeCrab(frame: crabFrame, blink: p.move == .stand && !agent.blocked && beat > 0.45 && beat < 0.6,
                           sleepy: p.move == .sleep, raise: arms)
            }
        }
        .frame(width: a.width, height: a.height)
        .overlay(alignment: .topLeading) {
            if let frame { PetOutfit(outfit: worn, width: a.width, frame: frame) }
            else if !codex {
                CrabOutfit(outfit: worn, width: a.width, bodyTop: 1 + bob, hand: CGPoint(x: 22.5, y: 7.5 + bob - swing - arms.right))
            }
        }
        .overlay(alignment: .topTrailing) {
            if agent.blocked { BlockedBadge(size: 1.3 * u).offset(x: (codex ? 0.2 : 0.4) * u, y: (codex ? 0.2 : -0.6) * u) }
        }
        .scaleEffect(x: 1 + p.squash, y: 1 - p.squash, anchor: .bottom)
        .rotationEffect(.radians(p.turn))
        // whatever is below the floor is hidden: a peek, a seated sprite's legs; the hat above and the prop beside stay
        .mask(alignment: .top) {
            Rectangle().frame(width: 2 * a.width, height: a.height + (p.sunk > 0 ? max(0, a.height * (1 - margin) - p.sunk) : a.height))
                .offset(y: -a.height)
        }
        .opacity(agent.idle && !agent.done ? BreakTricks.sleeperOpacity(a, p) : 1)
        .position(x: p.x, y: p.feet + margin * a.height - a.height / 2)
        .allowsHitTesting(!p.overControl)
        .help(Self.tip(agent))
    }

    /// The ladders propped against buttons and the ropes down from the top, behind whoever climbs them: plain wood,
    /// rails and rungs, and a tan rope, on the crab's grid for a crab and finer for a Codex pet. Clicks pass through.
    private func ladders(_ cast: [TrickActor], _ poses: [TrickPose]) -> some View {
        Canvas { context, _ in
            var path = Path()
            for (a, p) in zip(cast, poses) {
                if p.rope.count > 1 {
                    var rope = Path()
                    rope.addLines(p.rope)
                    context.stroke(rope, with: .color(Color(rgb: 0xD8C49A)), lineWidth: a.kind == .crab ? 1.5 / 24 * a.width : 0.035 * a.width)
                }
                guard let r = p.ladder, r.height > 0 else { continue }
                let crab = a.kind == .crab, rail = crab ? 1.5 / 24 * a.width : 0.05 * a.width
                let rung = crab ? rail : 0.025 * a.height, pitch = BreakTricks.rungPitch(a)
                path.addRect(CGRect(x: r.minX, y: r.minY, width: rail, height: r.height))
                path.addRect(CGRect(x: r.maxX - rail, y: r.minY, width: rail, height: r.height))
                var y = r.maxY - pitch / 2   // from the floor up, so rungs stay put as it's propped up
                while y - rung >= r.minY { path.addRect(CGRect(x: r.minX, y: y - rung, width: r.width, height: rung)); y -= pitch }
            }
            context.fill(path, with: .color(Color(rgb: 0xB48A5E)))
        }
        .allowsHitTesting(false)
    }

    /// The sleepers' Zs, drifting up beside where a hat would go.
    private func snores(_ cast: [TrickActor], _ poses: [TrickPose], first: Int, t: Double) -> some View {
        Canvas { context, _ in
            let clear = perches.map(\.rect)
            let z = context.resolve(Text("Z").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(Color(white: 0.86)))
            for (i, (a, p)) in zip(cast, poses).enumerated() where i >= first {
                for s in BreakTricks.snores(a, p, index: i, t: t, clear: clear) {
                    var c = context
                    c.opacity = s.opacity
                    c.translateBy(x: s.x, y: s.y)
                    c.scaleBy(x: s.size / 20, y: s.size / 20)
                    c.draw(z, at: .zero)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A floating agent `size` across at `center` overlaps a button or the idea.
    private func overControl(_ center: CGPoint, _ size: CGFloat) -> Bool {
        let box = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        return perches.contains { $0.rect.intersects(box) }
    }

    private func floatPosition(_ spot: CGPoint, slot: Int, t: Double, moving: Bool) -> CGPoint {
        guard moving else { return spot }
        let w = 0.17 + Double(slot % 7) * 0.02, p = Double(slot) * 1.7, drift = BreakTricks.floatDrift * ring
        return CGPoint(x: spot.x + drift * sin(w * t * 2 + p), y: spot.y + drift * sin(w * t * 1.3 + p * 1.7))
    }

    private func floaterView(_ agent: BreakAgent, at spot: CGPoint, slot: Int, t: Double) -> some View {
        let account: AccountID = switch agent.app {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        case .grok: .grok
        }
        let at = floatPosition(spot, slot: slot, t: t, moving: !agent.blocked && !agent.idle && !still)
        let d = ring * Self.stagger(slot)   // never more than the spot allows
        return ZStack {
            Circle().fill(Color(white: 0.03))
            Circle().strokeBorder(account.accent, lineWidth: 0.22 * unit)
            BrandIcon(account: account, size: d * 0.46)
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.6), radius: 0.6 * unit, y: 0.25 * unit)   // inside floatSpots' allowance
        .overlay(alignment: .topTrailing) { if agent.blocked { BlockedBadge(size: 1.3 * unit) } }
        .opacity(agent.idle ? 0.45 : 1)
        .position(at)
        .allowsHitTesting(!overControl(at, d))
        .help(Self.tip(agent))
    }

    private func helperView(at spot: CGPoint, slot: Int, t: Double) -> some View {
        let at = floatPosition(spot, slot: slot, t: t, moving: !still), w = 0.88 * ring
        return sprite(.running, t + Double(slot) * 0.3)
            .frame(width: w, height: w * 208 / 192)
            .position(at)
            .allowsHitTesting(!overControl(at, w))
            .help("Codex helper")
    }

    /// The last spot when even the rings run out: how many agents and helpers aren't on screen.
    private func moreRing(_ count: Int, at spot: CGPoint) -> some View {
        Text("+\(count)")
            .font(.system(size: ring * 0.3, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color(white: 0.8))
            .frame(width: ring, height: ring)
            .background(Circle().fill(Color(white: 0.03)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.22 * unit))
            .position(spot)
            .allowsHitTesting(!overControl(spot, ring))
            .help("\(count) more not shown")
            .accessibilityLabel("\(count) more not shown")
    }

    private static func tip(_ agent: BreakAgent) -> String {
        [agent.label.isEmpty ? agent.app.rawValue : agent.label, agent.blocked ? "waiting for you" : agent.done ? "finished" : agent.idle ? "idle" : nil,
         agent.msg.isEmpty ? nil : agent.msg]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct BlockedBadge: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: size * 0.62, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.orange, in: Circle())
            .accessibilityLabel("Waiting for you")
    }
}

// MARK: - Settings → Breaks

/// Settings → Breaks. A binding, not AppState, so it can be rendered on its own.
struct BreakSettingsSection: View {
    @Binding var settings: BreakSettings
    @ObservedObject private var controller = BreakController.shared
    @State private var sounds: [String] = []

    var body: some View {
        Section("Schedule") {
            Toggle("Remind me to take breaks", isOn: $settings.enabled)
            LabeledContent("Micro break") {
                HStack(spacing: 6) {
                    Text("every").foregroundStyle(.secondary)
                    minutes($settings.microEvery, [10, 15, 20, 25, 30, 45, 60])
                    Text("for").foregroundStyle(.secondary)
                    seconds($settings.microLength, [10, 20, 30, 45, 60])
                }
            }
            LabeledContent("Long break") {
                HStack(spacing: 6) {
                    Text("every").foregroundStyle(.secondary)
                    minutes($settings.longEvery, [30, 45, 60, 90, 120])
                    Text("for").foregroundStyle(.secondary)
                    minutes($settings.longLength, [2, 3, 5, 10, 15])
                    Toggle("Long break", isOn: $settings.longEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            Picker("Time away counts as a break", selection: $settings.awayMode) {
                Text("When locked, asleep or idle for 5 minutes").tag(BreakAwayMode.idle)
                Text("Only when locked or asleep (fixed schedule)").tag(BreakAwayMode.fixed)
            }
            .pickerStyle(.radioGroup)
            Toggle(isOn: $settings.waitForCalls) {
                Text("Wait during calls")
                Text("A break that comes due while an app is using the microphone, as on a video call, waits until the call ends; the call doesn't count as time away")
            }
            Text("Breaks keep to their times: every 10 minutes means every 10 minutes, however long each break takes. A long break takes the place of a micro break due within two minutes of it. A break waits while the screen is locked, during a Pulse voice call, and during other calls when Wait during calls is on. To skip breaks through a meeting, hover over the rail and choose Pause. Choose a fixed schedule if you watch the screen without touching the keyboard or mouse.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Break screen") {
            LabeledContent("Colour") {
                HStack(spacing: 9) {
                    ForEach(BreakColor.presets, id: \.name) { preset in
                        Button { settings.color = preset.name } label: {
                            Circle().fill(Color(rgb: preset.bar)).frame(width: 16, height: 16)
                                .padding(2)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: settings.color == preset.name ? 1.5 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(preset.name.capitalized)
                        .accessibilityLabel(preset.name.capitalized)
                        .accessibilityAddTraits(settings.color == preset.name ? .isSelected : [])
                    }
                    let custom = BreakColor.rgb(hex: settings.color)
                    ColorPicker("Custom colour", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Custom colour: the Mac's colour picker, which also takes a hex code")
                    .accessibilityLabel("Custom colour")
                    .accessibilityValue(custom.map(BreakColor.hex) ?? "")
                    .accessibilityAddTraits(custom != nil ? .isSelected : [])
                }
            }
            LabeledContent("Sound at start") { SoundChoice(title: "Sound at start", sound: soundBinding(\.startSound), sounds: sounds) }
            LabeledContent("Sound at end") { SoundChoice(title: "Sound at end", sound: soundBinding(\.endSound), sounds: sounds) }
                .onAppear { sounds = BatterySounds.all().map(\.name) }
            Toggle(isOn: $settings.showAgents) {
                Text("Show agents")
                Text("The Codex pet, and the agents open in Rex on this Mac and the Macs it connects to: working, waiting for you, just finished, or asleep")
            }
            Toggle(isOn: $settings.partyMode) {
                Text("Party mode")
                Text("Hats, costumes and props on the agents")
            }
            .disabled(!settings.showAgents)
            Toggle(isOn: $settings.holidays) {
                Text("Holiday surprises")
                Text("A short film behind the countdown on Halloween and Thanksgiving; in Party mode, holiday hats all that week and in December")
            }
        }
        Section("Ideas") {
            Toggle(isOn: $settings.ideas) {
                Text("Suggest something to do")
                Text("From Pulse's list of quick ideas, or your own")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Text("Easy").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(settings.ideaLevel) }, set: { settings.ideaLevel = Int($0.rounded()) }), in: 0...2, step: 1)
                        .labelsHidden()
                        .accessibilityValue(BreakSettings.levels[settings.ideaLevel])
                    Text("Wild").foregroundStyle(.secondary)
                }
            } label: { Text("Level") }
            LabeledContent("Your own ideas") {
                TextEditor(text: $settings.ownIdeas)
                    .font(.body)
                    .multilineTextAlignment(.leading)   // the Form right-aligns a row's content
                    .frame(width: 250, height: 72)
                    .accessibilityLabel("Your own ideas")
            }
            Text("One idea per line; yours come up about one break in three. Reroll picks another at your level, Surprise me one from any level.")
                .font(.caption).foregroundStyle(.secondary)
        }
        BreakHistorySection(history: controller.history)
    }

    /// "" in the settings is None in the picker.
    private func soundBinding(_ key: WritableKeyPath<BreakSettings, String>) -> Binding<String?> {
        Binding(get: { settings[keyPath: key].isEmpty ? nil : settings[keyPath: key] },
                set: { settings[keyPath: key] = $0 ?? "" })
    }

    private var customColor: Binding<Color> {
        Binding(get: { Color(rgb: BreakColor.pair(settings.color).glow) }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { UInt32(max(0, min(255, ($0 * 255).rounded()))) }
            let picked = rgb[0] << 16 | rgb[1] << 8 | rgb[2]
            if picked != BreakColor.pair(settings.color).glow { settings.color = BreakColor.hex(picked) }
        })
    }

    private func minutes(_ value: Binding<TimeInterval>, _ options: [Int]) -> some View {
        Picker("Minutes", selection: value) {
            ForEach(options, id: \.self) { Text("\($0) min").tag(TimeInterval($0 * 60)) }
        }
        .labelsHidden().fixedSize()
    }

    private func seconds(_ value: Binding<TimeInterval>, _ options: [Int]) -> some View {
        Picker("Seconds", selection: value) {
            ForEach(options, id: \.self) { Text("\($0) s").tag(TimeInterval($0)) }
        }
        .labelsHidden().fixedSize()
    }
}

/// Settings → Breaks → History: today's and this week's breaks by how they ended, and the latest few.
struct BreakHistorySection: View {
    let history: BreakHistory

    var body: some View {
        Section("History") {
            let cal = Calendar.current, now = Date()
            let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
            LabeledContent("Today", value: BreakHistory.summary(history.counts(since: cal.startOfDay(for: now))))
            LabeledContent("This week", value: BreakHistory.summary(history.counts(since: week)))
            let recent = history.records.suffix(6).reversed()
            if recent.isEmpty {
                Text("No breaks yet.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, r in
                        HStack {
                            Text(r.at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .leading)
                            Text(r.kind == .micro ? "Micro break" : "Long break")
                            Spacer()
                            Text(r.outcome.label.prefix(1).uppercased() + r.outcome.label.dropFirst()).foregroundStyle(r.outcome == .taken ? .primary : .secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            Text("Kept on this Mac for 90 days. Skipped means dismissed with Escape or the countdown's ×, or breaks turned off during one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// On hover, beside the rail: when the next break comes, and Pause for a meeting that isn't a call on this Mac.
struct NextBreakHint: View {
    @ObservedObject var controller: BreakController
    var tail: Edge = .trailing

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            if let text = controller.nextText(context.date) {
                let paused = controller.pausedUntil.map { $0 > context.date } ?? false
                VStack(alignment: .leading, spacing: 7) {
                    Label(text, systemImage: paused ? "pause.circle" : "cup.and.saucer")
                    HStack(spacing: 6) {
                        if paused {
                            chip("Resume", help: "Breaks come on their times again") { controller.pauseBreaks(for: nil) }
                        } else {
                            Text("Pause").foregroundStyle(.secondary).accessibilityHidden(true)
                            ForEach([30, 60, 120], id: \.self) { minutes in
                                let length = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr"
                                chip(length, help: "No breaks for \(length)") { controller.pauseBreaks(for: TimeInterval(minutes * 60)) }
                                    .accessibilityLabel("Pause breaks for \(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)))")
                            }
                        }
                    }
                }
                .font(.system(size: 12.5, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 14).padding(.vertical, 9)
                .padding(Edge.Set(tail), PillShape.tailWidth)
                .glassCard(in: PillShape(edge: tail, maxRadius: 16))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func chip(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
    }
}
