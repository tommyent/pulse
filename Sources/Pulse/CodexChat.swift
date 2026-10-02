import Foundation
import AppKit
import Combine
import os

/// What Pulse decided about speaking voice work: IDs and reasons only, never what was said or written.
private let voiceLog = Logger(subsystem: "app.pulse", category: "voice-results")

// MARK: - Codex app-server over stdio (JSON-RPC, one JSON object per line)
//
// The pet's chat, live voice, and activity all ride on Codex's own app-server, which signs in with
// ~/.codex/auth.json: the same subscription the Codex app uses, no API key. The process is spawned
// when the pet card opens (to show the saved conversation and the work models) or by the first message
// or voice start, and lives until Pulse quits (the usage rings never touch it).

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

    /// A request nobody waits on, written before this returns, so a caller's check and the write are one step.
    /// Its reply is ignored like any unknown ID. Returns whether it was written.
    @discardableResult
    func post(_ method: String, _ params: [String: Any]) -> Bool {
        let (stdin, id): (FileHandle?, Int) = lock.withLock {
            defer { nextID += 1 }
            return (process?.isRunning == true ? stdin : nil, nextID)
        }
        guard let stdin else { return false }
        return (try? write(["jsonrpc": "2.0", "id": id, "method": method, "params": params], to: stdin)) != nil
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

    /// Whole frames, one at a time: requests write from any executor and posts from the main actor, and a frame
    /// larger than the pipe's atomic size could otherwise interleave with another. Never held with `lock`.
    private let writeLock = NSLock()
    private func write(_ obj: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try writeLock.withLock { try handle.write(contentsOf: data) }
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
    /// Set on results of work a call started, so they never read as spoken replies: "After the call" when
    /// it finished once the call was over, "Work result" when reopened (history can't tell when it was heard).
    var caption: String?
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
- `bills.md` what is due, when, how much, and whether it is paid; pay only when the owner explicitly asks for that payment
- `ideas.md` one heading per idea, notes under it
- `research/` longer write-ups as `.md` or `.html`, one file per topic
- `archive/` anything done or stale; move, do not delete

## Rules

- Capture first, ask later. When something comes in by chat or voice, write it down immediately in
  the right file, or in `inbox/` if unsure. Keep it short and date-stamp it.
- When asked to organize, sweep `inbox/` into the files above and report what moved.
- Note bills, deadlines, and follow-ups. Don't send email, pay, book, or contact anyone on your own:
  do that only when the owner explicitly asks for that specific action, and let Pulse's permission
  prompts confirm it. For work in other folders, request permission
  and carry out the requested task after approval, including through available agents and tools.
- Never delete the owner's words; rewrite for brevity only when asked.
- On every open, if `reminders.md` has anything due today or overdue, say so first.
"""

/// Replace only the original restrictions; preserve the owner's other instructions and notes.
func updatedPetInstructions(_ text: String) -> String {
    // Oldest first: each step expects the text the one before it leaves.
    text.replacingOccurrences(of: "You can only read and write\ninside this folder.", with:
        "This is your default working\nfolder. When asked to work elsewhere (commonly ~/Projects or ~/Downloads), request permission\nfor the needed paths before accessing them. Use the permission request tool when available;\notherwise request command approval. Work only within the approved action or task scope.")
        .replacingOccurrences(of: "anyone. If an item needs action outside this folder, add it to `todos.md` tagged `#needs-agent`.", with:
        "anyone. For work in other folders, request permission\n  and carry out the requested task after approval, including through available agents and tools.")
        .replacingOccurrences(of: "whether it is paid; never pay anything", with: "whether it is paid; pay only when the owner explicitly asks for that payment")
        .replacingOccurrences(of: "- Tracking only: note bills, deadlines, and follow-ups. Do not send email, pay, book, or contact\n  anyone.", with:
        "- Note bills, deadlines, and follow-ups. Don't send email, pay, book, or contact anyone on your own:\n  do that only when the owner explicitly asks for that specific action, and let Pulse's permission\n  prompts confirm it.")
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
    @Published var draft = ""   // unsent text survives closing the card
    // What Codex reports for the open conversation: the model it actually runs, its folder, when it began.
    @Published private(set) var model: String?
    @Published private(set) var folder: String?
    @Published private(set) var conversationStarted: Date?
    @Published private(set) var effort: String?
    /// The models Codex offers for the work (`model/list`). The voice that talks is a separate realtime
    /// model; choosing here never changes it.
    struct WorkModel: Identifiable {
        let id, name: String; let efforts: [String]   // lowest first, as Codex lists them
        var helpers = false                            // Codex's multi-agent v2
        var defaultEffort: String?                     // what a conversation without an effort of its own runs at
    }
    @Published private(set) var workModels: [WorkModel] = []   // the ones offered in the menu
    private var catalog: [WorkModel] = []   // all of them, hidden ones too: a conversation may run one
    private var catalogDefault: String?     // the model Codex gives a new conversation that names none (this server's, read again after a restart)
    @Published private(set) var choosingWork = false   // one switch at a time; the menu waits for it
    // Saved only once Codex accepted it (or, with no conversation yet, once it matched what Codex offers):
    // new conversations start with it.
    @Published private(set) var preferredModel: String?
    @Published private(set) var preferredEffort: String?
    static let workModelKey = "petWorkModel", workEffortKey = "petWorkEffort"
    /// The header's model and effort: the open conversation's, else the saved choice. Nothing otherwise:
    /// model/list's default isn't what Codex's own settings give a new conversation.
    var shownModel: String? { model ?? preferredModel }
    var shownEffort: String? { model != nil ? effort : preferredEffort }
    /// The helpers' effort when it isn't the pet's own: the one this conversation's rule names since it opened (the
    /// pet may talk at medium, or have been switched since). A newer pick applies from the next open.
    var helperEffort: String? {
        guard let hint = hintEffort, hint != shownEffort, hasHelpers(shownModel) else { return nil }
        return hint
    }
    var pendingHelperEffort: String? {
        guard model != nil, let pick = preferredEffort, pick != hintEffort, hasHelpers(shownModel) else { return nil }
        return pick
    }
    /// A model the owner picked that this conversation can't switch to until it next opens (see chooseWork).
    var pendingModel: String? { model != nil && preferredModel != nil && preferredModel != model ? preferredModel : nil }
    private func hasHelpers(_ model: String?) -> Bool { catalog.first { $0.id == model }?.helpers == true }
    var chosenEffort: String? { preferredEffort ?? helperEffort ?? shownEffort }   // the menu's checkmark: what the owner picked
    private var switchError: String?   // shown only until a switch succeeds

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
    private var voiceTurns: Set<String> = []   // work a call started, including the transcript flush after it
    // Pulse, not Codex, hands the voice its results (clientManagedHandoffs): only a finished turn's
    // result, once, into the call that asked, and only if nothing newer was said or typed since.
    private var callNumber = 0                             // bumped by each call start
    private var inputNumber = 0                            // place in line of the newest input: an utterance with words, or typing
    private var inputsSeen = 0                             // places handed out, in the order inputs first appear
    private var askedAt: [String: (call: Int, input: Int)] = [:]   // turn → the call and input it answers
    private var voiceInputs: [String: Int] = [:]           // this call's utterances: transcript item ID → place in line
    private var spokenInputs: [String: Int] = [:]          // their words → the newest input that said them
    private var asks: [String: String] = [:]               // this call's requests: their words → turn
    private var voiceResults: [String: (key: String, asks: Bool)] = [:]   // turn → its result
    private var spokenTurns: Set<String> = []
    // Helpers: Codex sub-agents the pet started, seen through Pulse's one server. A helper's own first turn is
    // its job and that turn's turn/completed its outcome. A finished helper doesn't wake the pet, so Pulse asks
    // the pet to report it, once the pet is free.
    private struct Helper {
        enum State { case running, finished, reporting, reported }
        let path: String
        let spawnTurn: String
        let epoch: Int
        var owner: Int?               // the call that asked for it; nil when typed or never proven: shown, not spoken
        var ownerCall: Int?           // a voice request not yet tied to its words: the call live when it started
        var parent: String?           // set for a helper's own helper, which Pulse stops on sight
        var firstTurn: String?        // the work it was started for
        var currentTurn: String?
        var outcome: (status: String, final: String?)?
        var state = State.running
        var failedReports = 0         // reports superseded or cut short: one more spoken try, then chat only
        var stopping = false
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var isWorking: Bool { outcome == nil || currentTurn != nil }   // its first job, or a later turn, still running
    }
    private var helpers: [String: Helper] = [:]                          // child thread → helper
    private var unclaimed: [String: [(String, [String: Any])]] = [:]     // a few events that beat their helper's registration
    private struct Report { let seq: Int; let jobs: [String]; let owner: Int?; let epoch: Int; let speak: Bool; var sent = false; var turn: String?; var superseded = false; var stopped = false }
    private var report: Report?
    private var reportSeq = 0
    private var reportTurns: Set<String> = []
    private var earlyReportEnd: [String: Any]?   // a report turn's end that beat its turn/start reply
    private var heldItems: [(text: String, item: String, params: [String: Any], completed: Bool, phase: String?, asks: Bool)] = []   // and its items
    private var cancelledReports: Set<String> = []   // report turns Stop cancelled before Codex named them: nothing of theirs shows
    private var reportsHeld = false              // after Stop, until the owner asks for something again
    @Published private(set) var helpersWorking = 0
    private var firstAsked: [String: Int] = [:]  // turn → the call whose voice first asked into it: a helper's only possible owner
    private var typedInto: Set<String> = []      // turns typed input was accepted into: their later helpers are chat only
    private var typedPending = 0                 // typed sends Codex hasn't accepted yet: helpers seen meanwhile are chat only
    private var stoppedTurns: Set<String> = []   // the pet's turns Stop interrupted: helpers they start are stopped on sight
    private var retiredRoots: [String: Int] = [:]   // previous conversations' threads → their epoch, for their late helpers
    @Published private(set) var hintEffort: String?   // the helpers' effort the rule this conversation opened with names, if any
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
        preferredModel = defaults.string(forKey: Self.workModelKey)
        preferredEffort = defaults.string(forKey: Self.workEffortKey)
        server.onNotification = { [weak self] method, params in self?.handle(method, params) }
        PetApprovals.shared.onPromptOpened = { [weak self] request in self?.promptOpened(request) }
        PetApprovals.shared.helperOf = { [weak self] thread in self?.helperLabel(thread) }
    }

    /// Mid-call, a prompt is a window the user may not be looking at: a sound, and the voice says so.
    /// Answering stays a click in that window; nothing said in the call answers it.
    private func promptOpened(_ request: PetApproval) {
        guard voiceState == .live || voiceState == .speaking, realtimeRequested, let tid = threadId else { return }
        playCue("Glass")
        let what = request.questions.isEmpty ? "is asking for your OK" : "has a question for you"
        server.post("thread/realtime/appendSpeech", ["threadId": tid, "text": "Codex \(what) in a window on your screen."])
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

    /// Loads the models Codex offers for the work. Called when the card opens, which starts Codex if needed.
    func loadWorkModels() {
        guard catalog.isEmpty, !loadingWorkModels else { return }
        loadingWorkModels = true
        workModelsLoad = Task {
            defer { loadingWorkModels = false }
            do {
                try await server.start()
                var found = [WorkModel](), hidden = Set<String>(), defaults = [String](), cursor: String?
                repeat {
                    var params: [String: Any] = ["limit": 50, "includeHidden": true]
                    if let cursor { params["cursor"] = cursor }
                    let r = try await server.request("model/list", params)
                    for m in r["data"] as? [[String: Any]] ?? [] {
                        guard let id = m["model"] as? String else { continue }
                        let efforts = (m["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
                        found.append(WorkModel(id: id, name: m["displayName"] as? String ?? id, efforts: efforts, helpers: m["multiAgentVersion"] as? String == "v2",
                                               defaultEffort: m["defaultReasoningEffort"] as? String))
                        if m["hidden"] as? Bool == true { hidden.insert(id) }
                        if m["isDefault"] as? Bool == true { defaults.append(id) }
                    }
                    cursor = r["nextCursor"] as? String
                } while cursor != nil
                // Codex's own pick for a conversation that names no model is its catalog's default; only an unambiguous one counts.
                catalog = found; catalogDefault = defaults.count == 1 ? defaults[0] : nil
                workModels = found.filter { !hidden.contains($0.id) }
            } catch {}   // the menu just stays a label; chat reports a missing Codex itself
        }
    }
    private var loadingWorkModels = false
    private var workModelsLoad: Task<Void, Never>?

    /// The pet's own effort: medium when helpers do work above it (a model with helpers that offers medium), else the
    /// work effort itself, since the pet then works itself or the work needs no more. Medium is a ceiling, never a floor.
    func talkEffort(model: String?, work: String?) -> String? {
        guard let work, let chosen = catalog.first(where: { $0.id == model }), chosen.helpers,
              let medium = chosen.efforts.firstIndex(of: "medium"), let level = chosen.efforts.firstIndex(of: work), level > medium else { return work }
        return "medium"
    }

    /// Settings for a conversation Pulse opens: the helper rule naming the helpers' effort, and the pet's own effort.
    /// The work choice is the owner's pick; without one, a saved conversation's own (read without reopening it, and
    /// remembered, since the pet's lowered effort is saved back to it) or Codex's default for a new one. With no
    /// effort anywhere, Codex runs the model's own default, so that is the work effort. A new conversation whose
    /// settings name no model gets the catalog's default, named explicitly so it is the model the rule was written
    /// for; a saved conversation keeps its own, and an unanswered read leaves both unknown (no split is claimed).
    private func openingConfig(resuming saved: String?) async -> (config: [String: Any], work: String?, model: String?) {
        loadWorkModels(); await workModelsLoad?.value   // which models have helpers
        var model = preferredModel, work = preferredEffort, named: String?, known = true   // known: a read said what's unset
        if work == nil, let saved {
            if let kept = defaults.string(forKey: Self.threadWorkKey), kept.hasPrefix(saved + "=") { work = String(kept.dropFirst(saved.count + 1)) }
            let r = try? await server.request("thread/read", ["threadId": saved, "includeTurns": false], timeout: .seconds(3))   // optional: never stalls an open
            let thread = Self.decoded(r?["thread"], "model", "reasoningEffort")
            known = thread != nil
            if model == nil { model = thread?["model"] as? String }
            if work == nil { work = thread?["reasoningEffort"] as? String }
        } else if work == nil || model == nil {
            let r = try? await server.request("config/read", ["cwd": (try? Self.petHome(at: workspace).path) ?? ""], timeout: .seconds(3))
            let config = Self.decoded(r?["config"], "model", "model_reasoning_effort")
            known = config != nil
            if model == nil { model = config?["model"] as? String }
            if work == nil { work = config?["model_reasoning_effort"] as? String }
            if model == nil, saved == nil, known, let fallback = catalogDefault { model = fallback; named = fallback }
        }
        // The model's own default, only if it offers it: otherwise the effort stays unknown rather than invented.
        if work == nil, known, let row = catalog.first(where: { $0.id == model }), let fallback = row.defaultEffort, row.efforts.contains(fallback) { work = fallback }
        var config = Self.helperConfig(work: work)
        // The owner's pick, or the pet lowered for its helpers; an effort that's Codex's own anyway isn't pinned.
        if let talk = talkEffort(model: model, work: work), talk != work || preferredEffort != nil { config["model_reasoning_effort"] = talk }
        return (config, work, named)
    }

    /// A settings read Pulse can rely on: each named field a string, or unset (absent or null). Anything else, like a
    /// failed read, leaves the settings unknown rather than unset, so no default stands in for them.
    static func decoded(_ read: Any?, _ fields: String...) -> [String: Any]? {
        guard let read = read as? [String: Any], fields.allSatisfy({ read[$0] == nil || read[$0] is NSNull || read[$0] is String }) else { return nil }
        return read
    }

    /// The split counts as applied only when the opened model has helpers and the pet really runs at the lower effort.
    /// If the model was only known once opened (a default with an effort but no model), the pet is lowered then.
    private func settleSplit(_ opened: inout Opened, work: String?) async {
        guard let work, let talk = talkEffort(model: opened.model, work: work), talk != work else { return }
        if opened.effort != talk, (try? await server.request("thread/settings/update", ["threadId": opened.id, "effort": talk])) != nil { opened.effort = talk }
        if opened.effort == talk { opened.helperEffort = work }
    }
    static let threadWorkKey = "petThreadWorkEffort"   // "<thread>=<effort>": a saved conversation's own work choice

    /// Switches the work model and effort. With a conversation to continue it is reopened if needed and
    /// switched there first; the choice is kept for new conversations only once Codex accepted it.
    func chooseWork(model chosen: String, effort level: String) {
        guard !choosingWork, workModels.first(where: { $0.id == chosen })?.efforts.contains(level) == true else { return }
        choosingWork = true
        let conversation = epoch
        Task {
            defer { choosingWork = false }
            if let pending = lookup { await pending.value }   // it may yet find a conversation to continue
            guard conversation == epoch else { return }       // New conversation meanwhile: this choice was for the old one
            // One already being opened (a first message's thread/start still unanswered) counts too.
            guard threadId != nil || threadTask != nil || resumeId != nil || defaults.string(forKey: Self.savedThreadKey) != nil || legacyCandidate != nil else {
                savePreference(chosen, level)   // nothing to continue: the next conversation starts with it
                return
            }
            do {
                let tid = try await ensureThread()
                guard conversation == epoch, tid == threadId else { return }
                // Helpers get the model the pet runs and the effort its rule names. A model that can't run that effort
                // waits for the next open, as a new helper effort does, so no helper is ever asked for a pair Codex refuses.
                if let hint = hintEffort, let next = workModels.first(where: { $0.id == chosen }), next.helpers, !next.efforts.contains(hint) {
                    savePreference(chosen, level)
                    if let shown = switchError, status == shown { status = nil }
                    switchError = nil
                    return
                }
                // The pet's own effort; a new helper effort reaches the rule when the conversation next opens.
                _ = try await server.request("thread/settings/update", ["threadId": tid, "model": chosen, "effort": talkEffort(model: chosen, work: level) ?? level])
                guard conversation == epoch, tid == threadId else { return }
                savePreference(chosen, level)   // the header follows Codex's own thread/settings/updated
                if let shown = switchError, status == shown { status = nil }
                switchError = nil
            } catch {
                guard conversation == epoch else { return }
                switchError = "Couldn't switch the work model (\(error.localizedDescription))."
                status = switchError
            }
        }
    }

    private func savePreference(_ chosen: String, _ level: String) {
        preferredModel = chosen; preferredEffort = level
        defaults.set(chosen, forKey: Self.workModelKey)
        defaults.set(level, forKey: Self.workEffortKey)
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
        inputsSeen += 1; inputNumber = inputsSeen   // typing supersedes any voice answer not yet spoken
        voiceLog.notice("input \(self.inputNumber) typed")
        supersedeReport(); reportsHeld = false
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
                typedPending += 1
                if let joined = turnId { typedInto.insert(joined) }   // Codex steers it into the running turn
                let r: [String: Any]
                do { r = try await server.request("turn/start", ["threadId": tid, "input": [["type": "text", "text": text, "text_elements": []]]]) }
                catch { typedPending -= 1; throw error }
                typedPending -= 1
                if let accepted = (r["turn"] as? [String: Any])?["id"] as? String { typedInto.insert(accepted) }   // maybe a voice turn it joined
                // Stop while Codex was accepting the turn: interrupt it, and helpers it started, as soon as its ID is known.
                if !current(), let accepted = (r["turn"] as? [String: Any])?["id"] as? String {
                    if conversation == epoch { stopHelpers(startedIn: accepted) }
                    if accepted != interruptedTurn {
                        if conversation == epoch { interruptedTurn = accepted }
                        _ = try? await server.request("turn/interrupt", ["threadId": tid, "turnId": accepted])
                    }
                }
            } catch is CancellationError {   // New conversation dropped the thread this was waiting for
            } catch {
                guard current() else { return }
                if mine == sends { thinking = false }
                status = error.localizedDescription
            }
        }
    }

    /// Stop: the pet's current work and this conversation's running helpers. Queued reports wait until the owner
    /// asks for something again, so stopping never immediately starts a report.
    func interrupt() {
        PetApprovals.shared.cancelAll()
        stops += 1
        stopHelpers()
        if let queued = report, !queued.sent { report = nil; for job in queued.jobs { helpers[job]?.state = .finished } }
        report?.stopped = true   // one already sent is never spoken, even if it finishes before the interrupt lands
        reportsHeld = true
        if let turnId { stoppedTurns.insert(turnId) }
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
        realtimeActive = false; voiceTurns = []; askedAt = [:]; voiceResults = [:]; spokenTurns = []; agentText = [:]
        // Running helpers were just asked to stop: keep them until their own end confirms it. A helper the old
        // conversation's work starts later is stopped on sight, never adopted by the new one.
        helpers = helpers.filter { $0.value.isWorking }; unclaimed = [:]
        if let old = threadId {
            retiredRoots[old] = epoch - 1   // kept until the connection to Codex ends: any of them can still report a late helper
        }
        report = nil; reportTurns = []; earlyReportEnd = nil; heldItems = []; cancelledReports = []; reportsHeld = false
        firstAsked = [:]; typedInto = []; stoppedTurns = []; hintEffort = nil   // retiredRoots stay: late helpers
        closesExpected = 0   // the old thread's closes no longer reach this conversation
        threadTask?.cancel(); lookup?.cancel(); lookup = nil
        threadId = nil; threadTask = nil   // next message starts a fresh thread, even if one was being created
        resumeId = nil; legacyCandidate = nil; earlierCursor = nil; recoveryMessage = nil
        model = nil; effort = nil; folder = nil; conversationStarted = nil   // the draft stays: it may be for the new conversation
        defaults.removeObject(forKey: Self.savedThreadKey)
        defaults.set(true, forKey: Self.legacyCheckedKey)   // a fresh start never reopens an older conversation
        turnId = nil; interruptedTurn = nil
        thinking = false; waitingOnYou = false; retrying = false
        countHelpers()
    }

    // MARK: voice (client-owned WebRTC call negotiated through the app-server)

    var isRecording: Bool { (voiceState == .live || voiceState == .speaking) && !muted }
    var microphonePaused: Bool { (voiceState == .live || voiceState == .speaking) && muted }

    /// The waveform button. Starting a call here always listens, even if push-to-talk last left it muted;
    /// `startVoice` itself keeps whatever mute the caller set.
    func toggleVoice() {
        if voiceState == .off { muted = false; startVoice() } else { stopVoice() }
    }

    /// `retryOnAudioGlitch` is false only for the one automatic retry below, so it can never loop.
    func startVoice(retryOnAudioGlitch: Bool = true) {
        guard voiceState == .off else { return }
        voiceMayRetry = retryOnAudioGlitch
        callNumber += 1; voiceInputs = [:]; spokenInputs = [:]; asks = [:]
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
                    // As Codex's CLI: progress notes never reach the voice, which read them as "done" too early.
                    "clientManagedHandoffs": true,
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

    struct Opened {
        let id: String; let history: [ChatMessage]; let earlier: String?; let note: String?; var reconnected = false
        var model: String?, effort: String?, folder: String?, started: Date?
        var hintEffort: String?     // the helpers' effort its rule names
        var helperEffort: String?   // that effort, when the opened model and the pet's lower effort prove a split

        /// The model, folder and start Codex reports when it starts or reopens a thread.
        mutating func describe(_ r: [String: Any]) {
            model = r["model"] as? String
            effort = r["reasoningEffort"] as? String
            folder = (r["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            started = ((r["thread"] as? [String: Any])?["createdAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }

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
                model = opened.model; effort = opened.effort; folder = opened.folder; conversationStarted = opened.started
                // Applied only by the open that became current. Without the owner's pick a split's work effort is
                // remembered for this conversation, so reopening it never mistakes the pet's own medium for it.
                hintEffort = opened.hintEffort
                if preferredEffort == nil, let work = opened.helperEffort { defaults.set("\(opened.id)=\(work)", forKey: Self.threadWorkKey) }
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
        // The helper rule and the pet's own effort apply to Pulse's conversations only, in memory; Codex's own limit
        // on helpers applies. The rule replaces Codex's multi-agent mode message (developer instructions are overruled
        // by it, and not resent on resume); models without that mode never see it.
        var params: [String: Any] = ["cwd": home.path, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"]
        let reconnecting = resumeId != nil   // its messages are still on screen
        var id = resumeId ?? defaults.string(forKey: Self.savedThreadKey) ?? legacyCandidate
        var legacy = id != nil && id == legacyCandidate
        if id == nil && !defaults.bool(forKey: Self.legacyCheckedKey) {
            id = try await newestPetThread(in: home)
            legacy = id != nil
        }
        try Task.checkCancellation()   // New conversation cancels an open that hasn't reached Codex yet
        let opening = await openingConfig(resuming: id)
        params["config"] = opening.config
        try Task.checkCancellation()
        // The owner's model, for a new conversation or a reopened one (where a switch deferred until then applies).
        // The effort is set with the thread, atomically (in openingConfig).
        if let chosen = preferredModel ?? opening.model { params["model"] = chosen }
        guard let id else {
            let r = try await server.request("thread/start", params)
            guard let id = (r["thread"] as? [String: Any])?["id"] as? String else { throw CodexAppServer.Failure.remote("thread/start returned no id") }
            var opened = Opened(id: id, history: [], earlier: nil, note: nil)
            opened.describe(r)
            opened.hintEffort = opening.work
            // A model Pulse named as Codex's default must be the one that opened; otherwise no split is claimed.
            if opening.model == nil || opened.model == opening.model { await settleSplit(&opened, work: opening.work) }
            return opened
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
        var opened = Opened(id: id, history: history, earlier: page?["nextCursor"] as? String, note: notes.isEmpty ? nil : notes.joined(separator: " "), reconnected: reconnecting)
        opened.describe(r)
        opened.hintEffort = opening.work
        await settleSplit(&opened, work: opening.work)
        return opened
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
            let items = turn["items"] as? [[String: Any]] ?? []
            let asked = items.first { $0["type"] as? String == "userMessage" }.map(text(of:)) ?? ""
            // Work the voice handed over: its progress notes stay out and its replies are marked. Typed
            // turns read as they did live.
            let caption: String? = isTranscriptFlush(asked) ? "After the call" : isDelegation(asked) ? "Work result"
                : asked.hasPrefix(reportTag) ? "Helper result" : nil
            return items.compactMap { item -> ChatMessage? in
                switch item["type"] as? String {
                case "userMessage":
                    let text = Self.text(of: item)
                    guard !isTranscriptFlush(text), !text.hasPrefix(reportTag) else { return nil }   // core's end-of-call handoff, Pulse's report request
                    let shown = spokenRequest(text)
                    return shown.isEmpty ? nil : ChatMessage(role: .user, text: shown)
                case "agentMessage":
                    let text = item["text"] as? String ?? ""
                    if text.isEmpty || (caption != nil && isPrivateNote(text, phase: item["phase"] as? String)) { return nil }
                    return ChatMessage(role: .assistant, text: text, caption: caption)
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
        // Another thread's events are a helper's, or an old conversation's: never this conversation's state.
        if let tid = p["threadId"] as? String, tid != threadId { return helperEvent(tid, method, p) }
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
            if type == "subAgentActivity" { noteHelperActivity(item, turn: (p["turnId"] as? String) ?? turnId, under: nil) }
            let asked = type == "userMessage" ? Self.text(of: item) : ""
            if Self.isDelegation(asked), let turn = (p["turnId"] as? String) ?? turnId {
                voiceTurns.insert(turn)   // the voice handed this to Codex, even if the call has since ended
                if realtimeActive && !Self.isTranscriptFlush(asked) {   // a question this call asked, maybe of running work
                    supersedeReport(); reportsHeld = false
                    if firstAsked[turn] == nil { firstAsked[turn] = callNumber }
                    // It answers the utterance this call transcribed with its words, once that transcript is in;
                    // one never transcribed here (reworded, or from an earlier call) is only shown.
                    let words = Self.words(Self.spokenRequest(asked))
                    asks[words] = turn
                    if let input = spokenInputs[words] { bind(turn, to: input) }
                    else { voiceLog.notice("turn \(turn, privacy: .public) asked; waiting for its transcript") }
                }
            }
        case "item/completed":
            guard let item = p["item"] as? [String: Any], let id = item["id"] as? String else { return }
            if let i = activity.firstIndex(where: { $0.id == id }) { activity[i].done = true }
            if item["type"] as? String == "subAgentActivity" { noteHelperActivity(item, turn: (p["turnId"] as? String) ?? turnId, under: nil) }
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                let asks = !((item["questions"] as? [Any])?.isEmpty ?? true)
                updateAgent(text, item: id, params: p, completed: true, phase: item["phase"] as? String, asks: asks)
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
            if let done = turn?["id"] as? String, let turn {
                // A report's end can beat Codex's reply to its turn/start: it's settled when that reply names it.
                if let pending = report, pending.sent, pending.turn == nil, !voiceTurns.contains(done) { earlyReportEnd = turn }
                else { settleTurn(turn) }
            }
            retrying = false
            activity = activity.filter { !$0.done }.suffix(6).map { $0 }
            reportIfIdle()
        case "thread/settings/updated":   // Codex's own word on the model and effort now in use
            guard let settings = p["threadSettings"] as? [String: Any] else { return }
            if let current = settings["model"] as? String { model = current }
            effort = settings["effort"] as? String
        case "model/rerouted":
            guard let from = p["fromModel"] as? String, let to = p["toModel"] as? String else { return }
            messages.append(ChatMessage(role: .note, text: "Codex used \(to) instead of \(from) for this request."))
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
                if role == "user", realtimeActive { noteVoiceInput(id, sofar: text, complete: completed) }
            }   // a bemItemPromoted adds nothing: every result already shows, and progress notes stay out
        case "thread/realtime/item/transcript/delta":
            guard let id = p["itemId"] as? String, let delta = p["delta"] as? String,
                  let i = messages.firstIndex(where: { $0.sourceID == "voice:" + id }), messages[i].live else { return }
            messages[i].text += delta
            if messages[i].role == .user, realtimeActive { noteVoiceInput(id, sofar: messages[i].text, complete: false) }
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
            catalog = []; catalogDefault = nil   // the next server's catalog is read again; the menu keeps showing this one until then
            realtimeActive = false; realtimeRequested = false; closesExpected = 0
            finishLive()
            turnId = nil; interruptedTurn = nil
            thinking = false; waitingOnYou = false
            if voiceState != .off { voiceState = .off; VoiceBridge.shared.close() }
            resumeId = threadId ?? resumeId   // the next message reconnects to this same conversation
            threadId = nil
            let lost = helpers.values.filter { $0.epoch == epoch && $0.parent == nil && $0.isWorking }.count
            helpers = [:]; unclaimed = [:]; report = nil; reportTurns = []; earlyReportEnd = nil; heldItems = []; cancelledReports = []; retiredRoots = [:]
            if lost > 0 { messages.append(ChatMessage(role: .note, text: "Pulse lost track of \(lost == 1 ? "a helper" : "\(lost) helpers") when Codex's app-server stopped; that work may be unfinished.")) }
            countHelpers()
            status = "Codex app-server stopped. Your next message reconnects to this conversation."
            recoveryMessage = status
        default: break
        }
    }

    /// Voice work and reports end here: the finished turn's own items are the authority on its result.
    private func settleTurn(_ turn: [String: Any]) {
        guard let done = turn["id"] as? String, voiceTurns.contains(done) || reportTurns.contains(done) else { return }
        // The finished turn's own items are the authority on its result, as in Codex's CLI: one only
        // they carry still shows, a changed one replaces what streamed, and none means nothing to say.
        let final = (turn["items"] as? [[String: Any]] ?? []).last {
            $0["type"] as? String == "agentMessage" && !Self.isPrivateNote($0["text"] as? String ?? "", phase: $0["phase"] as? String)
        }
        voiceResults[done] = nil
        if let final, let id = final["id"] as? String, let text = final["text"] as? String {
            updateAgent(text, item: id, params: ["turnId": done], completed: true, phase: final["phase"] as? String,
                        asks: !((final["questions"] as? [Any])?.isEmpty ?? true))
        }
        voiceLog.notice("turn \(done, privacy: .public) \(turn["status"] as? String ?? "?", privacy: .public): \((turn["items"] as? [Any])?.count ?? 0) items, result \(final?["id"] as? String ?? "none", privacy: .public)\(self.voiceResults[done]?.asks == true ? " (a question)" : "", privacy: .public)")
        if turn["status"] as? String == "completed" { speakResult(of: done) }
        if report?.turn == done { reportEnded(turn) }
    }

    private func updateAgent(_ text: String, item: String, params: [String: Any], completed: Bool, phase: String? = nil, asks: Bool = false) {
        let turn = (params["turnId"] as? String) ?? turnId ?? ""
        if cancelledReports.contains(turn), !voiceTurns.contains(turn) { return }
        // While a report's turn/start is unanswered, an unknown turn's items may be the report's: held until the reply says.
        if let pending = report, pending.sent, pending.turn == nil, !voiceTurns.contains(turn), !reportTurns.contains(turn) {
            var params = params; params["turnId"] = turn
            heldItems.append((text, item, params, completed, phase, asks))
            return
        }
        let key = "agent:\(turn):\(item)"
        if completed { agentText[key] = text } else { agentText[key, default: ""] += text }
        // Work the voice handed over shows its results once each, never its progress notes (an unknown
        // phase counts as final). A result shows whether or not the voice speaks it, so nothing depends on
        // being heard: marked as work, or as coming after the call if it finished once the call had ended.
        if voiceTurns.contains(turn) || reportTurns.contains(turn) {
            guard completed, !Self.isPrivateNote(text, phase: phase) else { return }
            voiceResults[turn] = (key, asks)
            let caption = !voiceTurns.contains(turn) ? "Helper result" : realtimeActive ? "Work result" : "After the call"
            setMessage(text, role: .assistant, key: key, live: false, caption: caption)
            return
        }
        setMessage(agentText[key] ?? "", role: .assistant, key: key, live: !completed)
    }

    /// A progress note, or one Codex marks private ([ANALYSIS]/[COMMENTARY] without a final phase), as its CLI reads them.
    static func isPrivateNote(_ text: String, phase: String?) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return phase == "commentary" || text.isEmpty
            || (phase != "final_answer" && (text.hasPrefix("[ANALYSIS]") || text.hasPrefix("[COMMENTARY]") || text == "[FINAL]"))
    }

    /// Speaks a finished turn's result once, as Codex's CLI does, into the call whose voice asked for it, if
    /// nothing was said or typed since. Otherwise, and for failed or stopped turns, it is only shown. A question
    /// or a long answer stays in the chat, and the voice says so. The check and the write are one step, so
    /// hanging up, typing or a new call can't slip between them; once written it can't be recalled, and it
    /// is never retried, which could speak it twice.
    private func speakResult(of turn: String) {
        let asked = askedAt[turn]
        let gates: [(ok: Bool, why: String)] = [   // the first that fails is the reason, for the log
            (voiceResults[turn] != nil, "no result"),
            (asked != nil, "not asked in a call"),
            (asked?.call == callNumber, "asked in an earlier call"),
            (asked?.input == inputNumber, "newer input since"),
            (realtimeActive && realtimeRequested && (voiceState == .live || voiceState == .speaking), "no live call"),
            (threadId != nil, "no conversation"),
            (!spokenTurns.contains(turn), "already handled"),
        ]
        if let failed = gates.first(where: { !$0.ok }) {
            voiceLog.notice("turn \(turn, privacy: .public) not spoken: \(failed.why, privacy: .public)")
            return
        }
        guard let result = voiceResults[turn], let tid = threadId else { return }
        submitSpeech(turn, result, tid)
    }

    /// Hands a finished result to the voice, once per turn. A question or a long answer stays in the chat, and
    /// the voice says so. Never retried: it could speak twice.
    private func submitSpeech(_ turn: String, _ result: (key: String, asks: Bool), _ tid: String) {
        spokenTurns.insert(turn)
        var text = (agentText[result.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[FINAL]") { text = text.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty else { voiceLog.notice("turn \(turn, privacy: .public) not spoken: empty result"); return }
        // ponytail: the CLI caps speech at 990 estimated tokens; ~4 UTF-8 bytes a token approximates its estimate
        let kind = result.asks ? "question pointer" : text.utf8.count > 990 * 4 ? "long-answer pointer" : "result"
        let speech = result.asks ? "Codex has a question for you in the pet chat."
            : text.utf8.count > 990 * 4 ? "Codex's answer is in the pet chat." : text
        let written = server.post("thread/realtime/appendSpeech", ["threadId": tid, "text": speech])
        voiceLog.notice("turn \(turn, privacy: .public): \(kind, privacy: .public) \(written ? "written to Codex for the voice (not proof it was heard)" : "could not be written to Codex", privacy: .public)")
    }

    /// A new utterance supersedes any answer not yet spoken, from its first words; a transcript that stays empty
    /// (a cough, a noise) never does. Each keeps its place in line from when it first appeared, so one whose words
    /// come late never jumps ahead of newer speech or typing. A request the voice handed over before its own
    /// transcript finished is matched to it by its words, so its answer still speaks.
    private func noteVoiceInput(_ id: String, sofar text: String, complete: Bool) {
        if voiceInputs[id] == nil { inputsSeen += 1; voiceInputs[id] = inputsSeen }
        guard let input = voiceInputs[id] else { return }
        if input > inputNumber, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {   // repeats and late words never move it back
            inputNumber = input
            supersedeReport()
            voiceLog.notice("input \(input) spoken (transcript \(id, privacy: .public))")
        }
        guard complete else { return }
        let words = Self.words(text)
        guard !words.isEmpty else { return }
        let newest = max(spokenInputs[words] ?? 0, input)   // a late repeat of an older utterance keeps the newer one
        spokenInputs[words] = newest
        if let turn = asks[words] { bind(turn, to: newest) }
    }

    /// A turn answers the newest input this call matched to it; a repeat never moves it back.
    private func bind(_ turn: String, to input: Int) {
        if let had = askedAt[turn], had.call == callNumber, had.input >= input { return }
        // A binding in the call that was live when a helper started proves that helper's owner; any other never does.
        for (thread, helper) in helpers where helper.spawnTurn == turn && helper.owner == nil && helper.ownerCall == callNumber {
            helpers[thread]?.owner = callNumber; helpers[thread]?.ownerCall = nil
        }
        askedAt[turn] = (callNumber, input)
        voiceLog.notice("turn \(turn, privacy: .public) answers input \(input) of call \(self.callNumber)")
    }

    /// What was said, for matching a request to its transcript: lowercase words, without the request's escaping.
    static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
            .lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    // MARK: helpers (Codex sub-agents) and their reports

    /// Sent with each conversation Pulse opens, never written to the folder's AGENTS.md: only Pulse wakes the pet
    /// when a helper finishes, so a CLI session in the same folder must not start helpers and wait for nobody.
    static func helperConfig(work: String?) -> [String: Any] {
        ["features.multi_agent_v2.multi_agent_mode_hint_text": helperRule + (work.map { " Pass reasoning_effort \"\($0)\" to spawn_agent." } ?? "")]
    }
    static let helperRule = """
    Pulse helpers. This applies only if your spawn_agent tool accepts fork_turns. If another agent started you (you are a helper), do your task yourself and never start helpers.
    Hand substantial work (building something, research, multi-step changes) or anything the owner asks to run in the background to one helper with spawn_agent. Give it a self-contained task: the exact asks, the files it owns and any constraints. Use fork_turns "none" unless it truly needs the recent conversation. Tell the owner in one sentence that it has started, then end your turn: don't wait for it, verify it or bring up its result yourself; Pulse will ask you for a report. Answer the owner's other questions directly. If asked about a helper, check list_agents before answering. Helpers don't open browsers or apps unless the owner asked.
    """

    /// A helper started: by the pet (its first turn becomes the job), or by a helper, which Pulse stops on sight.
    /// Its owner is fixed now, or later by a binding of its request in the call that was live when it started; never
    /// borrowed from another call.
    private func noteHelperActivity(_ item: [String: Any], turn: String?, under parent: String?, retiredEpoch: Int? = nil) {
        let retiring = retiredEpoch != nil
        guard item["kind"] as? String == "started", let child = item["agentThreadId"] as? String, helpers[child] == nil, let turn else { return }
        var helper = Helper(path: item["agentPath"] as? String ?? "helper", spawnTurn: turn, epoch: retiredEpoch ?? epoch, parent: parent)
        // Only the call that first asked into this turn can own it; once typed input joined (or is joining), later
        // helpers are chat only: which request they serve can't be proven.
        if parent == nil, !retiring, let call = firstAsked[turn], typedPending == 0, !typedInto.contains(turn) {
            if let asked = askedAt[turn], asked.call == call { helper.owner = call } else { helper.ownerCall = call }
        }
        helper.stopping = parent != nil || retiring || stoppedTurns.contains(turn)   // a helper's own helper, or one stopped work started
        helpers[child] = helper
        voiceLog.notice("helper \(child, privacy: .public) registered\(parent == nil ? "" : " under a helper; stopping it", privacy: .public)")
        for (method, p) in unclaimed.removeValue(forKey: child) ?? [] { helperEvent(child, method, p) }
        countHelpers()
    }

    /// A helper's turn starts and ends, and helpers it starts: nothing else of a helper's reaches this conversation.
    private func helperEvent(_ thread: String, _ method: String, _ p: [String: Any]) {
        let item = p["item"] as? [String: Any]
        guard var helper = helpers[thread] else {
            if let retired = retiredRoots[thread] {
                if let item, item["type"] as? String == "subAgentActivity" { noteHelperActivity(item, turn: p["turnId"] as? String, under: nil, retiredEpoch: retired) }
                return
            }
            // A helper's first events can beat its registration on the pet's thread: keep a few, briefly.
            guard method.hasPrefix("turn/") || item?["type"] as? String == "subAgentActivity",
                  unclaimed[thread] != nil || unclaimed.count < 4 else { return }
            unclaimed[thread, default: []].append((method, p))
            if unclaimed[thread]!.count > 6 { unclaimed[thread]!.removeFirst() }
            return
        }
        switch method {
        case "turn/started":
            guard let id = (p["turn"] as? [String: Any])?["id"] as? String else { return }
            helper.currentTurn = id
            if helper.firstTurn == nil { helper.firstTurn = id }
            helpers[thread] = helper
            countHelpers()   // a later turn of a known helper is work too: Stop stays available for it
            if helper.stopping { stopHelperTurn(thread, id) }
        case "turn/completed":
            let turn = p["turn"] as? [String: Any]
            guard let id = turn?["id"] as? String else { return }
            let endsCurrent = helper.currentTurn == id || helper.currentTurn == nil   // a repeat of an older end doesn't
            if helper.currentTurn == id { helper.currentTurn = nil }
            if helper.firstTurn == nil { helper.firstTurn = id }
            let status = turn?["status"] as? String ?? "unknown"
            // Only the work it was started for is its outcome; later turns aren't reported in this version, but a
            // stop of one is confirmed by its own end.
            guard id == helper.firstTurn, helper.outcome == nil else {
                if endsCurrent, helper.stopping, status == "interrupted", helper.parent == nil { noteStopped(helper) }
                if endsCurrent, helper.parent == nil { helper.stopping = false }   // the next piece of work isn't stopped in advance
                helpers[thread] = helper.epoch != epoch && !helper.isWorking ? nil : helper
                countHelpers()
                return
            }
            let final = (turn?["items"] as? [[String: Any]] ?? []).last {
                $0["type"] as? String == "agentMessage" && !Self.isPrivateNote($0["text"] as? String ?? "", phase: $0["phase"] as? String)
            }?["text"] as? String
            helper.outcome = (status, final)
            let stopped = helper.stopping && status == "interrupted"
            helper.state = stopped || helper.parent != nil || helper.epoch != epoch ? .reported : .finished
            helpers[thread] = helper
            voiceLog.notice("helper \(thread, privacy: .public) ended \(status, privacy: .public)\(final == nil ? " without a final message" : "", privacy: .public)")
            if stopped, helper.parent == nil { noteStopped(helper) }   // a stop is confirmed only by the helper's own end
            if helper.parent == nil { helpers[thread]?.stopping = false }
            if helper.epoch != epoch { helpers[thread] = nil }
            countHelpers()
            reportIfIdle()
        case "item/started", "item/completed":
            if let item, item["type"] as? String == "subAgentActivity" { noteHelperActivity(item, turn: p["turnId"] as? String, under: thread) }
        default: break
        }
    }

    /// Stop asks every working helper to stop (or those a stopped turn of the pet's started, which also stops the ones
    /// it starts later): its first job or a later turn. "Stopped" is said only when that work's own end confirms it;
    /// work whose turn isn't known yet is stopped as soon as it is.
    private func stopHelpers(startedIn stopped: String? = nil) {
        if let stopped { stoppedTurns.insert(stopped) }
        for (thread, helper) in helpers where helper.isWorking && !helper.stopping && (stopped == nil || helper.spawnTurn == stopped) {
            helpers[thread]?.stopping = true
            if let turn = helper.currentTurn { stopHelperTurn(thread, turn) }
        }
    }

    private func noteStopped(_ helper: Helper) {
        messages.append(ChatMessage(role: .note, text: helper.epoch == epoch ? "Stopped helper \(helper.name)."
            : "Stopped helper \(helper.name) from the previous conversation. (This note isn't saved.)"))
    }

    private func stopHelperTurn(_ thread: String, _ turn: String) {
        Task {
            do { _ = try await server.request("turn/interrupt", ["threadId": thread, "turnId": turn]) }
            catch {
                // Already ended: its own turn/completed settles it, as does work that has since ended or moved on.
                guard !error.localizedDescription.contains("no active turn"), let helper = helpers[thread], helper.currentTurn == turn else { return }
                // A real failure to stop, which Stop may try again. (A helper's own helper stays marked: any later turn
                // of it is still stopped on sight.) It's this conversation's problem only if the helper is its own.
                if helper.parent == nil { helpers[thread]?.stopping = false }
                if helper.epoch == epoch { status = "Couldn't stop helper \(helper.name): \(error.localizedDescription)" }
                else { messages.append(ChatMessage(role: .note, text: "Couldn't stop helper \(helper.name) from the previous conversation (\(error.localizedDescription)); it may still be running. (This note isn't saved.)")) }
            }
        }
    }

    /// Who is asking for approval: nil for the pet's own conversation; a helper's name, or "a helper" until it's known.
    private func helperLabel(_ thread: String) -> String? {
        thread == threadId ? nil : helpers[thread]?.name ?? "a helper"
    }

    private func countHelpers() {
        let working = helpers.values.filter { $0.epoch == epoch && $0.parent == nil && $0.isWorking }.count
        if helpersWorking != working { helpersWorking = working }
    }

    /// Asks the pet to tell the owner how finished helpers went, once the pet is free: never inside the owner's
    /// own turn. One owner per report, so a call never hears a typed request's or another call's result; the
    /// live call's helpers go first.
    private func reportIfIdle() {
        guard report == nil, !reportsHeld, turnId == nil, !thinking, !waitingOnYou, threadId != nil else { return }
        let ready = helpers.filter { $0.value.state == .finished && $0.value.epoch == epoch && $0.value.parent == nil }
        guard let first = ready.first else { return }
        let live: Int? = realtimeActive ? callNumber : nil
        let owner = live != nil && ready.contains { $0.value.owner == live } ? live : first.value.owner
        let jobs = ready.filter { $0.value.owner == owner }.map(\.key).sorted()
        reportSeq += 1
        report = Report(seq: reportSeq, jobs: jobs, owner: owner, epoch: epoch, speak: owner != nil && jobs.allSatisfy { helpers[$0]!.failedReports <= 1 })
        for job in jobs { helpers[job]?.state = .reporting }
        let input = reportInput(jobs)
        let previous = lastSend, stop = stops, conversation = epoch, seq = reportSeq
        lastSend = Task {
            await previous?.value   // the same queue as typed messages
            // Re-checked after waiting: anything newer wins, and the report waits for the next idle moment.
            guard stop == stops, conversation == epoch, report?.seq == seq, report?.superseded == false,
                  turnId == nil, !thinking, let tid = threadId else { return reportDidNotRun(seq) }
            report?.sent = true
            thinking = true
            voiceLog.notice("report \(seq) for \(jobs.count) helper(s) started")
            do {
                let r = try await server.request("turn/start", ["threadId": tid, "input": [["type": "text", "text": input, "text_elements": []]]])
                guard let accepted = (r["turn"] as? [String: Any])?["id"] as? String else { return reportDidNotRun(seq) }
                // Stop or New conversation while Codex accepted it: stop that turn first; it is never shown or requeued
                // (after Stop its helpers wait, held, for the owner's next input).
                if stop != stops || conversation != epoch {
                    if earlyReportEnd?["id"] as? String == accepted { earlyReportEnd = nil }
                    if conversation == epoch {
                        if report?.seq == seq { report = nil; for job in jobs { helpers[job]?.state = .finished } }
                        cancelledReports.insert(accepted)
                        releaseHeldItems()
                        stopHelpers(startedIn: accepted)
                    }
                    _ = try? await server.request("turn/interrupt", ["threadId": tid, "turnId": accepted])
                    return
                }
                reportTurns.insert(accepted)
                guard report?.seq == seq else { return releaseHeldItems() }
                report?.turn = accepted
                releaseHeldItems()
                // It may have ended already: settled now, and the next batch of finished helpers reports.
                if let early = earlyReportEnd, early["id"] as? String == accepted { earlyReportEnd = nil; settleTurn(early); reportIfIdle() }
            } catch {
                if conversation == epoch { thinking = false }
                reportDidNotRun(seq)
            }
        }
    }

    /// The report's turn/start was answered, or never will be: held items show, the report's own through its
    /// final-only filter; a cancelled report's, never.
    private func releaseHeldItems() {
        let held = heldItems; heldItems = []
        for h in held {
            updateAgent(h.text, item: h.item, params: h.params, completed: h.completed, phase: h.phase, asks: h.asks)
        }
    }

    /// A report that never started costs no try. A busy pet retries when its turn ends; one something newer
    /// superseded tries again after a moment, in case that never became a turn.
    private func reportDidNotRun(_ seq: Int) {
        guard let mine = report, mine.seq == seq else { return }
        report = nil
        releaseHeldItems()
        for job in mine.jobs { helpers[job]?.state = .finished }
        if mine.superseded { Task { try? await Task.sleep(for: .seconds(5)); reportIfIdle() } }
    }

    /// A report turn ended. Spoken only if nothing newer came in, Stop wasn't pressed, the turn completed and its call
    /// is still live. One that didn't finish tries again: once more spoken, then in the chat; a third failure gives up.
    /// Stop costs no try: its jobs wait, held, for the owner's next ask.
    private func reportEnded(_ turn: [String: Any]) {
        guard let mine = report, let id = turn["id"] as? String, mine.turn == id else { return }
        report = nil
        if turn["status"] as? String == "completed" && !mine.superseded {
            for job in mine.jobs { helpers[job]?.state = .reported }
            let gates: [(ok: Bool, why: String)] = [
                (!mine.stopped, "stopped"),
                (mine.speak, "chat only"),
                (mine.owner == callNumber, "asked in another call, or typed"),
                (mine.epoch == epoch, "older conversation"),
                (realtimeActive && realtimeRequested && (voiceState == .live || voiceState == .speaking), "no live call"),
                (voiceResults[id] != nil, "no result"),
                (!spokenTurns.contains(id), "already handled"),
            ]
            if let failed = gates.first(where: { !$0.ok }) {
                voiceLog.notice("report turn \(id, privacy: .public) not spoken: \(failed.why, privacy: .public)")
            } else if let result = voiceResults[id], let tid = threadId {
                submitSpeech(id, result, tid)
            }
        } else if mine.stopped {
            voiceLog.notice("report turn \(id, privacy: .public) stopped")
            for job in mine.jobs { helpers[job]?.state = .finished }
        } else {
            // A chat-only report that didn't finish hasn't shown its result either: the same tries as a spoken one.
            voiceLog.notice("report turn \(id, privacy: .public) \(mine.superseded ? "superseded" : "cut short", privacy: .public)")
            for job in mine.jobs {
                helpers[job]?.failedReports += 1
                if let tries = helpers[job]?.failedReports { helpers[job]?.state = tries > 2 ? .reported : .finished }
            }
        }
    }

    /// The owner said or typed something new: a report not yet spoken stands down, before its words reach Codex.
    private func supersedeReport() {
        guard report?.superseded == false else { return }
        report?.superseded = true
        voiceLog.notice("report superseded by newer input")
    }

    /// Pulse's own request for a report, hidden from the chat: the facts it already holds, so the answer never
    /// depends on when Codex delivers the helpers' mail.
    private func reportInput(_ jobs: [String]) -> String {
        let lines = jobs.compactMap { helpers[$0] }.map { helper -> String in
            let status = helper.outcome?.status ?? "unknown"
            let final = helper.outcome?.final.map { " Its final message: \"\(String($0.prefix(2000)))\"" } ?? " It left no final message."
            return "- \(helper.path): ended with status \(status).\(final)"
        }
        return Self.reportTag + "\nThese helpers you started have ended. Tell the owner the outcome of exactly these, in one or two sentences each. Say plainly if one failed, was refused or was stopped: status completed alone doesn't mean it succeeded. Don't mention anything else.\n" + lines.joined(separator: "\n") + "\n</pulse_helper_report>"
    }
    static let reportTag = "<pulse_helper_report>"

    /// A request the voice handed to Codex (core wraps it in <realtime_delegation>).
    static func isDelegation(_ text: String) -> Bool { text.hasPrefix("<realtime_delegation>") }

    /// Core's handoff of a call's last words: a delegation whose source is the transcript tail flush.
    static func isTranscriptFlush(_ text: String) -> Bool {
        isDelegation(text) && text.contains("<source>transcript_tail_flush</source>")
    }

    static func text(of item: [String: Any]) -> String {
        (item["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    private func setMessage(_ text: String, role: ChatMessage.Role, key: String, live: Bool, caption: String? = nil) {
        if let i = messages.firstIndex(where: { $0.sourceID == key }) {
            messages[i].text = text
            messages[i].live = live
            if messages[i].caption == nil { messages[i].caption = caption }   // a bubble that became a result keeps its first mark
        } else {
            messages.append(ChatMessage(role: role, text: text, live: live, sourceID: key, caption: caption))
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
