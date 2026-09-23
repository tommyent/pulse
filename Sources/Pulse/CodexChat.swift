import Foundation
import AppKit
import Combine

// MARK: - Codex app-server over stdio (JSON-RPC, one JSON object per line)
//
// The pet's chat, live voice, and activity all ride on Codex's own app-server, which signs in with
// ~/.codex/auth.json: the same subscription the Codex app uses, no API key. The process is spawned
// the first time the pet card opens and lives until Pulse quits (the usage rings never touch it).

final class CodexAppServer: @unchecked Sendable {
    static let shared = CodexAppServer()

    enum Failure: LocalizedError {
        case notInstalled, notRunning, remote(String), transport, timeout(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Codex CLI not found (install codex, then sign in)"
            case .notRunning: "Codex app-server is not running"
            case .remote(let m): m
            case .transport: "Codex app-server connection closed"
            case .timeout(let method): "Codex did not answer \(method) in time"
            }
        }
    }

    /// Notifications and server-initiated requests, delivered on the main thread.
    var onNotification: ((String, [String: Any]) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var generation = 0   // one per spawned process: callbacks from an older process are ignored
    private var starting: Task<Void, Error>?
    private(set) var ready = false

    private init() {
        // the child does not always notice a closed stdin; end it with Pulse
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stop()
        }
    }

    /// Spawns and initializes once; concurrent callers share the same start, later calls return immediately.
    func start() async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if process?.isRunning == true && ready { return nil }
            if starting == nil { starting = Task { try await self.spawn() } }
            return starting
        }
        guard let task else { return }
        defer { lock.withLock { if starting == task { starting = nil } } }
        try await task.value
    }

    private func spawn() async throws {
        stop()   // a process left over from a failed start must not linger
        guard let bin = locateBinary("codex") else { throw Failure.notInstalled }
        let gen = lock.withLock { generation += 1; return generation }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["app-server", "--listen", "stdio://"]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; self?.closed(gen); return }
            self?.consume(data, gen)
        }
        p.terminationHandler = { [weak self] _ in self?.closed(gen) }
        try p.run()
        lock.withLock {
            process = p
            stdin = inPipe.fileHandleForWriting
            buffer = Data()
        }
        do {
            _ = try await request("initialize", ["clientInfo": ["name": "pulse", "title": "Pulse", "version": "0.1"],
                                                 "capabilities": ["experimentalApi": true]])
        } catch { stop(); throw error }
        notify("initialized", [:])
        lock.withLock { ready = true }
    }

    /// Ends the current process. Its waiting requests fail now; its late callbacks are ignored.
    func stop() {
        let (p, waiting, wasReady) = lock.withLock {
            defer { process = nil; stdin = nil; ready = false; pending = [:]; generation += 1 }
            return (process, pending, ready)
        }
        ended(waiting, announce: wasReady)   // a replaced working server invalidates the session's thread
        p?.terminate()
    }

    /// `timeout` bounds the acknowledgement only; a turn's streamed work arrives later as notifications.
    /// Every continuation leaves `pending` under the lock before it resumes, so reply, timeout,
    /// write failure and disconnect can each resume it at most once.
    func request(_ method: String, _ params: [String: Any], timeout: Duration = .seconds(30)) async throws -> [String: Any] {
        let (stdin, id): (FileHandle, Int) = try lock.withLock {
            guard let stdin, process?.isRunning == true else { throw Failure.notRunning }
            defer { nextID += 1 }
            return (stdin, nextID)
        }
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.take(id)?.resume(throwing: Failure.timeout(method))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { pending[id] = cont }
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params], to: stdin)
            } catch {
                take(id)?.resume(throwing: Failure.transport)
            }
        }
    }

    private func take(_ id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.withLock { pending.removeValue(forKey: id) }
    }

    private func isCurrent(_ gen: Int) -> Bool { lock.withLock { gen == generation } }

    func notify(_ method: String, _ params: [String: Any]) {
        lock.lock(); let stdin = stdin; lock.unlock()
        guard let stdin else { return }
        try? write(["jsonrpc": "2.0", "method": method, "params": params], to: stdin)
    }

    /// Reject unsupported server requests; supported approvals use a structured result.
    func respond(id: Any, error message: String) {
        lock.lock(); let stdin = stdin; lock.unlock()
        guard let stdin else { return }
        try? write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]], to: stdin)
    }

    func respond(id: Any, result: [String: Any]) {
        lock.lock(); let stdin = stdin; lock.unlock()
        guard let stdin else { return }
        try? write(["jsonrpc": "2.0", "id": id, "result": result], to: stdin)
    }

    private func write(_ obj: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func consume(_ data: Data, _ gen: Int) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            dispatch(msg, gen)
        }
    }

    private func dispatch(_ msg: [String: Any], _ gen: Int) {
        let method = msg["method"] as? String
        if let id = msg["id"] as? Int, method == nil {
            let cont = take(id)
            if let err = msg["error"] as? [String: Any] {
                cont?.resume(throwing: Failure.remote((err["message"] as? String) ?? "Codex error"))
            } else {
                cont?.resume(returning: (msg["result"] as? [String: Any]) ?? [:])
            }
            return
        }
        guard let method else { return }
        let params = (msg["params"] as? [String: Any]) ?? [:]
        if let id = msg["id"] {
            DispatchQueue.main.async {
                guard self.isCurrent(gen) else { return }
                PetApprovals.shared.receive(id: id, method: method, params: params)
            }
            return
        }
        DispatchQueue.main.async {
            guard self.isCurrent(gen) else { return }
            PetApprovals.shared.observe(method, params)
            self.onNotification?(method, params)
        }
    }

    /// The process ended on its own (pipe closed or exit). Stale processes are ignored.
    private func closed(_ gen: Int) {
        let waiting: [Int: CheckedContinuation<[String: Any], Error>]? = lock.withLock {
            guard gen == generation else { return nil }
            defer { pending = [:]; process = nil; stdin = nil; ready = false; generation += 1 }
            return pending
        }
        if let waiting { ended(waiting, announce: true) }
    }

    private func ended(_ waiting: [Int: CheckedContinuation<[String: Any], Error>], announce: Bool) {
        for c in waiting.values { c.resume(throwing: Failure.transport) }
        guard announce else { return }
        DispatchQueue.main.async {
            PetApprovals.shared.cancelAll(reply: false)
            self.onNotification?("pulse/closed", [:])
        }
    }
}

