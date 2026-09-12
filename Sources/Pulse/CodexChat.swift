import Foundation
import WebKit

// MARK: - Codex app-server over stdio (JSON-RPC, one JSON object per line)
//
// The pet's chat, live voice, and activity all ride on Codex's own app-server, which signs in with
// ~/.codex/auth.json: the same subscription the Codex app uses, no API key. The process is spawned
// the first time the pet card opens and lives until Pulse quits (the usage rings never touch it).

final class CodexAppServer: @unchecked Sendable {
    static let shared = CodexAppServer()

    enum Failure: LocalizedError {
        case notInstalled, notRunning, remote(String), transport
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Codex CLI not found (install codex, then sign in)"
            case .notRunning: "Codex app-server is not running"
            case .remote(let m): m
            case .transport: "Codex app-server connection closed"
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
    private(set) var ready = false

    private init() {
        // the child does not always notice a closed stdin; end it with Pulse
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stop()
        }
    }

    /// Spawns and initializes once; later calls return immediately.
    func start() async throws {
        if lock.withLock({ process?.isRunning == true && ready }) { return }
        guard let bin = locateBinary("codex") else { throw Failure.notInstalled }
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
            if data.isEmpty { h.readabilityHandler = nil; self?.closed(); return }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] _ in self?.closed() }
        try p.run()
        lock.withLock {
            process = p
            stdin = inPipe.fileHandleForWriting
            buffer = Data()
        }
        _ = try await request("initialize", ["clientInfo": ["name": "pulse", "title": "Pulse", "version": "0.1"],
                                             "capabilities": ["experimentalApi": true]])
        notify("initialized", [:])
        lock.withLock { ready = true }
    }

    func stop() {
        lock.lock()
        let p = process
        process = nil; stdin = nil; ready = false
        lock.unlock()
        p?.terminate()
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let (stdin, id): (FileHandle, Int) = try lock.withLock {
            guard let stdin, process?.isRunning == true else { throw Failure.notRunning }
            defer { nextID += 1 }
            return (stdin, nextID)
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { pending[id] = cont }
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params], to: stdin)
            } catch {
                lock.withLock { pending[id] = nil }
                cont.resume(throwing: Failure.transport)
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        lock.lock(); let stdin = stdin; lock.unlock()
        guard let stdin else { return }
        try? write(["jsonrpc": "2.0", "method": method, "params": params], to: stdin)
    }

    /// Answer a server-initiated request (approvals, user input). The pet never grants; it declines.
    func respond(id: Any, error message: String) {
        lock.lock(); let stdin = stdin; lock.unlock()
        guard let stdin else { return }
        try? write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]], to: stdin)
    }

    private func write(_ obj: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            dispatch(msg)
        }
    }

    private func dispatch(_ msg: [String: Any]) {
        let method = msg["method"] as? String
        if let id = msg["id"] as? Int, method == nil {
            lock.lock(); let cont = pending.removeValue(forKey: id); lock.unlock()
            if let err = msg["error"] as? [String: Any] {
                cont?.resume(throwing: Failure.remote((err["message"] as? String) ?? "Codex error"))
            } else {
                cont?.resume(returning: (msg["result"] as? [String: Any]) ?? [:])
            }
            return
        }
        guard let method else { return }
        if let id = msg["id"] {
            // server → client request: the pet has no approval UI, so decline and let the turn continue
            respond(id: id, error: "not supported by Pulse")
            DispatchQueue.main.async { self.onNotification?("serverRequest/declined", ["method": method]) }
            return
        }
        let params = (msg["params"] as? [String: Any]) ?? [:]
        DispatchQueue.main.async { self.onNotification?(method, params) }
    }

    private func closed() {
        lock.lock()
        let waiting = pending; pending = [:]
        process = nil; stdin = nil; ready = false
        lock.unlock()
        for (_, c) in waiting { c.resume(throwing: Failure.transport) }
        DispatchQueue.main.async { self.onNotification?("pulse/closed", [:]) }
    }
}

// MARK: - Pet session: one Codex thread carrying text turns and live voice

struct ChatMessage: Identifiable {
    enum Role { case user, assistant, note }
    let id = UUID()
    var role: Role
    var text: String
    var live = false   // still streaming
}

struct ActivityPill: Identifiable {
    let id: String
    var label: String
    var done = false
}

@MainActor
final class CodexPetSession: ObservableObject {
    static let shared = CodexPetSession()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var activity: [ActivityPill] = []
    @Published private(set) var thinking = false
    @Published private(set) var voiceState: VoiceState = .off
    @Published var muted = false { didSet { VoiceBridge.shared.setMuted(muted) } }
    @Published private(set) var status: String?   // connection / error line under the composer

    enum VoiceState { case off, connecting, live, speaking }

    private let server = CodexAppServer.shared
    private var threadId: String?
    private var turnId: String?
    private var streamingItem: String?
    private var voiceStartTask: Task<Void, Never>?

