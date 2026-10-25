import AppKit
import Combine
import CoreGraphics
import SwiftUI
import os

private let log = Logger(subsystem: "app.pulse", category: "breaks")

extension UserDefaults {
    /// Starts a countdown at once, for testing: `defaults write app.pulse simulatedBreak long` (or `micro`). Breaks
    /// must be on in Settings. Pulse clears it once used, so each write is one countdown.
    @objc dynamic var simulatedBreak: String? { string(forKey: "simulatedBreak") }
    /// Shows this text as the break's idea instead of asking Apple Intelligence, for testing on a Mac without it:
    /// `defaults write app.pulse simulatedIdea "…"`.
    var simulatedIdea: String? { string(forKey: "simulatedIdea") }
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
    @Published private(set) var history = BreakHistory()
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
    private var awayIdle = false     // no input has counted as time away; "back" is logged when input returns
    private var held: String?        // why a due break is waiting (a voice call, a locked screen), logged as it changes
    private var saved: BreakClocks?  // what break-clock.json holds
    private var sound: NSSound?      // kept until it has played

    private static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pulse")
    private static let clocksURL = dir.appending(path: "break-clock.json")
    private static let historyURL = dir.appending(path: "break-history.jsonl")

    var settings: BreakSettings { schedule.settings }
    func remaining(_ now: Date) -> (left: TimeInterval, total: TimeInterval) { schedule.remaining(now) ?? (0, 1) }
    var kind: BreakKind? {
        switch phase {
        case .working: nil
        case let .countdown(k, _), let .onBreak(k, _), let .paused(k, _): k
        }
    }

    /// For the rail on hover and the menu: "Next: micro in 7 min · long in 42 min". nil while breaks are off.
    func nextText(_ now: Date) -> String? {
        guard schedule.settings.enabled else { return nil }
        if !phase.isWorking { return "Break now" }
        if let held { return "Next: a break is waiting for \(held)" }
        let next = schedule.upcoming(now)
        return nextBreakText(micro: next.micro, long: next.long, now: now)
    }

