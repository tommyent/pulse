import Foundation

/// An agent another app runs, as Rex reports it: working, blocked (waiting for you), failed, or idle (idle or done).
struct BreakAgent: Equatable, Identifiable {
    enum App: String, CaseIterable {
        case claude = "claude-code", codex, antigravity, grok
        /// The name Rex reports: Grok Build runs as "grok-build".
        init?(rex name: String) { self.init(rawValue: name == "grok-build" ? "grok" : name) }
    }
    /// What a blocked agent waits for: approval, a typed answer, or a sign-in.
    enum Kind: String { case permission, question, auth }
    let id: String   // Rex's block id
    let app: App
    let blocked: Bool
    var idle = false
    var label = ""   // its pane's label
    var msg = ""
    var done = false   // finished in the last `celebration`, and not looked at yet (Rex's "done"); idle too
    var failed = false   // Rex's "error": it failed and stopped
    var kind: Kind?      // only while blocked
    var host = ""        // the Rex host its pane is on, as `-S` takes it; "" is this Mac
    var session = ""     // its pane's Rex session and tab, for showing the pane
    var window = ""
    var since: Date?     // when it began waiting, failed, finished or went idle
    var pid: Int32?      // the process that reported the status; a finished or failed one may have exited since

    /// Waiting for you, or failed: the two states that count on the rail.
    var needsYou: Bool { blocked || failed }

    /// How long a finished agent celebrates. Rex keeps "done" until the pane is looked at, hours later sometimes;
    /// after this it sleeps like any idle agent.
    static let celebration: TimeInterval = 15 * 60
    /// Who gets a place first on the break screen: those who need you, then working, then idle.
    var rank: Int { needsYou ? 0 : idle ? 2 : 1 }

    /// A report that repeats a wait or a failure (a new message, a snapshot read again) keeps the time it began.
    func keepingWait(of old: BreakAgent?) -> BreakAgent {
        guard let old, needsYou, old.blocked == blocked, old.failed == failed, old.kind == kind, let began = old.since else { return self }
        var kept = self
        kept.since = min(began, since ?? began)
        return kept
    }

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
    /// Stand-in agents for testing without Rex: `defaults write io.github.tommyent.pulse simulatedAgents "claude-code working,
    /// claude-code blocked permission 12, codex error"`. Each is an app and a state, then if wanted what a blocked one waits for
    /// (permission, question, auth) and how many minutes ago its state began. Also works as `--args -simulatedAgents "…"`.
    @objc dynamic var simulatedAgents: String? { string(forKey: "simulatedAgents") }
}

/// The servers the reader follows, each with the number of its current start. A host that was let go and taken up
/// again is a new start, so a retry still pending from the old one must not start a second stream beside the new one.
struct WatchedServers {
    private var starts: [String: Int] = [:]
    private var count = 0
    var servers: [String] { Array(starts.keys) }
    func contains(_ server: String) -> Bool { starts[server] != nil }
    func isCurrent(_ server: String, start: Int) -> Bool { starts[server] == start }
    mutating func watch(_ server: String) -> Int {
        count += 1
        starts[server] = count
        return count
    }
    mutating func unwatch(_ server: String) { starts[server] = nil }
    mutating func removeAll() { starts = [:] }   // the count goes on: an old start never matches a later one
}

/// Numbers requests so that only the latest counts: a newer click on a row makes an older one stale.
final class LatestRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0
    func next() -> Int { lock.withLock { latest += 1; return latest } }
    func isLatest(_ request: Int) -> Bool { lock.withLock { latest == request } }
}

/// Reads the agents Rex reports (https://www.superlogical.com/rex) while someone wants them: the rail's agents ring all
/// day, a break while it's on screen. One snapshot of every pane and Rex's event stream from just before it, until nobody
/// does. Every call passes `--autostart=false`, so Pulse never starts a Rex server; when Rex is missing or not running,
/// `agents` stays empty. This Mac's server and each host Rex connects to (`rex hosts`) are read on their own, so a host
/// that's off doesn't hold up or reset the others.
@MainActor
final class RexAgents: ObservableObject {
    /// Where a pane is: its label, its session and its tab, from the snapshot.
    struct Place: Equatable { var label = "", session = "", window = "" }

