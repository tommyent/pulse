import AppKit
import Combine
import CoreGraphics
import SwiftUI
import os

private let log = Logger(subsystem: "app.pulse", category: "breaks")

extension UserDefaults {
    /// Starts a countdown at once, for testing: `defaults write app.pulse simulatedBreak long` (or `micro`). Breaks
    /// must be on in Settings. Also works as `--args -simulatedBreak long`.
    @objc dynamic var simulatedBreak: String? { string(forKey: "simulatedBreak") }
}

/// Runs the break schedule: a one-second clock while breaks are on, the countdown beside the rail, the overlay on
/// every screen, the idea and the agents on it.
@MainActor
final class BreakController: ObservableObject {
    static let shared = BreakController()
    enum Idea: Equatable { case hidden, loading, shown(String) }

    /// Published only when it changes: the rail redraws for the countdown, not every second.
    @Published private(set) var phase = BreakSchedule.Phase.working
    @Published private(set) var idea = Idea.hidden
    let rex = RexAgents()
    private(set) var breakStarted = Date()
    private var schedule = BreakSchedule(settings: BreakSettings(), now: .now)
    private weak var state: AppState?
    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var pillPanel: NSPanel?   // only while the rings are hidden
    private var ideaTask: Task<Void, Never>?
    private var shownIdeas: [String] = []
    private var lockedAt: Date?
    private var sleptAt: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var simulation: NSKeyValueObservation?
    private var awayLevel = 0        // what time away is holding now: 0 nothing, 1 the micro clock, 2 both; logged as it rises
    private var heldForCall = false  // a due break waiting for a Pulse voice call, logged when it starts and stops

    var settings: BreakSettings { schedule.settings }
    func remaining(_ now: Date) -> (left: TimeInterval, total: TimeInterval) { schedule.remaining(now) ?? (0, 1) }
    var kind: BreakKind? {
        switch phase {
        case .working: nil
        case let .countdown(k, _), let .onBreak(k, _), let .paused(k, _): k
        }
    }