    init() {
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
            } catch {
                thinking = false
                status = error.localizedDescription
            }
        }
    }

    func interrupt() {
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
        threadId = nil   // next message starts a fresh thread
        turnId = nil
        thinking = false
    }

    // MARK: voice (client-owned WebRTC call negotiated through the app-server)

    func toggleVoice() {
        if voiceState == .off { startVoice() } else { stopVoice() }
    }

    func startVoice() {
        guard voiceState == .off else { return }
        voiceState = .connecting
        status = nil
        voiceStartTask = Task {
            do {
                let tid = try await ensureThread()
                try Task.checkCancellation()
                let offer = try await VoiceBridge.shared.createOffer(muted: muted)
                try Task.checkCancellation()
                _ = try await server.request("thread/realtime/start", [
                    "threadId": tid,
                    "transport": ["type": "webrtc", "sdp": offer],
                    "version": "v3",              // the subscription-backed session; v1/v2 need an API key
                    "voice": "cove",
                    "outputModality": "audio",
                    "includeStartupContext": false,
                    "flushTranscriptTailOnSessionEnd": true,
                ])
                // the answer arrives as thread/realtime/sdp
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

    private func ensureThread() async throws -> String {
        try await server.start()
        if let threadId { return threadId }
        let r = try await server.request("thread/start", [
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
        ])
        guard let id = (r["thread"] as? [String: Any])?["id"] as? String else { throw CodexAppServer.Failure.remote("thread/start returned no id") }
        threadId = id
        return id
    }

    private func handle(_ method: String, _ p: [String: Any]) {
        if let tid = p["threadId"] as? String, tid != threadId { return }
        switch method {
        case "turn/started":
            turnId = (p["turn"] as? [String: Any])?["id"] as? String
        case "item/agentMessage/delta":
            guard let delta = p["delta"] as? String, let item = p["itemId"] as? String else { return }
            append(delta, role: .assistant, key: item)
        case "item/started":
            guard let item = p["item"] as? [String: Any], let type = item["type"] as? String, let id = item["id"] as? String else { return }
            if let label = activityLabel(type, item) { activity.append(ActivityPill(id: id, label: label)) }
        case "item/completed":
            guard let item = p["item"] as? [String: Any], let id = item["id"] as? String else { return }
            if let i = activity.firstIndex(where: { $0.id == id }) { activity[i].done = true }
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                if let i = messages.lastIndex(where: { $0.live && $0.role == .assistant }) {
                    messages[i].text = text; messages[i].live = false
                } else if !text.isEmpty {
                    messages.append(ChatMessage(role: .assistant, text: text))
                }
                streamingItem = nil
            }
        case "turn/completed":
            turnId = nil
            thinking = false
            finishLive()
            activity = activity.filter { !$0.done }.suffix(6).map { $0 }
        case "error":
            thinking = false
            status = ((p["error"] as? [String: Any])?["message"] as? String) ?? "Codex error"
        case "thread/realtime/sdp":
            if let sdp = p["sdp"] as? String { VoiceBridge.shared.accept(answer: sdp) }
        case "thread/realtime/started":
            if voiceState == .connecting { voiceState = .live }
        case "thread/realtime/transcript/delta":
            guard let delta = p["delta"] as? String, let role = p["role"] as? String else { return }
            append(delta, role: role == "user" ? .user : .assistant, key: "rt-" + role)
        case "thread/realtime/transcript/done":
            finishLive()
        case "thread/realtime/error":
            status = p["message"] as? String
            voiceState = .off
            VoiceBridge.shared.close()
        case "thread/realtime/closed":
            if voiceState != .off { voiceState = .off; VoiceBridge.shared.close() }
        case "pulse/voice":
            // events off the WebRTC data channel: speaking state drives the pet
            if let type = p["type"] as? String, voiceState != .off {
                if type == "output_audio_buffer.started" { voiceState = .speaking }
                else if type == "output_audio_buffer.stopped" || type == "output_audio_buffer.cleared" { voiceState = .live }
            }
        case "pulse/closed":
            turnId = nil
            thinking = false
            if voiceState != .off { voiceState = .off; VoiceBridge.shared.close() }
            threadId = nil
            status = "Codex app-server stopped"
        default: break
        }
    }

    /// Streams into the last live message of the same key, or opens a new one.
    private func append(_ delta: String, role: ChatMessage.Role, key: String) {
        if streamingItem == key, let i = messages.indices.last, messages[i].live {
            messages[i].text += delta
        } else {
            finishLive()
            streamingItem = key
            messages.append(ChatMessage(role: role, text: delta, live: true))
        }
    }

    private func finishLive() {
        for i in messages.indices where messages[i].live { messages[i].live = false }
        messages.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        streamingItem = nil
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

// MARK: - WebRTC peer inside a hidden WKWebView
//
// macOS has no public WebRTC API; WebKit's is complete (mic capture, Opus, data channel), so a
// one-page WKWebView owns the call. Swift only shuttles SDP strings and data-channel events.

@MainActor
final class VoiceBridge: NSObject, WKScriptMessageHandler, WKUIDelegate {
    static let shared = VoiceBridge()
    let webView: WKWebView
    private var offerWaiter: CheckedContinuation<String, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(ScriptProxy(), name: "pulse")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        super.init()
        ScriptProxy.target = self
        webView.uiDelegate = self
        webView.alphaValue = 0.02   // in the window (media needs it), invisible
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://pulse.local/voice"))
    }

    func createOffer(muted: Bool) async throws -> String {
        offerWaiter?.resume(throwing: CodexAppServer.Failure.remote("voice start superseded"))
        return try await withCheckedThrowingContinuation { cont in
            offerWaiter = cont
            // async functions return a Promise, which evaluateJavaScript reports as an error: void it
            webView.evaluateJavaScript("void pulseStart(\(muted))") { [weak self] _, err in
                if let err, let w = self?.offerWaiter { self?.offerWaiter = nil; w.resume(throwing: err) }
            }
        }
    }

    func accept(answer sdp: String) {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: [sdp])) ?? Data(), encoding: .utf8) ?? "[\"\"]"
        webView.evaluateJavaScript("void pulseAccept(\(json)[0])")
    }

    func setMuted(_ muted: Bool) { webView.evaluateJavaScript("pulseMute(\(muted))") }
    func close() {
        webView.evaluateJavaScript("pulseStop()")
        offerWaiter?.resume(throwing: CodexAppServer.Failure.remote("voice stopped"))
        offerWaiter = nil
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "pulse.local" else { return }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "offer":
            if let sdp = body["sdp"] as? String { offerWaiter?.resume(returning: sdp) }
            else { offerWaiter?.resume(throwing: CodexAppServer.Failure.remote((body["error"] as? String) ?? "no microphone")) }
            offerWaiter = nil
        case "event":
            if let type = body["type"] as? String { CodexAppServer.shared.onNotification?("pulse/voice", ["type": type]) }
        case "closed":
            CodexAppServer.shared.onNotification?("thread/realtime/closed", ["reason": "peer closed"])
        default: break
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone && frame.isMainFrame
                        && origin.protocol == "https" && origin.host == "pulse.local" ? .grant : .deny)
    }

    /// WKUserContentController retains its handler; a tiny proxy keeps the bridge out of that cycle.
    private final class ScriptProxy: NSObject, WKScriptMessageHandler {
        static weak var target: VoiceBridge?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            Self.target?.userContentController(c, didReceive: m)
        }
    }

    static let page = """
    <!doctype html><meta charset=utf-8><audio id=out autoplay></audio><script>
    let pc = null, dc = null, mic = null, generation = 0, muted = false;
    const post = (m) => webkit.messageHandlers.pulse.postMessage(m);
    async function pulseStart(initialMuted = false) {
      pulseStop();
      const run = generation;
      muted = initialMuted;
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
        if (run !== generation) { for (const t of stream.getTracks()) t.stop(); return; }
        mic = stream;
        pulseMute(muted);
        const peer = pc = new RTCPeerConnection();
        dc = peer.createDataChannel('oai-events');
        dc.onmessage = (e) => { try { post({ kind: 'event', type: JSON.parse(e.data).type || '' }); } catch {} };
        peer.ontrack = (e) => { document.getElementById('out').srcObject = e.streams[0]; };
        peer.onconnectionstatechange = () => { if (run === generation && ['failed','closed','disconnected'].includes(peer.connectionState)) { pulseStop(); post({ kind: 'closed' }); } };
        for (const t of mic.getTracks()) peer.addTrack(t, mic);
        const offer = await peer.createOffer();
        if (run !== generation) return;
        await peer.setLocalDescription(offer);
        await new Promise((r) => { if (peer.iceGatheringState === 'complete') r(); else { const f = () => { if (peer.iceGatheringState === 'complete') { peer.removeEventListener('icegatheringstatechange', f); r(); } }; peer.addEventListener('icegatheringstatechange', f); setTimeout(r, 1500); } });
        if (run === generation) post({ kind: 'offer', sdp: peer.localDescription.sdp });
      } catch (e) { if (run === generation) { post({ kind: 'offer', error: String(e && e.message || e) }); pulseStop(); } }
    }
    async function pulseAccept(sdp) { if (pc) await pc.setRemoteDescription({ type: 'answer', sdp }); }
    function pulseMute(m) { muted = m; if (mic) for (const t of mic.getAudioTracks()) t.enabled = !m; }
    function pulseStop() {
      generation++;
      if (mic) { for (const t of mic.getTracks()) t.stop(); mic = null; }
      if (dc) { dc.onmessage = null; dc = null; }
      if (pc) { pc.onconnectionstatechange = null; pc.close(); pc = null; }
    }
    </script>
    """
}
