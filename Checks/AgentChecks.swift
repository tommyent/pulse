// Run from the project: swiftc Sources/Pulse/Breaks.swift Sources/Pulse/RexAgents.swift Sources/Pulse/Agents.swift Checks/AgentChecks.swift -o /tmp/pulse-agent-check && /tmp/pulse-agent-check
import Foundation

@main
enum AgentChecks {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    static func json(_ s: String) -> Data { Data(s.utf8) }

    static func waiting(_ id: String, _ app: BreakAgent.App = .claude, since: Double, kind: BreakAgent.Kind? = nil) -> BreakAgent {
        BreakAgent(id: id, app: app, blocked: true, kind: kind, since: at(since))
    }
    static func failed(_ id: String, _ app: BreakAgent.App = .grok, since: Double) -> BreakAgent {
        BreakAgent(id: id, app: app, blocked: false, failed: true, since: at(since))
    }
    static func finished(_ id: String, _ app: BreakAgent.App = .claude, since: Double) -> BreakAgent {
        BreakAgent(id: id, app: app, blocked: false, idle: true, done: true, since: at(since))
    }
    static func working(_ id: String, _ app: BreakAgent.App = .codex) -> BreakAgent { BreakAgent(id: id, app: app, blocked: false) }

    static func main() {
        parsing()
        events()
        board()
        quietRules()
        notifier()
        settingsAndRex()
        print("Agent checks passed: Rex's error state and kind, closed panes, waits kept across reports, the card's order and counts, "
              + "the bubbles, the quiet rules and a break on screen, one alert for each wait, which Rex app is asked, off by default, and the ring only with Rex")
    }

    static func parsing() {
        let stamp = "2026-10-26T01:35:14.24817-04:00", began = RexAgents.date(stamp)!
        func record(_ state: String, _ more: [String: Any] = [:]) -> [String: Any] {
            ["app": "claude-code", "state": state, "updated_at": stamp].merging(more) { _, new in new }
        }
        // error: kept as failed, with its line and when it failed; it needs you without being blocked
        let error = RexAgents.agent(fromRecord: record("error", ["msg": "Stopped: rate limit"]), block: "b", now: began + 600)
        assert(error == BreakAgent(id: "b", app: .claude, blocked: false, msg: "Stopped: rate limit", failed: true, since: began))
        assert(error?.needsYou == true && error?.rank == 0 && error?.idle == false)
        // kind: what a blocked agent waits for; one Rex adds later counts as none, and it means nothing off a blocked agent
        for (kind, expected) in [("permission", BreakAgent.Kind.permission), ("question", .question), ("auth", .auth)] {
            let blocked = RexAgents.agent(fromRecord: record("blocked", ["kind": kind]), block: "b")
            assert(blocked?.kind == expected && blocked?.blocked == true && blocked?.since == began)
        }
        assert(RexAgents.agent(fromRecord: record("blocked", ["kind": "someday"]), block: "b")?.kind == nil)
        assert(RexAgents.agent(fromRecord: record("blocked"), block: "b")?.kind == nil)
        assert(RexAgents.agent(fromRecord: record("working", ["kind": "permission"]), block: "b")?.kind == nil)
        assert(RexAgents.agent(fromRecord: record("error", ["kind": "permission"]), block: "b")?.kind == nil)
        // an event without a time has just happened
        assert(RexAgents.agent(fromRecord: ["app": "codex", "state": "blocked"], block: "b", now: at(3))?.since == at(3))
        assert(RexAgents.agent(fromRecord: ["app": "codex", "state": "error"], block: "b", now: at(3))?.since == at(3))
        // a finished agent keeps its line and its time; a state Rex adds later is still nothing
        let done = RexAgents.agent(fromRecord: record("done", ["msg": "All checks pass"]), block: "b", now: began + 60)
        assert(done?.done == true && done?.msg == "All checks pass" && done?.since == began)
        assert(RexAgents.agent(fromRecord: record("someday"), block: "b") == nil)
        // a status line is shown as plain text: direction overrides and other invisible formatting are dropped
        assert(RexAgents.plain("Run \u{202E}txt.exe\u{202C} now\u{200B}?\u{7}") == "Run txt.exe now?")
        assert(RexAgents.plain("Reading 14 files — 60%") == "Reading 14 files — 60%")
        assert(RexAgents.agent(fromRecord: record("blocked", ["msg": "Approve\u{202E}?"]), block: "b")?.msg == "Approve?")

        // stand-ins: an app and a state, then what a blocked one waits for and how long ago, in either order
        let fake = RexAgents.simulated("claude-code blocked permission 12, codex blocked 4 question, grok error 9, codex done 20, claude-code", now: at(30))
        assert(fake.map(\.kind) == [.permission, .question, nil, nil, nil])
        assert(fake.map(\.since) == [at(18), at(26), at(21), at(10), nil])
        assert(fake[2].failed && fake[3].done && !fake[4].needsYou && fake.map(\.label) == ["claude-code 1", "codex 2", "grok 3", "codex 4", "claude-code 5"])
    }

