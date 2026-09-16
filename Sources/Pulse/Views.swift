import SwiftUI

private let cardBackground = Color.black

/// Liquid Glass on macOS 26+, a flat card on older systems. Follows the view's colorScheme.
private struct GlassCard<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: S
    func body(content: Content) -> some View {
        if scheme == .dark {
            // glass frosts everything gray; the reference look is opaque piano black with a soft top sheen
            // shadow lives on the shape and stays inside the overlay's 12pt padding, or the window clips it flat
            content.background(shape.fill(LinearGradient(colors: [Color(white: 0.07), Color.black],
                                                         startPoint: .top, endPoint: .bottom))
                                    .shadow(color: .black.opacity(0.45), radius: 7, y: 3))
                .overlay(rim)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.white.opacity(0.35)), in: shape)
                .overlay(rim)
        } else {
            content.background(scheme == .dark ? cardBackground : Color(white: 0.95), in: shape)
                .overlay(rim)
        }
    }

    /// Thin light-catching edge: bright at the top, fading out toward the bottom, like a polished bezel.
    private var rim: some View {
        shape.stroke(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.45 : 0.9), .white.opacity(0.04)],
                                    startPoint: .top, endPoint: .bottom),
                     lineWidth: 1)
    }
}

extension View {
    func glassCard<S: Shape>(in shape: S) -> some View { modifier(GlassCard(shape: shape)) }
}

/// Text inks. On the black surfaces the system "label" white (85%) reads dull; use pure white.
/// Light mode keeps the system label colours.
enum Ink {
    static func primary(_ s: ColorScheme) -> Color { s == .dark ? .white : .primary }
    static func secondary(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.6) : .secondary }
}

private let brandIcons: [AccountID: NSImage] = {
    var d: [AccountID: NSImage] = [:]
    for id in AccountID.allCases {
        if let url = Bundle.pulseResources.url(forResource: "Resources/\(id.rawValue)", withExtension: "svg"),
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

private struct CodexPet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var session = CodexPetSession.shared
    let size: CGFloat
    private static let frames: [CodexPetSprite.State: [CGImage]] = Bundle.pulseResources
        .url(forResource: "Resources/codex-pet", withExtension: "webp")
        .map(CodexPetSprite.frames(from:)) ?? [:]

    /// The pet mirrors the session: waving while a voice call is live, waiting while Codex thinks.
    private var state: CodexPetSprite.State {
        if session.voiceState == .speaking { return .running }
        if session.voiceState != .off { return .waving }
        return session.thinking ? .waiting : .idle
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            if let frames = Self.frames[state], frames.count == CodexPetSprite.track(state).durations.count {
                let index = reduceMotion ? 0 : CodexPetSprite.frame(state, at: context.date.timeIntervalSinceReferenceDate)
                Image(decorative: frames[index], scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                BrandIcon(account: .codex, size: size)
            }
        }
        .frame(width: size, height: size * 208 / 192)
    }
}

struct RingView: View {
    @Environment(\.colorScheme) private var scheme
    let account: AccountID
    let percent: Double?
    var secondary: Double? = nil
    var tertiary: Double? = nil    // third window (Claude: the per-model weekly cap), innermost arc
    var size: CGFloat = 52
    var showPercent = true

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.black)
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .padding(-size * 0.08)
                Circle().stroke(Color(white: 0.19), lineWidth: size * 0.12)   // #303030: a defined grey on black
                if let percent {
                    arc(percent, lineWidth: size * 0.12)
                }
                if let secondary {
                    // inner arc, lighter shade: the second window (e.g. weekly)
                    arc(secondary, lineWidth: size * 0.07, dimmed: true)
                        .padding(size * 0.16)
                }
                if let tertiary {
                    arc(tertiary, lineWidth: size * 0.06, dimmed: true)
                        .padding(size * 0.27)
                }
                BrandIcon(account: account, size: size * (tertiary == nil ? 0.4 : 0.32))
                    .colorScheme(.dark) // Ring wells stay dark in both appearances.
            }
            .frame(width: size, height: size)
            if showPercent {
                Text(percent.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Ink.primary(scheme))
            }
        }
    }

    private func arc(_ pct: Double, lineWidth: CGFloat, dimmed: Bool = false) -> some View {
        let frac = max(0, min(pct, 100)) / 100
        let base = dimmed ? account.accent.opacity(0.6) : account.accent
        return Circle()
            .trim(from: 0, to: frac)
            .stroke(base, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

struct WindowRow: View {
    @Environment(\.colorScheme) private var scheme
    let window: UsageWindow
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.label)
                .font(.subheadline)
                .foregroundStyle(Ink.primary(scheme))
            if let p = window.percentUsed {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(scheme == .dark ? Color(white: 0.18) : Color.primary.opacity(0.25))
                        Capsule().fill(tint)
                            .frame(width: max(6, geo.size.width * min(p, 100) / 100))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(Int(p))% Used").font(.caption)
                    Spacer()
                    Text(resetLabel(window.resetsAt)).font(.caption)
                }
                .foregroundStyle(Ink.secondary(scheme))
            }
        }
    }
}

