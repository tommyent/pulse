import AppKit
import Combine
import SwiftUI
import os

private let log = Logger(subsystem: "io.github.tommyent.pulse", category: "agents")

/// The agents ring's state: Rex's agents while the switch is on, the failures cleared with their ×, the quiet rule in
/// force, and Pulse's own sound and alert for agents that need you.
@MainActor
final class AgentsMonitor: ObservableObject {
    static let shared = AgentsMonitor()
    static let rexApp = "com.superlogical.rex"

    /// What the ring shows. Replaced only when it changes: the rail redraws for a change, not for the clock.
    @Published private(set) var board = AgentBoard()
    @Published private(set) var agents: [BreakAgent] = []
    /// The failures whose × was clicked, by block, each with the time that failure began.
    @Published private(set) var dismissed: [String: Date] = [:]
    /// The quiet rule that is holding a sound or an alert back while someone needs you; nil for the rules that show
    /// nothing (Rex in front, a locked screen).
    @Published private(set) var hold: AgentHold?
    /// Whether Pulse found the `rex` command on this Mac. Stand-in agents count, so the ring can be tried without Rex.
    @Published private(set) var rexFound = false
    /// Idle agents' context, by block, where their session data could be found (`AgentContext`).
    @Published private(set) var contexts: [String: AgentContext] = [:]

    private var contextRead: [String: Date] = [:]   // block → the idle spell (when it began) its context was read for
    private var readingContexts = false
    private weak var state: AppState?
    private var settings = AgentSettings()
    private var notifier = AgentNotifier()
    private var timer: Timer?
    private var panel: NSPanel?
    private var alertShows: [String] = []   // the agents the open alert lists
    private var alertAfter: AgentHold?
    private var sound: NSSound?             // kept until it has played
    private var cancellables: Set<AnyCancellable> = []
    private let clicks = LatestRequest()
    private var showing: Task<Void, Never>?   // the latest row click's requests to Rex

