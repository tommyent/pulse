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

    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.pulseResources.url(forResource: "Resources/pulse", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()

    init() {
        // A write to a Codex child that just exited raises SIGPIPE, which would kill Pulse silently.
        // Ignored, the write throws EPIPE instead and the existing error paths report it.
        signal(SIGPIPE, SIG_IGN)
        // single instance: a new launch replaces any running one
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "app.pulse")
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.forceTerminate()
        }
        let state = AppState()
        _state = StateObject(wrappedValue: state)   // the pet's folder waits for its first use: no Documents prompt at launch
        overlay = OverlayController(state: state)
        NSApplication.shared.setActivationPolicy(.accessory)   // no Dock icon
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(state: state)
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
        }
    }
}

/// Borderless panels refuse key status by default; the pet's composer needs it (without activating Pulse).
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel is rarely key, and a first click on a non-key window only makes it key: the rail's drag would need a
/// second click. Accepting the first mouse lets that first click reach the overlay too.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private var railFrame = CGRect.zero
    private var cardFrame = CGRect.zero
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
        if event.window !== panel || overlayClickIsOutside(point, in: CGRect(origin: .zero, size: panel.frame.size),
                                                          rail: railFrame, card: state.cardVisible || state.petVisible ? cardFrame : nil) {
            state.collapseOverlay()
        }
    }

    /// Content grows away from the selected edge; never move it under an active drag.
    private func contentSized(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        contentSize = size
        let screenID = dockScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let liveScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID
        }
        guard !state.dragging, let screen = liveScreen ?? panel.screen ?? NSScreen.main else { return }
        dockScreen = screen
        let bounds = screen.visibleFrame
        let frame = state.dock.frame(size: size,
                                     anchor: pinned ?? CGPoint(x: bounds.midX, y: bounds.midY),
                                     in: bounds)
        pinned = state.dock.anchor(of: frame)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
    }

    private func screenPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: panel.frame.minX + location.x, y: panel.frame.maxY - location.y)
    }

    private func drag(_ location: CGPoint) {
        let mouse = screenPoint(location)
        if dragStart == nil {
            dragStart = (mouse, panel.frame.origin)
            state.dragging = true
        }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func drop(_ location: CGPoint) {
        guard dragStart != nil else { return }
        let mouse = screenPoint(location)
        dockScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel.screen ?? NSScreen.main
        if let screen = dockScreen {
            pinned = mouse
            state.persisted.dock = DockEdge.nearest(to: mouse, in: screen.visibleFrame)
        }
        dragStart = nil
        // Keep ring clicks suppressed until the mouse-up event has finished dispatching.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.dragging = false
            self.state.collapseOverlay()
            self.contentSized(self.contentSize)
            self.panel.saveFrame(usingName: "PulseOverlay")
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
            onDrag: { [weak self] in self?.drag($0) },
            onDrop: { [weak self] in self?.drop($0) },
            onRailFrame: { [weak self] in self?.railFrame = $0 },
            onCardFrame: { [weak self] in self?.cardFrame = $0 },
            pointerInside: { [weak self] in self.map { $0.panel.frame.insetBy(dx: 1, dy: 1).contains(NSEvent.mouseLocation) } ?? false }))
        panel.contentView = hosting
        if panel.setFrameUsingName("PulseOverlay"), panel.frame.width > 50 {
            pinned = state.dock.anchor(of: panel.frame)
            dockScreen = panel.screen
        }
        panel.setFrameAutosaveName("PulseOverlay")

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