    func attach(_ state: AppState) {
        self.state = state
        schedule = BreakSchedule(settings: state.persisted.breaks, now: .now)
        let atLaunch = Self.describe(schedule.settings)
        if schedule.settings.enabled { log.notice("breaks on at launch, clocks start now: \(atLaunch, privacy: .public)") }
        state.$persisted.map(\.breaks).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] new in
                guard let self else { return }
                if new.enabled && !schedule.settings.enabled {
                    schedule = BreakSchedule(settings: new, now: .now)
                    log.notice("breaks turned on, clocks start now: \(Self.describe(new), privacy: .public)")
                } else {
                    if !new.enabled && schedule.settings.enabled { log.notice("breaks turned off") }
                    schedule.settings = new
                }
                tick()
                updateClock()
            }
            .store(in: &cancellables)
        // the rings' own switch decides where the countdown shows
        state.$persisted.map(\.showOverlay).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.placePill() }
            .store(in: &cancellables)

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.lockedAt = .now }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.cameBack(from: \.lockedAt) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.sleptAt = .now }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.cameBack(from: \.sleptAt) }
        })
        // KVO here also sees `defaults write` from another process
        simulation = UserDefaults.standard.observe(\.simulatedBreak, options: [.initial]) { _, _ in
            Task { @MainActor in BreakController.shared.simulate() }
        }
    }

    private func cameBack(from key: ReferenceWritableKeyPath<BreakController, Date?>) {
        if let since = self[keyPath: key] {
            let before = clocks, away = Date().timeIntervalSince(since)
            schedule.away(away, now: .now)
            logResets(since: before, "away: \(key == \BreakController.lockedAt ? "locked" : "asleep") for \(Int(away)) s")
        }
        self[keyPath: key] = nil
    }

    private var clocks: (micro: Date, long: Date) { (schedule.lastMicro, schedule.lastLong) }

    /// Logs the clocks that really restarted, and why. A clock off with its switch, which only follows the time, isn't.
    private func logResets(since before: (micro: Date, long: Date), _ why: String) {
        let s = schedule.settings
        let micro = schedule.lastMicro != before.micro, long = s.longEnabled && schedule.lastLong != before.long
        guard s.enabled, micro || long else { return }
        log.notice("clock reset (\(why, privacy: .public)): \(long ? "micro and long" : "micro", privacy: .public); next micro in \(Int(s.microEvery)) s\(long ? ", long in \(Int(s.longEvery)) s" : "", privacy: .public)")
    }

    private static func describe(_ s: BreakSettings) -> String {
        "micro every \(Int(s.microEvery)) s for \(Int(s.microLength)) s, long " + (s.longEnabled ? "every \(Int(s.longEvery)) s for \(Int(s.longLength)) s" : "off")
    }

    private func simulate() {
        guard let name = UserDefaults.standard.simulatedBreak, let kind = BreakKind(rawValue: name), schedule.settings.enabled else { return }
        if let e = schedule.begin(kind, now: .now) { handle(e, why: "simulatedBreak") }
        updateClock()
    }

    // MARK: the clock

    private func updateClock() {
        let needed = schedule.settings.enabled || phase != .working
        if needed, timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { BreakController.shared.tick() } }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let now = Date()
        // any input event: kCGAnyInputEventType
        let input = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let idle = max(input, lockedAt.map { now.timeIntervalSince($0) } ?? 0)
        let voice = CodexPetSession.shared.voiceState != .off
        let before = clocks, previous = schedule.phase, enabled = schedule.settings.enabled
        let held = voice && previous == .working && enabled && schedule.due(at: now) != nil
        let event = schedule.tick(now: now, idle: idle, voiceActive: voice)
        if held != heldForCall {
            if held { log.notice("break due but held: a Pulse voice call is on") } else { log.notice("voice hold over") }
            heldForCall = held
        }
        // time away restarts the clocks on every tick it lasts: log only when it starts holding one more of them
        if enabled, previous == .working, event == nil {
            let level = schedule.settings.longEnabled && schedule.lastLong != before.long ? 2 : schedule.lastMicro != before.micro ? 1 : 0
            if level > awayLevel { logResets(since: before, "away: no input or locked for \(Int(idle)) s") }
            else if level == 0, awayLevel > 0 { log.notice("back from time away: the clocks run again") }
            awayLevel = level
        }
        guard let event else { return publish() }
        let why = switch (event, previous) {
        case (.start, _): "the countdown ran out"
        case (.end, .onBreak): "finished"
        case (.end, .countdown) where voice: "a Pulse voice call started"
        case (.end, _): "breaks turned off"
        default: ""
        }
        handle(event, why: why, clocksBefore: before)
    }

    private func publish() { if phase != schedule.phase { phase = schedule.phase } }

    private func handle(_ event: BreakSchedule.Event, why: String = "", clocksBefore: (micro: Date, long: Date)? = nil) {
        let ended = kind
        publish()
        switch event {
        case let .countdown(k): log.notice("countdown: \(k.rawValue, privacy: .public) break in \(Int(BreakSchedule.countdown)) s\(why.isEmpty ? "" : " (" + why + ")", privacy: .public)")
        case let .start(k):
            let length = Int(schedule.settings.length(k))
            log.notice("break started: \(k.rawValue, privacy: .public) for \(length) s (\(why, privacy: .public))")
        case .end: log.notice("break ended: \(ended?.rawValue ?? "?", privacy: .public) (\(why, privacy: .public))")
        }
        if let clocksBefore { logResets(since: clocksBefore, why) }
        switch event {
        case .countdown:
            shownIdeas = []
            requestIdea(surprise: false)
            placePill()
        case let .start(kind):
            placePill()
            showOverlay(kind)
        case .end:
            placePill()
            hideOverlay()
            ideaTask?.cancel()
            idea = .hidden
            shownIdeas = []
        }
        updateClock()
    }

    // MARK: actions from the pill and the overlay

    func startNow() { if let e = schedule.startNow(.now) { handle(e, why: "clicked") } }
    func pause() { schedule.pause(.now); publish(); log.notice("paused") }
    func resume() { schedule.resume(.now); publish(); log.notice("resumed") }
    func snooze() { if let e = schedule.snooze(.now) { handle(e, why: "snoozed, back in \(Int(BreakSchedule.snooze)) s") } }
    func backToWork() { let before = clocks; if let e = schedule.backToWork(.now) { handle(e, why: "Back to Work", clocksBefore: before) } }
    func reroll() { requestIdea(surprise: false) }
    func surprise() { requestIdea(surprise: true) }

    /// Writing an idea never holds up the timer: a placeholder shows while it runs, and a failure keeps the last idea
    /// or hides the line.
    private func requestIdea(surprise: Bool) {
        let s = schedule.settings
        guard s.ideas, let kind, BreakIdeas.available else { idea = .hidden; return }
        let previous = idea
        ideaTask?.cancel()
        idea = .loading
        let avoid = shownIdeas
        ideaTask = Task { [weak self] in
            let text = await BreakIdeas.generate(length: s.length(kind), level: s.level, interests: s.interests,
                                                 surprise: surprise, avoid: avoid)
            guard !Task.isCancelled, let self else { return }
            if let text {
                idea = .shown(text)
                shownIdeas.append(text)
            } else {
                idea = previous == .loading ? .hidden : previous
            }
        }
    }

    // MARK: the countdown when the rings are hidden

    /// With the rings on screen the countdown grows out of the rail (OverlayView); without them it gets a panel of its
    /// own at the middle of the right edge.
    private func placePill() {
        guard phase.isCountdown, state?.persisted.showOverlay == false, let screen = NSScreen.main?.visibleFrame else {
            pillPanel?.close()
            pillPanel = nil
            return
        }
        guard pillPanel == nil else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hosting = OverlayHostingView(rootView: BreakPill(controller: self, tail: .trailing).padding(12)
            .colorScheme(state?.isLight == true ? .light : .dark).environment(\.glassTint, state?.glassTint ?? true))
        panel.contentView = hosting
        let size = CGSize(width: 220, height: 80)
        panel.setFrame(CGRect(x: screen.maxX - size.width - 4, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        pillPanel = panel
    }

    // MARK: the overlay on every screen

    private func showOverlay(_ kind: BreakKind) {
        hideOverlay()
        breakStarted = .now
        let s = schedule.settings
        let main = NSScreen.main ?? NSScreen.screens.first
        let agents = s.showAgents
        if agents { rex.start() }
        let petOnRight = state?.dock != .left
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for screen in NSScreen.screens {
            let panel = BreakPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver   // above the rings, alerts and full-screen apps
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: BreakOverlayView(
                controller: self, size: screen.frame.size,
                agents: agents && screen == main, showPet: state?.showsPet ?? true, petOnRight: petOnRight))
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            panels.append(panel)
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.6; panel.animator().alphaValue = 1 }
            }
        }
        // the keyboard, so Escape can end the break
        NSApp.activate(ignoringOtherApps: true)
        (panels.first { $0.screen == main } ?? panels.first)?.makeKey()
        if let first = panels.first {
            NSAccessibility.post(element: first, notification: .announcementRequested, userInfo: [
                .announcement: "Time to take a break: \(BreakIdeaPrompt.duration(s.length(kind)))",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    private func hideOverlay() {
        rex.stop()
        guard !panels.isEmpty else { return }
        let closing = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; closing.forEach { $0.animator().alphaValue = 0 } },
                                             completionHandler: { closing.forEach { $0.close() } })
        if NSApp.isActive { NSApp.deactivate() }   // hand the keyboard back to whatever was in use
    }
}

/// Borderless panels refuse key status by default; the overlay takes it for Escape.
private final class BreakPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
