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
        // single instance: a new launch replaces any running one
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "app.pulse")
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.forceTerminate()
        }
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        _ = CodexPetSession.petHome()   // ~/Documents/codex-pet exists from first launch, not first chat
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
    private var voiceKeyDown: Date?
    private var voiceKeyStarted = false

    /// Voice shortcut: press starts (opening the pet card) or ends the call; a hold of more than
    /// half a second is push-to-talk and ends on release.
    private func bindVoiceKey(_ combo: HotKeyCombo) {
        voiceKey = HotKey(combo)
        voiceKey?.onPress = { [weak self] in
            guard let self else { return }
            let session = CodexPetSession.shared
            voiceKeyDown = .now
            if session.voiceState == .off {
                state.cardVisible = false
                state.petVisible = true
                session.startVoice()
                voiceKeyStarted = true
            } else {
                session.stopVoice()
                voiceKeyStarted = false
            }
        }
        voiceKey?.onRelease = { [weak self] in
            guard let self, voiceKeyStarted, let down = voiceKeyDown else { return }
            voiceKeyStarted = false
            if Date().timeIntervalSince(down) > 0.5 { CodexPetSession.shared.stopVoice() }   // held: push-to-talk
        }
    }

    private func mouseDown(_ event: NSEvent) {
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
        panel.setFrame(frame, display: true)
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
        let hosting = NSHostingView(rootView: OverlayView(state: state,
            onSize: { [weak self] size in self?.contentSized(size) },
            onDrag: { [weak self] in self?.drag($0) },
            onDrop: { [weak self] in self?.drop($0) },
            onRailFrame: { [weak self] in self?.railFrame = $0 },
            onCardFrame: { [weak self] in self?.cardFrame = $0 }))
        panel.contentView = hosting
        // the pet's voice call lives in a 2×2 pt WebKit view; WebKit only captures and plays while in a window
        hosting.addSubview(VoiceBridge.shared.webView)
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

        state.$persisted
            .map { $0.voiceHotKey ?? .voiceDefault }
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
