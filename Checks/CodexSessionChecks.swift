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
        signal(SIGPIPE, SIG_IGN)   // as PulseApp.init does; checkStartup writes to servers that just exited
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
        const log = word => process.env.PULSE_CHECK_LOG && require('node:fs').appendFileSync(process.env.PULSE_CHECK_LOG, word + '\\n');
        log('spawn');
        let dieNext = false, rejectNext = false, listMode = 'empty';
        require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
          const m = JSON.parse(line);
          if (m.method === 'initialize') setTimeout(() => send({ id: m.id, result: {} }), process.env.PULSE_CHECK_SLOW_START ? 600 : 0);
          if (m.method === 'thread/start') {
            assert.equal(m.params.approvalPolicy, 'on-request');
            assert.equal(m.params.approvalsReviewer, 'user');
            assert.equal(m.params.sandbox, 'workspace-write');
            assert(!m.params.runtimeWorkspaceRoots, 'no extra folders are permanently granted');
            log('thread');
            send({ id: m.id, result: { thread: { id: 'fixture-thread' } } });
          }
          if (m.method === 'fixture/list') { listMode = m.params.mode; send({ id: m.id, result: {} }); }
          if (m.method === 'thread/list') {
            log('list' + (m.params.cursor ? ':' + m.params.cursor : ''));
            const here = m.params.cwd, thread = (id, originator, cwd, updatedAt) => ({ id, originator, cwd, updatedAt });
            if (listMode === 'fail') send({ id: m.id, error: { message: 'fixture list failure' } });
            else if (listMode === 'legacy' && !m.params.cursor)   // page 1: only threads that must not be picked
              send({ id: m.id, result: { data: [thread('newer-cli', 'codex-tui', here, 400), thread('pet-elsewhere', 'pulse', '/tmp/elsewhere', 350)], nextCursor: 'page-2' } });
            else if (listMode === 'legacy')
              send({ id: m.id, result: { data: [thread('legacy-pet', 'pulse', here + '/', 300), thread('older-pet', 'pulse', here, 100)], nextCursor: null } });
            else send({ id: m.id, result: { data: [], nextCursor: null } });
          }
          if (m.method === 'thread/resume') {
            for (const [k, v] of [['approvalPolicy', 'on-request'], ['approvalsReviewer', 'user'], ['sandbox', 'workspace-write']]) assert.equal(m.params[k], v);
            log('resume:' + m.params.threadId + (m.params.excludeTurns ? ':reconnect' : ':history'));
            if (m.params.threadId === 'missing-thread') send({ id: m.id, error: { message: 'no rollout found' } });
            else if (m.params.threadId === 'tools-only')   // a page with nothing to show but more before it
              send({ id: m.id, result: { thread: { id: 'tools-only' }, initialTurnsPage: { data: [{ id: 't9', status: 'completed', items: [{ type: 'commandExecution', id: 'c9' }] }], nextCursor: 'earlier' } } });
            else {
              const said = (text) => ({ type: 'userMessage', id: text, content: [{ type: 'text', text }] });
              const reply = (text) => ({ type: 'agentMessage', id: 'r-' + text, text });
              const newest = { id: 't2', status: 'completed', items: [said('<realtime_delegation>\\n  <input>Open my inbox</input>\\n  <transcript_delta>user: open my inbox</transcript_delta>\\n</realtime_delegation>'), { type: 'commandExecution', id: 'c' }, reply('Done.')] };
              const older = { id: 't1', status: 'completed', items: [said("What's due today?"), reply('Two bills.')] };
              send({ id: m.id, result: { thread: { id: m.params.threadId }, initialTurnsPage: m.params.excludeTurns ? null : { data: [newest, older], nextCursor: 'earlier' } } });
            }
          }
          if (m.method === 'thread/turns/list') {
            log('turns:' + m.params.cursor);
            send({ id: m.id, result: { data: [{ id: 't0', status: 'completed', items: [{ type: 'userMessage', id: 'u0', content: [{ type: 'text', text: 'First thing today' }] }, { type: 'agentMessage', id: 'a0', text: 'Noted.' }] }], nextCursor: null } });
          }
          if (m.method === 'fixture/exit') process.exit(0);   // fixture/silent is never answered
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
          if (m.method === 'fixture/consent') {
            // Browser Use's site-access request, as built by its plugin; turnId may be null.
            const meta = {codex_approval_kind:'mcp_tool_call',codex_sensitive_action:true,connector_id:'browser-use',connector_name:'Chrome',persist:'always',tool_name:'access_browser_origin',tool_title:'Access browser origin',tool_params:{origin:'https://example.com'}};
            const ask = (id, extra = {}) => send({id, method:'mcpServer/elicitation/request', params:{threadId:'fixture-thread',turnId:null,serverName:'cua_repl',mode:'form',message:'Allow Chrome to access https://example.com?',requestedSchema:{type:'object',properties:{}},_meta:meta,...extra}});
            ask('site-deny'); ask('site-allow'); ask('site-dismiss');
            ask('otp', {_meta:{...meta,codex_approval_kind:'browser_email_otp',codex_requires_user_input:true},requestedSchema:{type:'object',properties:{approved:{type:'boolean'}},required:['approved']}});
            ask('strict', {_meta:{...meta,codex_strict_auto_review:true}});
            send({id:'verify', method:'mcpServer/elicitation/request', params:{threadId:'fixture-thread',serverName:'cua_repl',mode:'openai/userVerification',title:'Verify',description:'Device check',challenge:'abc'}});
            send({id:'link', method:'mcpServer/elicitation/request', params:{threadId:'fixture-thread',serverName:'cua_repl',mode:'url',message:'Sign in',url:'https://example.com/login',elicitationId:'e1'}});
            ask('loose-schema', {requestedSchema:{properties:{}}});
            ask('required-schema', {requestedSchema:{type:'object',properties:{},required:['approved']}});
            const q = {threadId:'fixture-thread',turnId:'fixture-turn',isBlocking:true};
            const retry = {id:'q1',header:'Gmail',question:'Retry Gmail?',options:[{label:'Yes',description:'Try again'},{label:'No',description:'Leave it'}]};
            const ask2 = (id, questions) => send({id, method:'item/tool/requestUserInput', params:{...q,itemId:id,questions}});
            ask2('question', [retry, {id:'q4',header:'Browser',question:'Which browser?',options:[{label:'Chrome',description:''},{label:'Safari',description:''}]}]);
            ask2('question-mixed', [retry, {id:'q2',header:'Code',question:'Enter the code',isSecret:true,options:[{label:'123',description:''}]}]);
            ask2('question-free', [{id:'q3',header:'Name',question:'What should the file be called?'}]);
            ask2('question-dup', [retry, {...retry,question:'Same id again?'}]);
            ask2('question-other', [{...retry,id:'q5',isOther:true}]);
            send({id:'stop-command', method:'item/commandExecution/requestApproval', params:{threadId:'fixture-thread',turnId:'fixture-turn',itemId:'x',command:'echo hi',cwd:'/tmp'}});
            ask('stop-site');
            send({id:m.id,result:{}});
          }
          if (!m.method) {
            if (m.id === 900 || m.id === 'repeat') assert.deepEqual(m.result,{decision:'accept'});
            else if (m.id === 'file') assert.deepEqual(m.result,{decision:'decline'});
            else if (m.id === 'permissions') assert.deepEqual(m.result,{permissions:{fileSystem:{read:null,write:['/Users/example/Projects']}},scope:'turn'});
            else if (m.id === 'unsupported') assert(m.error);
            // Exact objects: a decline must never carry persist, and nothing unshowable may be declined or errored.
            else if (m.id === 'site-deny') assert.deepEqual(m.result,{action:'decline'});
            else if (m.id === 'site-allow') assert.deepEqual(m.result,{action:'accept'});
            else if (['site-dismiss','otp','strict','verify','link','loose-schema','required-schema','stop-site'].includes(m.id)) assert.deepEqual(m.result,{action:'cancel'});
            else if (m.id === 'stop-command') assert.deepEqual(m.result,{decision:'cancel'});
            else if (m.id === 'question') assert.deepEqual(m.result,{answers:{q1:{answers:['Yes']}}});
            else if (['question-mixed','question-free','question-dup','question-other'].includes(m.id)) assert.deepEqual(m.result,{answers:{}});
            else throw new Error('unexpected or stale approval reply');
            send({method:'fixture/approved',params:{id:m.id}});
          }
          if (m.method === 'turn/start') {
            const text = m.params.input[0].text;
            log('turn/start:' + text);
            const accept = () => {
              send({ id: m.id, result: { turn: { id: 'fixture-turn' } } });
              send({ method: 'turn/started', params: { threadId: m.params.threadId, turn: { id: 'fixture-turn' } } });
              send({ method: 'item/started', params: { threadId: 'fixture-thread', item: { id: 'fixture-item', type: 'reasoning' } } });
            };
            if (text === 'slow acknowledgement') setTimeout(accept, 300); else accept();
          }
          if (m.method === 'fixture/die-next') { dieNext = true; send({ id: m.id, result: {} }); }
          if (m.method === 'fixture/reject-next') { rejectNext = true; send({ id: m.id, result: {} }); }
          if (m.method === 'thread/realtime/start' && rejectNext) { rejectNext = false; log('realtime/rejected'); send({ id: m.id, error: { message: 'fixture rejection' } }); }
          else if (m.method === 'thread/realtime/start') {
            log('realtime/start');
            send({ id: m.id, result: {} });
            send({ method: 'thread/realtime/started', params: { threadId: m.params.threadId } });
            send({ method: 'thread/realtime/sdp', params: { threadId: m.params.threadId, sdp: dieNext ? 'die-after-devices' : 'fixture-answer' } });
            dieNext = false;
          }
          if (m.method === 'thread/realtime/stop') {   // closes late, like a real call winding down
            send({ id: m.id, result: {} });
            setTimeout(() => { log('realtime/closed'); send({ method: 'thread/realtime/closed', params: { threadId: m.params.threadId, reason: 'requested' } }); }, 150);
          }
          if (m.method === 'turn/interrupt') {
            log('turn/interrupt');
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
        checkDir = dir
        let session = CodexPetSession(workspace: dir.appendingPathComponent("pet"), defaults: isolatedDefaults())
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
        try await checkConsent()
        try await checkLifecycle(in: dir)
        try await checkRecovery(in: dir)
        try await checkStartup(in: dir)
        try await checkNativeVoice(in: dir)
        try await checkVoiceLifecycle(in: dir, server: cli)
    }

    @MainActor
    static func wait(_ what: @autoclosure () -> String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(done(), what())
    }

    static var checkDir = FileManager.default.temporaryDirectory
    /// A path suite keeps the plist in the checks' temporary folder, never in ~/Library/Preferences,
    /// so no run (even one an assertion ends) leaves settings behind or touches the user's own.
    static func isolatedSuite() -> String { checkDir.appendingPathComponent("defaults-" + UUID().uuidString).path }
    static func isolatedDefaults() -> UserDefaults { UserDefaults(suiteName: isolatedSuite())! }

    static func lines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Turn control: delegated voice work, results after hangup, failures, waiting on the user, and Stop
    /// before a turn starts or while Codex is still accepting it.
    @MainActor
    static func checkLifecycle(in dir: URL) async throws {
        let log = dir.appendingPathComponent("lifecycle.log")
        setenv("PULSE_CHECK_LOG", log.path, 1)
        CodexAppServer.shared.stop()   // respawn so the fake server logs here
        try await Task.sleep(for: .milliseconds(50))   // the old server's pulse/closed goes to the old session
        let session = CodexPetSession(workspace: dir.appendingPathComponent("pet-lifecycle"), defaults: isolatedDefaults())
        func notify(_ method: String, _ fields: [String: Any] = [:]) {
            var p = fields; p["threadId"] = "fixture-thread"
            CodexAppServer.shared.onNotification?(method, p)
        }
        session.send("first")
        try await wait("a text turn starts (status \(session.status ?? "none"), thinking \(session.thinking), log \(lines(log)))") { session.thinking && lines(log).contains("turn/start:first") }
        notify("turn/completed", ["turn": ["id": "fixture-turn", "status": "completed"]])

        notify("thread/realtime/started")
        notify("turn/started", ["turn": ["id": "fixture-turn"]])
        assert(session.thinking, "work the voice delegated shows as running")
        session.interrupt()
        try await wait("Stop interrupts delegated voice work") { !session.thinking && lines(log).filter { $0 == "turn/interrupt" }.count == 1 }

        notify("turn/started", ["turn": ["id": "background"]])
        notify("thread/realtime/closed")
        let before = session.messages.count
        let result: [String: Any] = ["turnId": "background", "item": ["id": "result", "type": "agentMessage", "text": "Finished after the call"]]
        notify("item/completed", result)
        notify("item/completed", result)
        assert(session.messages.count == before + 1 && session.messages.last?.text == "Finished after the call", "a result finishing after hangup was never heard, so it shows once")
        notify("turn/completed", ["turn": ["id": "background", "status": "completed"]])

        notify("turn/started", ["turn": ["id": "failing"]])
        notify("turn/completed", ["turn": ["id": "failing", "status": "failed", "error": ["message": "fixture failure"]]])
        assert(session.status == "fixture failure" && !session.thinking, "a failed turn says why")
        notify("thread/status/changed", ["status": ["type": "active", "activeFlags": ["waitingOnApproval"]]])
        assert(session.waitingOnYou, "a pending approval shows")
        notify("thread/status/changed", ["status": ["type": "active", "activeFlags": [String]()]])
        assert(!session.waitingOnYou)

        notify("turn/started", ["turn": ["id": "fixture-turn"]])
        notify("error", ["turnId": "fixture-turn", "error": ["message": "Reconnecting 1/5"], "willRetry": true])
        assert(session.thinking && session.status == "Reconnecting 1/5", "a turn Codex is retrying keeps running")
        notify("turn/completed", ["turn": ["id": "fixture-turn", "status": "completed"]])
        assert(session.status == nil && !session.thinking, "a retry that succeeds clears its status")
        notify("turn/started", ["turn": ["id": "fixture-turn"]])
        notify("error", ["turnId": "fixture-turn", "error": ["message": "Reconnecting 1/5"], "willRetry": true])
        let interrupts = lines(log).filter { $0 == "turn/interrupt" }.count
        session.interrupt()
        try await wait("Stop still interrupts a turn Codex is retrying") { !session.thinking && lines(log).filter { $0 == "turn/interrupt" }.count == interrupts + 1 }
        notify("turn/started", ["turn": ["id": "final"]])
        notify("error", ["turnId": "final", "error": ["message": "Out of retries"], "willRetry": false])
        assert(!session.thinking && session.status == "Out of retries", "a final error ends the turn")

        notify("turn/started", ["turn": ["id": "unknown-turn"]])   // the fake server rejects interrupting it
        session.interrupt()
        session.clear()
        try await Task.sleep(for: .milliseconds(200))
        assert(session.status == nil, "an old conversation's failed Stop never reports in the new one")
        let threads = lines(log).filter { $0 == "thread" }.count
        session.send("queued before New conversation")
        session.clear()
        try await Task.sleep(for: .milliseconds(200))
        assert(lines(log).filter { $0 == "thread" }.count == threads && !session.thinking, "a send queued before New conversation creates no thread")
        session.send("stopped early")
        session.interrupt()
        try await Task.sleep(for: .milliseconds(400))
        assert(!lines(log).contains("turn/start:stopped early") && !session.thinking, "Stop before the turn reaches Codex sends nothing")

        session.send("slow acknowledgement")
        try await wait("the slow turn is requested") { lines(log).contains("turn/start:slow acknowledgement") }
        session.interrupt()
        session.send("after stop")
        try await wait("the next turn starts") { lines(log).contains("turn/start:after stop") }
        let order = Array(lines(log).filter { $0.hasPrefix("turn/") }.suffix(3))
        assert(order == ["turn/start:slow acknowledgement", "turn/interrupt", "turn/start:after stop"],
               "Stop while Codex accepts a turn interrupts it once its ID arrives, before the next turn starts (got \(order))")
        notify("turn/completed", ["turn": ["id": "fixture-turn", "status": "completed"]])
        try await wait("settled") { !session.thinking }

        // Losing the server mid-request: the pending turn fails once, visibly, in the same conversation,
        // and the next message reaches a new server. The dead process's callbacks never arrive.
        session.send("slow acknowledgement")
        try await wait("a turn is pending") { lines(log).filter { $0 == "turn/start:slow acknowledgement" }.count == 2 }
        CodexAppServer.shared.stop()
        try await wait("the pending turn fails visibly (\(session.status ?? "none"))") { !session.thinking && session.status != nil }
        session.send("after the server came back")
        try await wait("the next message reaches a new server") { lines(log).contains("turn/start:after the server came back") }
        notify("turn/completed", ["turn": ["id": "fixture-turn", "status": "completed"]])
        try await wait("settled again") { !session.thinking }
        print("Lifecycle checks passed: delegated voice work, results after hangup, failures, retries, waiting state, stale work after New conversation, Stop before and during turn start, a lost server")
    }

    /// The conversation continues across restarts and a lost server, and never silently becomes a new one.
    @MainActor
    static func checkRecovery(in dir: URL) async throws {
        let log = dir.appendingPathComponent("recovery.log")
        setenv("PULSE_CHECK_LOG", log.path, 1)
        CodexAppServer.shared.stop()
        try await Task.sleep(for: .milliseconds(50))
        func count(_ prefix: String) -> Int { lines(log).filter { $0.hasPrefix(prefix) }.count }
        let key = CodexPetSession.savedThreadKey, checked = CodexPetSession.legacyCheckedKey

        // Nothing saved and the one-time look already done: opening the card starts nothing.
        let quiet = isolatedDefaults(); quiet.set(true, forKey: checked)
        CodexPetSession(workspace: dir.appendingPathComponent("pet-quiet"), defaults: quiet).reopen()
        try await Task.sleep(for: .milliseconds(300))
        assert(count("spawn") == 0, "opening the card with nothing to continue spawns no app-server")

        // Opening the card shows the saved conversation without starting a turn or the microphone.
        let saved = isolatedDefaults(); saved.set("saved-thread", forKey: key)
        let session = CodexPetSession(workspace: dir.appendingPathComponent("pet-recovery"), defaults: saved)
        session.reopen()
        try await wait("the saved conversation reopens on card open") { session.messages.count == 5 }
        assert(lines(log).contains("resume:saved-thread:history") && count("thread") == 0 && count("turn/") == 0 && session.voiceState == .off)
        assert(session.messages.prefix(4).map(\.text) == ["What's due today?", "Two bills.", "Open my inbox", "Done."], "history oldest first, a spoken request without its wrapper (got \(session.messages.map(\.text)))")
        assert(session.messages[4].role == .note && session.messages[4].text.contains("voice call"), "says the transcript isn't the whole voice call")
        assert(session.canLoadEarlier)
        session.send("continue")
        try await wait("a message continues the conversation") { lines(log).contains("turn/start:continue") }
        assert(session.messages.last?.text == "continue" && count("resume:") == 1, "the new message stays below history, which loads once")
        CodexAppServer.shared.onNotification?("turn/completed", ["threadId": "saved-thread", "turn": ["id": "fixture-turn", "status": "completed"]])

        // A lost server: the next message reconnects to the same conversation without repeating history.
        let shown = session.messages.count
        CodexAppServer.shared.stop()
        try await wait("the stop is explained") { session.status?.contains("reconnects") == true }
        session.send("after the server came back")
        try await wait("the next message reconnects") { lines(log).contains("turn/start:after the server came back") }
        assert(lines(log).contains("resume:saved-thread:reconnect") && count("thread") == 0, "a lost server reopens the same conversation, never a new one")
        assert(session.messages.count == shown + 1 && saved.string(forKey: key) == "saved-thread")
        CodexAppServer.shared.onNotification?("turn/completed", ["threadId": "saved-thread", "turn": ["id": "fixture-turn", "status": "completed"]])
        assert(session.canLoadEarlier, "a reconnect keeps the older history still to load")
        session.loadEarlier()
        try await wait("load earlier adds older turns on top") { session.messages.first?.text == "First thing today" }
        assert(lines(log).contains("turns:earlier") && !session.canLoadEarlier)

        // A saved conversation Codex can't reopen stays saved and says so; only New conversation moves on.
        let broken = isolatedDefaults(); broken.set("missing-thread", forKey: key)
        let failing = CodexPetSession(workspace: dir.appendingPathComponent("pet-broken"), defaults: broken)
        failing.send("hello")
        try await wait("a failed reopen is visible") { failing.status?.hasPrefix("Couldn't reopen your last conversation") == true }
        assert(count("thread") == 0 && broken.string(forKey: key) == "missing-thread" && !failing.thinking, "a failed reopen never starts a new conversation")
        failing.clear()
        assert(broken.string(forKey: key) == nil && broken.bool(forKey: checked), "New conversation forgets the saved one for good")
        failing.send("fresh start")
        try await wait("New conversation then starts one") { count("thread") == 1 && broken.string(forKey: key) == "fixture-thread" }

        // Once, before anything was saved: the newest of this pet's own conversations, on any page.
        let legacy = isolatedDefaults()
        _ = try await CodexAppServer.shared.request("fixture/list", ["mode": "fail"])
        let migrating = CodexPetSession(workspace: dir.appendingPathComponent("pet-legacy"), defaults: legacy)
        migrating.reopen()
        try await wait("a failed lookup is visible, not 'nothing found'") { migrating.status?.hasPrefix("Couldn't look for your last conversation") == true }
        assert(!legacy.bool(forKey: checked) && count("thread") == 1, "a failed lookup is retried later and starts nothing")
        _ = try await CodexAppServer.shared.request("fixture/list", ["mode": "legacy"])
        let lists = count("list")
        migrating.reopen(); migrating.reopen()   // one shared lookup
        try await wait("the older pet conversation reopens") { lines(log).contains("resume:legacy-pet:history") }
        assert(lines(log).contains("list:page-2"), "the lookup reads past a page without a match")
        assert(count("list") == lists + 2 && count("resume:legacy-pet") == 1, "repeated card opens share one lookup and one reopen")
        try await wait("the earlier lookup error clears once it reopens") { migrating.status == nil }
        try await wait("its note shows") { migrating.messages.contains { $0.role == .note && $0.text.contains("before this update") } }
        assert(legacy.string(forKey: key) == "legacy-pet" && legacy.bool(forKey: checked))
        migrating.clear()

        // New conversation while Codex is still starting: the old message opens and saves nothing.
        setenv("PULSE_CHECK_SLOW_START", "1", 1)
        CodexAppServer.shared.stop()
        try await Task.sleep(for: .milliseconds(50))
        let cold = isolatedDefaults(); cold.set(true, forKey: checked)
        let starting = CodexPetSession(workspace: dir.appendingPathComponent("pet-cold"), defaults: cold)
        let threadsBefore = count("thread")
        starting.send("during startup")
        try await Task.sleep(for: .milliseconds(150))
        starting.clear()
        try await Task.sleep(for: .milliseconds(900))
        unsetenv("PULSE_CHECK_SLOW_START")
        assert(cold.string(forKey: key) == nil && count("thread") == threadsBefore && !lines(log).contains("turn/start:during startup"),
               "New conversation during a cold start leaves no thread opened or saved")

        _ = try await CodexAppServer.shared.request("fixture/list", ["mode": "legacy"])   // the restarted fake forgot it
        let sharing = CodexPetSession(workspace: dir.appendingPathComponent("pet-sharing"), defaults: isolatedDefaults())
        let listsBefore = count("list"), reopensBefore = count("resume:legacy-pet")
        sharing.reopen(); sharing.send("during the lookup")
        try await wait("a message sent during the lookup follows the reopen") { lines(log).contains("turn/start:during the lookup") }
        assert(count("list") == listsBefore + 2 && count("resume:legacy-pet") == reopensBefore + 1, "a message shares the card's lookup")
        sharing.clear()

        let toolsOnly = isolatedDefaults(); toolsOnly.set("tools-only", forKey: key)
        let quietPage = CodexPetSession(workspace: dir.appendingPathComponent("pet-tools"), defaults: toolsOnly)
        quietPage.reopen()
        try await wait("a page with nothing to show still offers older history") { quietPage.canLoadEarlier }
        quietPage.clear()

        let reopensBeforeCut = count("resume:legacy-pet")
        let interrupted = isolatedDefaults()
        let cut = CodexPetSession(workspace: dir.appendingPathComponent("pet-cut"), defaults: interrupted)
        cut.reopen(); cut.clear()   // New conversation while the lookup runs
        try await Task.sleep(for: .milliseconds(400))
        assert(count("resume:legacy-pet") == reopensBeforeCut && interrupted.string(forKey: key) == nil && cut.messages.isEmpty,
               "a lookup New conversation cut off never reopens anything")
        _ = try await CodexAppServer.shared.request("fixture/list", ["mode": "empty"])
        print("Recovery checks passed: reopen on card open, history and load earlier, reconnect after a lost server, failed reopen stays saved, one-time lookup across pages")
    }

    /// Calls never overlap: realtime notifications carry only the thread, so an ended call's late close
    /// must not end the next one. An audio retry runs once, and New conversation cancels a pending one.
    @MainActor
    static func checkVoiceLifecycle(in dir: URL, server script: URL) async throws {
        let fm = FileManager.default
        let codex = dir.appendingPathComponent("bin/codex")   // beside the fake voice helper from checkNativeVoice
        try fm.removeItem(at: codex)
        try fm.copyItem(at: script, to: codex)
        setenv("PULSE_CHECK_CODEX", codex.path, 1)
        let log = dir.appendingPathComponent("voice-lifecycle.log")
        setenv("PULSE_CHECK_LOG", log.path, 1)
        CodexAppServer.shared.stop()
        try await Task.sleep(for: .milliseconds(50))
        func starts() -> Int { lines(log).filter { $0 == "realtime/start" }.count }
        let session = CodexPetSession(workspace: dir.appendingPathComponent("pet-voice"), defaults: isolatedDefaults())
        session.playCue = { _ in }
        session.muted = true   // the fake helper expects calls to open muted
        var inCall: Bool { session.voiceState == .live || session.voiceState == .speaking }
        session.startVoice()
        try await wait("a call goes live (\(session.voiceState), \(session.status ?? "no status"))") { inCall }
        session.stopVoice()
        session.startVoice()
        try await wait("the next call goes live") { inCall }
        try await Task.sleep(for: .milliseconds(400))
        assert(inCall, "an ended call's late close must not end the next call")
        let calls = lines(log).filter { $0.hasPrefix("realtime/") }
        assert(calls == ["realtime/start", "realtime/closed", "realtime/start"], "the next call starts after the ended one closed (got \(calls))")

        session.stopVoice()
        _ = try await CodexAppServer.shared.request("fixture/die-next", [:])
        session.startVoice()
        try await wait("a helper dying right after its devices open retries once") { starts() == 4 && inCall }
        session.stopVoice()
        _ = try await CodexAppServer.shared.request("fixture/die-next", [:])
        session.startVoice()
        try await wait("the dying call starts") { starts() == 5 }
        try await wait("and fails") { session.voiceState == .off }
        session.clear()
        try await Task.sleep(for: .milliseconds(700))
        assert(starts() == 5 && session.voiceState == .off, "New conversation cancels a pending audio retry")

        _ = try await CodexAppServer.shared.request("fixture/reject-next", [:])
        session.startVoice()
        try await wait("a rejected start fails visibly") { session.voiceState == .off && session.status == "fixture rejection" }
        let started = Date()
        session.startVoice()
        try await wait("a rejected start leaves no close to wait for") { inCall }
        assert(Date().timeIntervalSince(started) < 2, "the next call did not wait on a close that cannot come")

        session.stopVoice()
        _ = try await CodexAppServer.shared.request("fixture/die-next", [:])
        session.startVoice()
        try await wait("another dying call starts") { starts() == 7 }
        try await wait("and fails") { session.voiceState == .off }
        CodexAppServer.shared.stop()   // losing the server must cancel the pending retry too
        try await Task.sleep(for: .milliseconds(700))
        assert(starts() == 7 && session.voiceState == .off, "a lost server cancels a pending audio retry")
        print("Voice lifecycle checks passed: End then Start, stale close, one audio retry, retry cancelled by New conversation or a lost server, rejected start")
    }

    @MainActor
    static func checkRecording(_ session: CodexPetSession) {
        var cues: [String] = []
        session.playCue = { cues.append($0) }
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
        assert(cues == ["Purr", "Morse"], "one cue when the mic goes live, one when a live call ends; none for a cancelled start")
        print("Recording checks passed: start, cancel connection, restart, mute indicator, speaking, end and start/stop cues")
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
        let suite = isolatedSuite()
        approvals.defaults = UserDefaults(suiteName: suite)!
        defer { approvals.defaults = originalDefaults }
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

    /// Browser Use remembers a decline for the whole conversation and treats cancel as no decision,
    /// so only an explicit Deny may decline; everything else Pulse cannot or did not decide cancels.
    @MainActor
    static func checkConsent() async throws {
        let approvals = PetApprovals.shared
        var shown = [String](), replied = [AnyHashable](), notes = [String]()
        let originalPresenter = approvals.present
        defer { approvals.present = originalPresenter; approvals.cancelAll(reply: false) }
        approvals.present = { request in
            let id = request.id.base as! String
            shown.append(id)
            if request.consent || !request.questions.isEmpty {
                assert(request.rememberKey == nil, "Pulse never remembers consent or answers; the tool keeps its own decisions")
            }
            switch id {
            case "site-deny":
                assert(request.consent && request.title == "Allow Chrome to access https://example.com?")
                assert(request.detail.contains("https://example.com") && request.detail.contains("rest of this conversation"))
                return .deny
            case "site-dismiss": return .dismiss
            case "question":
                assert(request.questions.map(\.id) == ["q1", "q4"])
                request.picks.answers["q1"] = "Yes"   // q4 skipped: only answered questions are sent
                return .allow
            case "stop-command": approvals.cancelAll(); return .allow   // Stop while a prompt is open; the late answer is dropped
            default: return .allow
            }
        }
        CodexAppServer.shared.onNotification = { method, params in
            if method == "fixture/approved", let id = params["id"] as? AnyHashable { replied.append(id) }
            if method == "pulse/note", let text = params["text"] as? String { notes.append(text) }
        }
        _ = try await CodexAppServer.shared.request("fixture/consent", [:])
        let expected: Set<AnyHashable> = ["site-deny", "site-allow", "site-dismiss", "otp", "strict", "verify", "link", "loose-schema",
                                          "required-schema", "question", "question-mixed", "question-free", "question-dup", "question-other",
                                          "stop-command", "stop-site"]
        let deadline = Date().addingTimeInterval(5)
        while replied.count < expected.count && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))   // a duplicate reply would arrive by now
        assert(shown == ["site-deny", "site-allow", "site-dismiss", "question", "stop-command"], "only plain consent and choices are shown, never forms, links, verification or strict review (shown \(shown))")
        assert(replied.count == expected.count && Set(replied) == expected, "every request gets exactly one reply (got \(replied))")
        assert(notes.count == 10 && notes.contains { $0.contains("“Sign in”") } && notes.contains { $0.contains("What should the file be called?") },
               "every request Pulse cannot show explains itself in the chat (got \(notes))")
        assert(notes.filter { $0.contains("secret") }.count == 1 && !notes.contains { $0.contains("secret") && $0.contains("Reply in this chat") },
               "a secret question is never invited into ordinary chat")
        var outsideTurn: [String: Any] = ["threadId": "t", "mode": "form", "message": "Allow?", "_meta": ["codex_approval_kind": "mcp_tool_call"],
                                          "requestedSchema": ["type": "object", "properties": [String: Any](), "required": NSNull()]]
        assert(PetApproval(id: 1, method: "mcpServer/elicitation/request", params: outsideTurn, item: nil) != nil, "consent without a turn is still shown")
        outsideTurn["requestedSchema"] = ["type": "object", "properties": ["note": ["type": "string"]]]
        assert(PetApproval(id: 1, method: "mcpServer/elicitation/request", params: outsideTurn, item: nil) == nil, "a form with fields is never accepted empty")
        print("Consent checks passed: allow, deny without persist, Esc and Stop cancel, strict schemas, choices without secrets, unshowable requests cancel with a note, one reply each")
    }

    @MainActor
    static func checkStartup(in dir: URL) async throws {
        let log = dir.appendingPathComponent("startup.log")
        setenv("PULSE_CHECK_LOG", log.path, 1)
        func count(_ word: String) -> Int {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == word }.count
        }
        let server = CodexAppServer.shared
        server.stop()
        // Text and voice starting together share one app-server and one thread. Voice then fails
        // at the missing native helper; only its thread start matters here.
        let session = CodexPetSession(workspace: dir.appendingPathComponent("pet-startup"), defaults: isolatedDefaults())
        session.send("first")
        session.startVoice()
        var deadline = Date().addingTimeInterval(5)
        while session.voiceState != .off && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        assert(count("spawn") == 1 && count("thread") == 1, "concurrent text and voice must share one app-server and one thread")
        session.clear()

        do {
            _ = try await server.request("fixture/silent", [:], timeout: .milliseconds(200))
            assertionFailure("a silent server must time out")
        } catch {
            guard let failure = error as? CodexAppServer.Failure, case .timeout = failure else { fatalError("expected a timeout, got \(error)") }
        }

        // A server that stopped reading: the write fails with EPIPE (SIGPIPE is ignored) and the
        // request fails once, instead of the signal killing the process.
        let deaf = dir.appendingPathComponent("deaf-codex")
        try """
        #!/usr/bin/env node
        // Answers initialize, then closes its stdin while staying alive for 2 s.
        process.on('uncaughtException', () => {});
        process.stdin.once('data', d => {
          const m = JSON.parse(String(d).split('\\n')[0]);
          process.stdout.write(JSON.stringify({ id: m.id, result: {} }) + '\\n');
          process.stdin.pause();
          setTimeout(() => require('node:fs').closeSync(0), 50);
        });
        setTimeout(() => process.exit(0), 2000);
        """.write(to: deaf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deaf.path)
        let fake = ProcessInfo.processInfo.environment["PULSE_CHECK_CODEX"]!
        setenv("PULSE_CHECK_CODEX", deaf.path, 1)
        server.stop()
        try await server.start()
        setenv("PULSE_CHECK_CODEX", fake, 1)
        try await Task.sleep(for: .milliseconds(300))
        let written = Date()
        do {
            _ = try await server.request("fixture/silent", [:], timeout: .seconds(5))
            assertionFailure("a write to a closed pipe must fail")
        } catch {
            guard let failure = error as? CodexAppServer.Failure, case .transport = failure else { fatalError("expected transport, got \(error)") }
            assert(Date().timeIntervalSince(written) < 0.5, "the write itself must fail, before the server exits")
        }

        // Requests racing a server exit must fail once: no hang, no double resume.
        server.stop()
        let before = count("spawn")
        for _ in 0..<20 {
            try await server.start()
            server.notify("fixture/exit", [:])
            _ = try? await server.request("fixture/silent", [:], timeout: .seconds(5))
        }
        deadline = Date().addingTimeInterval(5)
        while count("spawn") < before + 20 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(count("spawn") == before + 20, "each start after an exit spawns exactly one new server (got \(count("spawn") - before))")
        server.stop()
        print("Startup checks passed: shared app-server and thread start, request timeout, broken pipe, and requests racing a server exit")
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
        assert(failure != nil && !bridge.lastFailureWasEarlyDeath, "oversized helper frames must fail and close the process")
        bridge.close()
        failure = nil
        let dying = try await bridge.createOffer(muted: true)
        assert(dying == "fixture-offer")
        bridge.accept(answer: "die-after-devices")
        deadline = Date().addingTimeInterval(5)
        while failure == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(failure != nil && bridge.lastFailureWasEarlyDeath, "a helper dying just after its devices open must be retryable")
        bridge.close()
        print("Native voice checks passed: fragmented frames, negotiation, initial mute, activity, cancellation, reopening, malformed frames and early helper death")
    }
}
