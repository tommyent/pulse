import Foundation
import AppKit
import Combine

// MARK: - Codex app-server over stdio (JSON-RPC, one JSON object per line)
//
// The pet's chat, live voice, and activity all ride on Codex's own app-server, which signs in with
// ~/.codex/auth.json: the same subscription the Codex app uses, no API key. The process is spawned
// by the first message or voice start, or by opening the pet when there is a saved conversation to
// show, and lives until Pulse quits (the usage rings never touch it).

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
    @Published private(set) var waitingOnYou = false   // Codex is paused on an approval or a question

    enum VoiceState { case off, connecting, live, speaking }

    private let server = CodexAppServer.shared
    private var threadId: String?
    private var threadTask: Task<Opened, Error>?   // the in-flight open, shared by text, voice and reopening
    // The conversation continues across restarts: its ID is saved once Codex opened it, and only
    // New conversation forgets it. A lost server leaves `resumeId` for the next message to reconnect.
    private let defaults: UserDefaults
    static let savedThreadKey = "petThreadId"
    static let legacyCheckedKey = "petLegacyThreadChecked"   // looked once for a conversation from before saving
    private var resumeId: String?
    private var legacyCandidate: String?
    private var lookup: Task<Void, Never>?
    private var recoveryMessage: String?   // a reopening problem on the status line, cleared once it reopens
    @Published private(set) var earlierCursor: String?   // older turns of a reopened conversation
    var canLoadEarlier: Bool { earlierCursor != nil }
    private var turnId: String?
    private var interruptedTurn: String?   // one turn/interrupt per turn, from Stop or a stopped send
    private var lastSend: Task<Void, Never>?   // turn/starts run one at a time
    private var stops = 0                  // bumped by Stop; a send that began before it never starts its turn
    private var sends = 0                  // the newest send, so an older one never clears its state
    private var epoch = 0                  // bumped by New conversation: the old one's work stands down
    private var retrying = false           // the status line shows a retry Codex is making on its own
    private var realtimeActive = false
    private var heardAgentItems: Set<String> = []   // finished while a call was live: the voice relayed them
    private var promotedAgentItems: Set<String> = []
    private var agentText: [String: String] = [:]
    private var voiceStartTask: Task<Void, Never>?
    private var voiceRetry: Task<Void, Never>?
    private var voiceMayRetry = true
    // Realtime notifications carry only the thread ID, not the call, so calls never overlap. Each
    // thread/realtime/stop Codex accepts is answered by exactly one closed event with reason "requested"
    // (core's handle_close); the next call starts only once those have arrived. A stop Codex rejects
    // never ran, so it closes nothing. Elapsed time never counts as a close.
    private var realtimeRequested = false   // this call sent thread/realtime/start
    private var closesExpected = 0
    private let workspace: URL?

    init(workspace: URL? = nil, defaults: UserDefaults = .standard) {
        self.workspace = workspace
        self.defaults = defaults
        server.onNotification = { [weak self] method, params in self?.handle(method, params) }
    }

    /// Opening the card shows the conversation to continue: it reopens it without starting a turn or
    /// the microphone. With nothing saved (and the one-time look for an older one done) it starts nothing.
    func reopen() {
        guard threadId == nil, threadTask == nil, lookup == nil else { return }
        guard resumeId ?? defaults.string(forKey: Self.savedThreadKey) != nil || !defaults.bool(forKey: Self.legacyCheckedKey) else { return }
        let conversation = epoch
        if resumeId ?? defaults.string(forKey: Self.savedThreadKey) == nil { lookUpOlderConversation() }
        Task {
            await lookup?.value
            guard conversation == epoch, threadId == nil,
                  resumeId ?? defaults.string(forKey: Self.savedThreadKey) ?? legacyCandidate != nil else { return }   // nothing to show
            do { _ = try await ensureThread() }
            catch is CancellationError {}
            catch { if conversation == epoch { status = error.localizedDescription } }
        }
    }

    /// The one-time look for this pet's newest conversation from before Pulse saved them. Card opens,
    /// messages and calls all wait on the same look; New conversation cancels it.
    private func lookUpOlderConversation() {
        let conversation = epoch
        lookup = Task {
            defer { if conversation == epoch { lookup = nil } }
            do {
                try await server.start()
                let found = try await newestPetThread(in: Self.petHome(at: workspace))
                guard conversation == epoch, threadId == nil else { return }
                if let found { legacyCandidate = found } else { defaults.set(true, forKey: Self.legacyCheckedKey) }
            } catch is CancellationError {
            } catch { if conversation == epoch { status = error.localizedDescription } }   // tried again by the next message
        }
    }

    func loadEarlier() {
        guard let cursor = earlierCursor else { return }
        earlierCursor = nil   // one page at a time
        let conversation = epoch
        Task {
            do {
                let tid = try await ensureThread()
                let r = try await server.request("thread/turns/list", ["threadId": tid, "cursor": cursor, "limit": 20, "itemsView": "full", "sortDirection": "desc"])
                guard conversation == epoch, tid == threadId else { return }
                messages.insert(contentsOf: Self.history((r["data"] as? [[String: Any]] ?? []).reversed()), at: 0)
                earlierCursor = r["nextCursor"] as? String
            } catch {
                guard conversation == epoch else { return }
                earlierCursor = cursor; status = error.localizedDescription
            }
        }
    }

    // MARK: text

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        thinking = true
        status = nil
        sends += 1
        let previous = lastSend, stop = stops, conversation = epoch, mine = sends
        lastSend = Task {
            await previous?.value   // a stopped send finishes interrupting before the next turn starts
            let current = { stop == self.stops && conversation == self.epoch }
            // Stopped before reaching Codex: send nothing, create no thread, leave newer work alone.
            let standDown = { if conversation == self.epoch && mine == self.sends && self.turnId == nil { self.thinking = false } }
            guard current() else { return standDown() }
            do {
                let tid = try await ensureThread()
                guard current() else { return standDown() }
                let r = try await server.request("turn/start", [
                    "threadId": tid,
                    "input": [["type": "text", "text": text, "text_elements": []]],
                ])
                // Stop while Codex was accepting the turn: interrupt it as soon as its ID is known.
                if !current(), let accepted = (r["turn"] as? [String: Any])?["id"] as? String, accepted != interruptedTurn {
                    if conversation == epoch { interruptedTurn = accepted }
                    _ = try? await server.request("turn/interrupt", ["threadId": tid, "turnId": accepted])
                }
            } catch is CancellationError {   // New conversation dropped the thread this was waiting for
            } catch {
                guard current() else { return }
                if mine == sends { thinking = false }
                status = error.localizedDescription
            }
        }
    }

    func interrupt() {
        PetApprovals.shared.cancelAll()
        stops += 1
        guard let tid = threadId, let turnId, thinking, turnId != interruptedTurn else { return }
        interruptedTurn = turnId
        let conversation = epoch
        Task {
            do { _ = try await server.request("turn/interrupt", ["threadId": tid, "turnId": turnId]) }
            catch {
                guard conversation == epoch else { return }   // a newer conversation is not this one's to report on
                interruptedTurn = nil; status = error.localizedDescription
            }
        }
    }

    func clear() {
        interrupt()
        stopVoice()
        epoch += 1
        messages = []; activity = []; status = nil
        realtimeActive = false; heardAgentItems = []; promotedAgentItems = []; agentText = [:]
        closesExpected = 0   // the old thread's closes no longer reach this conversation
        threadTask?.cancel(); lookup?.cancel(); lookup = nil
        threadId = nil; threadTask = nil   // next message starts a fresh thread, even if one was being created
        resumeId = nil; legacyCandidate = nil; earlierCursor = nil; recoveryMessage = nil
        defaults.removeObject(forKey: Self.savedThreadKey)
        defaults.set(true, forKey: Self.legacyCheckedKey)   // a fresh start never reopens an older conversation
        turnId = nil; interruptedTurn = nil
        thinking = false; waitingOnYou = false; retrying = false
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
                try await previousCallClosed()
                realtimeRequested = true
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
                // Only Codex rejecting the start proves no call opened. A timeout may still open one,
                // so stopVoice tears it down through the close barrier like any ended call.
                if case CodexAppServer.Failure.remote = error { realtimeRequested = false }
                stopVoice()
                status = error.localizedDescription
            }
        }
    }

    func stopVoice() {
        cancelVoiceWork()   // even when already off: a pending audio retry must not restart a call
        guard voiceState != .off else { return }
        voiceState = .off
        realtimeActive = false   // results finishing from now on were never heard
        VoiceBridge.shared.close()
        finishLive()
        guard realtimeRequested, let tid = threadId else { return }   // tear down only a call that reached Codex
        realtimeRequested = false
        closesExpected += 1
        let conversation = epoch
        Task {
            do { _ = try await server.request("thread/realtime/stop", ["threadId": tid]) }
            catch CodexAppServer.Failure.remote(_) {   // Codex rejected the stop, so no close will come
                if conversation == epoch, closesExpected > 0 { closesExpected -= 1 }
            } catch {}   // no answer proves nothing: the close stays expected
        }
    }

    private func cancelVoiceWork() {
        voiceStartTask?.cancel(); voiceStartTask = nil
        voiceRetry?.cancel(); voiceRetry = nil
    }

    /// Waits for the ended calls' closes, so none can end the call now starting. If they don't come,
    /// this call fails visibly rather than overlap them.
    private func previousCallClosed() async throws {
        let deadline = Date.now.addingTimeInterval(3)
        // ponytail: 20 ms poll, only while a just-ended call closes; a continuation if it ever matters
        while closesExpected > 0 && Date.now < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        guard closesExpected == 0 else { throw CodexAppServer.Failure.remote("The last call is still closing. Try again in a moment.") }
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

    struct Opened { let id: String; let history: [ChatMessage]; let earlier: String?; let note: String?; var reconnected = false }

    /// Text, voice and reopening share one open. `clear()` drops an in-flight one, so it never
    /// becomes the new conversation, and only an open that is still current saves its ID.
    private func ensureThread() async throws -> String {
        let conversation = epoch   // a caller from before New conversation never opens or joins the new one
        if threadId == nil, let pending = lookup { await pending.value }
        try await server.start()
        guard conversation == epoch else { throw CancellationError() }
        if let threadId { return threadId }
        let task = threadTask ?? Task { try await self.openThread() }
        threadTask = task
        do {
            let opened = try await task.value
            guard conversation == epoch, threadTask == task || threadId == opened.id else { throw CancellationError() }
            if threadId != opened.id {   // the first caller to finish applies it, once
                threadId = opened.id; resumeId = nil; legacyCandidate = nil
                defaults.set(opened.id, forKey: Self.savedThreadKey)
                defaults.set(true, forKey: Self.legacyCheckedKey)
                // History goes above anything typed while it loaded.
                messages.insert(contentsOf: opened.history + (opened.note.map { [ChatMessage(role: .note, text: $0)] } ?? []), at: 0)
                if !opened.reconnected { earlierCursor = opened.earlier }   // a reconnect keeps the history still to page
                if let shown = recoveryMessage, status == shown { status = nil }   // that problem is over; a newer one stays
                recoveryMessage = nil
            }
            threadTask = nil
            return opened.id
        } catch {
            if threadTask == task { threadTask = nil }   // let the next call retry
            throw error
        }
    }

    /// Continues the pet's conversation (after a lost server, after a restart, or once, the newest
    /// pet conversation from before Pulse saved them) or starts one when there is none. A
    /// conversation that cannot be reopened stays saved and fails visibly: it never silently
    /// becomes a new one.
    private func openThread() async throws -> Opened {
        let home = try Self.petHome(at: workspace)
        var params: [String: Any] = ["cwd": home.path, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"]
        let reconnecting = resumeId != nil   // its messages are still on screen
        var id = resumeId ?? defaults.string(forKey: Self.savedThreadKey) ?? legacyCandidate
        var legacy = id != nil && id == legacyCandidate
        if id == nil && !defaults.bool(forKey: Self.legacyCheckedKey) {
            id = try await newestPetThread(in: home)
            legacy = id != nil
        }
        try Task.checkCancellation()   // New conversation cancels an open that hasn't reached Codex yet
        guard let id else {
            let r = try await server.request("thread/start", params)
            guard let id = (r["thread"] as? [String: Any])?["id"] as? String else { throw CodexAppServer.Failure.remote("thread/start returned no id") }
            return Opened(id: id, history: [], earlier: nil, note: nil)
        }
        params["threadId"] = id
        if reconnecting { params["excludeTurns"] = true }
        else { params["initialTurnsPage"] = ["limit": 20, "itemsView": "full", "sortDirection": "desc"] }
        let r: [String: Any]
        do { r = try await server.request("thread/resume", params) }
        catch { throw recoveryFailure("Couldn't reopen your last conversation (\(error.localizedDescription)). Start a New conversation to continue.") }
        guard (r["thread"] as? [String: Any])?["id"] as? String == id else {
            throw recoveryFailure("Couldn't reopen your last conversation. Start a New conversation to continue.")
        }
        let page = r["initialTurnsPage"] as? [String: Any]
        let history = Self.history((page?["data"] as? [[String: Any]] ?? []).reversed())
        var notes = [String]()
        if legacy { notes.append("Reopened your last pet conversation from before this update. Sites a tool blocked in it stay blocked here; start a New conversation to be asked again.") }
        if !history.isEmpty { notes.append("Shown: typed messages, requests Codex acted on and its replies. The rest of a voice call isn't shown here.") }
        return Opened(id: id, history: history, earlier: page?["nextCursor"] as? String, note: notes.isEmpty ? nil : notes.joined(separator: " "), reconnected: reconnecting)
    }

    /// The newest conversation this pet had before Pulse saved them: Pulse's own (originator "pulse")
    /// in exactly this folder. The local server can't filter by originator, so every page of this
    /// folder's threads is checked, newest first. A failed lookup is an error, never "nothing found".
    private func newestPetThread(in home: URL) async throws -> String? {
        let path = home.standardizedFileURL.path
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = ["cwd": home.path, "limit": 20, "sortKey": "updated_at", "sortDirection": "desc"]
            if let cursor { params["cursor"] = cursor }
            let r: [String: Any]
            do { r = try await server.request("thread/list", params) }
            catch { throw recoveryFailure("Couldn't look for your last conversation (\(error.localizedDescription)). Try again, or start a New conversation.") }
            let match = (r["data"] as? [[String: Any]] ?? []).first {
                $0["originator"] as? String == "pulse" && ($0["cwd"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path
            }
            if let id = match?["id"] as? String { return id }
            cursor = r["nextCursor"] as? String
        } while cursor != nil
        return nil
    }

    private func recoveryFailure(_ message: String) -> Error {
        recoveryMessage = message
        return CodexAppServer.Failure.remote(message)
    }

    /// Chat bubbles for reopened turns, oldest first: typed and delegated requests and Codex's replies.
    static func history<S: Sequence>(_ turns: S) -> [ChatMessage] where S.Element == [String: Any] {
        turns.flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap { item -> ChatMessage? in
                switch item["type"] as? String {
                case "userMessage":
                    let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                    let shown = spokenRequest(text)
                    return shown.isEmpty ? nil : ChatMessage(role: .user, text: shown)
                case "agentMessage":
                    let text = item["text"] as? String ?? ""
                    return text.isEmpty ? nil : ChatMessage(role: .assistant, text: text)
                default: return nil
                }
            }
        }
    }

    /// A request the voice delegated reads as what was said, not its wrapper.
    static func spokenRequest(_ text: String) -> String {
        guard text.hasPrefix("<realtime_delegation>"), let open = text.range(of: "<input>"),
              let close = text.range(of: "</input>", range: open.upperBound..<text.endIndex) else { return text }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handle(_ method: String, _ p: [String: Any]) {
        if let tid = p["threadId"] as? String, tid != threadId { return }
        switch method {
        case "turn/started":
            turnId = (p["turn"] as? [String: Any])?["id"] as? String
            thinking = true   // also work the voice delegated, so Stop can interrupt it
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
            turnId = nil; interruptedTurn = nil
            thinking = false
            let turn = p["turn"] as? [String: Any]
            if let completed = turn?["id"] as? String {
                for i in messages.indices where messages[i].sourceID?.hasPrefix("agent:\(completed):") == true { messages[i].live = false }
            }
            if turn?["status"] as? String == "failed" {
                status = ((turn?["error"] as? [String: Any])?["message"] as? String) ?? "Codex couldn't finish that."
            } else if retrying { status = nil }   // the retry worked
            retrying = false
            activity = activity.filter { !$0.done }.suffix(6).map { $0 }
        case "thread/status/changed":
            let state = p["status"] as? [String: Any]
            waitingOnYou = state?["type"] as? String == "active" && !(state?["activeFlags"] as? [String] ?? []).isEmpty
        case "error":
            // A retried turn is still running, so Stop stays available; only a final error ends it.
            retrying = p["willRetry"] as? Bool == true
            if !retrying { thinking = false }
            status = ((p["error"] as? [String: Any])?["message"] as? String) ?? "Codex error"
        case "thread/realtime/sdp":   // only the current call's answer; an ended call's is late
            if realtimeRequested, let sdp = p["sdp"] as? String { VoiceBridge.shared.mark("server answer"); VoiceBridge.shared.accept(answer: sdp) }
        case "thread/realtime/started":
            if closesExpected == 0 { realtimeActive = true }   // otherwise a call that was already ended
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
                promotedAgentItems.insert(key)
                if let text = agentText[key] { setMessage(text, role: .assistant, key: key, live: false) }
            }
        case "thread/realtime/item/transcript/delta":
            guard let id = p["itemId"] as? String, let delta = p["delta"] as? String,
                  let i = messages.firstIndex(where: { $0.sourceID == "voice:" + id }), messages[i].live else { return }
            messages[i].text += delta
        // The legacy role-only transcript notifications mirror this canonical stream: ignore them.
        case "thread/realtime/error":
            // Codex's errors name the thread; the native helper's own don't and always concern this call.
            guard realtimeRequested || p["threadId"] == nil else { return }   // an ended call's last words
            realtimeActive = false
            // The native helper dying moments after its devices open means an audio device changed
            // under it, which one quiet retry usually survives.
            let retry = voiceMayRetry && voiceState != .off && VoiceBridge.shared.lastFailureWasEarlyDeath
            stopVoice()
            guard !retry else {   // End call and New conversation cancel it through stopVoice
                voiceRetry = Task {
                    guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
                    startVoice(retryOnAudioGlitch: false)
                }
                return
            }
            status = p["message"] as? String
        case "thread/realtime/closed":
            realtimeActive = false
            if p["reason"] as? String == "requested", closesExpected > 0 { closesExpected -= 1; return }   // a call Pulse ended
            guard realtimeRequested else { return }   // the server's end of a call already ended here
            realtimeRequested = false
            finishLive()
            if voiceState != .off { voiceState = .off; VoiceBridge.shared.close() }
        case "pulse/note":   // a request Pulse cancelled or left unanswered because it cannot show it
            if let text = p["text"] as? String { messages.append(ChatMessage(role: .note, text: text)) }
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
            cancelVoiceWork()   // a queued start or audio retry must not reopen the microphone
            realtimeActive = false; realtimeRequested = false; closesExpected = 0
            finishLive()
            turnId = nil; interruptedTurn = nil
            thinking = false; waitingOnYou = false
            if voiceState != .off { voiceState = .off; VoiceBridge.shared.close() }
            resumeId = threadId ?? resumeId   // the next message reconnects to this same conversation
            threadId = nil
            status = "Codex app-server stopped. Your next message reconnects to this conversation."
            recoveryMessage = status
        default: break
        }
    }

    private func updateAgent(_ text: String, item: String, params: [String: Any], completed: Bool) {
        let turn = (params["turnId"] as? String) ?? turnId ?? ""
        let key = "agent:\(turn):\(item)"
        if completed { agentText[key] = text } else { agentText[key, default: ""] += text }
        // A live call speaks delegated results, so only promoted ones also go in the chat. A result that
        // finishes after the call ended was never heard, so it shows (once: later events update its bubble).
        if realtimeActive && completed { heardAgentItems.insert(key) }
        guard (!realtimeActive && !heardAgentItems.contains(key)) || promotedAgentItems.contains(key) else { return }
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
