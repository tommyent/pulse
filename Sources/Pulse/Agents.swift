import Foundation

/// The agents ring on the rail without any UI or system calls: its settings, what the ring and its card show, and when
/// Pulse's own sound and alert fire. The checks compile this file with Breaks.swift and RexAgents.swift.

struct AgentSettings: Codable, Equatable {
    var showOnRail = false   // opt-in: while it's on, Pulse reads Rex all day
    var sound = ""           // a sound's name, as Battery's pickers list them; "" is None, because Rex has sounds of its own
    var waitAlert = true     // the centre-screen alert once an agent has waited `waitMinutes`
    var waitMinutes = 5
    // the quiet rules: the sound and the alert wait
    var holdWhilePaused = true   // while breaks are paused from the cup,
    var holdDuringCalls = true   // while an app uses the microphone or a Pulse voice call runs,
    var holdWhileLocked = true   // and while the screen is locked or the Mac asleep

    static let waitChoices = [1, 2, 5, 10, 15, 30]

    /// The ring is on the rail only with the switch on and Rex found on this Mac: without Rex there's nothing to read.
    func onRail(rexFound: Bool) -> Bool { showOnRail && rexFound }

    init() {}

    // Every field may be missing or unreadable, as in BreakSettings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSettings()
        showOnRail = c.lenient(Bool.self, forKey: .showOnRail, in: decoder) ?? d.showOnRail
        sound = c.lenient(String.self, forKey: .sound, in: decoder) ?? d.sound
        waitAlert = c.lenient(Bool.self, forKey: .waitAlert, in: decoder) ?? d.waitAlert
        waitMinutes = max(1, c.lenient(Int.self, forKey: .waitMinutes, in: decoder) ?? d.waitMinutes)
        holdWhilePaused = c.lenient(Bool.self, forKey: .holdWhilePaused, in: decoder) ?? d.holdWhilePaused
        holdDuringCalls = c.lenient(Bool.self, forKey: .holdDuringCalls, in: decoder) ?? d.holdDuringCalls
        holdWhileLocked = c.lenient(Bool.self, forKey: .holdWhileLocked, in: decoder) ?? d.holdWhileLocked
    }
}

/// What the agents ring and its card show at a moment: the agents in the card's order. The active ones (waiting,
/// failed, just finished, working) set the ring's colour, number and tick; idle ones, and finished ones past their
/// 15 minutes, are in the ring only as grey bubbles behind them. Failed ones whose mark was cleared are left out.
struct AgentBoard: Equatable {
    /// In the card's order: waiting for you, failed, just finished, working, idle.
    enum State: Int { case waiting, failed, finished, working, idle }
    enum Tone { case quiet, waiting, failed }

    struct Row: Equatable, Identifiable {
        let agent: BreakAgent
        let state: State
        var id: String { agent.id }

        /// "Asks permission · 12 min", "Failed · 9 min ago", "Finished · just now", "Working", "Idle · 2 days 3 hr".
        func stateText(_ now: Date) -> String {
            let minutes = max(0, Int(now.timeIntervalSince(agent.since ?? now) / 60))
            let hours = minutes / 60, days = hours / 24
            // past a day the minutes go: "1 day 4 hr" is the point for an agent that has sat that long
            let time = minutes < 60 ? "\(minutes) min"
                : days < 1 ? (minutes % 60 == 0 ? "\(hours) hr" : "\(hours) hr \(minutes % 60) min")
                : "\(days) day\(days == 1 ? "" : "s")" + (hours % 24 == 0 ? "" : " \(hours % 24) hr")
            switch state {
            case .idle: return agent.since == nil || minutes < 1 ? "Idle" : "Idle · \(time)"
            case .waiting:
                let asks = switch agent.kind {
                case .permission: "Asks permission"
                case .question: "Asks a question"
                case .auth: "Asks you to sign in"
                case nil: "Waiting for you"
                }
                return minutes < 1 ? asks : "\(asks) · \(time)"
            case .failed: return minutes < 1 ? "Failed · just now" : "Failed · \(time) ago"
            case .finished: return minutes < 1 ? "Finished · just now" : "Finished · \(time) ago"
            case .working: return "Working"
            }
        }
    }

    var rows: [Row] = []

    init() {}

