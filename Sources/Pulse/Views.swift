import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private struct GlassTintKey: EnvironmentKey { static let defaultValue = true }
private struct ShowsRemainingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Rings, bars and percentages show what's left of each limit instead of what's used.
    var showsRemaining: Bool {
        get { self[ShowsRemainingKey.self] }
        set { self[ShowsRemainingKey.self] = newValue }
    }

    /// A black tint on dark glass. Off leaves the system material untinted.
    var glassTint: Bool {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
}

/// Dark Liquid Glass, with the optional black tint.
private struct GlassCard<S: Shape>: ViewModifier {
    @Environment(\.glassTint) private var tinted
    let shape: S
    func body(content: Content) -> some View {
        content.background {
            // Glass's adaptive foreground effect can invert semantic text independently of our dark surface.
            Color.clear.glassEffect(tinted ? .regular.tint(.black) : .regular, in: shape)
                .background(.black, in: shape)
        }
    }
}

extension View {
    func glassCard<S: Shape>(in shape: S) -> some View { modifier(GlassCard(shape: shape)) }
}

private let brandIcons: [AccountID: NSImage] = {
    var d: [AccountID: NSImage] = [:]
    for id in AccountID.allCases {
        // PNG for logos whose SVG needs filters macOS can't draw (Antigravity's blurs)
        if let url = ["svg", "png"].lazy.compactMap({ Bundle.pulseResources.url(forResource: "Resources/\(id.rawValue)", withExtension: $0) }).first,
           let img = NSImage(contentsOf: url) {
            // template-tint only monochrome icons; full-color icons render as-is
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            img.isTemplate = src.contains("currentColor")
            img.size = NSSize(width: 128, height: 128)   // rasterize SVG large, scale down crisp
            d[id] = img
        }
    }
    return d
}()

struct BrandIcon: View {
    let account: AccountID
    var size: CGFloat

    var body: some View {
        if let img = brandIcons[account] {
            Image(nsImage: img)
                .renderingMode(img.isTemplate ? .template : .original)
                .interpolation(.high)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: account.glyph)
                .font(.system(size: size * 0.8, weight: .bold))
                .foregroundStyle(.primary)
        }
    }
}

extension CodexPetSession {
    /// Yellow connects, blue listens, red pauses the microphone. nil = off (each view picks its neutral).
    var voiceTint: Color? {
        guard voiceState != .off else { return nil }
        if voiceState == .connecting { return .yellow }
        if microphonePaused { return .red }
        return AccountID.codex.accent
    }
}

private struct CodexPet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var session = CodexPetSession.shared
    let size: CGFloat
    var animateIdle = true   // false in the collapsed rail: an always-on 10 fps idle loop costs CPU all day
    private static let frames: [CodexPetSprite.State: [CGImage]] = Bundle.pulseResources
        .url(forResource: "Resources/codex-pet", withExtension: "webp")
        .map(CodexPetSprite.frames(from:)) ?? [:]

    /// The pet mirrors the session: waiting while Codex needs an answer (even mid-call) or thinks,
    /// running while it speaks, waving while a voice call is live.
    private var state: CodexPetSprite.State {
        if session.waitingOnYou { return .waiting }
        if session.voiceState == .speaking { return .running }
        if session.voiceState != .off { return .waving }
        return session.thinking ? .waiting : .idle
    }

    var body: some View {
        let still = reduceMotion || (state == .idle && !animateIdle)
        ZStack {
            Circle().stroke(session.voiceTint ?? Color.primary.opacity(0.18), lineWidth: size * 0.12)
            TimelineView(.animation(minimumInterval: 0.1, paused: still)) { context in
                if let frames = Self.frames[state], frames.count == CodexPetSprite.track(state).durations.count {
                    let index = still ? 0 : CodexPetSprite.frame(state, at: context.date.timeIntervalSinceReferenceDate)
                    Image(decorative: frames[index], scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    BrandIcon(account: .codex, size: size * 0.4)
                }
            }
            .frame(width: size * 0.72, height: size * 0.78)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if session.microphonePaused {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: max(8, size * 0.22), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: max(14, size * 0.36), height: max(14, size * 0.36))
                    .background(.red, in: Circle())
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
    }
}

struct RingView: View {
    @Environment(\.showsRemaining) private var remaining
    let account: AccountID
    let percent: Double?
    var secondary: Double? = nil
    var tertiary: Double? = nil    // third window, a per-model cap (Claude's, Antigravity's): the disc behind the icon
    var size: CGFloat = 52
    var showPercent = true
    var nearLimit = false   // any of the account's windows at 98%+, drawn or not

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // the outer track's gray, never red: the level rises as the cap is used, or falls showing what's left
                if let tertiary {
                    let d = size * 0.61   // inside the inner track
                    Rectangle().fill(Color.primary.opacity(0.18))
                        .frame(width: d, height: d * max(0, min(shown(tertiary), 100)) / 100)
                        .frame(width: d, height: d, alignment: .bottom)
                        .clipShape(Circle())
                }
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: size * 0.12)
                if let percent {
                    arc(percent, lineWidth: size * 0.12)
                }
                if let secondary {
                    arc(secondary, lineWidth: size * 0.07)
                        .padding(size * 0.16)
                }
                BrandIcon(account: account, size: size * 0.4)
            }
            .frame(width: size, height: size)
            // Claude's accent is nearly red, so a red arc alone wouldn't read: same badge style as the pet's paused mic
            .overlay(alignment: .bottomTrailing) {
                if nearLimit {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: max(7, size * 0.17), weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: max(11, size * 0.28), height: max(11, size * 0.28))
                        .background(.red, in: Circle())
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            if showPercent {
                Text(percent.map { "\(remaining ? 100 - Int($0) : Int($0))%" } ?? "—")   // 98.4 used is 98%, so 2% left
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.primary)
            }
        }
    }

    private func shown(_ used: Double) -> Double { remaining ? 100 - used : used }

    /// Always the account's colour: near a limit the badge and Pulse's alert say so, not the arc.
    private func arc(_ used: Double, lineWidth: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: max(0, min(shown(used), 100)) / 100)
            .stroke(account.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// The battery as the rail's last ring: green, yellow or red by charge, a bolt while plugged in.
struct BatteryRing: View {
    let reading: BatteryReading
    let level: BatteryLevel
    var size: CGFloat = 52
    var showPercent = true

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: size * 0.12)
                Circle()
                    .trim(from: 0, to: CGFloat(max(reading.percent, 1)) / 100)
                    .stroke(level.color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: reading.onAC ? "bolt.fill" : "battery.\(min(100, (reading.percent + 12) / 25 * 25))percent")
                    .font(.system(size: size * (reading.onAC ? 0.34 : 0.26), weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
            .frame(width: size, height: size)
            if showPercent {
                Text("\(reading.percent)%")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(level == .critical ? Color.red : Color.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityAddTraits(.isImage)   // without a role, VoiceOver may skip it
        .accessibilityValue(summary)
        .help(summary)
    }

    private var summary: String {
        "\(reading.percent)%" + (reading.onAC ? ", plugged in" : reading.minutesLeft.map { ", about \(batteryTimeLeft($0)) left" } ?? "")
            + (reading.simulated ? " (simulated)" : "")
    }
}

struct WindowRow: View {
    @Environment(\.showsRemaining) private var remaining
    let window: UsageWindow
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.label)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
            if let p = window.percentUsed {
                ProgressView(value: max(0, min(remaining ? 100 - p : p, 100)), total: 100)
                .tint(window.isNearLimit ? .red : tint)
                .frame(height: 6)
                HStack {
                    Text(remaining ? "\(100 - Int(p))% Left" : "\(Int(p))% Used").font(.caption)
                        .foregroundStyle(window.isNearLimit ? Color.red : Color.secondary)
                    Spacer()
                    Text(resetLabel(window.resetsAt)).font(.caption)
                }
                .foregroundStyle(Color.secondary)
            }
        }
    }
}

