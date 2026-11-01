import SwiftUI
import Combine
import os

/// One line per drop and per landing: how a hand test went, read with
/// `/usr/bin/log show --last 5m --predicate 'subsystem == "io.github.tommyent.pulse" AND category == "rail"'`.
private let railLog = Logger(subsystem: "io.github.tommyent.pulse", category: "rail")
private func describe(_ f: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", f.minX, f.minY, f.width, f.height) }

extension Bundle {
    /// Packaged app keeps Pulse_Pulse.bundle in Contents/Resources, where SPM's
    /// generated Bundle.module accessor never looks; .module still covers dev builds.
    static let pulseResources: Bundle =
        Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Pulse_Pulse.bundle")) } ?? .module
}

@main
struct PulseApp: App {
    @StateObject private var state: AppState
    private let overlay: OverlayController
    private let batteryAlerts: BatteryAlerts

    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.pulseResources.url(forResource: "Resources/pulse", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()

    init() {
        // Set the application so AppKit panels and SwiftUI presentations share one appearance.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        // A write to a Codex child that just exited raises SIGPIPE, which would kill Pulse silently.
        // Ignored, the write throws EPIPE instead and the existing error paths report it.
        signal(SIGPIPE, SIG_IGN)
        // single instance: a new launch replaces any running one
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "io.github.tommyent.pulse")
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.forceTerminate()
        }
        let state = AppState()
        _state = StateObject(wrappedValue: state)   // the pet's folder waits for its first use: no Documents prompt at launch
        overlay = OverlayController(state: state)
        batteryAlerts = BatteryAlerts(state: state)
        BreakController.shared.attach(state)
        _ = Updates.shared.controller   // starts Sparkle's scheduled checks
        NSApplication.shared.setActivationPolicy(.accessory)   // no Dock icon
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(state: state)
                .containerBackground(.clear, for: .window)
                .pulsePresentation(state)
        } label: {
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "waveform.path.ecg")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: state)
                .containerBackground(for: .window) {
                    PulseSurface(shape: Rectangle())
                        .environment(\.pulseAppearance, state.persisted.appearance)
                        .environment(\.appearsActive, true)
                        .preferredColorScheme(.dark)
                }
                .pulsePresentation(state)
        }
    }
}

/// Borderless panels refuse key status by default; the pet's composer needs it (without activating Pulse).
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// AppKit keeps a window's top below the menu bar. A glide's box and a rail tucked into the top must pass it: what
    /// lies past the usable screen is masked instead (the owner's logs showed the panel held 274 pt short mid-glide).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The panel is rarely key, and a first click on a non-key window only makes it key: the rail's drag would need a
/// second click. Accepting the first mouse lets that first click reach the overlay too.
final class OverlayHostingView: NSHostingView<AnyView> {
    convenience init<Content: View>(rootView: Content) {
        self.init(rootView: AnyView(rootView))
    }