/// Rounded card plus a tail (pointing at the rail) as one shape, so the glass renders as a single piece.
private struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 13
    var edge: Edge = .trailing
    func path(in rect: CGRect) -> Path {
        let t = Self.tailWidth
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
            p.move(to: CGPoint(x: body.maxX, y: rect.midY - 12))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: body.maxX, y: rect.midY + 12))
        case .leading:
            p.move(to: CGPoint(x: body.minX, y: rect.midY - 12))
            p.addLine(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: body.minX, y: rect.midY + 12))
        case .top:
            p.move(to: CGPoint(x: rect.midX - 12, y: body.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: 0))
            p.addLine(to: CGPoint(x: rect.midX + 12, y: body.minY))
        case .bottom:
            p.move(to: CGPoint(x: rect.midX - 12, y: body.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX + 12, y: body.maxY))
        }
        p.closeSubpath()
        return Path(roundedRect: body, cornerRadius: 18).union(p)
    }
}

struct UsageCard: View {
    @Environment(\.colorScheme) private var scheme
    let snapshot: AccountSnapshot
    var tailEdge: Edge = .trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandIcon(account: snapshot.id, size: 17)
                Text("\(snapshot.displayName) Usage").font(.headline)
                Spacer()
                Text(snapshot.planLabel).font(.caption).foregroundStyle(Ink.secondary(scheme))
            }
            .foregroundStyle(Ink.primary(scheme))
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
        .glassCard(in: BubbleShape(edge: tailEdge))
    }
}