    func attach(_ state: AppState) {
        self.state = state
        let now = Date()
        var loaded = BreakHistory(jsonLines: (try? Data(contentsOf: Self.historyURL)) ?? Data())
        if loaded.prune(now: now) { try? loaded.jsonLines.write(to: Self.historyURL, options: .atomic) }
        history = loaded
        schedule = BreakSchedule(settings: state.persisted.breaks, now: now)
        if schedule.settings.enabled { restoreClocks(now) }
        state.$persisted.map(\.breaks).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] new in
                guard let self else { return }
                let old = schedule.settings
                if new.enabled && !old.enabled {
                    schedule = BreakSchedule(settings: new, now: .now)
                    log.notice("breaks turned on, clocks start now: \(Self.describe(new), privacy: .public)")
                } else {
                    if !new.enabled && old.enabled { log.notice("breaks turned off") }
                    if new.awayMode != old.awayMode { log.notice("time away now counts: \(Self.describe(new), privacy: .public)") }
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
            MainActor.assumeIsolated { BreakController.shared.wentAway(\.lockedAt) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.cameBack(from: \.lockedAt) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.wentAway(\.sleptAt) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.cameBack(from: \.sleptAt) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BreakController.shared.quitting() }
        })
        // KVO here also sees `defaults write` from another process
        simulation = UserDefaults.standard.observe(\.simulatedBreak, options: [.initial]) { _, _ in
            Task { @MainActor in BreakController.shared.simulate() }
        }
    }

    // MARK: time away and restarts

    private func wentAway(_ key: ReferenceWritableKeyPath<BreakController, Date?>) {
        self[keyPath: key] = .now
        saveClocks(force: true)   // a sleep can end in a restart
        tick()                    // a countdown or a break on screen stops now
    }

    private func cameBack(from key: ReferenceWritableKeyPath<BreakController, Date?>) {
        guard let since = self[keyPath: key] else { return }
        self[keyPath: key] = nil
        let away = Date().timeIntervalSince(since), what = key == \BreakController.lockedAt ? "locked" : "asleep"
        if let e = schedule.away(away, now: .now) { handle(e, why: "\(what) for \(Int(away)) s") }
        else { log.notice("back after \(what, privacy: .public) for \(Int(away)) s: shorter than a break, the clocks carry on") }
    }

    /// Carries on from the clocks saved before Pulse last quit.
    private func restoreClocks(_ now: Date) {
        guard let data = try? Data(contentsOf: Self.clocksURL), let clocks = try? JSONDecoder().decode(BreakClocks.self, from: data) else {
            log.notice("breaks on at launch, clocks start now: \(Self.describe(self.schedule.settings), privacy: .public)")
            return
        }
        let quitFor = max(0, now.timeIntervalSince(clocks.savedAt))
        // asleep or off: a restart since the save means the Mac was down until it booted
        let downFor = Self.bootTime().map { $0 > clocks.savedAt ? $0.timeIntervalSince(clocks.savedAt) : 0 } ?? 0
        let event = schedule.restore(clocks, now: now, quitFor: quitFor, downFor: downFor)
        let next = schedule.upcoming(now), longIn = next.long.map { Int($0.timeIntervalSince(now)) } ?? -1
        log.notice("clocks restored after Pulse was quit for \(Int(quitFor)) s (the Mac down \(Int(downFor)) s): next micro in \(Int(next.micro.timeIntervalSince(now))) s, long in \(longIn) s")
        if let event { handle(event, why: "Pulse quit for \(Int(quitFor)) s") }
    }

    private func quitting() {
        if let e = schedule.skip(.now) { handle(e, why: "Pulse quit") }   // a break on screen is recorded as skipped
        saveClocks(force: true)
    }

    /// break-clock.json: written when a due time changes and once a minute, so a restart knows when Pulse stopped.
    private func saveClocks(force: Bool = false) {
        guard schedule.settings.enabled else { return }
        let now = Date(), c = schedule.clocks
        if !force, let saved, saved.nextMicro == c.nextMicro, saved.nextLong == c.nextLong, now.timeIntervalSince(saved.savedAt) < 60 { return }
        var fresh = c
        fresh.savedAt = now
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: Self.clocksURL, options: .atomic) }
        saved = fresh
    }

    private func record(_ kind: BreakKind, due: Date, _ outcome: BreakSchedule.Outcome) {
        let r = BreakRecord(kind: kind, due: due, at: .now, outcome: outcome)
        history.add(r)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Self.historyURL) {
            h.seekToEndOfFile()
            h.write(BreakHistory.line(r))
            try? h.close()
        } else {
            try? BreakHistory.line(r).write(to: Self.historyURL, options: .atomic)
        }
    }

    private static func bootTime() -> Date? {
        var tv = timeval(), size = MemoryLayout<timeval>.size, mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    private static func describe(_ s: BreakSettings) -> String {
        "micro every \(Int(s.microEvery)) s for \(Int(s.microLength)) s, long "
            + (s.longEnabled ? "every \(Int(s.longEvery)) s for \(Int(s.longLength)) s" : "off")
            + (s.awayMode == .idle ? "; away: locked, asleep or 300 s idle" : "; away: only locked or asleep (fixed)")
    }

    private func simulate() {
        guard let name = UserDefaults.standard.simulatedBreak, let kind = BreakKind(rawValue: name), schedule.settings.enabled else { return }
        UserDefaults.standard.removeObject(forKey: "simulatedBreak")   // one countdown per write, not one at every launch
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
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let voice = CodexPetSession.shared.voiceState != .off, locked = lockedAt != nil || sleptAt != nil
        let previous = schedule.phase, enabled = schedule.settings.enabled
        let waiting = enabled && previous == .working && schedule.due(at: now) != nil
            ? (locked ? "the screen to unlock" : voice ? "your voice call to end" : nil) : nil
        let event = schedule.tick(now: now, idle: idle, locked: locked, voiceActive: voice)
        if waiting != held {
            if let waiting { log.notice("break due but held: waiting for \(waiting, privacy: .public)") } else { log.notice("hold over") }
            held = waiting
        }
        if awayIdle, idle < BreakSchedule.idleAway || schedule.settings.awayMode == .fixed {
            log.notice("back from time away: input again, the clocks run from here")
            awayIdle = false
        }
        defer { saveClocks() }
        guard let event else { return publish() }
        let why = switch (event, previous) {
        case (.start, _): "the countdown ran out"
        case (.end(_, .taken, _), _): "finished"
        case (.end(_, nil, _), _): locked ? "the screen locked" : "a Pulse voice call started"
        case (.end(_, .skipped, _), _): "breaks turned off"
        case (.away, _): "no input for \(Int(idle)) s"
        default: ""
        }
        if case .away = event { awayIdle = true }
        handle(event, why: why)
    }

    private func publish() { if phase != schedule.phase { phase = schedule.phase } }

    private func handle(_ event: BreakSchedule.Event, why: String = "") {
        publish()
        let now = Date(), next = schedule.upcoming(now)
        let nextLine = "next micro in \(Int(next.micro.timeIntervalSince(now))) s" + (next.long.map { ", long in \(Int($0.timeIntervalSince(now))) s" } ?? "")
        switch event {
        case let .countdown(k):
            log.notice("countdown: \(k.rawValue, privacy: .public) break in \(Int(BreakSchedule.countdown)) s\(why.isEmpty ? "" : " (" + why + ")", privacy: .public)")
            shownIdeas = []
            requestIdea(surprise: false)
            placePill()
        case let .start(k):
            let length = Int(schedule.settings.length(k))
            log.notice("break started: \(k.rawValue, privacy: .public) for \(length) s (\(why, privacy: .public))")
            placePill()
            showOverlay(k)
        case let .end(k, outcome, due):
            if let outcome {
                record(k, due: due, outcome)
                log.notice("break ended: \(k.rawValue, privacy: .public) \(outcome.label, privacy: .public) (\(why, privacy: .public)); \(nextLine, privacy: .public)")
            } else {
                log.notice("break interrupted: \(k.rawValue, privacy: .public) (\(why, privacy: .public)), still due")
            }
            placePill()
            hideOverlay()
            ideaTask?.cancel()
            idea = .hidden
            shownIdeas = []
        case let .away(counted):
            for k in [BreakKind.micro, .long] { if let due = counted[k] { record(k, due: due, .away) } }
            let kinds = counted.keys.map(\.rawValue).sorted().joined(separator: " and ")
            log.notice("time away counted as a \(kinds, privacy: .public) break (\(why, privacy: .public)); \(nextLine, privacy: .public)")
        }
        if let name = schedule.settings.sound(for: event) {
            sound?.stop()
            sound = BatterySounds.sound(name)   // played at the system output volume
            sound?.play()
            let when = if case .start = event { "starts" } else { "ends" }
            log.notice("sound: \(name, privacy: .public) as the break \(when, privacy: .public)")
        }
        saveClocks(force: true)
        updateClock()
    }

    // MARK: actions from the pill and the overlay

    func startNow() { if let e = schedule.startNow(.now) { handle(e, why: "clicked") } }
    func pause() { schedule.pause(.now); publish(); log.notice("paused") }
    func resume() { schedule.resume(.now); publish(); log.notice("resumed") }
    func snooze() { if let e = schedule.snooze(.now) { handle(e, why: "snoozed, back in \(Int(BreakSchedule.snooze)) s") } }
    func backToWork() { if let e = schedule.backToWork(.now) { handle(e, why: "Back to Work") } }
    func skip() { if let e = schedule.skip(.now) { handle(e, why: "Escape") } }
    func reroll() { requestIdea(surprise: false) }
    func surprise() { requestIdea(surprise: true) }

    /// Writing an idea never holds up the timer: a placeholder shows while it runs, and a failure keeps the last idea
    /// or hides the line.
    private func requestIdea(surprise: Bool) {
        let s = schedule.settings
        if let text = UserDefaults.standard.simulatedIdea, kind != nil { idea = .shown(text); return }
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
