import Foundation

/// An agent another app runs, as Rex reports it: working, blocked (waiting for you) or idle (idle or done).
struct BreakAgent: Equatable, Identifiable {
    enum App: String, CaseIterable {
        case claude = "claude-code", codex, antigravity, grok
        /// The name Rex reports: Grok Build runs as "grok-build".
        init?(rex name: String) { self.init(rawValue: name == "grok-build" ? "grok" : name) }
    }
    let id: String   // Rex's block id
    let app: App
    let blocked: Bool
    var idle = false
    var label = ""
    var msg = ""
    /// Who gets a place first on the break screen: blocked, then working, then idle.
    var rank: Int { blocked ? 0 : idle ? 2 : 1 }

    /// Fills `spots` floating places with agents, then the pet's `helpers`; when some don't fit, the last place says
    /// how many (`more`), so it holds no agent. With no places at all, everyone not walking counts as `more`.
    static func crowd(_ agents: [BreakAgent], lanes: Int, spots: Int, helpers: Int)
        -> (shown: (walkers: [BreakAgent], floaters: [BreakAgent], hidden: [BreakAgent]), helpers: Int, more: Int) {
        func fit(_ n: Int) -> (shown: (walkers: [BreakAgent], floaters: [BreakAgent], hidden: [BreakAgent]), helpers: Int, more: Int) {
            let shown = onScreen(agents, lanes: lanes, slots: n)
            let fitted = min(helpers, max(0, n - shown.floaters.count))
            return (shown, fitted, shown.hidden.count + helpers - fitted)
        }
        let all = fit(spots)
        return all.more > 0 && spots > 0 ? fit(spots - 1) : all
    }

    /// Who the break screen draws: Claude and Codex agents walk in `lanes`; everyone else floats as a ring in
    /// `slots`, other apps first, then the agents the lanes had no room for. Each app that has an agent gets its
    /// best one in first (so busy Claude agents can't hide every Codex one), then the rest by rank. `hidden`: who
    /// didn't fit even there, by rank.
    static func onScreen(_ agents: [BreakAgent], lanes: Int, slots: Int) -> (walkers: [BreakAgent], floaters: [BreakAgent], hidden: [BreakAgent]) {
        let ranked = agents.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
        func fill(_ group: [BreakAgent], _ n: Int) -> [BreakAgent] {
            var out = Array(App.allCases.compactMap { app in group.first { $0.app == app } }.prefix(n))
            for a in group where out.count < n && !out.contains(a) { out.append(a) }
            return out.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }   // by id within a rank, so places don't swap
        }
        let walkers = fill(ranked.filter { $0.app == .claude || $0.app == .codex }, lanes)
        let walking = Set(walkers.map(\.id))
        let others = ranked.filter { !walking.contains($0.id) }
        let floaters = fill(others.filter { $0.app != .claude && $0.app != .codex }, slots)
        let ringed = floaters + others.filter { $0.app == .claude || $0.app == .codex }.prefix(max(0, slots - floaters.count))
        let shown = walking.union(ringed.map(\.id))
        return (walkers, ringed, ranked.filter { !shown.contains($0.id) })
    }
}

extension UserDefaults {
    /// Stand-in agents for testing without Rex: `defaults write app.pulse simulatedAgents "claude-code working,
    /// claude-code blocked, codex working"`. Also works as `--args -simulatedAgents "…"`.
    @objc dynamic var simulatedAgents: String? { string(forKey: "simulatedAgents") }
}

/// Reads the agents Rex reports (https://www.superlogical.com/rex), only while a break is on screen: one
/// snapshot of every pane and Rex's event stream from just before it, until `stop()`. Every call passes `--autostart=false`, so Pulse
/// never starts a Rex server; when Rex is missing or not running, `agents` stays empty. This Mac's server and each host
/// Rex connects to (`rex hosts`) are read on their own, so a host that's off doesn't hold up or reset the others.
@MainActor
final class RexAgents: ObservableObject {
    @Published private(set) var agents: [BreakAgent] = []
    /// Each server's agents, by its `-S` value ("" is this Mac's).
    private var found: [String: [BreakAgent]] = [:] {
        didSet {
            var seen = Set<String>()   // a host that is this Mac under another name reports the same panes
            agents = found.keys.sorted().flatMap { found[$0] ?? [] }.filter { seen.insert($0.id).inserted }
        }
    }
    private var streams: [String: Process] = [:]
    private var labels: [String: String] = [:]   // block id → pane label, from the snapshot
    private var pending: [String: [(String, BreakAgent?)]] = [:] // events that arrive while a server's snapshot runs, applied after it
    private var reading: [String: Int] = [:]   // each server's latest snapshot: an older one still running is dropped when it ends
    private var generation = 0