    @Published private(set) var agents: [BreakAgent] = []
    /// Each server's agents, by its `-S` value ("" is this Mac's).
    private var found: [String: [BreakAgent]] = [:] {
        didSet {
            var seen = Set<String>()   // a host that is this Mac under another name reports the same panes
            agents = found.keys.sorted().flatMap { found[$0] ?? [] }.filter { seen.insert($0.id).inserted }
        }
    }
    private var watching = WatchedServers()   // the servers followed: their stream is up, or waiting to start again
    private var streams: [String: Process] = [:]
    private var places: [String: [String: Place]] = [:]   // each server's panes by block id, as its latest snapshot had them
    private var pending: [String: [(String, BreakAgent?)]] = [:] // events that arrive while a server's snapshot runs, applied after it
    private var reading: [String: Int] = [:]   // each server's latest snapshot: an older one still running is dropped when it ends
    private var generation = 0
    private var users: Set<String> = []   // who wants the agents read
    private var rex: URL?
    private var asked: Set<String> = []   // panes the snapshot didn't have, each read for once
    private var readingSoon: Set<String> = []   // servers with that read already on its way
    private var simulation: NSKeyValueObservation?
    private let find: () -> URL?

    /// `find`: where the `rex` command is. Pulse looks in the usual places; a test can hand in its own.
    init(find: @escaping () -> URL? = { RexAgents.executable() }) { self.find = find }

    /// Reads while anyone wants it, and stops with the last one.
    func want(_ on: Bool, for user: String) {
        let was = !users.isEmpty
        if on { users.insert(user) } else { users.remove(user) }
        if users.isEmpty, was { stop() } else if !users.isEmpty, !was { start() }
    }

    private func start() {
        stop()
        if simulation == nil {
            // KVO also sees `defaults write` from another process: the stand-ins can change while the ring is on
            simulation = UserDefaults.standard.observe(\.simulatedAgents) { [weak self] _, _ in
                Task { @MainActor in
                    if let self, !self.users.isEmpty { self.start() }
                }
            }
        }
        if let simulated = UserDefaults.standard.simulatedAgents {
            agents = Self.simulated(simulated)
            return
        }
        guard let rex = find() else { return }
        self.rex = rex
        generation += 1
        let mine = generation
        watch(rex, "", mine)
        watchHosts(rex, mine)
        // shortcut: a full read every 10 minutes picks up a renamed pane and anything the stream missed, and the list
        // of hosts is read again with it; follow Rex's layout events instead if that ever proves too slow
        Task { @MainActor in
            while generation == mine {
                try? await Task.sleep(for: .seconds(600))
                guard generation == mine else { return }
                for server in watching.servers { read(rex, server, mine, again: false) }
                watchHosts(rex, mine)
            }
        }
    }

    /// The hosts Rex connects to. Read at the start, when Rex says its list changed, whenever this Mac's stream
    /// starts over and with every 10-minute read: a host added since is watched too, and one removed is let go. A
    /// listed host that can't be reached yet is watched all the same; its stream keeps trying.
    private func watchHosts(_ rex: URL, _ mine: Int) {
        Task.detached(priority: .utility) {
            let listed = Self.run(rex, ["hosts", "list", "--json"]).map(Self.hosts(fromList:))
            await MainActor.run {
                guard self.generation == mine, let listed else { return }   // a list that couldn't be read changes nothing
                for host in listed where !self.watching.contains(host) { self.watch(rex, host, mine) }
                for gone in self.watching.servers where !gone.isEmpty && !listed.contains(gone) { self.unwatch(gone) }
            }
        }
    }

    /// The stream starts first, so a change during the snapshot isn't lost.
    private func watch(_ rex: URL, _ server: String, _ mine: Int) {
        follow(rex, server, start: watching.watch(server))
        read(rex, server, mine, again: true)
    }

    /// A host that is no longer in Rex's list: its stream ends and its agents go.
    private func unwatch(_ server: String) {
        watching.unwatch(server)
        streams.removeValue(forKey: server)?.terminate()
        pending[server] = nil
        places[server] = nil
        found[server] = nil
    }

