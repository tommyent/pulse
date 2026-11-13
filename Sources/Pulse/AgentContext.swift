import Darwin
import Foundation

/// How full an idle agent's context is, read from the agent's own session data on this Mac. Rex's status doesn't
/// carry it, so each app is read its own way, and only where the pane leads to one session with certainty:
///
/// - Claude Code notes each running session under its process number (`~/.claude/sessions/<pid>.json`); the session's
///   transcript ends with the tokens of its last reply. The transcript doesn't say how large the model's context is,
///   so Claude's shows as tokens, not as a percentage.
/// - Codex keeps its session file open while it runs; the file's token counts name the model's context size.
/// - Grok keeps its session's event log open; `signals.json` beside it holds the tokens and the context size.
/// - Antigravity: nothing known to read.
///
/// Nothing is shown for an agent on another Mac, for one whose process has gone (or whose process number now belongs
/// to something started later), or when the process leads to no session or to more than one.
struct AgentContext: Equatable {
    var tokens: Int
    var window: Int?   // nil when the session data doesn't say how large the model's context is

    /// "Context 71%", or "Context 719k tokens" where only the tokens are known. Rounded down, as Grok rounds its own.
    var text: String {
        if let window, window > 0 { return "Context \(min(100, tokens * 100 / window))%" }
        if tokens >= 1_000_000 { return "Context \(tokens / 1_000_000).\(tokens % 1_000_000 / 100_000)M tokens" }
        return tokens >= 1000 ? "Context \(tokens / 1000)k tokens" : "Context \(tokens) tokens"
    }

    /// What Pulse asks macOS about an agent's process. Neither needs a permission for the user's own processes. A check
    /// hands in its own.
    struct Processes {
        var started: (Int32) -> Date?        // nil when the process is gone
        var openFiles: (Int32) -> [String]
        static let live = Processes(started: AgentContext.started, openFiles: AgentContext.openFiles)
    }

    static func read(_ agent: BreakAgent, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     processes: Processes = .live) -> AgentContext? {
        // the process that reported the status, still running: one started after the report only shares its number
        guard agent.host.isEmpty, let pid = agent.pid, let since = agent.since,
              let started = processes.started(pid), started <= since else { return nil }
        switch agent.app {
        case .claude:
            guard let record = try? Data(contentsOf: home.appending(path: ".claude/sessions/\(pid).json")),
                  let session = claudeSession(fromRecord: record, pid: pid),
                  let transcript = claudeTranscript(session, home: home) else { return nil }
            // a reply's line is usually near the end; one long tool result can push it further back
            return tail(transcript, 512 << 10).flatMap(claudeContext) ?? tail(transcript, 4 << 20).flatMap(claudeContext)
        case .codex:
            let files = processes.openFiles(pid).filter { $0.contains("/.codex/sessions/") && $0.hasSuffix(".jsonl") }
            let kinds = files.map { codexIsOwnThread(firstLine(URL(fileURLWithPath: $0))) }
            // one that can't be told apart might be a second conversation: then no number at all
            guard !kinds.contains(nil) else { return nil }
            let own = zip(files, kinds).filter { $0.1 == true }.map { $0.0 }
            guard own.count == 1 else { return nil }
            return tail(URL(fileURLWithPath: own[0]), 512 << 10).flatMap(codexContext)
        case .grok:
            let logs = Set(processes.openFiles(pid).filter { $0.contains("/.grok/sessions/") && $0.hasSuffix("/events.jsonl") })
            guard logs.count == 1, let log = logs.first else { return nil }
            let signals = URL(fileURLWithPath: log).deletingLastPathComponent().appending(path: "signals.json")
            return (try? Data(contentsOf: signals)).flatMap(grokContext)
        case .antigravity:
            return nil
        }
    }

    /// Which idle agents' context has been looked for. Each is read once for its idle spell, found or not: at rest
    /// neither its context nor the reason nothing was found changes, and a miss costs megabytes of transcript.
    struct Reads {
        private var spells: [String: Date] = [:]   // block → the idle spell (when it began) already read for