    static func events() {
        func sessionEvent(_ type: String, _ payload: String) -> Data {
            json(#"{"type":"session_event","payload":{"session_id":"session:s1","event":{"type":"\#(type)","payload":\#(payload)}}}"#)
        }
        func status(_ record: String) -> Data {
            sessionEvent("block_event", #"{"block_id":"b9","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":\#(record),"reason":"report"}}"#)
        }
        let errored = RexAgents.update(fromEvent: status(#"{"state":"error","app":"grok-build","msg":"Stopped"}"#))
        assert(errored?.0 == "b9" && errored?.1?.failed == true && errored?.1?.app == .grok && errored?.1?.msg == "Stopped")
        let asks = RexAgents.update(fromEvent: status(#"{"state":"blocked","kind":"question","app":"codex","msg":"Which URL?"}"#))
        assert(asks?.1?.kind == .question && asks?.1?.blocked == true)
        // the event names its session, so a pane opened after the snapshot can still be shown
        assert(asks?.1?.session == "session:s1" && errored?.1?.session == "session:s1")
        // a closed pane takes its agent with it: a failed or finished record otherwise outlives its program
        let closed = RexAgents.update(fromEvent: sessionEvent("block_closed", #"{"block_id":"b9"}"#))
        assert(closed?.0 == "b9" && closed?.1 == nil)
        assert(RexAgents.update(fromEvent: sessionEvent("block_created", #"{"block_id":"b9"}"#)) == nil)
        assert(RexAgents.update(fromEvent: sessionEvent("window_closed", #"{"window_id":"w1"}"#)) == nil)
        // lines as `rex events --all --json` printed them on 2026-11-12, from a pane whose program asked, failed and exited
        let block = "block:01a1d08f-f035-76ae-814a-7f77abff4755"
        let realAsk = RexAgents.update(fromEvent: json(#"{"type":"session_event","payload":{"session_id":"session:01a1d08f-f035-71cc-865a-c065e08b8e11","event":{"type":"block_event","payload":{"block_id":"block:01a1d08f-f035-76ae-814a-7f77abff4755","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":{"state":"blocked","kind":"question","app":"claude-code","effective_app":"claude-code","msg":"Which URL?","updated_at":"2026-11-12T11:20:59.735235-05:00","owner":{"pid":34906,"name":"bash"}},"reason":"report"}}}}}"#))
        assert(realAsk?.0 == block && realAsk?.1?.kind == .question && realAsk?.1?.since == RexAgents.date("2026-11-12T11:20:59.735235-05:00"))
        let realError = RexAgents.update(fromEvent: json(#"{"type":"session_event","payload":{"session_id":"session:01a1d08f-f035-71cc-865a-c065e08b8e11","event":{"type":"block_event","payload":{"block_id":"block:01a1d08f-f035-76ae-814a-7f77abff4755","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":{"state":"error","app":"claude-code","effective_app":"claude-code","msg":"Stopped: rate limit","updated_at":"2026-11-12T11:21:01.753752-05:00","owner":{"pid":34906,"name":"bash"}},"reason":"report"}}}}}"#))
        assert(realError?.1?.failed == true && realError?.1?.msg == "Stopped: rate limit" && realError?.1?.session == "session:01a1d08f-f035-71cc-865a-c065e08b8e11")
        // Rex kept that failure after the program exited, and said nothing more until the pane closed
        let realClose = RexAgents.update(fromEvent: json(#"{"type":"session_event","payload":{"session_id":"session:01a1d08f-f035-71cc-865a-c065e08b8e11","event":{"type":"block_closed","payload":{"block_id":"block:01a1d08f-f035-76ae-814a-7f77abff4755"}}}}"#))
        assert(realClose?.0 == block && realClose?.1 == nil)

        // a wait that is reported again (a new line, a snapshot read again) keeps the time it began
        let first = waiting("b", since: 0, kind: .permission)
        var again = waiting("b", since: 7, kind: .permission); again.msg = "Still waiting"
        assert(again.keepingWait(of: first).since == at(0) && again.keepingWait(of: first).msg == "Still waiting")
        assert(again.keepingWait(of: nil).since == at(7))
        assert(waiting("b", since: 7, kind: .question).keepingWait(of: first).since == at(7), "another kind of wait is a new wait")
        assert(failed("b", since: 7).keepingWait(of: first).since == at(7), "failing after a wait is new")
        assert(failed("b", since: 7).keepingWait(of: failed("b", since: 2)).since == at(2))
        assert(working("b").keepingWait(of: first).since == nil)
        assert(waiting("b", since: 7).keepingWait(of: working("b")).since == at(7), "it ran in between: a new wait")

        // showing a pane: it is always this Mac's Rex app that is asked. The two lists have the shape `rex client ls
        // --json` gave on two Macs on 2026-11-12, with made-up names: each server lists its own Mac's app on the local
        // socket and the other Mac's as a network client.
        let here = json(#"{"clients":[{"client_id":"client:studio-app","info":{"kind":"app","label":"Studio Mac"},"principal":{"kind":"tailscale","transport":"tailscale"}},{"client_id":"client:desk-app","info":{"kind":"app","label":"Desk Mac"},"principal":{"kind":"peer","transport":"unix"}},{"client_id":"client:socket","principal":{"kind":"peer","transport":"unix"}},{"client_id":"client:cli","info":{"kind":"cli"},"principal":{"transport":"unix"}}]}"#)
        let mine = RexAgents.localApp(fromList: here)
        assert(mine?.id == "client:desk-app" && mine?.label == "Desk Mac", "on this Mac's server: the app on the local socket")
        let there = json(#"{"clients":[{"client_id":"client:studio-own","info":{"kind":"app","label":"Studio Mac"},"principal":{"kind":"peer","transport":"unix"}},{"client_id":"client:desk-visiting","info":{"kind":"app","label":"Desk Mac"},"principal":{"kind":"tailscale","transport":"tailscale"}},{"client_id":"client:cli","info":{"kind":"cli"},"principal":{"transport":"unix"}}]}"#)
        assert(RexAgents.remoteApp(fromList: there, label: "Desk Mac") == "client:desk-visiting",
               "on the other Mac's server: this Mac's app, a network client there, not that Mac's own app on its socket")
        // the other Mac's own app is never asked, even when the labels can't settle it
        assert(RexAgents.remoteApp(fromList: there, label: "Studio Mac") == "client:desk-visiting")
        assert(RexAgents.remoteApp(fromList: there, label: "Unknown") == "client:desk-visiting" && RexAgents.remoteApp(fromList: there, label: "") == "client:desk-visiting")
        let onlyTheirs = json(#"{"clients":[{"client_id":"client:studio-own","info":{"kind":"app","label":"Studio Mac"},"principal":{"transport":"unix"}}]}"#)
        assert(RexAgents.remoteApp(fromList: onlyTheirs, label: "Studio Mac") == nil, "this Mac's app isn't connected there: nobody is asked")
        let three = json(#"{"clients":[{"client_id":"client:own","info":{"kind":"app","label":"Studio Mac"},"principal":{"transport":"unix"}},{"client_id":"client:a","info":{"kind":"app","label":"Travel Mac"},"principal":{"transport":"tailscale"}},{"client_id":"client:b","info":{"kind":"app","label":"Desk Mac"},"principal":{"transport":"tailscale"}}]}"#)
        assert(RexAgents.remoteApp(fromList: three, label: "Desk Mac") == "client:b", "among several network apps: the one with this Mac's label")
        assert(RexAgents.remoteApp(fromList: three, label: "Unknown") == nil, "several network apps and no way to tell: none is asked")
        assert(RexAgents.localApp(fromList: there)?.id == "client:studio-own" && RexAgents.localApp(fromList: three)?.label == "Studio Mac")
        let noApp = json(#"{"clients":[{"client_id":"client:cli","info":{"kind":"cli"},"principal":{"transport":"unix"}}]}"#)
        assert(RexAgents.localApp(fromList: noApp) == nil && RexAgents.remoteApp(fromList: noApp, label: "Desk Mac") == nil)
        assert(RexAgents.localApp(fromList: json("not json")) == nil && RexAgents.remoteApp(fromList: json("not json"), label: "x") == nil)
        // a stream that keeps ending is started again more and more slowly, up to once a minute
        assert(RexAgents.nextRetry(after: 2, lived: 0) == 4 && RexAgents.nextRetry(after: 32, lived: 5) == 60 && RexAgents.nextRetry(after: 60, lived: 59) == 60)
        assert(RexAgents.nextRetry(after: 60, lived: 61) == 2, "one that ran for a minute starts over quickly")
        var placed = waiting("block:1", since: 0); placed.session = "session:s1"; placed.window = "window:w1"
        assert(RexAgents.selectArguments(placed) == ["do", "session.select", "session_id=session:s1", "window_id=window:w1"])
        placed.window = ""
        assert(RexAgents.selectArguments(placed) == ["do", "session.select", "session_id=session:s1"])
    }

    static func board() {
        let idle = BreakAgent(id: "idle", app: .codex, blocked: false, idle: true)
        let stale = finished("stale", since: 0)   // finished 20 minutes ago, never looked at
        let agents = [working("w2", .claude), finished("d1", since: 9), failed("f1", since: 11), waiting("b2", .codex, since: 16, kind: .question),
                      idle, working("w1"), waiting("b1", since: 8, kind: .permission), finished("d2", .antigravity, since: 17), stale]
        let board = AgentBoard(agents, now: at(20))
        // the order: waiting for you (the longest wait on top), failed, just finished (the latest first), working
        assert(board.rows.map(\.id) == ["b1", "b2", "f1", "d2", "d1", "w1", "w2"], "\(board.rows.map(\.id))")
        assert(board.rows.map(\.state) == [.waiting, .waiting, .failed, .finished, .finished, .working, .working])
        // the count: waiting plus failed; finished, working and idle agents aren't in it
        assert(board.needsYou == 3 && board.needing.map(\.id) == ["b1", "b2", "f1"])
        assert(board.tone == .failed && board.justFinished && board.summary == "3 need you · 2 working")
        assert(board.spoken == "2 waiting for you, 1 failed, 2 just finished, 2 working")
        // more than four: three bubbles, those who need you first, and how many more
        assert(board.bubbles.apps == [.claude, .codex, .grok] && board.bubbles.more == 4)
        assert(board.rows[0].stateText(at(20)) == "Asks permission · 12 min" && board.rows[1].stateText(at(20)) == "Asks a question · 4 min")
        assert(board.rows[2].stateText(at(20)) == "Failed · 9 min ago" && board.rows[3].stateText(at(20)) == "Finished · 3 min ago")
        assert(board.rows[5].stateText(at(20)) == "Working")
        assert(AgentBoard.Row(agent: waiting("x", since: 0, kind: .auth), state: .waiting).stateText(at(125)) == "Asks you to sign in · 2 hr 5 min")
        assert(AgentBoard.Row(agent: waiting("x", since: 0), state: .waiting).stateText(at(0.5)) == "Waiting for you")
        assert(AgentBoard.Row(agent: waiting("x", since: 0), state: .waiting).stateText(at(120)) == "Waiting for you · 2 hr")
        assert(AgentBoard.Row(agent: failed("x", since: 0), state: .failed).stateText(at(0.2)) == "Failed · just now")
        assert(AgentBoard.Row(agent: waiting("x", since: 5), state: .waiting).stateText(at(0)) == "Waiting for you", "a clock ahead on another Mac")

        // failed stays until its × is clicked, and comes back when it fails again
        let cleared = AgentBoard(agents, dismissed: ["f1": at(11)], now: at(20))
        assert(cleared.needsYou == 2 && cleared.tone == .waiting && !cleared.rows.contains { $0.id == "f1" })
        assert(AgentBoard(agents, dismissed: ["f1": at(10)], now: at(20)).needsYou == 3, "a later failure isn't the one cleared")
        // finished: a tick for 15 minutes, never counted
        let later = AgentBoard([finished("d1", since: 9)], now: at(23.9))
        assert(later.justFinished && later.needsYou == 0 && later.tone == .quiet && later.summary == "1 finished")
        assert(AgentBoard([finished("d1", since: 9)], now: at(24)).rows.isEmpty)
        // waiting clears by itself: an agent Rex reports working again is only working
        let answered = AgentBoard([working("b1", .claude), waiting("b2", since: 16)], now: at(20))
        assert(answered.needsYou == 1 && answered.tone == .waiting && answered.summary == "1 needs you · 1 working")
        let quiet = AgentBoard([working("w1"), working("w2", .claude)], now: at(20))
        assert(quiet.tone == .quiet && quiet.needsYou == 0 && !quiet.justFinished && quiet.summary == "2 working" && quiet.tick == 0)
        assert(quiet.bubbles.apps == [.codex, .claude] && quiet.bubbles.more == 0)
        let empty = AgentBoard([idle, stale], now: at(20))
        assert(empty.rows.isEmpty && empty.summary.isEmpty && empty.spoken == "No active agents" && empty.bubbles.apps.isEmpty)
        assert(AgentBoard() == AgentBoard([], now: at(0)))
        let four = AgentBoard([working("a"), working("b"), working("c"), waiting("d", .grok, since: 0)], now: at(1))
        assert(four.bubbles.apps == [.grok, .codex, .codex, .codex] && four.bubbles.more == 0, "four fit; the one who needs you is in front")
        // the minimized rail's tick: 4 pt for each who needs you, up to the rings' longest
        assert(AgentBoard([waiting("a", since: 0)], now: at(1)).tick == 8 && board.tick == 16)
        assert(AgentBoard((0..<9).map { waiting("a\($0)", since: 0) }, now: at(1)).tick == 20)

        // every bubble stays inside the ring's inner edge, and neighbours overlap without one hiding another
        for count in 1...4 {
            let places = AgentBoard.bubblePlaces(count)
            assert(places.centres.count == count)
            for c in places.centres { assert((c.x * c.x + c.y * c.y).squareRoot() + places.diameter / 2 <= 0.44, "\(count) bubbles") }
            for (i, a) in places.centres.enumerated() {
                for b in places.centres.dropFirst(i + 1) {
                    let apart = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
                    assert(apart > places.diameter * 0.7, "\(count) bubbles: one covers more than a third of another")
                }
            }
        }
    }

    static func quietRules() {
        let s = AgentSettings(), until = at(90)
        func hold(_ s: AgentSettings = s, locked: Bool = false, onBreak: Bool = false, voice: Bool = false, paused: Date? = nil, rex: Bool = false,
                  mic: Bool = false) -> AgentHold? {
            AgentHold.current(s, now: at(0), locked: locked, onBreak: onBreak, voiceCall: voice, pausedUntil: paused, rexInFront: rex, microphone: { mic })
        }
        assert(hold() == nil)
        assert(hold(locked: true, onBreak: true, voice: true, paused: until, rex: true, mic: true) == .locked)
        assert(hold(onBreak: true, voice: true, paused: until, rex: true, mic: true) == .onBreak)
        assert(hold(voice: true, paused: until, rex: true, mic: true) == .voiceCall)
        assert(hold(paused: until, rex: true, mic: true) == .paused(until: until))
        assert(hold(rex: true, mic: true) == .call && hold(rex: true) == .rexInFront)
        assert(hold(paused: at(-1)) == nil, "a pause that has run out holds nothing")
        // each switch turns its own rule off; a break on screen and Rex in front have none
        var off = s; off.holdWhileLocked = false; off.holdDuringCalls = false; off.holdWhilePaused = false
        assert(hold(off, locked: true, voice: true, paused: until, mic: true) == nil && hold(off, rex: true) == .rexInFront)
        assert(hold(off, locked: true, onBreak: true, rex: true) == .onBreak)
        // a break makes Pulse the app in front, so Rex no longer is: the break holds in its place, and for 3 s after
        // it, until the app that was in front is back
        assert(hold(onBreak: true, rex: false) == .onBreak)
        assert(AgentHold.breakHolds(onScreen: true, ended: .distantPast, now: at(0)))
        assert(AgentHold.breakHolds(onScreen: false, ended: at(0), now: at(0.04)) && !AgentHold.breakHolds(onScreen: false, ended: at(0), now: at(0.06)))
        assert(!AgentHold.breakHolds(onScreen: false, ended: .distantPast, now: at(0)))
        var calls = s; calls.holdDuringCalls = false
        assert(hold(calls, voice: true, mic: true) == nil && hold(calls, locked: true) == .locked)
        // the microphone is only read when no rule before it holds
        var reads = 0
        _ = AgentHold.current(s, now: at(0), locked: true, onBreak: false, voiceCall: false, pausedUntil: nil, rexInFront: false, microphone: { reads += 1; return true })
        _ = AgentHold.current(s, now: at(0), locked: false, onBreak: false, voiceCall: false, pausedUntil: until, rexInFront: false, microphone: { reads += 1; return true })
        _ = AgentHold.current(s, now: at(0), locked: false, onBreak: true, voiceCall: false, pausedUntil: nil, rexInFront: false, microphone: { reads += 1; return true })
        _ = AgentHold.current(calls, now: at(0), locked: false, onBreak: false, voiceCall: false, pausedUntil: nil, rexInFront: false, microphone: { reads += 1; return true })
        assert(reads == 0)

        // what the card and the later alert say; the ring's bell shows for the three rules with a line
        let time: (Date) -> String = { _ in "3:30 PM" }
        assert(AgentHold.paused(until: until).line(time) == "Sounds and alerts wait until breaks resume at 3:30 PM")
        assert(AgentHold.call.line(time) == "Sounds and alerts wait for your call to end")
        assert(AgentHold.voiceCall.line(time) == "Sounds and alerts wait for your voice call to end")
        assert(AgentHold.locked.line(time) == nil && AgentHold.rexInFront.line(time) == nil && AgentHold.onBreak.line(time) == nil)
        assert(!AgentHold.onBreak.shown && AgentHold.onBreak.after == "During your break")
        assert(AgentHold.paused(until: until).shown && AgentHold.call.shown && AgentHold.voiceCall.shown && !AgentHold.locked.shown && !AgentHold.rexInFront.shown)
        assert(AgentHold.locked.after == "While the screen was locked" && AgentHold.paused(until: until).after == "While breaks were paused")
        assert(AgentHold.rexInFront.after == nil)
    }

    static func notifier() {
        typealias R = AgentNotifier.Result
        let s = AgentSettings()   // no sound, the alert after 5 minutes
        let a = waiting("a", since: 0), b = waiting("b", since: 3), f = failed("f", since: 4)

        // the alert: once a wait passes 5 minutes, then never again for that wait
        var n = AgentNotifier()
        assert(n.step([a], now: at(0), settings: s, hold: nil) == R())
        assert(n.step([a], now: at(4.9), settings: s, hold: nil) == R())
        assert(n.step([a, b], now: at(5), settings: s, hold: nil) == R(alert: true))
        assert(n.step([a, b], now: at(6), settings: s, hold: nil) == R() && n.step([a, b], now: at(60), settings: s, hold: nil) == R())
        assert(n.step([a, b], now: at(8), settings: s, hold: nil) == R(), "b was in a's alert: it gets no second one")
        // a failed agent is announced the same way; one that joins later gets its own
        assert(n.step([a, b, f], now: at(8.5), settings: s, hold: nil) == R())
        assert(n.step([a, b, f], now: at(9), settings: s, hold: nil) == R(alert: true))
        // answered and waiting again: a new wait, a new alert
        assert(n.step([b, f], now: at(10), settings: s, hold: nil) == R())
        let again = waiting("a", since: 11)
        assert(n.step([again, b, f], now: at(15.9), settings: s, hold: nil) == R())
        assert(n.step([again, b, f], now: at(16), settings: s, hold: nil) == R(alert: true))

        // one meeting: breaks paused, three agents come to need you, no alert until the pause ends, then one
        let pause = AgentHold.paused(until: at(85))
        n = AgentNotifier()
        assert(n.step([], now: at(0), settings: s, hold: nil) == R())
        assert(n.step([waiting("m1", since: 15)], now: at(15), settings: s, hold: pause) == R())
        assert(n.step([waiting("m1", since: 15)], now: at(21), settings: s, hold: pause) == R(), "due, and held")
        let three = [waiting("m1", since: 15), waiting("m2", since: 26), failed("m3", since: 45)]
        assert(n.step(three, now: at(50), settings: s, hold: pause) == R())
        assert(n.step(three, now: at(85), settings: s, hold: nil) == R(alert: true, after: pause))
        assert(n.step(three, now: at(86), settings: s, hold: nil) == R(), "one alert, not one for each")
        // answered during the hold: nothing afterwards
        n = AgentNotifier()
        assert(n.step([a], now: at(6), settings: s, hold: .call) == R())
        assert(n.step([], now: at(7), settings: s, hold: .call) == R() && n.step([], now: at(8), settings: s, hold: nil) == R())
        assert(n.step([b], now: at(9), settings: s, hold: nil) == R(alert: true), "a later wait isn't blamed on the old hold")
        // a locked screen and Rex in front hold it too
        n = AgentNotifier()
        assert(n.step([a], now: at(6), settings: s, hold: .locked) == R())
        assert(n.step([a], now: at(7), settings: s, hold: .rexInFront) == R())
        assert(n.step([a], now: at(8), settings: s, hold: nil) == R(alert: true, after: .rexInFront))
        // a break on screen: someone is past the limit and held by Rex in front; a break starts, which puts Pulse in
        // front; nothing fires or counts as announced during it; one alert once it's over
        var loudly = s; loudly.sound = "Glass"
        for settings in [s, loudly] {
            n = AgentNotifier()
            assert(n.step([a], now: at(6), settings: settings, hold: .rexInFront) == R())
            assert(n.step([a], now: at(7), settings: settings, hold: .onBreak) == R())
            assert(n.step([a, b], now: at(9), settings: settings, hold: .onBreak) == R(), "nor for one who starts waiting during it")
            assert(n.step([a, b], now: at(12), settings: settings, hold: nil) == R(alert: true, after: .onBreak))
            assert(n.step([a, b], now: at(13), settings: settings, hold: nil) == R(), "once")
        }
        // back in Rex after the break: still held, and the alert comes on leaving Rex
        n = AgentNotifier()
        assert(n.step([a], now: at(6), settings: s, hold: .rexInFront) == R() && n.step([a], now: at(7), settings: s, hold: .onBreak) == R())
        assert(n.step([a], now: at(12), settings: s, hold: .rexInFront) == R())
        assert(n.step([a], now: at(20), settings: s, hold: nil) == R(alert: true, after: .rexInFront))
        // a wait that hasn't reached 5 minutes when the hold ends still waits its 5 minutes
        n = AgentNotifier()
        assert(n.step([a], now: at(2), settings: s, hold: .call) == R() && n.step([a], now: at(3), settings: s, hold: nil) == R())
        assert(n.step([a], now: at(5), settings: s, hold: nil) == R(alert: true))

        // the alert switched off, or a longer wait chosen
        var noAlert = s; noAlert.waitAlert = false
        n = AgentNotifier()
        assert(n.step([a], now: at(60), settings: noAlert, hold: nil) == R())
        var slow = s; slow.waitMinutes = 15
        assert(n.step([a], now: at(14), settings: slow, hold: nil) == R() && n.step([a], now: at(15), settings: slow, hold: nil) == R(alert: true))

        // the sound: once as a wait begins, when one is chosen
        var loud = s; loud.sound = "Glass"
        n = AgentNotifier()
        assert(n.step([a], now: at(0), settings: loud, hold: nil) == R(sound: true))
        assert(n.step([a], now: at(1), settings: loud, hold: nil) == R())
        assert(n.step([a, b], now: at(3), settings: loud, hold: nil) == R(sound: true))
        assert(n.step([a, b], now: at(5), settings: loud, hold: nil) == R(alert: true), "the alert has the system sound: no second one")
        // held, the sound waits: one afterwards for everyone, or none when the alert comes instead
        n = AgentNotifier()
        assert(n.step([a], now: at(0), settings: loud, hold: .voiceCall) == R())
        assert(n.step([a, b], now: at(3), settings: loud, hold: .voiceCall) == R())
        assert(n.step([a, b], now: at(4), settings: loud, hold: nil) == R(sound: true))
        assert(n.step([a, b], now: at(4.5), settings: loud, hold: nil) == R())
        n = AgentNotifier()
        assert(n.step([a], now: at(0), settings: loud, hold: .call) == R())
        assert(n.step([a], now: at(6), settings: loud, hold: nil) == R(alert: true, after: .call))
        assert(n.step([a], now: at(7), settings: loud, hold: nil) == R())
        // with no sound chosen, a held wait owes none
        n = AgentNotifier()
        assert(n.step([a], now: at(0), settings: noAlert, hold: .call) == R() && n.step([a], now: at(1), settings: noAlert, hold: nil) == R())
    }

    static func settingsAndRex() {
        // off by default; no sound, the alert after 5 minutes, every quiet rule on
        let d = AgentSettings()
        assert(!d.showOnRail && d.sound.isEmpty && d.waitAlert && d.waitMinutes == 5 && d.holdWhilePaused && d.holdDuringCalls && d.holdWhileLocked)
        assert(AgentSettings.waitChoices.contains(d.waitMinutes))
        var changed = d; changed.showOnRail = true; changed.sound = "Glass"; changed.waitMinutes = 10; changed.holdDuringCalls = false
        assert(try! JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(changed)) == changed)
        // a value this version can't read costs only that value
        let partial = try! JSONDecoder().decode(AgentSettings.self, from: json(#"{"showOnRail":true,"sound":7,"waitMinutes":0,"holdWhileLocked":"no","later":1}"#))
        assert(partial.showOnRail && partial.sound.isEmpty && partial.waitMinutes == 1 && partial.holdWhileLocked)
        assert(try! JSONDecoder().decode(AgentSettings.self, from: json("{}")) == d)

        // without Rex there is no ring, whatever the switch says
        assert(!changed.onRail(rexFound: false) && changed.onRail(rexFound: true) && !d.onRail(rexFound: true))
        // finding Rex: the rex command in a folder Pulse looks in, by file checks alone
        let fm = FileManager.default, home = fm.temporaryDirectory.appending(path: "pulse-agents-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let systemWide = fm.isExecutableFile(atPath: "/opt/homebrew/bin/rex") || fm.isExecutableFile(atPath: "/usr/local/bin/rex")
        assert(RexAgents.executable(home: home) == nil || systemWide)
        let bin = home.appending(path: ".local/bin")
        try! fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try! Data("#!/bin/sh\n".utf8).write(to: bin.appending(path: "rex"))
        assert(RexAgents.executable(home: home) == nil || systemWide, "a file that can't be run isn't Rex")
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "rex").path)
        assert(RexAgents.executable(home: home)?.path == bin.appending(path: "rex").path)
    }
}