    func attach(_ state: AppState) {
        self.state = state
        findRex()
        // with the rings hidden there's no ring to show: nothing is read, and nothing sounds
        state.$persisted.map { saved in
            var agents = saved.agents
            if !saved.showOverlay { agents.showOnRail = false }
            return agents
        }
        .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &cancellables)
        BreakController.shared.rex.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.agents = $0
                self?.update()
            }
            .store(in: &cancellables)
    }

    /// Looks for Rex again: at launch, and when Settings opens, where a Rex installed since should show.
    func findRex() {
        let found = RexAgents.executable() != nil || UserDefaults.standard.simulatedAgents != nil
        guard found != rexFound else { return }
        rexFound = found
        apply(settings)
    }

    private var onRail: Bool { settings.onRail(rexFound: rexFound) }

    private func apply(_ new: AgentSettings) {
        settings = new
        BreakController.shared.rex.want(onRail, for: "rail")   // all day while the switch is on
        update()
    }

    /// Runs when the agents or the settings change, and on a timer while someone needs you or has just finished.
    private func update() {
        let now = Date()
        let kept = dismissed.filter { id, since in agents.contains { $0.id == id && $0.failed && $0.since == since } }
        if kept != dismissed { dismissed = kept }   // an agent that ran again can fail again
        let fresh = onRail ? AgentBoard(agents, dismissed: dismissed, now: now) : AgentBoard()
        if fresh != board { board = fresh }
        let needing = fresh.needing
        let rule = needing.isEmpty ? nil : currentHold(now)
        let holding = rule?.shown == true && (settings.waitAlert || !settings.sound.isEmpty) ? rule : nil
        if holding != hold { hold = holding }
        let result = notifier.step(needing, now: now, settings: settings, hold: rule)
        if result.sound { play(settings.sound) }
        if result.alert { showAlert(after: result.after) } else if panel != nil { showAlert(after: alertAfter, again: true) }

        let every: TimeInterval? = needing.isEmpty ? (fresh.justFinished ? 30 : nil) : 5
        guard every != timer?.timeInterval else { return }
        timer?.invalidate()
        timer = every.map { seconds in
            let t = Timer(timeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated { AgentsMonitor.shared.update() } }
            t.tolerance = seconds / 5
            RunLoop.main.add(t, forMode: .common)
            return t
        }
    }

    private func currentHold(_ now: Date) -> AgentHold? {
        let breaks = BreakController.shared
        return AgentHold.current(settings, now: now, locked: breaks.away,
                                 onBreak: AgentHold.breakHolds(onScreen: breaks.onScreen, ended: breaks.breakEnded, now: now),
                                 voiceCall: CodexPetSession.shared.voiceState != .off, pausedUntil: breaks.pausedUntil,
                                 rexInFront: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.rexApp,
                                 microphone: BreakController.microphoneInUse)
    }

    private func play(_ name: String) {
        sound?.stop()
        sound = BatterySounds.sound(name)   // played at the system output volume
        sound?.play()
        log.notice("sound: \(name, privacy: .public) as an agent needs you")
    }

    // MARK: the alert

    /// One alert for everyone who needs you, with the system sound once. While it's open (`again`) it's redrawn as the
    /// list changes, centred for its new size without another sound, and closes once nobody needs you.
    private func showAlert(after: AgentHold?, again: Bool = false) {
        guard let state else { return }
        let needing = board.rows.filter { $0.state == .waiting || $0.state == .failed }
        let finished = board.rows.filter { $0.state == .finished }
        guard !needing.isEmpty else { return closeAlert() }
        let shows = (needing + finished).map(\.id)
        if panel != nil, shows == alertShows { return }
        let open = panel != nil
        panel?.close()
        alertShows = shows
        alertAfter = again ? alertAfter : after
        panel = AlertPanel.show(AgentsAlertView(rows: needing, finished: finished, after: alertAfter?.after,
                                                show: { [weak self] in self?.show($0) }, dismiss: { [weak self] in self?.closeAlert() }),
                                announcing: AgentsAlertView.title(needing.count), state: state)
        if !open {
            NSSound.beep()   // the alert sound chosen in System Settings → Sound
            log.notice("agents alert: \(needing.count) need you\(after.map { ", held by \($0)" } ?? "", privacy: .public)")
        }
    }

    private func closeAlert() {
        panel?.close()
        panel = nil
        alertShows = []
        alertAfter = nil
    }

    // MARK: idle agents' context

    /// The open card asks for this every half minute. Each idle agent on this Mac is read once for its idle spell: at
    /// rest its context doesn't move. One that couldn't be read is tried again. Off the main thread, since it opens
    /// the agents' session files.
    func readContexts() {
        let idle = board.rows.filter { $0.state == .idle }.map(\.agent)
        let current = contexts.filter { id, _ in idle.contains { $0.id == id && $0.since == contextRead[id] } }
        if current != contexts { contexts = current }   // an agent that ran again has a new context to read
        contextRead = contextRead.filter { current[$0.key] != nil }
        let wanted = idle.filter { $0.host.isEmpty && $0.pid != nil && $0.since != nil && current[$0.id] == nil }
        guard !wanted.isEmpty, !readingContexts else { return }
        readingContexts = true
        Task.detached(priority: .utility) {
            let read = wanted.map { ($0, AgentContext.read($0)) }
            await MainActor.run {
                for (agent, context) in read {
                    guard let context else { continue }
                    self.contexts[agent.id] = context
                    self.contextRead[agent.id] = agent.since
                }
                self.readingContexts = false
            }
        }
    }

    // MARK: actions from the card and the alert

    /// The ×: clears Pulse's mark on a failed agent. Nothing changes in Rex.
    func clear(_ agent: BreakAgent) {
        guard agent.failed, let since = agent.since else { return }
        dismissed[agent.id] = since
        update()
    }

    /// A click on a row. Nothing is answered from Pulse: Rex comes to the front, and its pane is shown as far as the
    /// `rex` command can (`RexAgents.show`).
    func show(_ agent: BreakAgent) {
        state?.collapseOverlay()
        closeAlert()
        let rex = RexAgents.executable(), click = clicks.next(), earlier = showing
        // Only the latest click counts. An earlier one sends nothing more, and this one waits for whatever request
        // that one had under way, so the pane Rex ends on is the one clicked last.
        showing = Task { @MainActor [clicks] in
            await earlier?.value
            guard clicks.isLatest(click) else { return }
            // in front first, and asked only then: Rex's guide says its app may not act on a request in the background
            await Self.bringRexForward()
            guard let rex, clicks.isLatest(click) else { return }
            await Task.detached(priority: .userInitiated) {
                RexAgents.show(agent, rex: rex, thisMac: Host.current().localizedName ?? "") { clicks.isLatest(click) }
            }.value
        }
    }

    /// Opens or activates Rex, then waits until it's the app in front: 3 s at most, after which it's asked anyway.
    private static func bringRexForward() async {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rexApp) else { return }
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == rexApp { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