    required init(rootView: AnyView) {
        // Set the hosting presentation, so default text and AppKit-backed semantic colors agree.
        super.init(rootView: AnyView(rootView.preferredColorScheme(.dark)))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rootView = AnyView(rootView.preferredColorScheme(.dark))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// CADisplayLink calls an Objective-C selector; this hands each frame to a closure.
private final class FrameTicker: NSObject {
    var onFrame: (CADisplayLink) -> Void = { _ in }
    @objc func frame(_ link: CADisplayLink) { onFrame(link) }
}

@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let state: AppState
    private var cancellables: Set<AnyCancellable> = []
    private var pinned: CGPoint?
    private var dockScreen: NSScreen?
    private var contentSize = CGSize(width: 68, height: 148)
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var throwing = ThrowTracker()
    /// While a drop glides, SwiftUI moves the rings into the new layout and the panel is a box that fits both layouts,
    /// the content centred in it.
    private var flight: (glide: RailGlide, box: CGSize, time: CFTimeInterval?)?
    private var flightLink: CADisplayLink?
    private var peekWatch: Timer?
    private let ticker = FrameTicker()
    private var railFrame = CGRect.zero
    private var cardFrame = CGRect.zero
    private var hintFrame = CGRect.zero   // the next-break hint on hover; .zero while it's hidden
    private var pillFrame = CGRect.zero   // a break's countdown; stale once it ends, so read only during one
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var voiceKey: HotKey?
    private var voiceGesture = VoiceShortcutGesture()

    /// A held shortcut mutes only capture on release, so Codex can still answer aloud.
    private func bindVoiceKey(_ combo: HotKeyCombo?) {
        cancelVoiceKey()
        voiceKey = nil   // unregister before registering its replacement
        // Hidden, the pet's call ends, the shortcut is free for other apps and running work finishes without new work.
        CodexPetSession.shared.hidden = combo == nil
        guard let combo else {
            state.petVisible = false
            return
        }
        voiceKey = HotKey(combo)
        if voiceKey == nil {
            // Enter outside GCD's serial main queue so a modal cannot delay microphone mute.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.voiceKey == nil, self.state.voiceHotKey == combo, self.state.showsPet else { return }
                    let alert = NSAlert()
                    alert.messageText = "Voice shortcut unavailable"
                    alert.informativeText = "Pulse couldn't register \(combo.label). Choose another shortcut in Settings → Codex pet. You can still use the waveform button to start or end a call."
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
        voiceKey?.onPress = { [weak self] in
            guard let self else { return }
            let session = CodexPetSession.shared
            let action = voiceGesture.keyDown(at: ProcessInfo.processInfo.systemUptime,
                                               voiceActive: session.voiceState != .off, muted: session.muted)
            applyVoiceKey(action)
        }
        voiceKey?.onRelease = { [weak self] in
            guard let self else { return }
            applyVoiceKey(voiceGesture.keyUp(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func applyVoiceKey(_ action: VoiceShortcutGesture.Action?) {
        let session = CodexPetSession.shared
        switch action {
        case .start, .unmute:
            session.muted = false
            if action == .start {
                state.cardVisible = false
                state.petVisible = true
                session.startVoice()
            }
        case .mute: session.muted = true
        case .end: session.stopVoice()
        case nil: break
        }
    }

    private func cancelVoiceKey() {
        // If a held call fails and auto-retries, capture stays muted until a new explicit press.
        if voiceGesture.cancel() { CodexPetSession.shared.muted = true }
    }

    private func mouseDown(_ event: NSEvent) {
        guard NSApp.modalWindow == nil else { return }   // a click in an approval alert is not a click away from the pet
        let point = CGPoint(x: event.locationInWindow.x, y: panel.frame.height - event.locationInWindow.y)
        if event.window === panel {
            if state.tuckedAway { return }   // the sliver and the band beside it are the handle: inside
            // a click on a peeking rail brings it out for good; one in a card it opened (the pet's) doesn't
            if state.peeking, railFrame.contains(point) { state.tuckedBinding.wrappedValue = false }
        }
        // a click on the countdown must not collapse the rail: the pill would move off the pointer before mouse-up
        if event.window !== panel || overlayClickIsOutside(point, in: CGRect(origin: .zero, size: panel.frame.size),
                                                          rail: railFrame, card: state.cardVisible || state.petVisible ? cardFrame : hintFrame)
            && !(BreakController.shared.phase.isCountdown && pillFrame.contains(point)) {
            state.collapseOverlay()
        }
    }

    /// Content grows away from the selected edge; never move it under an active drag.
    private func contentSized(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        contentSize = size
        guard let frame = restingFrame() else { return }
        if var f = flight {   // the glide lands on it; the box keeps room for the old layout too
            f.glide.target = frame
            f.glide.slack = state.tuckedAway ? 0 : 16   // a tuck stops at its spot: further in, the sliver would vanish
            f.box = CGSize(width: max(f.box.width, frame.width + 32), height: max(f.box.height, frame.height + 32))
            flight = f
            return
        }
        guard panel.frame != frame else { return }
        place(frame, display: false)
    }

    /// Where the panel rests for the current content: docked at its edge, or tucked past it. nil while dragging.
    private func restingFrame() -> CGRect? {
        let screenID = dockScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let liveScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID
        }
        guard !state.dragging, let screen = liveScreen ?? panel.screen ?? NSScreen.main else { return nil }
        dockScreen = screen
        let bounds = screen.visibleFrame
        let frame = state.dock.frame(size: contentSize,
                                     anchor: pinned ?? CGPoint(x: bounds.midX, y: bounds.midY),
                                     in: bounds)
        pinned = state.dock.anchor(of: frame)
        return state.tuckedAway ? state.dock.tucked(frame, in: bounds) : frame
    }

    /// Moves the panel. Whatever lies past the screen's usable area (a tucked rail, a glide pressing on the edge) is masked
    /// away, so it never shows under the transparent menu bar, through the Dock or on a neighbouring display.
    private func place(_ target: CGRect, display: Bool = true) {
        if panel.frame != target { panel.setFrame(target, display: display) }
        let frame = panel.frame   // what the window really got
        guard let view = panel.contentView, let screen = dockScreen ?? panel.screen else { return }
        // dragged freely it may cross onto another display; at rest, tucked or gliding it belongs to its docking one
        let areas = state.dragging ? NSScreen.screens.map(\.visibleFrame) : [screen.visibleFrame]
        guard let parts = visibleParts(of: frame, in: areas) else { view.layer?.mask = nil; return }
        let mask = view.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
        let path = CGMutablePath()
        // window coordinates to the view's (flipped, as its backing layer is: measured offscreen)
        for part in parts { path.addRect(view.convert(part.offsetBy(dx: -frame.minX, dy: -frame.minY), from: nil)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = view.bounds
        mask.path = path   // empty when the panel is off its display altogether: hidden, not unmasked
        CATransaction.commit()
        view.layer?.mask = mask
    }

    /// Where the pointer counts as on the rail, for hover exits, the peek watch and a landing alike: the panel, plus while
    /// peeking the 4 pt between it and the screen's edge, where the sliver was.
    private var peekArea: CGRect { state.peeking ? visiblePanel.insetBy(dx: -6, dy: -6) : visiblePanel.insetBy(dx: 1, dy: 1) }

    /// While peeking, the pointer is watched rather than hover events trusted: exits are ignored mid-glide, and a pointer
    /// resting where the sliver was may never enter the peeked panel at all.
    private func watchPeek(_ peeking: Bool) {
        peekWatch?.invalidate()
        peekWatch = nil
        guard peeking else { return }
        peekWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.state.gliding, !self.state.dragging, !self.state.petVisible else { return }
                if !self.peekArea.contains(NSEvent.mouseLocation) { self.state.collapseOverlay() }   // ends the peek
            }
        }
    }

    /// The part of the panel on screen, where the pointer can be on it.
    private var visiblePanel: CGRect {
        guard let screen = dockScreen ?? panel.screen else { return panel.frame }
        let visible = panel.frame.intersection(screen.visibleFrame)
        return visible.isNull ? panel.frame : visible
    }

    /// The pointer in screen coordinates; the gesture's own locations move with the panel, which a landing resizes.
    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            if let flight { land(CGRect(x: flight.glide.center.first - contentSize.width / 2, y: flight.glide.center.second - contentSize.height / 2,
                                        width: contentSize.width, height: contentSize.height), caught: true) }   // caught mid-glide
            dragStart = (mouse, panel.frame.origin)
            state.dragging = true
        }
        guard let start = dragStart else { return }
        throwing.add(mouse, at: ProcessInfo.processInfo.systemUptime)
        // a tucked rail pulled out by its sliver comes out with the pointer; it stays tucked in state until the drop
        place(CGRect(origin: CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y),
                     size: panel.frame.size))
    }

    private func drop() {
        guard dragStart != nil else { return }
        let mouse = NSEvent.mouseLocation
        dockScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel.screen ?? NSScreen.main
        throwing.add(mouse, at: ProcessInfo.processInfo.systemUptime)
        let velocity = throwing.velocity(at: ProcessInfo.processInfo.systemUptime)
        var edge = state.dock, tuck = false
        if let screen = dockScreen {
            let landing = DockEdge.landing(from: mouse, velocity: velocity, current: state.dock, in: screen.visibleFrame,
                                           display: screen.frame)
            pinned = landing.point
            edge = landing.edge
            tuck = landing.tuck
        }
        railLog.notice("drop at \(String(format: "%.0f,%.0f", mouse.x, mouse.y), privacy: .public) v \(String(format: "%.0f,%.0f", velocity.dx, velocity.dy), privacy: .public) \(self.state.dock.rawValue, privacy: .public) -> \(edge.rawValue, privacy: .public)\(tuck ? " tucked" : "", privacy: .public)")
        dragStart = nil
        throwing = ThrowTracker()
        // Keep ring clicks suppressed until the mouse-up event has finished dispatching.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.dragging = false
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // a plain, immediate move
            withAnimation(still ? nil : .spring(morphSpring)) {
                self.state.persisted.dock = edge
                self.state.collapseOverlay()
                self.state.tuckedBinding.wrappedValue = tuck
            }
            self.settle(velocity: velocity, spring: tuck ? tuckSpring : railSpring())
        }
    }

    /// Moves the rail to where it rests now: docked, or tucked into its edge. On `spring` (a drop's is the owner's bouncy
    /// one), starting at `velocity`; under Reduce Motion at once (a drop) or with a crossfade (`fade`: tucking, peeking).
    private func settle(velocity: CGVector = .zero, fade: Bool = false, spring: Spring = tuckSpring) {
        guard !state.dragging else { return }   // the drop settles it
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, flight == nil {
            guard let target = restingFrame(), target != panel.frame else { return }   // a drop already moved it
            guard fade else {
                contentSized(contentSize)
                panel.saveFrame(usingName: "PulseOverlay")
                return
            }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.contentSized(self.contentSize)
                    self.panel.saveFrame(usingName: "PulseOverlay")
                    NSAnimationContext.runAnimationGroup { $0.duration = 0.1; self.panel.animator().alphaValue = 1 }
                }
            }
            return
        }
        if flight == nil {
            let start = panel.frame
            // the fastest flicks (9000 pt/s in the owner's logs) only overshoot further: 3200 pt/s already feels immediate
            let cap = min(1, 3200 / max(1, hypot(velocity.dx, velocity.dy)))
            flight = (RailGlide(center: AnimatablePair(start.midX, start.midY), velocity: AnimatablePair(velocity.dx * cap, velocity.dy * cap),
                                target: start, edge: state.dock, spring: spring, slack: state.tuckedAway ? 0 : 16),
                      CGSize(width: start.width + 32, height: start.height + 32), nil)
            // only the glide sizes the panel meanwhile: no window resize from Auto Layout before the box catches up
            (panel.contentView as? OverlayHostingView)?.sizingOptions = []
            flightLink = panel.contentView?.displayLink(target: ticker, selector: #selector(FrameTicker.frame(_:)))
            flightLink?.add(to: .main, forMode: .common)
            state.gliding = true   // hover waits: the box sliding under a still pointer would expand the rail mid-flight
        }
        contentSized(contentSize)   // a first target; a new layout's size moves it when it arrives
    }