        /// Forgets the agents that are no longer idle, or went idle anew, and returns the ones still to read: on this
        /// Mac, with a process and a time to check it by.
        mutating func wanted(among idle: [BreakAgent]) -> [BreakAgent] {
            let now = Dictionary(idle.compactMap { agent in agent.since.map { (agent.id, $0) } }) { first, _ in first }
            spells = spells.filter { now[$0.key] == $0.value }
            return idle.filter { $0.host.isEmpty && $0.pid != nil && $0.since != nil && spells[$0.id] == nil }
        }

        /// Whether a number read earlier still belongs to the agent's idle spell.
        func covers(_ id: String) -> Bool { spells[id] != nil }

        mutating func read(_ agent: BreakAgent) { spells[agent.id] = agent.since }
    }

    // MARK: Claude Code

    /// `~/.claude/sessions/<pid>.json`: the id of the session that process runs, when the record is that process's own.
    static func claudeSession(fromRecord data: Data, pid: Int32) -> String? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["pid"] as? Int == Int(pid), let id = record["sessionId"] as? String,
              !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }   // a file name, never a path
        return id
    }

    /// The session's transcript: `<session>.jsonl` in the one project folder that has it. nil when it's in none, or in
    /// several: an old copy left in another folder can't be told from the live one. Every folder is looked in, the
    /// one named after the working folder included.
    static func claudeTranscript(_ session: String, home: URL) -> URL? {
        let projects = home.appending(path: ".claude/projects"), fm = FileManager.default
        let found = ((try? fm.contentsOfDirectory(atPath: projects.path)) ?? [])
            .map { projects.appending(path: $0).appending(path: "\(session).jsonl") }
            .filter { fm.fileExists(atPath: $0.path) }
        return found.count == 1 ? found[0] : nil
    }

    /// The tokens of the last reply in the main conversation (a helper's replies are its own context): what was sent,
    /// read from and written to the cache, and what came back.
    static func claudeContext(_ tail: Data) -> AgentContext? {
        for line in tail.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
                  let usage = (entry["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
                .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            if tokens > 0 { return AgentContext(tokens: tokens, window: nil) }   // Pulse's own notices carry none
        }
        return nil
    }

    // MARK: Codex

    /// A session file's first line: true for the conversation itself, false for a helper's thread, which the same
    /// process also keeps open, and nil when the line can't be read or isn't the session's own description.
    static func codexIsOwnThread(_ firstLine: Data?) -> Bool? {
        guard let firstLine, let entry = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              entry["type"] as? String == "session_meta", let meta = entry["payload"] as? [String: Any] else { return nil }
        return meta["parent_thread_id"] == nil && !(meta["source"] is [String: Any])
    }

    /// The last token count: the tokens of the latest request against the model's context size.
    static func codexContext(_ tail: Data) -> AgentContext? {
        for line in tail.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "event_msg", let payload = entry["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let tokens = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int,
                  let window = info["model_context_window"] as? Int, window > 0 else { continue }
            return AgentContext(tokens: tokens, window: window)
        }
        return nil
    }

    // MARK: Grok

    /// `signals.json` in the session's folder.
    static func grokContext(_ signals: Data) -> AgentContext? {
        guard let record = try? JSONSerialization.jsonObject(with: signals) as? [String: Any],
              let tokens = record["contextTokensUsed"] as? Int, let window = record["contextWindowTokens"] as? Int, window > 0 else { return nil }
        return AgentContext(tokens: tokens, window: window)
    }

    // MARK: files and processes

    /// The last `bytes` of a file, from the first whole line in them.
    static func tail(_ url: URL, _ bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: from)) != nil, let data = try? handle.readToEnd() else { return nil }
        guard from > 0 else { return data }
        return data.firstIndex(of: 0x0A).map { data[data.index(after: $0)...] }
    }

    /// A file's first line, when it ends within the first megabyte (Codex's holds its whole instructions).
    static func firstLine(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20), let end = data.firstIndex(of: 0x0A) else { return nil }
        return data[..<end]
    }

    /// When a process started; nil when there is none with that number.
    static func started(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The paths of the files a process has open.
    static func openFiles(_ pid: Int32) -> [String] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let each = MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / each + 16)   // some may open meanwhile
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * each))
        guard got > 0 else { return [] }
        return fds.prefix(Int(got) / each).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            return withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }
}
