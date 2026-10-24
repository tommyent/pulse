import Foundation

/// An agent another app runs, as Rex reports it: only working and blocked ones are kept.
struct BreakAgent: Equatable, Identifiable {
    enum App: String, CaseIterable { case claude = "claude-code", codex, antigravity, grok }
    let id: String   // Rex's block id
    let app: App
    let blocked: Bool
    var label = ""
    var msg = ""
}

extension UserDefaults {
    /// Stand-in agents for testing without Rex: `defaults write app.pulse simulatedAgents "claude-code working,
    /// claude-code blocked, codex working"`. Also works as `--args -simulatedAgents "…"`.
    @objc dynamic var simulatedAgents: String? { string(forKey: "simulatedAgents") }
}

/// Reads which agents are working from Rex (https://www.superlogical.com/rex), only while a break is on screen: one
/// snapshot of every pane, then Rex's event stream until `stop()`. Every call passes `--autostart=false`, so Pulse
/// never starts a Rex server; when Rex is missing or not running, `agents` stays empty.
@MainActor
final class RexAgents: ObservableObject {
    @Published private(set) var agents: [BreakAgent] = []
    private var stream: Process?
    private var labels: [String: String] = [:]   // block id → pane label, from the snapshot
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
        Task.detached(priority: .utility) {
            let (found, labels) = Self.snapshot(rex)
            await MainActor.run {
                guard self.generation == mine else { return }
                self.labels = labels
                self.agents = found
                self.follow(rex)
            }
        }
    }

    func stop() {
        generation += 1
        stream?.terminate()
        stream = nil
        agents = []
    }

    // MARK: the event stream

    private func follow(_ rex: URL) {
        let p = Process()
        p.executableURL = rex
        p.arguments = ["--autostart=false", "events", "--all", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        stream = p
        let mine = generation
        // ends when stop() terminates the process and its pipe closes
        Task.detached(priority: .utility) { [self] in
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    guard let update = Self.update(fromEvent: Data(line.utf8)) else { continue }
                    await MainActor.run {
                        guard generation == mine else { return }
                        apply(update.0, update.1)
                    }
                }
            } catch {}   // the pipe closed: the stream is over
        }
    }

    private func apply(_ block: String, _ agent: BreakAgent?) {
        agents.removeAll { $0.id == block }
        guard var agent else { return }
        agent.label = labels[block] ?? ""
        agents.append(agent)
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

    /// Every session's terminal panes and the agent status each reports. Empty when Rex isn't running.
    nonisolated static func snapshot(_ rex: URL) -> ([BreakAgent], [String: String]) {
        guard let list = run(rex, ["api", "call", "session.list"]),
              let sessions = (try? JSONSerialization.jsonObject(with: list) as? [String: Any])?["sessions"] as? [[String: Any]]
        else { return ([], [:]) }
        var found: [BreakAgent] = [], labels: [String: String] = [:]
        for session in sessions.compactMap({ $0["session_id"] as? String }) {
            guard let ls = run(rex, ["block", "ls", "-s", session, "--json"]),
                  let blocks = (try? JSONSerialization.jsonObject(with: ls) as? [String: Any])?["blocks"] as? [[String: Any]]
            else { continue }
            for block in blocks {
                guard let id = block["block_id"] as? String,
                      (block["flavor"] as? String)?.hasPrefix("com.superlogical.terminal") == true else { continue }
                labels[id] = block["label"] as? String ?? ""
                guard let status = run(rex, ["block", "call", "-s", session, "-b", id, "program_status"]),
                      var agent = agent(fromStatus: status, block: id) else { continue }
                agent.label = labels[id] ?? ""
                found.append(agent)
            }
        }
        return (found, labels)
    }

    /// One short `rex` call: its output, or nil on failure or after 5 s.
    nonisolated private static func run(_ rex: URL, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = rex
        p.arguments = ["--autostart=false", "--timeout", "3s"] + args
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

    /// `program_status`'s reply: its root record, the one without an id.
    nonisolated static func agent(fromStatus data: Data, block: String) -> BreakAgent? {
        guard let records = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["records"] as? [[String: Any]],
              let root = records.first(where: { ($0["id"] as? String ?? "").isEmpty }) else { return nil }
        return agent(fromRecord: root, block: block)
    }

    nonisolated static func agent(fromRecord record: [String: Any], block: String) -> BreakAgent? {
        guard let name = record["app"] as? String ?? record["effective_app"] as? String,
              let app = BreakAgent.App(rawValue: name) else { return nil }
        switch record["state"] as? String {
        case "working": return BreakAgent(id: block, app: app, blocked: false, msg: record["msg"] as? String ?? "")
        case "blocked": return BreakAgent(id: block, app: app, blocked: true, msg: record["msg"] as? String ?? "")
        default: return nil   // idle, done, error and states Rex adds later
        }
    }

    /// A line of `rex events --all --json`: (block, its agent now, or nil when it stopped working). nil for every
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