    private func glide(_ link: CADisplayLink) {
        guard var f = flight else { return }
        let dt = f.time.map { min(link.timestamp - $0, 1.0 / 30) } ?? 0
        f.time = link.timestamp
        guard !f.glide.step(dt) else { return land(f.glide.target) }
        flight = f
        place(CGRect(x: f.glide.center.first - f.box.width / 2, y: f.glide.center.second - f.box.height / 2,
                     width: f.box.width, height: f.box.height))
    }

    private func land(_ frame: CGRect, caught: Bool = false) {
        railLog.notice("land \(describe(frame), privacy: .public) after \(String(format: "%.2f", self.flight?.glide.elapsed ?? 0), privacy: .public) s from \(describe(self.panel.frame), privacy: .public)")
        state.gliding = false
        flight = nil
        flightLink?.invalidate()
        flightLink = nil
        place(frame)
        (panel.contentView as? OverlayHostingView)?.sizingOptions = .standardBounds
        panel.saveFrame(usingName: "PulseOverlay")
        guard !caught else { return }   // the drag that caught it decides the rest
        switch hoverAfterLanding(pointerInside: peekArea.contains(NSEvent.mouseLocation), tuckedAway: state.tuckedAway,
                                 petVisible: state.petVisible) {
        case .collapse: state.collapseOverlay()   // ends a peek the pointer left mid-glide
        case .hover: state.hoveringOverlay = true
        case .leave: break
        }
    }