/// Rounded card plus a tail (pointing at the rail) as one shape, so the glass renders as a single piece.
private struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 13
    var edge: Edge = .trailing
    var at: CGFloat? = nil   // where the tail sits along its edge; nil = the middle
    func path(in rect: CGRect) -> Path {
        let t = Self.tailWidth
        // Kept clear of the 18pt corners by half the tail's 24pt base.
        let along = edge == .top || edge == .bottom ? rect.width : rect.height
        let c = min(max(at ?? along / 2, 30), along - 30)
        let body: CGRect
        switch edge {
        case .trailing: body = CGRect(x: 0, y: 0, width: rect.width - t, height: rect.height)
        case .leading:  body = CGRect(x: t, y: 0, width: rect.width - t, height: rect.height)
        case .top:      body = CGRect(x: 0, y: t, width: rect.width, height: rect.height - t)
        case .bottom:   body = CGRect(x: 0, y: 0, width: rect.width, height: rect.height - t)
        }
        var p = Path()
        switch edge {
        case .trailing:
            p.move(to: CGPoint(x: body.maxX, y: rect.minY + c - 12))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
            p.addLine(to: CGPoint(x: body.maxX, y: rect.minY + c + 12))
        case .leading:
            p.move(to: CGPoint(x: body.minX, y: rect.minY + c - 12))
            p.addLine(to: CGPoint(x: 0, y: rect.minY + c))
            p.addLine(to: CGPoint(x: body.minX, y: rect.minY + c + 12))
        case .top:
            p.move(to: CGPoint(x: rect.minX + c - 12, y: body.minY))
            p.addLine(to: CGPoint(x: rect.minX + c, y: 0))
            p.addLine(to: CGPoint(x: rect.minX + c + 12, y: body.minY))
        case .bottom:
            p.move(to: CGPoint(x: rect.minX + c - 12, y: body.maxY))
            p.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + c + 12, y: body.maxY))
        }
        p.closeSubpath()
        return Path(roundedRect: body, cornerRadius: 18).union(p)
    }
}

struct UsageCard: View {
    let snapshot: AccountSnapshot
    var tailEdge: Edge = .trailing
    var tailAt: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandIcon(account: snapshot.id, size: 17)
                Text("\(snapshot.displayName) Usage").font(.headline)
                Spacer()
                Text(snapshot.planLabel).font(.caption).foregroundStyle(Color.secondary)
            }
            .foregroundStyle(Color.primary)
            ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { i, w in
                WindowRow(window: w, tint: i == 0 ? snapshot.id.accent : snapshot.id.accent.opacity(0.5))
            }
            if let msg = snapshot.healthMessage {
                Text(msg).font(.caption).foregroundStyle(.primary.opacity(0.6))
            }
            if snapshot.id == .grok, snapshot.health == .needsAuth {
                Button("Connect Grok…") {
                    WebLogin.presentGrok { Task { await AppState.shared?.refreshAll() } }
                }
            }
        }
        .padding(16)
        .padding(Edge.Set(tailEdge), BubbleShape.tailWidth)
        .frame(width: tailEdge == .trailing || tailEdge == .leading ? 320 + BubbleShape.tailWidth : 320)
        .glassCard(in: BubbleShape(edge: tailEdge, at: tailAt))
    }
}