    func start() {
        stop()
        if let simulated = UserDefaults.standard.simulatedAgents {
            agents = Self.simulated(simulated)
            return
        }
        guard let rex = Self.executable() else { return }
        generation += 1
        let mine = generation
        watch(rex, "", mine)
        Task.detached(priority: .utility) {
            let hosts = Self.run(rex, ["hosts", "list", "--json"]).map(Self.hosts(fromList:)) ?? []
            await MainActor.run {
                guard self.generation == mine else { return }
                for host in hosts { self.watch(rex, host, mine) }
            }
        }
    }

    /// The stream starts first, so a change during the snapshot isn't lost.
    private func watch(_ rex: URL, _ server: String, _ mine: Int) {
        follow(rex, server)
        read(rex, server, mine, again: true)
    }

    /// A snapshot, with the events that arrive while it runs applied after it. The stream may not have subscribed yet
    /// during the first one, so a second read 3 s later catches a change that fell in between.
    private func read(_ rex: URL, _ server: String, _ mine: Int, again: Bool) {
        reading[server, default: 0] += 1
        let read = reading[server]
        pending[server] = []   // what an older snapshot had buffered is in this newer one
        Task.detached(priority: .utility) {
            let (agents, labels) = Self.snapshot(rex, server)
            await MainActor.run {
                guard self.generation == mine, self.reading[server] == read else { return }
                self.labels.merge(labels) { _, new in new }
                self.found[server] = agents
                let later = self.pending.removeValue(forKey: server) ?? []
                for (block, agent) in later { self.apply(server, block, agent) }
                guard again else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if self.generation == mine { self.read(rex, server, mine, again: false) }
                }
            }
        }
    }

    func stop() {
        generation += 1
        streams.values.forEach { $0.terminate() }
        streams = [:]
        pending = [:]
        found = [:]
    }

    // MARK: the event stream

    /// `restarts`: how many more times the stream may be started again if it ends on its own during a break.
    private func follow(_ rex: URL, _ server: String, restarts: Int = 3) {
        let p = Process()
        p.executableURL = rex
        p.arguments = ["--autostart=false"] + Self.target(server) + ["events", "--all", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        streams[server] = p
        let mine = generation
        // ends when stop() terminates the process and its pipe closes
        Task.detached(priority: .utility) { [self] in
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    guard let update = Self.update(fromEvent: Data(line.utf8)) else { continue }
                    await MainActor.run {
                        guard generation == mine else { return }
                        apply(server, update.0, update.1)
                    }
                }
            } catch {}   // the pipe closed: the stream is over
            // it ended on its own while the break is still on: start it again and read again, so nothing freezes
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard generation == mine, restarts > 0 else { return }
                follow(rex, server, restarts: restarts - 1)
                read(rex, server, mine, again: true)   // a second read once the new stream has surely subscribed
            }
        }
    }

    private func apply(_ server: String, _ block: String, _ agent: BreakAgent?) {
        if pending[server] != nil { pending[server]?.append((block, agent)); return }
        var list = found[server] ?? []
        list.removeAll { $0.id == block }
        if var agent {
            agent.label = labels[block] ?? ""
            list.append(agent)
        }
        found[server] = list
    }

    // MARK: finding and calling rex

    /// Where Pulse looks for `rex`: the usual CLI folders, then Rex's own app folder. Apps opened from Finder don't
    /// get the shell's PATH.
    nonisolated static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            home.appending(path: ".local/bin/rex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rex"),
            URL(fileURLWithPath: "/usr/local/bin/rex"),
            home.appending(path: "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Every session's terminal panes on `server` and the agent status each reports. Empty when that server isn't
    /// running or can't be reached. A host's panes are labelled with its name: "fix-tests on mini".
    nonisolated static func snapshot(_ rex: URL, _ server: String) -> ([BreakAgent], [String: String]) {
        guard let list = run(rex, ["api", "call", "session.list"], on: server),
              let sessions = (try? JSONSerialization.jsonObject(with: list) as? [String: Any])?["sessions"] as? [[String: Any]]
        else { return ([], [:]) }
        var found: [BreakAgent] = [], labels: [String: String] = [:]
        for session in sessions.compactMap({ $0["session_id"] as? String }) {
            guard let ls = run(rex, ["block", "ls", "-s", session, "--json"], on: server),
                  let blocks = (try? JSONSerialization.jsonObject(with: ls) as? [String: Any])?["blocks"] as? [[String: Any]]
            else { continue }
            for block in blocks {
                guard let id = block["block_id"] as? String,
                      (block["flavor"] as? String)?.hasPrefix("com.superlogical.terminal") == true else { continue }
                labels[id] = [block["label"] as? String ?? "", server].filter { !$0.isEmpty }.joined(separator: " on ")
                guard let status = run(rex, ["block", "call", "-s", session, "-b", id, "program_status"], on: server),
                      var agent = agent(fromStatus: status, block: id) else { continue }
                agent.label = labels[id] ?? ""
                found.append(agent)
            }
        }
        return (found, labels)
    }

    nonisolated private static func target(_ server: String) -> [String] { server.isEmpty ? [] : ["-S", server] }

    /// One short `rex` call to `server`: its output, or nil on failure or after 5 s.
    nonisolated private static func run(_ rex: URL, _ args: [String], on server: String = "") -> Data? {
        let p = Process()
        p.executableURL = rex
        p.arguments = ["--autostart=false", "--timeout", "3s"] + target(server) + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? data : nil
    }

    // MARK: parsing (the checks cover these)

    /// `rex hosts list --json`: the other Rex servers this Mac connects to, by the label `-S` takes.
    nonisolated static func hosts(fromList data: Data) -> [String] {
        let hosts = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hosts"] as? [[String: Any]] ?? []
        return hosts.compactMap { ($0["host"] as? [String: Any])?["label"] as? String }.filter { !$0.isEmpty }
    }

    /// `program_status`'s reply: its root record, the one without an id.
    nonisolated static func agent(fromStatus data: Data, block: String) -> BreakAgent? {
        guard let records = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["records"] as? [[String: Any]],
              let root = records.first(where: { ($0["id"] as? String ?? "").isEmpty }) else { return nil }
        return agent(fromRecord: root, block: block)
    }

    nonisolated static func agent(fromRecord record: [String: Any], block: String) -> BreakAgent? {
        guard let name = record["app"] as? String ?? record["effective_app"] as? String,
              let app = BreakAgent.App(rex: name) else { return nil }
        switch record["state"] as? String {
        case "working": return BreakAgent(id: block, app: app, blocked: false, msg: record["msg"] as? String ?? "")
        case "blocked": return BreakAgent(id: block, app: app, blocked: true, msg: record["msg"] as? String ?? "")
        case "idle", "done": return BreakAgent(id: block, app: app, blocked: false, idle: true)
        default: return nil   // error and states Rex adds later
        }
    }

    /// A line of `rex events --all --json`: (block, its agent now, or nil when its program stopped reporting). nil for every
    /// other event.
    nonisolated static func update(fromEvent line: Data) -> (String, BreakAgent?)? {
        guard let top = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              top["type"] as? String == "session_event",
              let event = (top["payload"] as? [String: Any])?["event"] as? [String: Any],
              event["type"] as? String == "block_event",
              let blockEvent = event["payload"] as? [String: Any],
              let block = blockEvent["block_id"] as? String,
              let payload = blockEvent["payload"] as? [String: Any] else { return nil }
        switch blockEvent["name"] as? String {
        case "program_status_changed":
            guard (payload["id"] as? String ?? "").isEmpty, let record = payload["record"] as? [String: Any] else { return nil }
            return (block, agent(fromRecord: record, block: block))
        case "program_status_removed":
            guard (payload["ids"] as? [String])?.contains("") ?? true else { return nil }
            return (block, nil)
        default:
            return nil
        }
    }

    /// "claude-code working, codex blocked" → stand-in agents labelled with their position.
    nonisolated static func simulated(_ text: String) -> [BreakAgent] {
        text.split(separator: ",").enumerated().compactMap { i, item in
            let parts = item.split(separator: " ").map(String.init)
            guard parts.count >= 1 else { return nil }
            return agent(fromRecord: ["app": parts[0], "state": parts.count > 1 ? parts[1] : "working",
                                      "msg": "Stand-in agent \(i + 1)"], block: "simulated-\(i)")
                .map { var a = $0; a.label = "\(parts[0]) \(i + 1)"; return a }
        }
    }
}