    init(state: AppState) {
        self.state = state
        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 68, height: 148),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = OverlayHostingView(rootView: OverlayView(state: state,
            onSize: { [weak self] size in self?.contentSized(size) },
            onDrag: { [weak self] in self?.drag() },
            onDrop: { [weak self] in self?.drop() },
            onRailFrame: { [weak self] in self?.railFrame = $0 },
            onCardFrame: { [weak self] in self?.cardFrame = $0 },
            onHintFrame: { [weak self] in self?.hintFrame = $0 },
            onPillFrame: { [weak self] in self?.pillFrame = $0 },
            // the same area the peek watch and a landing use, so no path ends a peek the others would keep
            pointerInside: { [weak self] in self.map { $0.peekArea.contains(NSEvent.mouseLocation) } ?? false }))
        panel.contentView = hosting
        hosting.wantsLayer = true   // the mask that hides what lies past the screen edge
        ticker.onFrame = { [weak self] link in MainActor.assumeIsolated { self?.glide(link) } }
        if panel.setFrameUsingName("PulseOverlay"), panel.frame.width > 50 {
            pinned = state.dock.anchor(of: panel.frame)
            // the display the rail's own band is on: a tucked panel mostly hangs past its edge, maybe onto another display
            let band = state.dock.railPoint(of: panel.frame)
            dockScreen = NSScreen.screens.first { $0.frame.contains(band) } ?? panel.screen
        }
        panel.setFrameAutosaveName("PulseOverlay")
        // A frame saved while a card or the hover hint widened the panel would otherwise keep the rail off its edge
        // until its size next changed: place it from the content's own size now.
        contentSized(hosting.fittingSize)

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(event) }
            return event // Let the clicked control or window receive its event.
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.collapseOverlay() }
        }

        // while the pet card holds the keyboard Pulse is the active app; switching to another app closes it
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.state.petVisible else { return }
                self.state.collapseOverlay()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.contentSized(self.contentSize)
            }
            .store(in: &cancellables)

        // tucking from the menu, peeking out and back: the rail slides on the same spring
        state.$persisted.map(\.tucked).removeDuplicates()
            .combineLatest(state.$peeking.removeDuplicates())
            .dropFirst()   // both start with their current values; act on changes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settle(fade: true) }
            .store(in: &cancellables)
        state.$peeking.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.watchPeek($0) }
            .store(in: &cancellables)
        // a card on a tucked rail (the voice shortcut opens the pet's) needs the rail out: it peeks until the card closes
        state.$petVisible.combineLatest(state.$cardVisible)
            .receive(on: RunLoop.main)
            .sink { [weak self] pet, card in
                guard let self, pet || card, self.state.tuckedAway else { return }
                self.state.peeking = true
            }
            .store(in: &cancellables)

        // the pet composer needs key status; a nonactivating panel gets it without activating Pulse
        state.$petVisible
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [panel] visible in
                if visible {
                    // typing needs key status; an accessory app activating shows no Dock or menu change
                    NSApp.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil)
                } else if NSApp.isActive {
                    panel.resignKey()
                    NSApp.deactivate()   // hand focus back to whatever the user was in
                }
            }
            .store(in: &cancellables)

        CodexPetSession.shared.$voiceState
            .removeDuplicates()
            .sink { [weak self] voice in
                if voice == .off { self?.cancelVoiceKey() }
            }
            .store(in: &cancellables)

        state.$persisted
            .map { $0.showPet == false || !$0.showOverlay ? nil : $0.voiceHotKey ?? .voiceDefault }   // the rings column hides the pet too
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] combo in self?.bindVoiceKey(combo) }
            .store(in: &cancellables)

        state.$persisted
            .receive(on: RunLoop.main)
            .sink { [panel] p in
                panel.level = p.alwaysOnTop ? .floating : .normal
                if p.showOverlay { panel.orderFront(nil) } else { panel.orderOut(nil) }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        peekWatch?.invalidate()   // the run loop would keep a repeating timer after its controller is gone
    }
}