/// The pet's popout: Codex quick chat, live voice, and what the agent is doing, on the same bubble
/// as the usage cards. Everything here is the Codex app-server's own session (see CodexChat.swift).
struct PetCard: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var session = CodexPetSession.shared
    @State private var draft = ""
    @FocusState private var composing: Bool
    var tailEdge: Edge = .trailing
    var showUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandIcon(account: .codex, size: 17)
                Text("Codex").font(.headline)
                Spacer()
                Button("Usage", action: showUsage).buttonStyle(.plain).font(.caption)
                    .foregroundStyle(Ink.secondary(scheme))
                Button { session.clear() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("New conversation")
            }
            .foregroundStyle(Ink.primary(scheme))

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
                .foregroundStyle(Ink.primary(scheme))
            }

            transcript

            if let status = session.status {
                Text(status).font(.caption).foregroundStyle(.red.opacity(0.85)).lineLimit(2)
            }

            HStack(spacing: 8) {
                TextField("Ask Codex…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($composing)
                    .onSubmit { submit() }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(scheme == .dark ? Color(white: 0.14) : Color(white: 0.92)))
                if session.thinking {
                    Button { session.interrupt() } label: { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.plain).help("Stop")
                } else {
                    Button { submit() } label: { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                voiceButton
            }
            .font(.title3)
            .foregroundStyle(Ink.primary(scheme))
        }
        .padding(16)
        .padding(Edge.Set(tailEdge), BubbleShape.tailWidth)
        .frame(width: tailEdge == .trailing || tailEdge == .leading ? 340 + BubbleShape.tailWidth : 340)
        .glassCard(in: BubbleShape(edge: tailEdge))
        .task { try? await Task.sleep(for: .milliseconds(200)); composing = true }   // after the panel is key
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
                    if session.messages.isEmpty {
                        Text(session.voiceState == .off ? "Type, or tap the waveform to talk. Same Codex sign-in, same threads."
                                                         : "Listening…")
                            .font(.caption).foregroundStyle(Ink.secondary(scheme))
                    }
                    ForEach(session.messages) { m in
                        HStack {
                            if m.role == .user { Spacer(minLength: 40) }
                            Text(m.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .fill(m.role == .user ? AccountID.codex.accent.opacity(0.35)
                                                          : (scheme == .dark ? Color(white: 0.16) : Color(white: 0.9))))
                            if m.role != .user { Spacer(minLength: 40) }
                        }
                        .id(m.id)
                    }
                    if session.thinking, !(session.messages.last?.live ?? false) {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").font(.caption) }
                            .foregroundStyle(Ink.secondary(scheme)).id("thinking")
                    }
                }
                .foregroundStyle(Ink.primary(scheme))
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)   // grows with the transcript, scrolls past 260pt
            .onChange(of: session.messages.last?.text) { _, _ in
                if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var voiceButton: some View {
        HStack(spacing: 6) {
            if session.voiceState != .off {
                Button { session.muted.toggle() } label: {
                    Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                }
                .buttonStyle(.plain).help(session.muted ? "Unmute" : "Mute")
            }
            Button { session.toggleVoice() } label: {
                Image(systemName: session.voiceState == .off ? "waveform.circle" : "waveform.circle.fill")
                    .foregroundStyle(session.voiceState == .off ? Ink.primary(scheme)
                                     : session.voiceState == .connecting ? Color.yellow : AccountID.codex.accent)
                    .symbolEffect(.variableColor.iterative, isActive: session.voiceState == .speaking)
            }
            .buttonStyle(.plain)
            .help(session.voiceState == .off ? "Start live voice" : "End live voice")
        }
    }

    private func submit() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty, !session.thinking else { return }
        session.send(draft)
        draft = ""
    }
}

struct OverlayView: View {
    @ObservedObject var state: AppState
    var onSize: ((CGSize) -> Void)? = nil
    var onDrag: ((CGPoint) -> Void)? = nil
    var onDrop: ((CGPoint) -> Void)? = nil
    var onRailFrame: ((CGRect) -> Void)? = nil
    var onCardFrame: ((CGRect) -> Void)? = nil