    /// A snapshot, with the events that arrive while it runs applied after it. The stream may not have subscribed yet
    /// during the first one, so a second read 3 s later catches a change that fell in between.
    private func read(_ rex: URL, _ server: String, _ mine: Int, again: Bool) {
        reading[server, default: 0] += 1
        let read = reading[server]
        pending[server] = []   // what an older snapshot had buffered is in this newer one
        Task.detached(priority: .utility) {
            let snapshot = Self.snapshot(rex, server)
            await MainActor.run {
                guard self.generation == mine, self.reading[server] == read, self.watching.contains(server) else { return }
                if let (agents, places) = snapshot {
                    self.places[server] = places   // replaced, not added to: closed panes go, renamed ones are renamed
                    let before = self.found[server] ?? []
                    self.found[server] = agents.map { agent in agent.keepingWait(of: before.first { $0.id == agent.id }) }
                } else if self.streams[server]?.isRunning != true {
                    self.found[server] = []   // the server is gone; with its stream still up, one failed read changes nothing
                }
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
        streams.values.forEach { $0.terminate() }   // Foundation collects the ended process: none is left as a zombie
        streams = [:]
        watching.removeAll()
        pending = [:]
        found = [:]
        places = [:]
        asked = []
        readingSoon = []
    }

    // MARK: the event stream

    /// A stream that ends on its own while it's wanted, or can't be started, starts again: after `retry` seconds,
    /// twice as long each time up to a minute, and from 2 s again once one has run for a minute. With Rex not running
    /// that's one short `rex` call a minute.
    private func follow(_ rex: URL, _ server: String, start: Int, retry: Double = 2) {
        let p = Process()
        p.executableURL = rex
        p.arguments = ["--autostart=false"] + Self.target(server) + ["events", "--all", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let started = (try? p.run()) != nil
        if started {
            // never two streams for one server: a Process that is only dropped leaves its child running
            if let old = streams[server], old.isRunning { old.terminate() }
            streams[server] = p
        }
        let mine = generation, began = Date()
        // ends when stop() terminates the process and its pipe closes
        Task.detached(priority: .utility) { [self] in
            if started {
                do {
                    for try await line in out.fileHandleForReading.bytes.lines {
                        // the stream carries every server event: only the few Pulse acts on are parsed
                        if server.isEmpty, line.contains("\"hosts_changed\"") {
                            await MainActor.run { if generation == mine { watchHosts(rex, mine) } }
                            continue
                        }
                        guard line.contains("program_status") || line.contains("block_closed"),
                              let update = Self.update(fromEvent: Data(line.utf8)) else { continue }
                        await MainActor.run {
                            guard generation == mine else { return }
                            apply(server, update.0, update.1)
                        }
                    }
                } catch {}   // the pipe closed: the stream is over
            }
            // it ended on its own while it's still wanted: start it again and read again, so nothing freezes
            let lived = started ? Date().timeIntervalSince(began) : 0
            try? await Task.sleep(for: .seconds(retry))
            await MainActor.run {
                // not if the host was let go meanwhile, even if it's being followed again: that start has its own stream
                guard generation == mine, watching.isCurrent(server, start: start) else { return }
                follow(rex, server, start: start, retry: Self.nextRetry(after: retry, lived: lived))
                read(rex, server, mine, again: true)   // a second read once the new stream has surely subscribed
                if server.isEmpty { watchHosts(rex, mine) }
            }
        }
    }

    /// How long to wait before the start after next: 2 s once a stream has run for a minute, else twice as long as
    /// last time, up to a minute.
    nonisolated static func nextRetry(after retry: Double, lived: TimeInterval) -> Double {
        lived > 60 ? 2 : min(retry * 2, 60)
    }

    private func apply(_ server: String, _ block: String, _ agent: BreakAgent?) {
        if pending[server] != nil { pending[server]?.append((block, agent)); return }
        var list = found[server] ?? []
        let old = list.first { $0.id == block }
        list.removeAll { $0.id == block }
        if var agent {
            let place = places[server]?[block]
            agent.label = place?.label ?? ""
            agent.host = server
            if agent.session.isEmpty { agent.session = place?.session ?? "" }
            agent.window = place?.window ?? ""
            list.append(agent.keepingWait(of: old))
            if place == nil { readSoon(server, for: block) }
        }
        found[server] = list
    }

    /// A pane opened since the snapshot has no label yet: one more read 2 s on. Panes that appear together share
    /// that one read, and each pane asks for it once.
    private func readSoon(_ server: String, for block: String) {
        guard let rex, asked.insert(block).inserted, readingSoon.insert(server).inserted else { return }
        let mine = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard generation == mine else { return }
            readingSoon.remove(server)
            read(rex, server, mine, again: false)
        }
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

    /// Every session's terminal panes on `server` and the agent status each reports. nil when that server isn't
    /// running or can't be reached. A host's panes carry its name in `host`, apart from their label: "fix-tests" on
    /// "studio".
    nonisolated static func snapshot(_ rex: URL, _ server: String) -> ([BreakAgent], [String: Place])? {
        guard let list = run(rex, ["api", "call", "session.list"], on: server),
              let sessions = (try? JSONSerialization.jsonObject(with: list) as? [String: Any])?["sessions"] as? [[String: Any]]
        else { return nil }
        var found: [BreakAgent] = [], places: [String: Place] = [:]
        for session in sessions.compactMap({ $0["session_id"] as? String }) {
            guard let ls = run(rex, ["block", "ls", "-s", session, "--json"], on: server),
                  let blocks = (try? JSONSerialization.jsonObject(with: ls) as? [String: Any])?["blocks"] as? [[String: Any]]
            else { continue }
            for block in blocks {
                guard let id = block["block_id"] as? String,
                      (block["flavor"] as? String)?.hasPrefix("com.superlogical.terminal") == true else { continue }
                let place = Place(label: block["label"] as? String ?? "", session: session, window: block["window_id"] as? String ?? "")
                places[id] = place
                guard let status = run(rex, ["block", "call", "-s", session, "-b", id, "program_status"], on: server),
                      var agent = agent(fromStatus: status, block: id) else { continue }
                agent.label = place.label
                agent.host = server
                agent.session = session
                agent.window = place.window
                found.append(agent)
            }
        }
        return (found, places)
    }

    // MARK: showing a pane

    /// Brings an agent's pane forward as far as the `rex` command can: the pane gets the focus in its session, and the
    /// Rex app on this Mac is asked to go to that session and tab. The app does that only with its Remote Control
    /// setting on. The caller then brings Rex to the front.
    /// `current` is asked before each request: once it says no (a newer click), nothing more is sent.
    nonisolated static func show(_ agent: BreakAgent, rex: URL, thisMac: String, current: () -> Bool = { true }) {
        guard !agent.session.isEmpty, current() else { return }
        _ = run(rex, ["block", "focus", "-s", agent.session, agent.id], on: agent.host)
        guard current() else { return }
        let here = run(rex, ["client", "ls", "--json"]).flatMap(localApp(fromList:))
        // a pane on another host is shown by this Mac's app too: it's asked through that host's server, where it is
        // one of the network clients
        let client = agent.host.isEmpty ? here?.id
            : run(rex, ["client", "ls", "--json"], on: agent.host).flatMap { remoteApp(fromList: $0, label: here?.label ?? thisMac) }
        guard let client, current() else { return }
        _ = run(rex, ["-C", client] + selectArguments(agent), on: agent.host)
    }

    /// The Rex app's own action for going to a session, and to the pane's tab when the snapshot knew it.
    nonisolated static func selectArguments(_ agent: BreakAgent) -> [String] {
        ["do", "session.select", "session_id=\(agent.session)"] + (agent.window.isEmpty ? [] : ["window_id=\(agent.window)"])
    }

    /// The Rex apps in `rex client ls --json`: each one's id, its label, and whether it's on that server's own Mac
    /// (connected over the local socket).
    nonisolated private static func apps(fromList data: Data) -> [(id: String, label: String, onServersMac: Bool)] {
        let clients = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["clients"] as? [[String: Any]] ?? []
        return clients.compactMap { client in
            guard let info = client["info"] as? [String: Any], info["kind"] as? String == "app",
                  let id = client["client_id"] as? String else { return nil }
            return (id, info["label"] as? String ?? "", (client["principal"] as? [String: Any])?["transport"] as? String == "unix")
        }
    }

    /// This Mac's Rex app in the client list of this Mac's own server: the app on the local socket.
    nonisolated static func localApp(fromList data: Data) -> (id: String, label: String)? {
        apps(fromList: data).first { $0.onServersMac }.map { ($0.id, $0.label) }
    }

    /// This Mac's Rex app in the client list of another host's server. There it's a network client: the app on that
    /// server's local socket is the host's own and is never asked. `label` is the one this Mac's app has on its own
    /// server (or this Mac's name); with no app under it, the only network app there is, and with several, none.
    nonisolated static func remoteApp(fromList data: Data, label: String) -> String? {
        let network = apps(fromList: data).filter { !$0.onServersMac }
        return (network.first { !label.isEmpty && $0.label == label } ?? (network.count == 1 ? network[0] : nil))?.id
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

    nonisolated static func agent(fromRecord record: [String: Any], block: String, now: Date = .now) -> BreakAgent? {
        guard let name = record["app"] as? String ?? record["effective_app"] as? String,
              let app = BreakAgent.App(rex: name) else { return nil }
        let msg = plain(record["msg"] as? String ?? "")
        let at = (record["updated_at"] as? String).flatMap(date)   // an event without one has just happened
        var agent: BreakAgent
        switch record["state"] as? String {
        case "working": agent = BreakAgent(id: block, app: app, blocked: false, msg: msg)
        case "blocked":
            agent = BreakAgent(id: block, app: app, blocked: true, msg: msg,
                               kind: (record["kind"] as? String).flatMap(BreakAgent.Kind.init(rawValue:)), since: at ?? now)
        case "error": agent = BreakAgent(id: block, app: app, blocked: false, msg: msg, failed: true, since: at ?? now)
        case "idle": agent = BreakAgent(id: block, app: app, blocked: false, idle: true, since: at ?? now)
        case "done":
            agent = BreakAgent(id: block, app: app, blocked: false, idle: true, msg: msg,
                               done: at.map { now.timeIntervalSince($0) < BreakAgent.celebration } ?? true, since: at ?? now)
        default: return nil   // states Rex adds later
        }
        // the process that reported the status, which the idle rows' context is found through
        agent.pid = ((record["owner"] as? [String: Any])?["pid"] as? Int).flatMap(Int32.init(exactly:))
        return agent
    }

    /// A status line is untrusted text from whatever runs in the pane. Pulse shows it as plain text, without the
    /// invisible formatting characters (direction overrides and the like) that could reorder the words around it.
    nonisolated static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.generalCategory != .format && $0.properties.generalCategory != .control
        }))
    }