/// The pet's popout: Codex quick chat, live voice, and what the agent is doing, on the same bubble
/// as the usage cards. Everything here is the Codex app-server's own session (see CodexChat.swift).
struct PetCard: View {
    @ObservedObject private var session = CodexPetSession.shared
    @FocusState private var composing: Bool
    @State private var following = true   // the transcript is at its bottom, so new text scrolls it

    /// Codex's replies with their inline Markdown (bold, italics, code, links); lists stay as written, and fenced
    /// code keeps its lines in a monospaced font.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        CodexPetSession.fenceParts(text).reduce(into: AttributedString()) { out, part in
            if part.code {
                var block = AttributedString(part.text)
                block.font = .system(.callout, design: .monospaced)
                out += block
            } else {
                out += (try? AttributedString(markdown: part.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(part.text)
            }
        }
    }

    private struct Bubble: View, Equatable {
        let message: ChatMessage

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.message.id == rhs.message.id && lhs.message.role == rhs.message.role
                && lhs.message.text == rhs.message.text && lhs.message.caption == rhs.message.caption
        }

        var body: some View {
            let m = message
            if m.role == .note {   // Pulse's own notice, not a message and not input: a small centered line
                Text(m.text).font(.caption).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled).frame(maxWidth: .infinity).padding(.vertical, 2).id(m.id)
            } else {
                HStack {
                    if m.role == .user { Spacer(minLength: 40) }
                    VStack(alignment: .leading, spacing: 2) {
                        // Results of work a call started: never one of the spoken replies.
                        if let caption = m.caption { Text(caption).font(.caption2).foregroundStyle(Color.secondary) }
                        Text(m.role == .user ? AttributedString(m.text) : inlineMarkdown(m.text))
                            .font(.callout)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(m.role == .user ? AccountID.codex.accent.opacity(0.35)
                                                      : m.caption != nil ? Color.clear
                                                      : Color(white: 0.16)))
                            .overlay { if m.caption != nil { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.5)) } }
                    }
                    .accessibilityElement(children: .combine)
                    if m.role != .user { Spacer(minLength: 40) }
                }
                .id(m.id)
            }
        }
    }
    var tailEdge: Edge = .trailing
    var tailAt: CGFloat? = nil
    var showUsage: (() -> Void)?   // nil while Codex usage is switched off

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandIcon(account: .codex, size: 17)
                // Takes only the width left over, so the details truncate instead of squeezing the buttons.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Codex").font(.headline)
                    if !session.workModels.isEmpty {
                        workModelMenu(workDetail ?? "Choose a work model", label: modelLine ?? "Choose a work model")
                    } else if let model = modelLine {
                        Text(model).font(.caption2).foregroundStyle(Color.secondary).lineLimit(1)
                    }
                    if let split = splitLine {   // its own line: a menu label never wraps, so it would cut this off
                        Text(split).font(.caption2).foregroundStyle(Color.secondary)   // wraps fully: pending notices can be long
                    }
                    if let place = placeDetail {
                        Text(place).font(.caption2).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let showUsage {
                    Button("Usage", action: showUsage).buttonStyle(.borderless).font(.caption)
                        .foregroundStyle(Color.secondary).fixedSize()
                }
                Button { session.clear() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New conversation: starts over and stops running helpers")
                    .accessibilityLabel("New conversation").accessibilityHint("Starts over and stops running helpers")
            }
            .foregroundStyle(Color.primary)

            if !session.activity.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.activity) { pill in
                            HStack(spacing: 4) {
                                if !pill.done { ProgressView().controlSize(.mini) }
                                Text(pill.label).lineLimit(1)
                            }
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(AccountID.codex.accent.opacity(pill.done ? 0.18 : 0.35)))
                        }
                    }
                }
                .foregroundStyle(Color.primary)
            }

            transcript

            if session.helpersWorking > 0 {
                Label(session.helpersWorking == 1 ? "A helper is working" : "\(session.helpersWorking) helpers are working", systemImage: "person.2")
                    .font(.caption).foregroundStyle(Color.secondary)
            }

            if session.microphonePaused {
                Label("Microphone paused · voice still on", systemImage: "mic.slash.fill")
                    .font(.caption).foregroundStyle(Color.secondary)
            }

            if let status = session.status {
                Text(status).font(.caption)
                    .foregroundStyle(status == CodexPetSession.reconnectNote ? Color.secondary : .red.opacity(0.85))
                    .lineLimit(3).help(status)
                if session.microphoneBlocked {
                    Button("Open Microphone Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }

            HStack(spacing: 8) {
                TextField("Ask Codex…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($composing)
                    .onSubmit { submit() }
                // Fixed slots: Send never moves and Stop never appears where a click meant for Send lands.
                Button { submit() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.borderless).help("Send").accessibilityLabel("Send")
                    .disabled(session.draft.trimmingCharacters(in: .whitespaces).isEmpty || !session.canSend)
                // Stop stays while helpers work, even with the pet free.
                Button { session.interrupt() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.borderless).help("Stop work and helpers").accessibilityLabel("Stop work and helpers")
                    .opacity(session.thinking || session.helpersWorking > 0 ? 1 : 0)
                    .disabled(!session.thinking && session.helpersWorking == 0)
                    .accessibilityHidden(!session.thinking && session.helpersWorking == 0)
                voiceButton
            }
            .font(.title3)
            .foregroundStyle(Color.primary)
        }
        .padding(16)
        .padding(Edge.Set(tailEdge), BubbleShape.tailWidth)
        .frame(width: tailEdge == .trailing || tailEdge == .leading ? 340 + BubbleShape.tailWidth : 340)
        .glassCard(in: BubbleShape(edge: tailEdge, at: tailAt))
        .task { session.reopen(); session.loadWorkModels(); try? await Task.sleep(for: .milliseconds(200)); composing = true }   // after the panel is key
        .onExitCommand {
            // Escape: end the call and hand the keyboard back to whatever was in front
            session.stopVoice()
            AppState.shared?.collapseOverlay()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.canLoadEarlier {
                        Button("Load earlier messages") { session.loadEarlier() }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(Color.secondary)
                    }
                    if session.messages.isEmpty {
                        Text(session.voiceState == .off ? "Type, or tap the waveform to talk. Same Codex sign-in, same threads."
                             : session.voiceState == .connecting ? "Starting microphone…"
                             : session.microphonePaused ? "Use the microphone button or shortcut to talk." : "Listening…")
                            .font(.caption).foregroundStyle(Color.secondary)
                    }
                    ForEach(session.messages) { m in
                        Bubble(message: m)
                    }
                    if session.waitingOnYou {
                        Label("Waiting for your answer in the Codex prompt", systemImage: "hand.raised")
                            .font(.caption).foregroundStyle(Color.secondary).id("thinking")
                    } else if session.thinking, !(session.messages.last?.live ?? false) {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").font(.caption) }
                            .foregroundStyle(Color.secondary).id("thinking")
                    }
                }
                .foregroundStyle(Color.primary)
            }
            .environment(\.openURL, OpenURLAction { openLink($0) })
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)   // grows with the transcript, scrolls past 260pt
            .modifier(FollowsBottom(following: $following))
            .onChange(of: session.messages.last?.text) { _, _ in
                // Scrolled up to read, the reader stays put; what they send always shows.
                guard let last = session.messages.last, following || last.role == .user else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .onAppear {   // reopening the card shows where the conversation is, not its oldest message
                DispatchQueue.main.async { if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var voiceButton: some View {
        HStack(spacing: 6) {
            if session.voiceState != .off {
                Button { session.muted.toggle() } label: {
                    Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                }
                .buttonStyle(.borderless).help(session.muted ? "Unmute" : "Mute").accessibilityLabel(session.muted ? "Unmute" : "Mute")
            }
            Button { session.toggleVoice() } label: {
                Image(systemName: session.voiceState == .off ? "waveform.circle" : "waveform.circle.fill")
                    .foregroundStyle(session.voiceTint ?? Color.primary)
                    .symbolEffect(.variableColor.iterative, isActive: session.voiceState == .connecting)
            }
            .buttonStyle(.borderless)
            .help(session.voiceState == .off ? "Start live voice" : "End live voice")
            .accessibilityLabel(session.voiceState == .off ? "Start live voice" : "End live voice")
        }
    }

    /// Model · folder · since when, as Codex reported them for the open conversation.
    /// Model · effort, as Codex reported them (or the saved choice before a conversation).
    private var workDetail: String? {
        let parts = [modelLine, splitLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The model, with its effort when the pet and helpers share it.
    private var modelLine: String? {
        let split = session.nextSplit != nil || session.helperEffort != nil
        let parts = [session.shownModel, split ? nil : session.shownEffort].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The pet's and helpers' efforts when they differ, and what changes from the next open.
    private var splitLine: String? {
        // Before a conversation opens, the split it will get previews from the pick.
        let next = session.nextSplit
        let talk = next.map { "talks at \($0.talk)" } ?? (session.helperEffort != nil ? session.shownEffort.map { "talks at \($0)" } : nil)
        let parts = [talk, next.map { "helpers at \($0.helpers)" } ?? session.helperEffort.map { "helpers at \($0)" },
                     session.pendingModel.map { "switches to \($0) from the next open" },
                     session.pendingHelperEffort.map { "helpers at \($0) from the next open" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Folder · since when, for the open conversation.
    private var placeDetail: String? {
        let started = session.conversationStarted.map { "since " + $0.formatted(.dateTime.month(.abbreviated).day()) }
        let parts = [session.folder, started].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The header detail doubles as the work-model menu: the model doing Codex's work and its effort,
    /// never the voice's own realtime model.
    private func workModelMenu(_ detail: String, label: String) -> some View {
        let planned = session.nextSplit != nil ? " (for the next conversation)" : ""
        return Menu {
            Section("Work model · the voice stays the same") {
                ForEach(session.workModels) { work in
                    Menu(work.id == session.shownModel ? "✓ " + work.name : work.name) {
                        ForEach(work.efforts, id: \.self) { level in
                            Button(work.id == session.shownModel && level == session.chosenEffort ? "✓ " + level : level) {
                                session.chooseWork(model: work.id, effort: level)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .font(.caption2).foregroundStyle(Color.secondary)
        }
        .menuStyle(.button).buttonStyle(.borderless)   // a plain label lines up with the lines around it
        .fixedSize()
        .disabled(session.choosingWork)
        .help("Work model: \(detail)\(planned). Choose the model and effort Codex works with; the voice doesn't change. With helpers and an effort above medium, the pet talks at medium and helpers work at the effort you pick; a new helper effort, or a model that can't run the helpers' current effort, applies from the next conversation or Pulse restart.")
        .accessibilityLabel("Work model: \(detail)\(planned)")
    }

    /// A link in a reply: web and mail links open; a file opens or is shown in Finder as `linkOpens` decides.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        guard let target = CodexPetSession.linkTarget(url, folder: session.homeFolder) else { return .discarded }
        guard target.isFileURL else { return .systemAction(target) }
        guard let file = CodexPetSession.linkOpens(target) else { return .discarded }
        if file.open { NSWorkspace.shared.open(file.url) } else { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        return .handled
    }

    private func submit() {
        guard !session.draft.trimmingCharacters(in: .whitespaces).isEmpty, session.canSend else { return }
        session.send(session.draft)
        session.draft = ""
    }
}

/// A card fades in where it opens. Only its opacity animates, never the layout, so the rail stays put.
private struct FadesIn: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).onAppear { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
    }
}

/// Keeps `following` up to date from the scroll view's geometry (the rule is `transcriptFollows`).
private struct FollowsBottom: ViewModifier {
    @Binding var following: Bool

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
            following = transcriptFollows(following, oldOffset: old.contentOffset.y, offset: new.contentOffset.y,
                                          visible: new.containerSize.height, content: new.contentSize.height)
        }
    }
}

struct OverlayView: View {
    @ObservedObject var state: AppState
    var onSize: ((CGSize) -> Void)? = nil
    var onDrag: ((CGPoint) -> Void)? = nil
    var onDrop: ((CGPoint) -> Void)? = nil
    var onRailFrame: ((CGRect) -> Void)? = nil
    var onCardFrame: ((CGRect) -> Void)? = nil
    var onHintFrame: ((CGRect) -> Void)? = nil
    var onPillFrame: ((CGRect) -> Void)? = nil
    var pointerInside: (() -> Bool)? = nil   // whether the pointer is really over the panel
    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var breaks = BreakController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exitWatch: Task<Void, Never>?

    private var expanded: Bool { state.hoveringOverlay || state.cardVisible || state.petVisible }
    @State private var itemFrames: [String: CGRect] = [:]   // the pet and each ring, so a card's tail points at its own
    @State private var cardFrame = CGRect.zero
    @State private var railFrame = CGRect.zero

    /// The tail's position along the card's edge: at the rail item that opened the card.
    private func tailAt(_ item: String) -> CGFloat? {
        guard let target = itemFrames[item], cardFrame != .zero else { return nil }
        return state.dock.isVertical ? ringCentre(target) - cardFrame.minY : target.midX - cardFrame.minX
    }

    /// On a vertical rail an item is its ring with the percentage under it: the tail points at the ring.
    private func ringCentre(_ item: CGRect) -> CGFloat { item.minY + min(item.width, item.height) / 2 }

    /// How far along the rail an open card moves so its tail lands on the item that opened it. A card centred on a
    /// long rail couldn't reach the items near its ends. It stays within the rail's length, so inside the panel, and
    /// doesn't move while a break's countdown shares its column.
    private func cardShift(_ item: String) -> CGFloat {
        guard let target = itemFrames[item], cardFrame != .zero, railFrame != .zero, !breaks.phase.isCountdown else { return 0 }
        let vertical = state.dock.isVertical
        let room = (vertical ? railFrame.height - cardFrame.height : railFrame.width - cardFrame.width) / 2
        guard room > 0 else { return 0 }
        return min(max(vertical ? ringCentre(target) - railFrame.midY : target.midX - railFrame.midX, -room), room)
    }

    var body: some View {
        let layout = state.dock.isVertical
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            : AnyLayout(VStackLayout(spacing: 16))
        layout {
            // card sits on the far side of the rail from the docked edge, tail pointing at the rail
            if state.dock == .top || state.dock == .left {
                rail
                card(tail: state.dock == .left ? .leading : .top)
            } else {
                card(tail: state.dock == .bottom ? .bottom : .trailing)
                rail
            }
        }
        .padding(12)   // no layout animation: the panel resizes at once, so an animated rail would slide from its old spot
        .onHover { over in
            guard !state.dragging else { return }
            exitWatch?.cancel(); exitWatch = nil
            if over { state.hoveringOverlay = true; return }
            guard !state.petVisible else { return }   // a chat stays open until a click outside
            // Hover also ends without the pointer leaving: when Pulse hands focus back as the pet closes, and while a
            // shorter card shifts the rail inside the not yet resized panel. Then no later exit may come, so the
            // pointer is watched until it really leaves.
            guard pointerInside?() == true else { return state.collapseOverlay() }
            // ponytail: a 250 ms check, only after an exit the pointer didn't make
            exitWatch = Task { @MainActor in
                while !Task.isCancelled, pointerInside?() == true { try? await Task.sleep(for: .milliseconds(250)) }
                if !Task.isCancelled, !state.petVisible { state.collapseOverlay() }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize?($0) }
        .environment(\.glassTint, state.glassTint)
        .environment(\.showsRemaining, state.showsRemaining)
    }

    /// A break's countdown grows out of the rail's middle; an open card moves along beside it.
    @ViewBuilder
    private func card(tail: Edge) -> some View {
        let beside = state.dock.isVertical
            ? AnyLayout(VStackLayout(alignment: tail == .leading ? .leading : .trailing, spacing: 10))
            : AnyLayout(HStackLayout(alignment: tail == .top ? .top : .bottom, spacing: 10))
        beside {
            BreakPill(controller: breaks, tail: tail, onFrame: onPillFrame)
            // hovering the rail with nothing else open: when the next breaks come
            if state.hoveringOverlay, !state.cardVisible, !state.petVisible, breaks.phase.isWorking, breaks.settings.enabled {
                NextBreakHint(controller: breaks, tail: tail)
                    // its Pause buttons take clicks, so a click there isn't a click away
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onHintFrame?($0) }
                    .onDisappear { onHintFrame?(.zero) }
                    .transition(.opacity)
            }
            let shift = cardShift(state.petVisible ? "pet" : state.selected.rawValue)
            usageOrPetCard(tail: tail)
                .offset(x: state.dock.isVertical ? 0 : shift, y: state.dock.isVertical ? shift : 0)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.3), value: breaks.phase.isCountdown)
    }

    @ViewBuilder
    private func usageOrPetCard(tail: Edge) -> some View {
        if state.petVisible {
            PetCard(tailEdge: tail, tailAt: tailAt("pet"), showUsage: state.persisted.enabled.contains(.codex) ? { toggleCard(.codex) } : nil)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0; onCardFrame?($0) }
                .modifier(FadesIn())
        } else if state.cardVisible, state.persisted.enabled.contains(state.selected) {
            UsageCard(snapshot: state.snapshots[state.selected] ?? placeholder(state.selected),
                      tailEdge: tail, tailAt: tailAt(state.selected.rawValue))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0; onCardFrame?($0) }
                .modifier(FadesIn())
        }
    }

    private var rail: some View {
        let layout = state.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: expanded ? 18 : 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: expanded ? 18 : 10))
        return layout {
            if state.showsPet {
                PetRailItem(expanded: expanded, onFrame: { itemFrames["pet"] = $0 }, toggle: togglePet)
            }
            ForEach(state.enabledAccounts) { id in
                let windows = state.snapshots[id]?.windows ?? []
                Button {
                    toggleCard(id)
                } label: {
                    RingView(account: id,
                             percent: windows.first?.percentUsed,
                             secondary: windows.dropFirst().first?.percentUsed,
                             // only a per-model cap (Claude's, Antigravity's): Grok's products and Antigravity's other pool stay on the card
                             tertiary: windows.first { $0.id.hasPrefix("weekly_model") }?.percentUsed,
                             size: expanded ? 52 : 28,
                             showPercent: expanded,
                             nearLimit: windows.contains(where: \.isNearLimit))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { itemFrames[id.rawValue] = $0 }
                .accessibilityLabel("\(id.displayName) usage")
                .accessibilityValue(windows.filter(\.isNearLimit).map { w in
                    let p = w.percentUsed ?? 0
                    return state.showsRemaining ? "\(w.label) has \(100 - Int(p))% left, near its limit"
                        : "\(w.label) at \(Int(p))%, near its limit"
                }.joined(separator: "; "))
            }
            // last: the bottom of a vertical rail, the right end of a horizontal one
            if state.persisted.battery.showInRail, let reading = battery.reading {
                BatteryRing(reading: reading, level: state.persisted.battery.level(reading.percent),
                            size: expanded ? 52 : 28, showPercent: expanded)
            }
        }
        .focusEffectDisabled()   // the panel can be key now (pet composer); no focus ring on the rail
        .padding(state.dock.isVertical ? .vertical : .horizontal, expanded ? 16 : 10)
        .padding(state.dock.isVertical ? .horizontal : .vertical, expanded ? 12 : 8)
        .glassCard(in: RoundedRectangle(cornerRadius: expanded ? 26 : 18))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { railFrame = $0; onRailFrame?($0) }
        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { onDrag?($0.location) }
            .onEnded { onDrop?($0.location) })
        .help("Drag to any screen edge")
    }

    private struct PetRailItem: View {
        @ObservedObject private var session = CodexPetSession.shared
        let expanded: Bool
        let onFrame: (CGRect) -> Void
        let toggle: (Bool) -> Void

        var body: some View {
            VStack(spacing: 6) {
                Button { toggle(NSApp.currentEvent?.modifierFlags.contains(.command) == true) } label: {
                    CodexPet(size: expanded ? 52 : 28, animateIdle: expanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
                .accessibilityLabel("Codex pet — chat and voice")
                .accessibilityValue(session.voiceState == .off ? "Voice off" : session.voiceState == .connecting ? "Connecting"
                                    : session.microphonePaused ? "Voice on, microphone paused" : "Recording")
                .accessibilityAction(named: "Start or end voice session") { toggle(true) }
                .help("Click to chat. Command-click to start or end voice.")
                if expanded {
                    Button { toggle(true) } label: {
                        Image(systemName: session.voiceState == .off ? "waveform.circle" : "waveform.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.voiceTint ?? Color.primary)
                            .symbolEffect(.variableColor.iterative, isActive: session.voiceState == .connecting)
                            .frame(width: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.voiceState == .off ? "Start live voice" : "End live voice")
                    .help(session.voiceState == .off ? "Start live voice" : "End live voice")
                }
            }
        }
    }

    private func togglePet(voice: Bool = false) {
        guard !state.dragging else { return }
        if voice {
            CodexPetSession.shared.toggleVoice()
        } else {
            state.cardVisible = false
            state.petVisible.toggle()
        }
    }

    private func toggleCard(_ id: AccountID) {
        guard !state.dragging else { return }
        state.petVisible = false
        if state.cardVisible, state.selected == id {
            state.cardVisible = false
        } else {
            state.selected = id
            state.cardVisible = true
        }
    }

    private func placeholder(_ id: AccountID) -> AccountSnapshot {
        AccountSnapshot(id: id, displayName: id.displayName, planLabel: "",
                        health: .needsAuth, windows: [], fetchedAt: .now, source: .cliStatus)
    }
}

struct MenuBarPopover: View {
    @ObservedObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(state.enabledAccounts) { id in
                if let snap = state.snapshots[id] {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            BrandIcon(account: id, size: 13)
                            Text("\(snap.displayName) Usage").font(.headline)
                        }
                        .foregroundStyle(.primary)
                        ForEach(Array(snap.windows.enumerated()), id: \.element.id) { i, w in
                            WindowRow(window: w, tint: i == 0 ? id.accent : id.accent.opacity(0.5))
                        }
                        if let msg = snap.healthMessage {
                            Text(msg).font(.caption).foregroundStyle(.primary.opacity(0.6))
                        }
                        if id == .grok, snap.health == .needsAuth {
                            Button("Connect Grok…") {
                                WebLogin.presentGrok { Task { await AppState.shared?.refreshAll() } }
                            }
                        }
                    }
                }
            }
            if state.enabledAccounts.isEmpty {
                Text("All accounts disabled").foregroundStyle(.secondary)
            }
            Divider()
            if state.persisted.breaks.enabled {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    if let text = BreakController.shared.nextText(context.date) {
                        Label(text, systemImage: "cup.and.saucer").foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)   // wraps rather than cutting off "a break is waiting for …"
                    }
                }
            }
            Toggle("Show usage rings on desktop", isOn: $state.persisted.showOverlay).toggleStyle(.checkbox)
            HStack {
                Button {
                    Task { await state.refreshAll() }
                } label: {
                    if state.refreshing { ProgressView().controlSize(.small) }
                    else { Text("Refresh") }
                }
                Spacer()
                Button("Settings…") {
                    // accessory app: without activation the settings window opens behind everything
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    DispatchQueue.main.async {
                        NSApp.windows.first { $0.title.contains("Settings") || $0.title.contains("Pulse") }?
                            .orderFrontRegardless()
                    }
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.showsRemaining, state.showsRemaining)
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    // owned by macOS, not state.json, so a change in System Settings → Login Items shows here too
    @State private var loginItem = SMAppService.mainApp.status

    /// One tab per group. Only the layout is grouped: every value is saved where it always was.
    var body: some View {
        TabView {
            tab("General", "gearshape", height: 210) {
                Section {
                    Toggle("Launch at login", isOn: Binding(
                        get: { loginItem == .enabled },
                        set: { on in
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            loginItem = SMAppService.mainApp.status
                        }))
                        .accessibilityLabel("Launch at login")
                    if loginItem == .requiresApproval {
                        Button("Allow Pulse in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Toggle("Tint the glass", isOn: state.glassTintBinding)
                        .accessibilityLabel("Tint the glass")
                        .help("Adds a black tint to the dark glass. Off leaves the dark system glass untinted.")
                }
            }
            tab("Accounts", "person.crop.circle", height: 360) {
                Section {
                    ForEach(AccountID.allCases) { id in
                        LabeledContent {
                            if id == .claude {
                                if state.snapshots[id]?.source == .officialProtocol, state.snapshots[id]?.health == .ok {
                                    Text("via Claude Code").font(.caption).foregroundStyle(.secondary)
                                        .help("Reads Claude Code's own sign-in from the Keychain; no separate login needed")
                                } else if state.snapshots[id]?.source == .officialUsagePage, state.snapshots[id]?.health == .ok {
                                    Button("Disconnect") {
                                        Task { await ClaudeWeb.shared.clearSession(); await state.refreshAll() }
                                    }
                                } else {
                                    Button("Connect…") {
                                        WebLogin.presentClaude { Task { await state.refreshAll() } }
                                    }
                                    .help("Sign in to claude.ai once so Pulse stops needing the Claude Code Keychain item")
                                }
                            }
                            if id == .grok {
                                if state.snapshots[id]?.health == .needsAuth || state.snapshots[id] == nil {
                                    Button("Reconnect…") {
                                        WebLogin.presentGrok { Task { await state.refreshAll() } }
                                    }
                                } else if state.snapshots[id]?.health != .ok {
                                    Button("Retry") { Task { await state.refreshAll() } }
                                } else if state.snapshots[id]?.source == .officialUsagePage {
                                    Button("Disconnect") {
                                        Task { await WebLogin.disconnectGrok(); await state.refreshAll() }
                                    }
                                } else {
                                    Text("via Grok CLI").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if id == .codex {
                                Text("via Codex CLI").font(.caption).foregroundStyle(.secondary)
                                    .help("Codex signs in through its own CLI (codex login)")
                            }
                            if id == .antigravity {
                                Text("via Antigravity CLI").font(.caption).foregroundStyle(.secondary)
                                    .help("Reads agy's own /usage report; sign in by running agy once")
                            }
                            Toggle("Enable \(id.displayName)", isOn: state.isEnabled(id)).labelsHidden().toggleStyle(.switch)
                                .accessibilityLabel("Enable \(id.displayName)")
                        } label: {
                            Text(id.displayName)
                            if let snap = state.snapshots[id] {
                                Text(snap.healthMessage ?? "\(snap.planLabel) · updated \(snap.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            }
                        }
                    }
                }
                Section {
                    Text("Subscription accounts only. API keys are not supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            tab("Rings", "circle.circle", height: 240) {
                Section {
                    Toggle("Show usage rings on desktop", isOn: $state.persisted.showOverlay)
                        .accessibilityLabel("Show usage rings on desktop")
                    Toggle("Always on top", isOn: $state.persisted.alwaysOnTop)
                        .accessibilityLabel("Always on top")
                    Text("Drag the usage rings to any screen edge. Top and bottom arrange horizontally.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show what's left", isOn: state.showsRemainingBinding)
                        .accessibilityLabel("Show what's left")
                        .help("Rings, bars and percentages show what's left of each limit instead of what's used, emptying as you use it.")
                }
            }
            tab("Battery", "battery.75percent", height: 540) {
                Section { BatterySettingsSection(settings: $state.persisted.battery) }
            }
            tab("Codex pet", "pawprint", height: 290) {
                Section {
                    Toggle("Show the Codex pet", isOn: state.showPetBinding)
                        .accessibilityLabel("Show the Codex pet")
                        .help("Chat and live voice with Codex, separate from the Codex usage ring. Off hides the pet, ends a call, frees the shortcut and starts nothing new; work already running finishes, then Codex stops.")
                    LabeledContent("Shortcut") { HotKeyRecorder(combo: state.voiceHotKeyBinding) }.disabled(!state.showsPet)
                    Text("Tap to start hands-free voice; tap again to pause or resume the microphone. Hold to talk; letting go pauses the microphone while replies keep playing. Double-tap to end the call; Escape also ends it and closes the card.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset remembered approvals") { PetApprovals.shared.resetRemembered() }
                        .help("Ask again for future command and folder-access requests. Current task grants expire when that task ends.")
                }
            }
            tab("Breaks", "cup.and.saucer", height: 720) {
                BreakSettingsSection(settings: $state.persisted.breaks)
            }
        }
        .onAppear { loginItem = SMAppService.mainApp.status }
    }

    private func tab<Content: View>(_ title: String, _ symbol: String, height: CGFloat,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(width: 460, height: height)
            .tabItem { Label(title, systemImage: symbol) }
    }
}

/// Settings → Battery. A binding, not AppState, so it can be rendered on its own.
struct BatterySettingsSection: View {
    @Binding var settings: BatterySettings
    @ObservedObject private var battery = BatteryMonitor.shared
    @State private var sounds: [String] = []
    @State private var importNote = ""
    @State private var pushoverReady = false
    @State private var pushNote = ""

    var body: some View {
        if battery.reading == nil {
            Text("This Mac has no battery.").foregroundStyle(.secondary)
        } else {
            rows
        }
    }

    @ViewBuilder private var rows: some View {
        let b = settings
        Toggle("Show the battery in the rail", isOn: $settings.showInRail)
            .accessibilityLabel("Show the battery in the rail")
            .onAppear {
                sounds = BatterySounds.all().map(\.name)
                pushoverReady = Pushover.configured
            }
        Toggle("Alert when the battery is low", isOn: $settings.alerts)
            .accessibilityLabel("Alert when the battery is low")
        LabeledContent("Yellow and low alert at") {
            Stepper("\(b.lowPercent)%", value: $settings.lowPercent, in: (b.criticalPercent + 5)...90, step: 5)
                .accessibilityLabel("Yellow and low battery alert threshold")
                .accessibilityValue("\(b.lowPercent) percent")
        }
        LabeledContent("Red and critical alert at") {
            Stepper("\(b.criticalPercent)%", value: $settings.criticalPercent, in: 5...(b.lowPercent - 5), step: 5)
                .accessibilityLabel("Red and critical battery alert threshold")
                .accessibilityValue("\(b.criticalPercent) percent")
        }
        soundRow("Low sound", sound: $settings.lowSound, loops: $settings.lowLoops)
        soundRow("Critical sound", sound: $settings.criticalSound, loops: $settings.criticalLoops)
        LabeledContent {
            Button("Import Sounds…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { return }
                let rejected = BatterySounds.importFiles(panel.urls)
                sounds = BatterySounds.all().map(\.name)
                importNote = rejected.isEmpty ? "" : "Couldn't import \(rejected.joined(separator: ", "))"
            }
        } label: {
            Text("Your own sounds")
            Text(importNote.isEmpty ? "Any audio file macOS plays. Copied into Pulse's folder." : importNote)
        }
        Toggle(isOn: Binding(get: { pushoverReady && b.pushover }, set: { settings.pushover = $0 })) {
            Text("Push to your phone when critical")
            Text(pushoverReady ? "Through Pushover, with the keys in ~/.config/pushover.env"
                 : "Needs Pushover's PUSHOVER_USER and PUSHOVER_TOKEN in ~/.config/pushover.env")
        }
        .accessibilityLabel("Push to your phone when critical")
        .disabled(!pushoverReady)
        if pushoverReady {
            LabeledContent(pushNote) {
                Button("Send Test Push") {
                    pushNote = "Sending…"
                    Task { pushNote = await BatteryAlerts.push(title: "Pulse test", message: "Battery alerts will reach you here.") ?? "Sent" }
                }
            }
        }
        Text("An alert stays on screen with its sound until you click Dismiss or plug in. It never goes to Notification Center.")
            .font(.caption).foregroundStyle(.secondary)
        if battery.reading?.simulated == true {
            Text("Simulated battery. `defaults delete app.pulse simulatedBattery` returns to the real one.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func soundRow(_ title: String, sound: Binding<String?>, loops: Binding<Bool>) -> some View {
        LabeledContent(title) {
            SoundChoice(title: title, sound: sound, sounds: sounds)
            Toggle("Loop", isOn: loops).toggleStyle(.checkbox).disabled(sound.wrappedValue == nil)
                .accessibilityLabel("Loop \(title.lowercased())")
        }
    }
}

/// A sound picker with None and a play button, for Battery's alerts and the breaks.
struct SoundChoice: View {
    let title: String
    @Binding var sound: String?
    let sounds: [String]

    var body: some View {
        Picker(title, selection: $sound) {
            Text("None").tag(String?.none)
            ForEach(sounds, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .labelsHidden()
        .fixedSize()
        Button { BatterySounds.togglePreview(sound) } label: { Image(systemName: "play.fill") }
            .buttonStyle(.borderless)
            .disabled(sound == nil)
            .help("Play this sound once; click again to stop")
            .accessibilityLabel("Play \(title.lowercased())")
    }
}