    /// `dismissed`: the failures whose × was clicked, by block, each with the time that failure began. One that fails
    /// again has a new time and shows again.
    init(_ agents: [BreakAgent], dismissed: [String: Date] = [:], now: Date) {
        let listed: [Row] = agents.compactMap { a in
            if a.blocked { return Row(agent: a, state: .waiting) }
            if a.failed { return a.since != nil && dismissed[a.id] == a.since ? nil : Row(agent: a, state: .failed) }
            if a.done, now.timeIntervalSince(a.since ?? now) < BreakAgent.celebration { return Row(agent: a, state: .finished) }
            return Row(agent: a, state: a.idle ? .idle : .working)   // a finish nobody looked at for 15 minutes is idle
        }
        // the longest wait on top; the latest failure and the latest finish first; working ones in a steady order; the
        // longest idle first, one whose time isn't known last
        rows = listed.sorted { a, b in
            if a.state != b.state { return a.state.rawValue < b.state.rawValue }
            switch a.state {
            case .waiting, .idle:
                let (x, y) = (a.agent.since ?? .distantFuture, b.agent.since ?? .distantFuture)
                if x != y { return x < y }
            case .failed, .finished:
                let (x, y) = (a.agent.since ?? .distantPast, b.agent.since ?? .distantPast)
                if x != y { return x > y }
            case .working: break
            }
            return a.id < b.id
        }
    }

    func count(_ state: State) -> Int { rows.filter { $0.state == state }.count }
    /// The rows without the idle ones: whose bubbles are in colour.
    var active: [Row] { rows.filter { $0.state != .idle } }
    /// Waiting or failed.
    var needsYou: Int { count(.waiting) + count(.failed) }
    /// The number under the ring: how many are working, until one needs you; then how many need you, which the
    /// ring's orange or red says. 0 with nobody working or waiting, as the other rings always carry a number.
    var number: Int { needsYou > 0 ? needsYou : count(.working) }
    var needing: [BreakAgent] { rows.filter { $0.state == .waiting || $0.state == .failed }.map(\.agent) }
    /// The ring's colour: red when any agent has failed, orange when one waits.
    var tone: Tone { count(.failed) > 0 ? .failed : count(.waiting) > 0 ? .waiting : .quiet }
    var justFinished: Bool { count(.finished) > 0 }

    /// The ring's bubbles: up to four agents' apps in the card's order, so the active ones come first, those who need
    /// you in front, and the idle ones last. The first `colour` are active and drawn in colour; the rest are idle
    /// and drawn grey. With more than four agents, three and how many more: the idle ones, unless over three are active.
    var bubbles: (apps: [BreakAgent.App], colour: Int, more: Int) {
        let apps = rows.map(\.agent.app), shown = apps.count > 4 ? 3 : apps.count
        return (Array(apps.prefix(shown)), min(shown, active.count), apps.count - shown)
    }

    /// The card's header: "3 need you · 2 working"; only finished agents, "2 finished"; only idle ones, "4 idle".
    var summary: String {
        let need = needsYou, working = count(.working), finished = count(.finished), idle = count(.idle)
        var parts = [need == 1 ? "1 needs you" : need > 1 ? "\(need) need you" : "", working > 0 ? "\(working) working" : ""].filter { !$0.isEmpty }
        if parts.isEmpty, finished > 0 { parts = ["\(finished) finished"] }
        if parts.isEmpty, idle > 0 { parts = ["\(idle) idle"] }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for the ring.
    var spoken: String {
        let waiting = count(.waiting), failed = count(.failed), finished = count(.finished), working = count(.working), idle = count(.idle)
        let parts = [waiting > 0 ? "\(waiting) waiting for you" : "", failed > 0 ? "\(failed) failed" : "",
                     finished > 0 ? "\(finished) just finished" : "", working > 0 ? "\(working) working" : ""].filter { !$0.isEmpty }
        return (parts.isEmpty ? ["No active agents"] : parts).joined(separator: ", ") + (idle > 0 ? ", \(idle) idle" : "")
    }

    /// The tick on the minimized rail: 4 pt for each agent that needs you, up to the rings' longest tick; none at 0.
    var tick: Double { needsYou == 0 ? 0 : min(20, 4 + 4 * Double(needsYou)) }

    /// Where `count` bubbles sit in the ring: each one's diameter, and their centres from the ring's centre, as
    /// shares of the ring's size. One is the plain icon; from two, discs that overlap and fill the ring: side by side
    /// on a slant, a triangle, a tilted square. All stay inside the ring's inner edge, 0.44 from the centre.
    static func bubblePlaces(_ count: Int) -> (diameter: Double, centres: [(x: Double, y: Double)]) {
        switch count {
        case ...1: (0.40, [(0, 0)])
        case 2: (0.46, [(-0.17, -0.05), (0.17, 0.05)])
        case 3: (0.42, [(-0.17, -0.11), (0.17, -0.09), (0, 0.19)])
        default: (0.37, [(-0.18, -0.151), (0.151, -0.18), (-0.151, 0.18), (0.18, 0.151)])
        }
    }
}

/// A quiet rule that is holding Pulse's own sound and alert for agents right now.
enum AgentHold: Equatable {
    case locked, onBreak, voiceCall, paused(until: Date), call, rexInFront

