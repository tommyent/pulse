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
        return Path(roundedRect: body, cornerRadius: body.height / 2).union(tail)
    }
}

/// The 30-second countdown: the seconds in a ring that empties, and the break's length beside it. A click starts
/// the break; otherwise it starts by itself.
struct BreakPill: View {
    @ObservedObject var controller: BreakController
    var tail: Edge = .trailing

    var body: some View {
        if case let .countdown(kind, endsAt) = controller.phase {
            let bar = Color(rgb: BreakColor.pair(controller.settings.color).bar)
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
                .padding(.leading, 7).padding(.trailing, 16)
                .frame(height: 52)
                .padding(Edge.Set(tail), PillShape.tailWidth)
                .contentShape(PillShape(edge: tail))
                .glassCard(in: PillShape(edge: tail))
            }
            .buttonStyle(.plain)
            .help("Click to start the break now. It starts by itself when the ring is empty.")
            .accessibilityHint("Starts the break now")
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
    var showPet = true
    var petOnRight = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = min(1.3, max(0.7, size.width / 1440))   // the mockup's sizes, scaled to this screen
        let colors = BreakColor.pair(controller.settings.color)
        let paused = controller.phase.isPaused
        ZStack {
            BreakGlow(rgb: colors.glow, size: size)
            VStack(spacing: 0) {
                Text("Time to take a break")
                    .font(.system(size: 50 * s, weight: .medium))
                    .tracking(-0.7 * s)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let r = controller.remaining(context.date)
                    VStack(spacing: 0) {
                        Text(Self.clock(r.left))
                            .font(.system(size: 172 * s, weight: .bold).monospacedDigit())
                            .tracking(-5 * s)
                            .foregroundStyle(paused ? Color(white: 0.55) : .white)
                            .padding(.top, 34 * s)
                        Capsule().fill(Color.white.opacity(0.1))
                            .frame(width: 368 * s, height: 6 * s)
                            .overlay(alignment: .leading) {
                                Capsule().fill(paused ? Color(white: 0.45) : Color(rgb: colors.bar))
                                    .frame(width: 368 * s * min(1, r.left / r.total))
                                    .animation(.linear(duration: 0.5), value: r.left)
                            }
                            .padding(.top, 46 * s)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(paused ? "Paused, \(Self.clock(r.left)) left" : "\(Self.clock(r.left)) left in your break")
                }
                Text(paused ? "paused" : "left in your break")
                    .font(.system(size: 17 * s))
                    .tracking(0.8 * s)
                    .foregroundStyle(Color(white: 0.5))
                    .padding(.top, 20 * s)
                ideaLine(s)
                HStack(spacing: 16 * s) {
                    Button("Back to Work") { controller.backToWork() }
                        .buttonStyle(OverlayButtonStyle(primary: true, s: s))
                        .keyboardShortcut(.cancelAction)
                        .help("End the break (Escape)")
                    Button { paused ? controller.resume() : controller.pause() } label: {
                        Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(OverlayButtonStyle(primary: false, s: s))
                    Button("Snooze 5 min") { controller.snooze() }
                        .buttonStyle(OverlayButtonStyle(primary: false, s: s))
                }
                .padding(.top, 72 * s)
            }
            .foregroundStyle(.white)
            if agents {
                BreakAgentsLayer(rex: controller.rex, size: size, start: controller.breakStarted,
                                 showPet: showPet, petOnRight: petOnRight, still: reduceMotion)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func ideaLine(_ s: CGFloat) -> some View {
        switch controller.idea {
        case .hidden:
            EmptyView()
        case .loading, .shown:
            VStack(spacing: 14 * s) {
                Group {
                    if case let .shown(text) = controller.idea {
                        (Text(Image(systemName: "sparkle")).foregroundColor(Color(rgb: BreakColor.pair(controller.settings.color).bar))
                            + Text("  " + text))
                    } else {
                        Text("Thinking of something to do in your break").redacted(reason: .placeholder)
                    }
                }
                .font(.system(size: 22 * s))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760 * s)
                .foregroundStyle(Color(white: 0.92))
                HStack(spacing: 26 * s) {
                    Button { controller.reroll() } label: { Label("Reroll", systemImage: "arrow.clockwise") }
                        .help("Another idea from your interests")
                    Button { controller.surprise() } label: { Label("Surprise me", systemImage: "dice") }
                        .help("Something unexpected you can do where you are")
                }
                .buttonStyle(QuietButtonStyle(s: s))
                .disabled(controller.idea == .loading)
            }
            .padding(.top, 46 * s)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The dark screen with the colour glowing at its edges and softly behind the timer. Each glow is a band from just
/// outside the screen to a little inside it, blurred inward, like an inset shadow.
private struct BreakGlow: View {
    let rgb: UInt32
    let size: CGSize

    var body: some View {
        let u = size.width / 100, glow = Color(rgb: rgb)
        ZStack {
            Color(white: 0.043)
            RadialGradient(colors: [glow.opacity(0.24), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 23 * u)
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

private struct OverlayButtonStyle: ButtonStyle {
    let primary: Bool
    let s: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17 * s, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(primary ? Color(white: 0.11) : Color(white: 0.93))
            .padding(.horizontal, 36 * s)
            .frame(height: 52 * s)
            .background(Capsule().fill(primary ? Color(white: 0.915) : Color(white: 0.106)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(primary ? 0 : 0.14), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

private struct QuietButtonStyle: ButtonStyle {
    let s: CGFloat
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15 * s, weight: .medium))
            .foregroundStyle(hovering ? Color.white : Color(white: 0.56))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - the agents

/// The Claude mark drawn as rectangles on its 24-unit grid, so it can walk: opposite legs lift in turn, the body
/// bobs and the arms swing. Frame 0 and 2 stand; 1 and 3 lift a pair.
struct ClaudeCrab: View {
    static let color = Color(rgb: 0xD97757)
    var frame = 0
    var blink = false

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
            p.addRect(r(0, 10.95 + bob + arm, 3, 3.1))
            p.addRect(r(21, 10.95 + bob - arm, 3, 3.1))
            for (i, x) in [4.487, 7.488, 15, 18].enumerated() { p.addRect(r(CGFloat(x), 17.079 + bob, 1.513, 2.921 - lift[i])) }
            // the eyes are holes in the body
            let eyeH: CGFloat = blink ? 0.5 : 2.847, eyeY = 8.102 + bob + (blink ? 1.8 : 0)
            p.addRect(r(6, eyeY, 1.488, eyeH))
            p.addRect(r(16.51, eyeY, 1.49, eyeH))
            context.fill(p, with: .color(Self.color), style: FillStyle(eoFill: true))
        }
        .aspectRatio(24 / 17, contentMode: .fit)
    }
}

/// The pet and every agent Rex reports as working, moving around the edges of the break screen: the pet and the
/// Claude crabs pace along the bottom, the rest float. A blocked agent stands still with a "!".
struct BreakAgentsLayer: View {
    @ObservedObject var rex: RexAgents
    @ObservedObject private var pet = CodexPetSession.shared
    let size: CGSize
    let start: Date
    let showPet: Bool
    let petOnRight: Bool
    let still: Bool

    private static let petFrames: [CodexPetSprite.State: [CGImage]] = Bundle.pulseResources
        .url(forResource: "Resources/codex-pet", withExtension: "webp")
        .map(CodexPetSprite.frames(from:)) ?? [:]

    var body: some View {
        let crabs = Array(rex.agents.filter { $0.app == .claude }.prefix(4))
        let floaters = Array(rex.agents.filter { $0.app != .claude }.prefix(6))
        let helpers = min(pet.helpersWorking, max(0, 6 - floaters.count))
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still)) { context in
            let t = still ? 0 : context.date.timeIntervalSince(start)
            ZStack(alignment: .topLeading) {
                if showPet { petView(t) }
                ForEach(Array(crabs.enumerated()), id: \.element.id) { i, agent in crabView(agent, lane: i, t: t) }
                ForEach(Array(floaters.enumerated()), id: \.element.id) { i, agent in floaterView(agent, slot: i, t: t) }
                ForEach(0..<helpers, id: \.self) { i in helperView(slot: floaters.count + i, t: t) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
    }

    private var u: CGFloat { size.width / 100 }
    private var floor: CGFloat { size.height - 1.2 * u }

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

    /// Walks in from the rail's side, waves, then paces with a hop now and then.
    private func petView(_ t: Double) -> some View {
        let w = 7 * u, home = petOnRight ? 82.0 : 18.0, enter = petOnRight ? 104.0 : -4.0
        var x = home, state = CodexPetSprite.State.idle
        if still { x = home }
        else if t < 3.2 { x = enter + (home - enter) * t / 3.2; state = petOnRight ? .walkLeft : .walkRight }
        else if t < 4.8 { state = .waving }
        else {
            let k = (t - 4.8).truncatingRemainder(dividingBy: 12)
            if k < 3 { x = home - 6 * k / 3; state = .walkLeft }
            else if k < 5 { x = home - 6; state = k > 3.8 && k < 4.45 ? .jump : .idle }
            else if k < 8 { x = home - 6 + 6 * (k - 5) / 3; state = .walkRight }
            else { state = .idle }
        }
        return sprite(state, t)
            .frame(width: w, height: w * 208 / 192)
            .position(x: x * u, y: floor - w * 104 / 192)
            .help(pet.helpersWorking > 0 ? "Codex pet · \(pet.helpersWorking) helper\(pet.helpersWorking == 1 ? "" : "s") working" : "Codex pet")
    }

    /// Paces sideways in its own lane on the side away from the pet.
    private func crabView(_ agent: BreakAgent, lane: Int, t: Double) -> some View {
        let w = 5.6 * u, span = 12.0
        let x0 = petOnRight ? 5.0 + Double(lane) * 15 : 95.0 - span - Double(lane) * 15
        var x = x0, walking = !agent.blocked && !still
        let k = (t + Double(lane) * 3.1).truncatingRemainder(dividingBy: 8)
        if walking {
            if k < 3 { x = x0 + span * k / 3 }
            else if k < 4 { x = x0 + span; walking = false }
            else if k < 7 { x = x0 + span - span * (k - 4) / 3 }
            else { walking = false }
        }
        let frame = walking ? Int(t * 8) % 4 : 0
        let blink = !walking && !agent.blocked && k.truncatingRemainder(dividingBy: 1) > 0.45 && k.truncatingRemainder(dividingBy: 1) < 0.6
        return ClaudeCrab(frame: frame, blink: blink)
            .frame(width: w)
            .overlay(alignment: .topTrailing) { if agent.blocked { BlockedBadge(size: 1.3 * u).offset(x: 0.4 * u, y: -0.6 * u) } }
            .position(x: x * u, y: floor - w * 17 / 48)
            .help(Self.tip(agent))
    }

    private func floatPosition(slot: Int, t: Double, moving: Bool) -> CGPoint {
        // two bands either side of the timer, then the top edge
        let bands: [(cx: Double, cy: Double, ax: Double, ay: Double)] = [
            (13, 24, 6, 10), (87, 26, 6, 9), (12, 58, 5, 10), (88, 58, 5, 12), (32, 8, 12, 2.5), (68, 8, 12, 2.5),
        ]
        let b = bands[slot % bands.count], w = 0.17 + Double(slot) * 0.02, p = Double(slot) * 1.7
        let x = moving ? b.cx + b.ax * sin(w * t * 2 + p) : b.cx
        let y = moving ? b.cy + b.ay * sin(w * t * 1.3 + p * 1.7) : b.cy
        return CGPoint(x: x * u, y: y * size.height / 100)
    }

    private func floaterView(_ agent: BreakAgent, slot: Int, t: Double) -> some View {
        let d = 5 * u
        let account: AccountID = switch agent.app {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        case .grok: .grok
        }
        return ZStack {
            Circle().fill(Color(white: 0.03))
            Circle().strokeBorder(account.accent, lineWidth: 0.22 * u)
            BrandIcon(account: account, size: d * 0.46)
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.6), radius: 1.2 * u, y: 0.5 * u)
        .overlay(alignment: .topTrailing) { if agent.blocked { BlockedBadge(size: 1.3 * u) } }
        .position(floatPosition(slot: slot, t: t, moving: !agent.blocked && !still))
        .help(Self.tip(agent))
    }

    private func helperView(slot: Int, t: Double) -> some View {
        sprite(.running, t + Double(slot) * 0.3)
            .frame(width: 4.4 * u, height: 4.4 * u * 208 / 192)
            .position(floatPosition(slot: slot, t: t, moving: !still))
            .help("Codex helper")
    }

    private static func tip(_ agent: BreakAgent) -> String {
        [agent.label.isEmpty ? agent.app.rawValue : agent.label, agent.blocked ? "waiting for you" : nil, agent.msg.isEmpty ? nil : agent.msg]
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

/// Lays its children out in rows, wrapping like words: the interest pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, point) in zip(subviews, arrange(subviews, width: bounds.width).points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + row), points)
    }
}

/// Settings → Breaks. A binding, not AppState, so it can be rendered on its own.
struct BreakSettingsSection: View {
    @Binding var settings: BreakSettings
    @State private var draft = ""
    @State private var hex = ""
    private let ideasAvailable = BreakIdeas.available

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
            Text("A long break takes the place of the micro break due at the same time. A break waits while a Pulse voice call is on, and time away from the Mac counts as a break.")
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
                }
            }
            LabeledContent("Custom colour") {
                HStack(spacing: 8) {
                    ColorPicker("Custom colour", selection: customColor, supportsOpacity: false).labelsHidden()
                    TextField("Hex", text: $hex, prompt: Text("#RRGGBB"))
                        .labelsHidden()
                        .frame(width: 84)
                        .monospacedDigit()
                        .onSubmit {
                            if let rgb = BreakColor.rgb(hex: hex) { settings.color = BreakColor.hex(rgb) }
                            hex = BreakColor.rgb(hex: settings.color).map(BreakColor.hex) ?? ""
                        }
                        .help("Six hex digits, then Return")
                }
            }
            .onAppear { hex = BreakColor.rgb(hex: settings.color).map(BreakColor.hex) ?? "" }
            .onChange(of: settings.color) { _, new in hex = BreakColor.rgb(hex: new).map(BreakColor.hex) ?? "" }
            Toggle(isOn: $settings.showAgents) {
                Text("Show agents that are working")
                Text("The Codex pet, and agents Rex reports as working or waiting for you")
            }
        }
        Section("Ideas") {
            Toggle(isOn: $settings.ideas) {
                Text("Suggest something to do")
                Text(ideasAvailable ? "Written on this Mac by Apple Intelligence"
                     : "Needs Apple Intelligence, which is off or still downloading on this Mac")
            }
            .disabled(!ideasAvailable)
            LabeledContent {
                HStack(spacing: 8) {
                    Text("Easy").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(settings.level) }, set: { settings.level = Int($0.rounded()) }), in: 0...4, step: 1)
                        .labelsHidden()
                        .accessibilityValue(BreakSettings.levels[settings.level])
                    Text("Adventurous").foregroundStyle(.secondary)
                }
            } label: { Text("Level") }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Interests") {
                    TextField("Interests", text: $draft, prompt: Text("Add an interest, then press Return"))
                        .labelsHidden()
                        .frame(width: 250)
                        .onSubmit {
                            settings.interests = BreakInterests.adding(draft, to: settings.interests)
                            draft = ""
                        }
                }
                if !settings.interests.isEmpty {
                    FlowLayout {
                        ForEach(settings.interests, id: \.self) { word in
                            HStack(spacing: 3) {
                                Text(word).font(.callout)
                                Button { settings.interests.removeAll { $0 == word } } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                        .frame(width: 16, height: 16).contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(word)")
                            }
                            .padding(.leading, 9).padding(.trailing, 4)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                        }
                    }
                }
            }
            Text("Reroll asks again from your interests and level. Surprise me ignores them and picks something odd you can do where you are.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!ideasAvailable)
    }

    private var customColor: Binding<Color> {
        Binding(get: { Color(rgb: BreakColor.pair(settings.color).glow) },
                set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { UInt32(max(0, min(255, ($0 * 255).rounded()))) }
                    settings.color = BreakColor.hex(rgb[0] << 16 | rgb[1] << 8 | rgb[2])
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