// MARK: - Pet session: one Codex thread carrying text turns and live voice

struct ChatMessage: Identifiable {
    enum Role { case user, assistant, note }
    let id = UUID()
    var role: Role
    var text: String
    var live = false   // still streaming
    var sourceID: String?
}

struct ActivityPill: Identifiable {
    let id: String
    var label: String
    var done = false
}

/// Seeded into ~/Documents/codex-pet once; the user owns it after that.
private let petAgentsMD = """
# codex-pet

This folder is a personal inbox: todos, reminders, bills, ideas, research, and any other junk the
owner wants off their head. You are the assistant that keeps it tidy. This is your default working
folder. When asked to work elsewhere (commonly ~/Projects or ~/Downloads), request permission
for the needed paths before accessing them. Use the permission request tool when available;
otherwise request command approval. Work only within the approved action or task scope.

## Layout

- `inbox/` raw dumps that have not been sorted yet (one file per item, `YYYY-MM-DD-slug.md`)
- `todos.md` open tasks, one `- [ ]` line each, newest at the bottom; tick instead of deleting
- `reminders.md` dated items, one line each: `YYYY-MM-DD HH:MM  what`
- `bills.md` what is due, when, how much, and whether it is paid; never pay anything
- `ideas.md` one heading per idea, notes under it
- `research/` longer write-ups as `.md` or `.html`, one file per topic
- `archive/` anything done or stale; move, do not delete

## Rules

- Capture first, ask later. When something comes in by chat or voice, write it down immediately in
  the right file, or in `inbox/` if unsure. Keep it short and date-stamp it.
- When asked to organize, sweep `inbox/` into the files above and report what moved.
- Tracking only: note bills, deadlines, and follow-ups. Do not send email, pay, book, or contact
  anyone. For work in other folders, request permission
  and carry out the requested task after approval, including through available agents and tools.
- Never delete the owner's words; rewrite for brevity only when asked.
- On every open, if `reminders.md` has anything due today or overdue, say so first.
"""

