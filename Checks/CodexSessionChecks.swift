import Foundation
import AppKit

// This binary supplies a fake CLI. It never launches the user's Codex or reads its credentials.
func locateBinary(_ name: String) -> URL? {
    ProcessInfo.processInfo.environment["PULSE_CHECK_CODEX"].map { URL(fileURLWithPath: $0) }
}

@main
enum CodexSessionChecks {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--approval-ui") || Bundle.main.bundleIdentifier == "app.pulse.approval-check" {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let preview = PetApproval(id: "ui-check", method: "item/commandExecution/requestApproval", params: [
                "threadId": "fixture", "turnId": "fixture", "command": "touch ~/Projects/pulse-approval-check.txt",
                "cwd": "~/Documents/codex-pet", "reason": "UI check only. No command will run and no files will change."
            ], item: nil)!
            let decision = preview.show()
            try decision.rawValue.write(toFile: "/private/tmp/pulse-approval-ui-result.txt", atomically: true, encoding: .utf8)
            print("UI approval result: \(decision.rawValue)")
            try await Task.sleep(for: .seconds(45))
            return
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env node
        const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
        const assert = require('node:assert/strict');
        require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
          const m = JSON.parse(line);
          if (m.method === 'initialize') send({ id: m.id, result: {} });
          if (m.method === 'thread/start') {
            assert.equal(m.params.approvalPolicy, 'on-request');
            assert.equal(m.params.approvalsReviewer, 'user');
            assert.equal(m.params.sandbox, 'workspace-write');
            assert(!m.params.runtimeWorkspaceRoots, 'no extra folders are permanently granted');
            send({ id: m.id, result: { thread: { id: 'fixture-thread' } } });
          }
          if (m.method === 'fixture/approvals') {
            const p = {threadId:'fixture-thread',turnId:'fixture-turn',itemId:'edit'};
            send({id:900, method:'item/commandExecution/requestApproval',params:{...p,command:'touch ~/Projects/example.txt',cwd:'/tmp',reason:'Requested project edit'}});
            send({method:'item/started',params:{...p,item:{id:'edit',type:'fileChange',changes:[{path:'/Users/example/Downloads/note.txt',kind:{type:'add'},diff:'+test'}]}}});
            send({id:'file',method:'item/fileChange/requestApproval',params:p});
            send({id:'permissions',method:'item/permissions/requestApproval',params:{...p,threadId:'child-thread',permissions:{network:null,fileSystem:{read:null,write:['/Users/example/Projects']}}}});
            send({id:'unsupported',method:'unknown/request',params:p});
            send({id:'stale',method:'item/commandExecution/requestApproval',params:{...p,command:'should never run'}});
            send({id:m.id,result:{}});
          }
          if (!m.method) {
            if (m.id === 900 || m.id === 'repeat') assert.deepEqual(m.result,{decision:'accept'});
            else if (m.id === 'file') assert.deepEqual(m.result,{decision:'decline'});
            else if (m.id === 'permissions') assert.deepEqual(m.result,{permissions:{fileSystem:{read:null,write:['/Users/example/Projects']}},scope:'turn'});
            else if (m.id === 'unsupported') assert(m.error);
            else throw new Error('unexpected or stale approval reply');
            send({method:'fixture/approved',params:{id:m.id}});
          }
          if (m.method === 'turn/start') {
            send({ id: m.id, result: { turn: { id: 'fixture-turn' } } });
            send({ method: 'turn/started', params: { threadId: 'fixture-thread', turn: { id: 'fixture-turn' } } });
            send({ method: 'item/started', params: { threadId: 'fixture-thread', item: { id: 'fixture-item', type: 'reasoning' } } });
          }
          if (m.method === 'turn/interrupt') {
            if (m.params.threadId !== 'fixture-thread' || m.params.turnId !== 'fixture-turn') {
              send({ id: m.id, error: { message: 'missing or incorrect turn identity' } });
            } else {
              send({ id: m.id, result: {} });
              send({ method: 'turn/completed', params: { threadId: 'fixture-thread' } });
            }
          }
        });
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        setenv("PULSE_CHECK_CODEX", cli.path, 1)
        let session = CodexPetSession(workspace: dir.appendingPathComponent("pet"))
        defer { CodexAppServer.shared.stop() }
        session.send("offline fixture")
        var deadline = Date().addingTimeInterval(10)
        while session.activity.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(!session.activity.isEmpty, "fake turn must start")
        assert(session.thinking)
        session.interrupt()
        deadline = Date().addingTimeInterval(10)
        while session.thinking && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(!session.thinking, "Stop must interrupt the active turn using its ID")
        assert(session.status == nil)
        print("Codex session check passed: text Stop supplies the active thread and turn IDs")

        checkRecording(session)
        checkTranscripts(session)
        try await checkApprovals()
        try await checkNativeVoice(in: dir)
    }

    @MainActor
    static func checkRecording(_ session: CodexPetSession) {
        session.muted = false
        session.toggleVoice()
        assert(session.voiceState == .connecting && !session.isRecording)
        session.toggleVoice()
        assert(session.voiceState == .off && !session.isRecording, "second activation cancels connection")
        session.toggleVoice()
        assert(session.voiceState == .connecting)
        CodexAppServer.shared.onNotification?("pulse/voiceReady", [:])
        assert(session.voiceState == .live && session.isRecording)
        session.muted = true
        assert(!session.isRecording, "muted microphone must not show recording")
        session.muted = false
        CodexAppServer.shared.onNotification?("pulse/voice", ["type": "output_audio_buffer.started"])
        assert(session.voiceState == .speaking && session.isRecording)
        session.toggleVoice()
        assert(session.voiceState == .off && !session.isRecording, "second activation ends the call")
        print("Recording checks passed: start, cancel connection, restart, mute indicator, speaking and end")
    }

    @MainActor
    static func checkTranscripts(_ session: CodexPetSession) {
        let notify = CodexAppServer.shared.onNotification!
        func send(_ method: String, _ fields: [String: Any] = [:]) {
            var p = fields; p["threadId"] = "fixture-thread"
            notify(method, p)
        }
        func item(_ id: String, _ role: String, _ text: String) -> [String: Any] {
            ["id": id, "type": "transcriptSegment", "role": role, "text": text, "realtimeSessionId": "voice-check"]
        }
        let count = session.messages.count
        send("thread/realtime/started")
        send("turn/started", ["turn": ["id": "voice-turn"]])
        send("thread/realtime/item/started", ["item": item("spoken", "assistant", "")])
        send("thread/realtime/item/transcript/delta", ["itemId": "spoken", "delta": "Doing great—"])
        send("thread/realtime/transcript/delta", ["role": "assistant", "delta": "Doing great—"])
        send("item/agentMessage/delta", ["turnId": "voice-turn", "itemId": "background", "delta": "Background answer"])
        send("thread/realtime/item/started", ["item": item("question", "user", "")])
        send("thread/realtime/item/transcript/delta", ["itemId": "question", "delta": "Where is "])
        send("thread/realtime/item/transcript/delta", ["itemId": "spoken", "delta": "ready whenever you are."])
        send("item/completed", ["turnId": "voice-turn", "item": ["id": "background", "type": "agentMessage", "text": "Background answer"]])
        send("turn/completed", ["turn": ["id": "voice-turn"]])
        send("thread/realtime/transcript/done", ["role": "assistant", "text": "Doing great—ready whenever you are."])
        send("thread/realtime/item/completed", ["item": item("spoken", "assistant", "Doing great—ready whenever you are.")])
        send("thread/realtime/item/transcript/delta", ["itemId": "question", "delta": "Downloads?"])
        send("thread/realtime/item/completed", ["item": item("question", "user", "Where is Downloads?")])
        send("thread/realtime/item/completed", ["item": item("question", "user", "Where is Downloads?")])
        let bubbles = Array(session.messages.dropFirst(count))
        assert(bubbles.map(\.text) == ["Doing great—ready whenever you are.", "Where is Downloads?"], "overlapping streams must retain two whole bubbles without legacy or background duplicates")
        assert(bubbles.allSatisfy { !$0.live })
        let stableID = bubbles[0].id
        send("thread/realtime/item/completed", ["item": item("spoken", "assistant", "Doing great—ready whenever you are!")])
        assert(session.messages[count].id == stableID && session.messages[count].text.hasSuffix("!"), "final text must replace the same bubble")
        send("thread/realtime/closed")
        send("item/completed", ["turnId": "voice-turn", "item": ["id": "background", "type": "agentMessage", "text": "Background answer"]])
        assert(session.messages.count == count + 2, "late delegated completion must not duplicate voice after closing")
        send("thread/realtime/item/completed", ["item": ["id": "promotion", "type": "bemItemPromoted", "turnId": "voice-turn", "itemId": "background", "presentation": ["type": "wholeItem"]]])
        assert(session.messages.last?.text == "Background answer", "explicitly promoted results remain available")
        send("turn/started", ["turn": ["id": "text-turn"]])
        send("item/agentMessage/delta", ["turnId": "text-turn", "itemId": "text-one", "delta": "First"])
        send("item/agentMessage/delta", ["turnId": "text-turn", "itemId": "text-two", "delta": "Second"])
        send("item/completed", ["turnId": "text-turn", "item": ["id": "text-one", "type": "agentMessage", "text": "First complete"]])
        send("item/completed", ["turnId": "text-turn", "item": ["id": "text-two", "type": "agentMessage", "text": "Second complete"]])
        assert(session.messages.suffix(2).map(\.text) == ["First complete", "Second complete"], "text completions must update their own item, not the last live bubble")
        print("Transcript checks passed: interleaved voice, canonical final text, duplicate events, delayed agent results, promoted results and overlapping text items")
    }

    @MainActor
    static func checkApprovals() async throws {
        let approvals = PetApprovals.shared
        var shown = [AnyHashable](), replied = [AnyHashable]()
        let originalPresenter = approvals.present
        let originalDefaults = approvals.defaults
        let suite = "pulse-approval-check-" + UUID().uuidString
        approvals.defaults = UserDefaults(suiteName: suite)!
        defer { approvals.defaults.removePersistentDomain(forName: suite); approvals.defaults = originalDefaults }
        defer { approvals.present = originalPresenter; approvals.cancelAll(reply: false) }
        approvals.present = { request in
            shown.append(request.id)
            if request.id == AnyHashable("file") {
                assert(request.detail.contains("/Users/example/Downloads/note.txt") && request.detail.contains("+test"))
                return .deny
            }
            if request.id == AnyHashable("stale") {
                approvals.observe("serverRequest/resolved", ["requestId": "stale"])
                return .always // A response after invalidation must not grant anything.
            }
            if request.id == AnyHashable(900) { return .always }
            return .allow
        }
        CodexAppServer.shared.onNotification = { method, params in
            if method == "fixture/approved", let id = params["id"] as? AnyHashable { replied.append(id) }
        }
        _ = try await CodexAppServer.shared.request("fixture/approvals", [:])
        let deadline = Date().addingTimeInterval(5)
        while (shown.count < 4 || replied.count < 4) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(shown == [AnyHashable(900), AnyHashable("file"), AnyHashable("permissions"), AnyHashable("stale")])
        assert(Set(replied) == Set([AnyHashable(900), AnyHashable("file"), AnyHashable("permissions"), AnyHashable("unsupported")]))
        let repeated: [String: Any] = ["threadId": "another-thread", "turnId": "another-turn", "itemId": "another-item", "command": "touch ~/Projects/example.txt", "cwd": "/tmp"]
        approvals.receive(id: "repeat", method: "item/commandExecution/requestApproval", params: repeated)
        let repeatDeadline = Date().addingTimeInterval(5)
        while replied.count < 5 && Date() < repeatDeadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(replied.contains(AnyHashable("repeat")) && shown.count == 4, "always allow must skip the next identical prompt")
        let stale = PetApproval(id: "stale", method: "item/commandExecution/requestApproval", params: ["threadId":"fixture-thread", "turnId":"fixture-turn", "itemId":"edit", "command":"should never run"], item: nil)!
        assert(!approvals.isRemembered(stale), "a resolved prompt must never save always allow")
        let p: [String: Any] = ["threadId":"t", "turnId":"u", "itemId":"i"]
        assert(PetApproval(id: 1, method: "item/fileChange/requestApproval", params: p, item: nil) == nil, "no preview must not grant file edits")
        var restricted = p; restricted["command"] = "test"; restricted["availableDecisions"] = ["decline"]
        assert(PetApproval(id: 1, method: "item/commandExecution/requestApproval", params: restricted, item: nil) == nil)
        var rememberedParams = p
        rememberedParams["command"] = "touch ~/Projects/example.txt"
        rememberedParams["cwd"] = "/Users/example/Documents/codex-pet"
        let remembered = PetApproval(id: 1, method: "item/commandExecution/requestApproval", params: rememberedParams, item: nil)!
        approvals.remember(remembered)
        assert(approvals.isRemembered(remembered))
        let reopened = PetApprovals(); reopened.defaults = UserDefaults(suiteName: suite)!
        assert(reopened.isRemembered(remembered), "always allow must survive a new coordinator")
        rememberedParams["command"] = "touch ~/Downloads/different.txt"
        let changed = PetApproval(id: 2, method: "item/commandExecution/requestApproval", params: rememberedParams, item: nil)!
        assert(!approvals.isRemembered(changed), "a different command must prompt")
        approvals.resetRemembered()
        assert(!approvals.isRemembered(remembered), "reset must revoke remembered approvals")
        let legacy = "Custom note\nYou can only read and write\ninside this folder.\nanyone. If an item needs action outside this folder, add it to `todos.md` tagged `#needs-agent`."
        let updated = updatedPetInstructions(legacy)
        assert(updated.hasPrefix("Custom note\n") && updated.contains("request permission") && !updated.contains("#needs-agent"))
        assert(updatedPetInstructions(updated) == updated, "migration must be idempotent")
        print("Approval checks passed: once/turn/always scope, persistence and reset, deny, child requests, stale resolution, unsupported requests and instruction migration")
    }

    @MainActor
    static func checkNativeVoice(in dir: URL) async throws {
        let fm = FileManager.default
        let bin = dir.appendingPathComponent("bin")
        let voice = dir.appendingPathComponent("codex-resources/voice")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: voice.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try Data().write(to: codex)
        let helper = voice.appendingPathComponent("bin/codex-voice-host")
        let node = ProcessInfo.processInfo.environment["PATH"]!.split(separator: ":")
            .map { String($0) + "/node" }.first { fm.isExecutableFile(atPath: $0) }!
        let fixture = try String(contentsOfFile: "Checks/VoiceChecks.js", encoding: .utf8)
            .replacingOccurrences(of: "#!/usr/bin/env node", with: "#!" + node)
        try fixture.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try #"{"buildCommit":"fixture"}"#.write(to: voice.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        setenv("PULSE_CHECK_CODEX", codex.path, 1)
        let bridge = VoiceBridge.shared
        var ready = false, speaking = false, failure: String?
        CodexAppServer.shared.onNotification = { method, params in
            if method == "pulse/voiceReady" { ready = true }
            if method == "pulse/voice", params["type"] as? String == "output_audio_buffer.started" { speaking = true }
            if method == "thread/realtime/error" { failure = params["message"] as? String }
        }
        let initialOffer = try await bridge.createOffer(muted: true)
        assert(initialOffer == "fixture-offer")
        assert(!ready, "offer must not mean audio is ready")
        bridge.accept(answer: "fixture-answer")
        var deadline = Date().addingTimeInterval(5)
        while !speaking && failure == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(ready && speaking && failure == nil, "native helper must negotiate, open devices, restore mute and poll")
        bridge.setMuted(false)
        try await Task.sleep(for: .milliseconds(100))
        bridge.close()
        ready = false; speaking = false
        let cancelled = Task { try await bridge.createOffer(muted: false) }
        try await Task.sleep(for: .milliseconds(10))
        bridge.close()
        do { _ = try await cancelled.value; assertionFailure("cancelled offer must fail") } catch {}
        let offer = try await bridge.createOffer(muted: true)
        assert(offer == "fixture-offer", "reopening must survive stale child callbacks")
        bridge.accept(answer: "malformed-frame")
        deadline = Date().addingTimeInterval(5)
        while failure == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(failure != nil, "oversized helper frames must fail and close the process")
        bridge.close()
        print("Native voice checks passed: fragmented frames, negotiation, initial mute, activity, cancellation, reopening and malformed frames")
    }
}