    private var expanded: Bool { state.hoveringOverlay || state.cardVisible || state.petVisible }

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
        .padding(12)
        .animation(expanded ? .easeOut(duration: 0.12) : nil, value: expanded)
        .animation(state.cardVisible ? .easeOut(duration: 0.12) : nil, value: state.cardVisible)
        .animation(state.petVisible ? .easeOut(duration: 0.12) : nil, value: state.petVisible)
        .onHover { over in
            guard !state.dragging else { return }
            if over { state.hoveringOverlay = true }
            else if !state.petVisible { state.collapseOverlay() }   // a chat stays open until a click outside
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize?($0) }
        .colorScheme(state.isLight ? .light : .dark)
    }

    @ViewBuilder
    private func card(tail: Edge) -> some View {
        if state.petVisible {
            PetCard(tailEdge: tail, showUsage: { toggleCard(.codex) })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCardFrame?($0) }
                .transition(.opacity.combined(with: .move(edge: tail)))
        } else if state.cardVisible, state.persisted.enabled.contains(state.selected) {
            UsageCard(snapshot: state.snapshots[state.selected] ?? placeholder(state.selected),
                      tailEdge: tail)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCardFrame?($0) }
                .transition(.opacity.combined(with: .move(edge: tail)))
        }
    }

    private var rail: some View {
        let layout = state.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: expanded ? 18 : 10))
            : AnyLayout(HStackLayout(spacing: expanded ? 18 : 10))
        return layout {
            if state.persisted.enabled.contains(.codex) {
                Button { togglePet() } label: {
                    CodexPet(size: expanded ? 52 : 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Codex pet — chat and voice")
            }
            ForEach(state.enabledAccounts) { id in
                let windows = state.snapshots[id]?.windows ?? []
                Button {
                    toggleCard(id)
                } label: {
                    RingView(account: id,
                             percent: windows.first?.percentUsed,
                             secondary: windows.dropFirst().first?.percentUsed,
                             tertiary: windows.dropFirst(2).first?.percentUsed,
                             size: expanded ? 52 : 28,
                             showPercent: expanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(id.displayName) usage")
            }
        }
        .focusEffectDisabled()   // the panel can be key now (pet composer); no focus ring on the rail
        .padding(state.dock.isVertical ? .vertical : .horizontal, expanded ? 16 : 10)
        .padding(state.dock.isVertical ? .horizontal : .vertical, expanded ? 12 : 8)
        .glassCard(in: RoundedRectangle(cornerRadius: expanded ? 26 : 18))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onRailFrame?($0) }
        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { onDrag?($0.location) }
            .onEnded { onDrop?($0.location) })
        .help("Drag to any screen edge")
    }

    private func togglePet() {
        guard !state.dragging else { return }
        state.cardVisible = false
        state.petVisible.toggle()
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
        .background(state.isLight ? Color(white: 0.95) : cardBackground)
        .colorScheme(state.isLight ? .light : .dark)   // drives .primary text and system controls
    }
}

/// Sun/moon segmented pill: amber sun for light, indigo moon for dark.
struct AppearanceToggle: View {
    @Binding var light: Bool

    var body: some View {
        HStack(spacing: 2) {
            segment("sun.max.fill", on: light, tint: .orange) { light = true }
            segment("moon.fill", on: !light, tint: .indigo) { light = false }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .animation(.spring(duration: 0.2), value: light)
    }

    private func segment(_ name: String, on: Bool, tint: Color, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : .secondary)
                .frame(width: 32, height: 22)
                .background(Capsule().fill(on ? tint : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name == "sun.max.fill" ? "Light appearance" : "Dark appearance")
        .accessibilityValue(on ? "Selected" : "Not selected")
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Accounts") {
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
                        Toggle("Enable \(id.displayName)", isOn: state.isEnabled(id)).labelsHidden()
                    } label: {
                        Text(id.displayName)
                        if let snap = state.snapshots[id] {
                            Text(snap.healthMessage ?? "\(snap.planLabel) · updated \(snap.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                }
            }
            Section("Overlay") {
                Toggle("Show floating card", isOn: $state.persisted.showOverlay)
                Toggle("Always on top", isOn: $state.persisted.alwaysOnTop)
                Text("Drag the usage rings to any screen edge. Top and bottom arrange horizontally.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Appearance") {
                    AppearanceToggle(light: state.lightModeBinding)
                }
            }
            Section("Codex voice") {
                LabeledContent("Shortcut") { HotKeyRecorder(combo: state.voiceHotKeyBinding) }
                Text("Press once to open the pet and start talking; press again to end the call. Hold it to talk only while it is down. Escape ends the call and closes the card.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Subscription accounts only. API keys are not supported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 500)
        .preferredColorScheme(state.isLight ? .light : .dark)
    }
}