/// Replace only the original restrictions; preserve the owner's other instructions and notes.
func updatedPetInstructions(_ text: String) -> String {
    text.replacingOccurrences(of: "You can only read and write\ninside this folder.", with:
        "This is your default working\nfolder. When asked to work elsewhere (commonly ~/Projects or ~/Downloads), request permission\nfor the needed paths before accessing them. Use the permission request tool when available;\notherwise request command approval. Work only within the approved action or task scope.")
        .replacingOccurrences(of: "anyone. If an item needs action outside this folder, add it to `todos.md` tagged `#needs-agent`.", with:
        "anyone. For work in other folders, request permission\n  and carry out the requested task after approval, including through available agents and tools.")
}

@MainActor
final class CodexPetSession: ObservableObject {
    static let shared = CodexPetSession()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var activity: [ActivityPill] = []
    @Published private(set) var thinking = false
    @Published private(set) var voiceState: VoiceState = .off {
        didSet {
            // Audible start and end of a live call, like dictation apps: macOS "Pluck" (Purr.aiff) when
            // the microphone goes live, "Pong" (Morse.aiff) when a call that went live ends.
            let wasLive = oldValue == .live || oldValue == .speaking
            if oldValue == .connecting && voiceState == .live { playCue("Purr") }
            else if wasLive && voiceState == .off { playCue("Morse") }
        }
    }
    var playCue: (String) -> Void = { NSSound(named: $0)?.play() }   // checks record instead of playing
    @Published var muted = false { didSet { VoiceBridge.shared.setMuted(muted) } }
    @Published private(set) var status: String?   // connection / error line under the composer

    enum VoiceState { case off, connecting, live, speaking }

    private let server = CodexAppServer.shared
    private var threadId: String?
    private var threadTask: Task<String, Error>?   // the in-flight thread/start, shared by text and voice
    private var turnId: String?
    private var realtimeActive = false
    private var voiceTurns: Set<String> = []
    private var promotedAgentItems: Set<String> = []
    private var agentText: [String: String] = [:]
    private var voiceStartTask: Task<Void, Never>?
    private var voiceMayRetry = true
    private let workspace: URL?

    init(workspace: URL? = nil) {
        self.workspace = workspace
        server.onNotification = { [weak self] method, params in self?.handle(method, params) }
    }