    /// Rex's times, such as "2026-10-26T01:35:14.24817-04:00".
    nonisolated static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A line of `rex events --all --json`: (block, its agent now, or nil when its program stopped reporting or its pane
    /// closed). nil for every other event.
    nonisolated static func update(fromEvent line: Data) -> (String, BreakAgent?)? {
        guard let top = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              top["type"] as? String == "session_event",
              let session = top["payload"] as? [String: Any],
              let event = session["event"] as? [String: Any],
              let blockEvent = event["payload"] as? [String: Any],
              let block = blockEvent["block_id"] as? String else { return nil }
        if event["type"] as? String == "block_closed" { return (block, nil) }
        guard event["type"] as? String == "block_event", let payload = blockEvent["payload"] as? [String: Any] else { return nil }
        switch blockEvent["name"] as? String {
        case "program_status_changed":
            guard (payload["id"] as? String ?? "").isEmpty, let record = payload["record"] as? [String: Any] else { return nil }
            var agent = agent(fromRecord: record, block: block)
            agent?.session = session["session_id"] as? String ?? ""
            return (block, agent)
        case "program_status_removed":
            guard (payload["ids"] as? [String])?.contains("") ?? true else { return nil }
            return (block, nil)
        default:
            return nil
        }
    }

    /// "claude-code working, codex blocked permission 12" → stand-in agents labelled with their position. After the
    /// app and the state come, in either order, what a blocked one waits for and how many minutes ago its state began.
    nonisolated static func simulated(_ text: String, now: Date = .now) -> [BreakAgent] {
        text.split(separator: ",").enumerated().compactMap { i, item in
            let parts = item.split(separator: " ").map(String.init)
            guard parts.count >= 1 else { return nil }
            var record = ["app": parts[0], "state": parts.count > 1 ? parts[1] : "working", "msg": "Stand-in agent \(i + 1)"]
            let extras = parts.dropFirst(2)
            if let kind = extras.first(where: { BreakAgent.Kind(rawValue: $0) != nil }) { record["kind"] = kind }
            let minutesAgo = extras.compactMap { Double($0) }.first ?? 0
            return agent(fromRecord: record, block: "simulated-\(i)", now: now.addingTimeInterval(-minutesAgo * 60))
                .map { var a = $0; a.label = "\(parts[0]) \(i + 1)"; return a }
        }
    }
}