    /// The rule in force. Two hold always, with no switch: a break on screen, which covers the alert and makes Pulse
    /// the app in front, and Rex in front, where you're already there and Rex shows its own marks. `microphone` is
    /// read only when no rule before it holds: reading it costs a couple of milliseconds.
    static func current(_ s: AgentSettings, now: Date, locked: Bool, onBreak: Bool, voiceCall: Bool, pausedUntil: Date?,
                        rexInFront: Bool, microphone: () -> Bool) -> AgentHold? {
        if s.holdWhileLocked, locked { return .locked }
        if onBreak { return .onBreak }
        if s.holdDuringCalls, voiceCall { return .voiceCall }
        if s.holdWhilePaused, let until = pausedUntil, until > now { return .paused(until: until) }
        if s.holdDuringCalls, microphone() { return .call }
        return rexInFront ? .rexInFront : nil
    }

    /// A break holds while it's on screen and for 3 s after it: Pulse was the app in front for it, and what was in
    /// front before (Rex, perhaps) needs a moment to come back.
    static func breakHolds(onScreen: Bool, ended: Date, now: Date) -> Bool {
        onScreen || now.timeIntervalSince(ended) < 3
    }

    /// Whether the ring carries the bell with a stroke and the card says why: not for Rex in front, which is most of
    /// the day, and not for a lock or a break, when the rail can't be seen.
    var shown: Bool { self != .rexInFront && self != .locked && self != .onBreak }

    /// The card's last line while the rule holds. `time` writes the pause's end as a time of day.
    func line(_ time: (Date) -> String) -> String? {
        switch self {
        case let .paused(until): "Sounds and alerts wait until breaks resume at \(time(until))"
        case .call: "Sounds and alerts wait for your call to end"
        case .voiceCall: "Sounds and alerts wait for your voice call to end"
        case .locked, .onBreak, .rexInFront: nil
        }
    }

    /// The alert's second line once the rule is over.
    var after: String? {
        switch self {
        case .paused: "While breaks were paused"
        case .call: "During your call"
        case .voiceCall: "During your voice call"
        case .locked: "While the screen was locked"
        case .onBreak: "During your break"
        case .rexInFront: nil
        }
    }
}

/// Decides when Pulse's own sound and centre-screen alert fire for agents that need you. The sound comes once as a
/// wait begins. The alert comes once a wait it hasn't announced passes the chosen minutes, and then covers everyone
/// who needs you, so each wait is announced once. While a quiet rule holds, neither fires; afterwards one alert (or,
/// with the alert off, one sound) covers whoever still needs you.
struct AgentNotifier {
    struct Result: Equatable {
        var sound = false   // play the chosen sound
        var alert = false   // show the alert, or leave the open one up
        var after: AgentHold?   // the rule that held this alert back
    }

    private var sounded: [String: Date] = [:]   // block → the wait (when it began) whose sound has played or was held
    private var alerted: [String: Date] = [:]   // block → the wait an alert has covered
    private var heldBack: AgentHold?            // the rule that last held a sound or an alert
    private var owesSound = false

    /// `needing`: the agents that need you now (`AgentBoard.needing`). Call it when they change and every few seconds
    /// while there are any.
    mutating func step(_ needing: [BreakAgent], now: Date, settings: AgentSettings, hold: AgentHold?) -> Result {
        let waits = Dictionary(needing.map { ($0.id, $0.since ?? now) }) { first, _ in first }
        // an agent that was answered, or ran and waits again, starts over
        sounded = sounded.filter { waits[$0.key] == $0.value }
        alerted = alerted.filter { waits[$0.key] == $0.value }
        if needing.isEmpty { heldBack = nil; owesSound = false; return Result() }

        let fresh = needing.filter { sounded[$0.id] == nil }
        let due = settings.waitAlert && needing.contains {
            alerted[$0.id] == nil && now.timeIntervalSince(waits[$0.id] ?? now) >= Double(settings.waitMinutes) * 60
        }
        let wantsSound = !settings.sound.isEmpty && !fresh.isEmpty
        for agent in fresh { sounded[agent.id] = waits[agent.id] }
        if let hold {
            if wantsSound || due { heldBack = hold }
            if wantsSound { owesSound = true }
            return Result()
        }
        var result = Result()
        if due {
            for agent in needing { alerted[agent.id] = waits[agent.id] }
            result = Result(alert: true, after: heldBack)   // the alert has the system sound: no second one
        } else if wantsSound || (owesSound && !settings.sound.isEmpty) {
            result.sound = true
        }
        heldBack = nil
        owesSound = false
        return result
    }
}