    // MARK: text

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        thinking = true
        status = nil
        Task {
            do {
                let tid = try await ensureThread()
                _ = try await server.request("turn/start", [
                    "threadId": tid,
                    "input": [["type": "text", "text": text, "text_elements": []]],
                ])
            } catch is CancellationError {   // New conversation dropped the thread this was waiting for
            } catch {
                thinking = false
                status = error.localizedDescription
            }
        }
    }

    func interrupt() {
        PetApprovals.shared.cancelAll()
        guard let tid = threadId, let turnId, thinking else { return }
        Task {
            do { _ = try await server.request("turn/interrupt", ["threadId": tid, "turnId": turnId]) }
            catch { status = error.localizedDescription }
        }
    }

    func clear() {
        interrupt()
        stopVoice()
        messages = []; activity = []; status = nil
        realtimeActive = false; voiceTurns = []; promotedAgentItems = []; agentText = [:]
        threadId = nil; threadTask = nil   // next message starts a fresh thread, even if one was being created
        turnId = nil
        thinking = false
    }

    // MARK: voice (client-owned WebRTC call negotiated through the app-server)

    var isRecording: Bool { (voiceState == .live || voiceState == .speaking) && !muted }

    func toggleVoice() {
        if voiceState == .off { startVoice() } else { stopVoice() }
    }

    /// `retryOnAudioGlitch` is false only for the one automatic retry below, so it can never loop.
    func startVoice(retryOnAudioGlitch: Bool = true) {
        guard voiceState == .off else { return }
        voiceMayRetry = retryOnAudioGlitch
        voiceState = .connecting
        status = nil
        VoiceBridge.shared.warmupStart = .now
        voiceStartTask = Task {
            do {
                let tid = try await ensureThread()
                VoiceBridge.shared.mark("thread ready")
                try Task.checkCancellation()
                let offer = try await VoiceBridge.shared.createOffer(muted: muted)
                try Task.checkCancellation()
                _ = try await server.request("thread/realtime/start", [
                    "threadId": tid,
                    "transport": ["type": "webrtc", "sdp": offer],
                    "version": "v3",              // the subscription-backed session; v1/v2 need an API key
                    "voice": "cove",
                    "outputModality": "audio",
                    "includeStartupContext": true,
                    "flushTranscriptTailOnSessionEnd": true,
                ])
                VoiceBridge.shared.mark("realtime/start acknowledged")   // the answer arrives as thread/realtime/sdp
            } catch {
                guard !Task.isCancelled else { return }
                voiceState = .off
                VoiceBridge.shared.close()
                status = error.localizedDescription
            }
        }
    }

    func stopVoice() {
        guard voiceState != .off else { return }
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceState = .off
        VoiceBridge.shared.close()
        finishLive()
        if let tid = threadId { Task { _ = try? await server.request("thread/realtime/stop", ["threadId": tid]) } }
    }

    // MARK: plumbing

    /// Default workspace. Extra access requires an approval; existing custom instructions survive migration.
    static func petHome(at workspace: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = workspace ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("codex-pet")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let agents = dir.appendingPathComponent("AGENTS.md")
        if !fm.fileExists(atPath: agents.path) { try petAgentsMD.write(to: agents, atomically: true, encoding: .utf8) }
        else {
            let previous = try String(contentsOf: agents, encoding: .utf8)
            let updated = updatedPetInstructions(previous)
            if updated != previous { try updated.write(to: agents, atomically: true, encoding: .utf8) }
        }
        return dir
    }

    /// Text and voice starting together share one thread/start. `clear()` drops an in-flight start,
    /// so its thread never becomes the new conversation.
    private func ensureThread() async throws -> String {
        try await server.start()
        if let threadId { return threadId }
        let task = threadTask ?? Task {
            let r = try await server.request("thread/start", [
                "cwd": Self.petHome(at: workspace).path,
                "approvalPolicy": "on-request",
                "approvalsReviewer": "user",
                "sandbox": "workspace-write",
            ])
            guard let id = (r["thread"] as? [String: Any])?["id"] as? String else { throw CodexAppServer.Failure.remote("thread/start returned no id") }
            return id
        }
        threadTask = task
        do {
            let id = try await task.value
            guard threadTask == task || threadId == id else { throw CancellationError() }
            threadId = id; threadTask = nil
            return id
        } catch {
            if threadTask == task { threadTask = nil }   // let the next call retry
            throw error
        }
    }

    private func handle(_ method: String, _ p: [String: Any]) {
        if let tid = p["threadId"] as? String, tid != threadId { return }
        switch method {
        case "turn/started":
            turnId = (p["turn"] as? [String: Any])?["id"] as? String
            if realtimeActive, let turnId { voiceTurns.insert(turnId) }
        case "item/agentMessage/delta":
            guard let delta = p["delta"] as? String, let item = p["itemId"] as? String else { return }
            updateAgent(delta, item: item, params: p, completed: false)
        case "item/started":
            guard let item = p["item"] as? [String: Any], let type = item["type"] as? String, let id = item["id"] as? String else { return }
            if let label = activityLabel(type, item) { activity.append(ActivityPill(id: id, label: label)) }
        case "item/completed":
            guard let item = p["item"] as? [String: Any], let id = item["id"] as? String else { return }
            if let i = activity.firstIndex(where: { $0.id == id }) { activity[i].done = true }
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                updateAgent(text, item: id, params: p, completed: true)
            }
        case "turn/completed":
            turnId = nil
            thinking = false
            if let completed = (p["turn"] as? [String: Any])?["id"] as? String {
                for i in messages.indices where messages[i].sourceID?.hasPrefix("agent:\(completed):") == true { messages[i].live = false }
            }
            activity = activity.filter { !$0.done }.suffix(6).map { $0 }
        case "error":
            thinking = false
            status = ((p["error"] as? [String: Any])?["message"] as? String) ?? "Codex error"
        case "thread/realtime/sdp":
            if let sdp = p["sdp"] as? String { VoiceBridge.shared.mark("server answer"); VoiceBridge.shared.accept(answer: sdp) }
        case "thread/realtime/started":
            realtimeActive = true
            if let turnId { voiceTurns.insert(turnId) }
        case "thread/realtime/item/started", "thread/realtime/item/completed":
            guard let item = p["item"] as? [String: Any], let id = item["id"] as? String else { return }
            let completed = method == "thread/realtime/item/completed"
            if item["type"] as? String == "transcriptSegment",
               let role = item["role"] as? String, ["user", "assistant"].contains(role),
               let text = item["text"] as? String {
                let key = "voice:" + id
                // A repeated start must not erase text that has already streamed.
                if completed || !messages.contains(where: { $0.sourceID == key }) {
                    setMessage(text, role: role == "user" ? .user : .assistant, key: key, live: !completed)
                }
            } else if item["type"] as? String == "bemItemPromoted",
                      let turn = item["turnId"] as? String, let agent = item["itemId"] as? String {
                let key = "agent:\(turn):\(agent)"
                voiceTurns.insert(turn)
                promotedAgentItems.insert(key)
                if let text = agentText[key] { setMessage(text, role: .assistant, key: key, live: false) }
            }
        case "thread/realtime/item/transcript/delta":
            guard let id = p["itemId"] as? String, let delta = p["delta"] as? String,
                  let i = messages.firstIndex(where: { $0.sourceID == "voice:" + id }), messages[i].live else { return }
            messages[i].text += delta
        // The legacy role-only transcript notifications mirror this canonical stream: ignore them.
        case "thread/realtime/error":
            realtimeActive = false
            // The native helper dying moments after its devices open means an audio device changed
            // under it, which one quiet retry usually survives.
            let retry = voiceMayRetry && voiceState != .off && VoiceBridge.shared.lastFailureWasEarlyDeath
            stopVoice()
            guard !retry else {
                Task { try? await Task.sleep(for: .milliseconds(300)); startVoice(retryOnAudioGlitch: false) }
                return
            }
            status = p["message"] as? String
        case "thread/realtime/closed":
            realtimeActive = false
            finishLive()
            if voiceState != .off { voiceState = .off; VoiceBridge.shared.close() }
        case "pulse/voiceReady":
            if voiceState == .connecting { voiceState = .live }
        case "pulse/voice":
            // Native speaker activity drives the pet. It arrives every 100 ms; assign only on change,
            // since every @Published assignment redraws the overlay.
            guard let type = p["type"] as? String, voiceState != .off else { return }
            let next: VoiceState
            if type == "output_audio_buffer.started" { next = .speaking }
            else if type == "output_audio_buffer.stopped" || type == "output_audio_buffer.cleared" { next = .live }
            else { return }
            if voiceState != next { voiceState = next }
        case "pulse/closed":
            realtimeActive = false
            finishLive()
            turnId = nil
            thinking = false
            if voiceState != .off { voiceState = .off; VoiceBridge.shared.close() }
            threadId = nil
            status = "Codex app-server stopped"
        default: break
        }
    }

    private func updateAgent(_ text: String, item: String, params: [String: Any], completed: Bool) {
        let turn = (params["turnId"] as? String) ?? turnId ?? ""
        let key = "agent:\(turn):\(item)"
        if completed { agentText[key] = text } else { agentText[key, default: ""] += text }
        // Voice speaks the delegated result. Only explicitly promoted artifacts also belong in chat.
        guard (!realtimeActive && !voiceTurns.contains(turn)) || promotedAgentItems.contains(key) else { return }
        setMessage(agentText[key] ?? "", role: .assistant, key: key, live: !completed)
    }

    private func setMessage(_ text: String, role: ChatMessage.Role, key: String, live: Bool) {
        if let i = messages.firstIndex(where: { $0.sourceID == key }) {
            messages[i].text = text
            messages[i].live = live
        } else {
            messages.append(ChatMessage(role: role, text: text, live: live, sourceID: key))
        }
    }

    private func finishLive() {
        for i in messages.indices { messages[i].live = false }
    }

    private func activityLabel(_ type: String, _ item: [String: Any]) -> String? {
        switch type {
        case "commandExecution": return "Running: " + ((item["command"] as? String) ?? "command").prefix(40)
        case "fileChange": return "Editing files"
        case "mcpToolCall": return "Tool: " + ((item["tool"] as? String) ?? "call")
        case "webSearch": return "Searching the web"
        case "reasoning": return "Thinking"
        default: return nil
        }
    }
}
