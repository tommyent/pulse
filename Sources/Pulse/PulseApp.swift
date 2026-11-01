import SwiftUI
import Combine

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
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
        return state.tuckedAway ? state.dock.tucked(frame, inset: railInset(), in: bounds) : frame
    }

    /// The rail's distance inside the content from its inner side (away from the edge): its padding, plus a break's
    /// countdown beside it.
    private func railInset() -> CGFloat {
        guard railFrame != .zero else { return 12 }
        // railFrame is in window coordinates (y down), and the content is centred in the panel (a glide's box is larger)
        let rail = railFrame.offsetBy(dx: -(panel.frame.width - contentSize.width) / 2,
                                      dy: -(panel.frame.height - contentSize.height) / 2)
        return switch state.dock {
        case .right: rail.minX
        case .left: contentSize.width - rail.maxX
        case .top: contentSize.height - rail.maxY
        case .bottom: rail.minY
        }
    }

    /// Moves the panel. Whatever lies past the screen's usable area (a tucked rail, a glide pressing on the edge) is masked
    /// away, so it never shows under the transparent menu bar, through the Dock or on a neighbouring display.
    private func place(_ frame: CGRect, display: Bool = true) {
        if panel.frame != frame { panel.setFrame(frame, display: display) }
        guard let view = panel.contentView, let screen = dockScreen ?? panel.screen else { return }
        let visible = frame.intersection(screen.visibleFrame)
        guard visible != frame, !visible.isNull else { view.layer?.mask = nil; return }
        let mask = view.layer?.mask ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = NSColor.black.cgColor
        // window coordinates to the view's (flipped, as its backing layer is: measured offscreen)
        mask.frame = view.convert(visible.offsetBy(dx: -frame.minX, dy: -frame.minY), from: nil)
        CATransaction.commit()
        view.layer?.mask = mask
    }

    /// The part of the panel on screen, where the pointer can be on it.
    private var visiblePanel: CGRect {
        guard let screen = dockScreen ?? panel.screen else { return panel.frame }
        let visible = panel.frame.intersection(screen.visibleFrame)
        return visible.isNull ? panel.frame : visible
    }

    private func screenPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: panel.frame.minX + location.x, y: panel.frame.maxY - location.y)
    }

    private func drag(_ location: CGPoint) {
        let mouse = screenPoint(location)
        if dragStart == nil {
            if let flight { land(CGRect(x: flight.glide.center.first - contentSize.width / 2, y: flight.glide.center.second - contentSize.height / 2,
                                        width: contentSize.width, height: contentSize.height)) }   // caught mid-glide
            dragStart = (mouse, panel.frame.origin)
            state.dragging = true
        }
        guard let start = dragStart else { return }
        throwing.add(mouse, at: ProcessInfo.processInfo.systemUptime)
        // a tucked rail pulled out by its sliver comes out with the pointer; it stays tucked in state until the drop
        place(CGRect(origin: CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y),
                     size: panel.frame.size))
    }

    private func drop(_ location: CGPoint) {
        guard dragStart != nil else { return }
        let mouse = screenPoint(location)
        dockScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel.screen ?? NSScreen.main
        throwing.add(mouse, at: ProcessInfo.processInfo.systemUptime)
        // the cursor stops at the display's edge while the hand flicks on: a throw into the rail's own edge ends there
        let display = dockScreen?.frame ?? .null
        let atEdge = mouse.x <= display.minX + 2 || mouse.x >= display.maxX - 2 || mouse.y <= display.minY + 2 || mouse.y >= display.maxY - 2
        let velocity = throwing.velocity(at: ProcessInfo.processInfo.systemUptime, pinned: atEdge)
        var edge = state.dock, tuck = false
        if let screen = dockScreen {
            let landing = DockEdge.landing(from: mouse, velocity: velocity, current: state.dock, in: screen.visibleFrame)
            pinned = landing.point
            edge = landing.edge
            tuck = state.dock.tucks(from: mouse, velocity: velocity, in: screen.visibleFrame)
        }
        dragStart = nil
        throwing = ThrowTracker()
        // Keep ring clicks suppressed until the mouse-up event has finished dispatching.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.dragging = false
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // a plain, immediate move
            withAnimation(still ? nil : .spring(railSpring())) {
                self.state.persisted.dock = edge
                self.state.collapseOverlay()
                self.state.tuckedBinding.wrappedValue = tuck
            }
            self.settle(velocity: velocity)
        }
    }

    /// Moves the rail to where it rests now: docked, or tucked into its edge. On the spring, starting at `velocity`;
    /// under Reduce Motion at once (a drop) or with a crossfade (`fade`: tucking, peeking).
    private func settle(velocity: CGVector = .zero, fade: Bool = false) {
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
            flight = (RailGlide(center: AnimatablePair(start.midX, start.midY), velocity: AnimatablePair(velocity.dx, velocity.dy),
                                target: start, edge: state.dock, spring: railSpring()),
                      CGSize(width: start.width + 32, height: start.height + 32), nil)
            // only the glide sizes the panel meanwhile: no window resize from Auto Layout before the box catches up
            (panel.contentView as? OverlayHostingView)?.sizingOptions = []
            flightLink = panel.contentView?.displayLink(target: ticker, selector: #selector(FrameTicker.frame(_:)))
            flightLink?.add(to: .main, forMode: .common)
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

    private func land(_ frame: CGRect) {
        flight = nil
        flightLink?.invalidate()
        flightLink = nil
        place(frame)
        (panel.contentView as? OverlayHostingView)?.sizingOptions = .standardBounds
        panel.saveFrame(usingName: "PulseOverlay")
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
            onDrag: { [weak self] in self?.drag($0) },
            onDrop: { [weak self] in self?.drop($0) },
            onRailFrame: { [weak self] in
                guard let self else { return }
                railFrame = $0
                if state.tuckedAway { contentSized(contentSize) }   // the tucked spot follows the rail's own frame
            },
            onCardFrame: { [weak self] in self?.cardFrame = $0 },
            onHintFrame: { [weak self] in self?.hintFrame = $0 },
            onPillFrame: { [weak self] in self?.pillFrame = $0 },
            pointerInside: { [weak self] in self.map { $0.visiblePanel.insetBy(dx: 1, dy: 1).contains(NSEvent.mouseLocation) } ?? false }))
        panel.contentView = hosting
        hosting.wantsLayer = true   // the mask that hides what lies past the screen edge
        ticker.onFrame = { [weak self] link in MainActor.assumeIsolated { self?.glide(link) } }
        if panel.setFrameUsingName("PulseOverlay"), panel.frame.width > 50 {
            pinned = state.dock.anchor(of: panel.frame)
            dockScreen = panel.screen
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
    }
}
