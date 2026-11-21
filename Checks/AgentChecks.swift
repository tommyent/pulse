// Run from the project: swiftc Sources/Pulse/Breaks.swift Sources/Pulse/RexAgents.swift Sources/Pulse/Agents.swift Sources/Pulse/AgentContext.swift Checks/AgentChecks.swift -o /tmp/pulse-agent-check && /tmp/pulse-agent-check
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
        keyboard()
        reader()
        removedHost()
        movedPane()
        context()
        notifier()
        settingsAndRex()
        print("Agent checks passed: Rex's error state and kind, closed panes, waits kept across reports, the card's order and counts, "
              + "the bubbles, idle agents and their context, the quiet rules and a break on screen, one alert for each wait, which Rex app is asked and what a row click sends, the card's keys, off by default, and the ring only with Rex")
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
        // Rex emits session_view_changed when a pane moves, swaps or is renamed
        let viewChanged = RexAgents.viewChangedSession(fromEvent: json(#"{"type":"session_event","payload":{"session_id":"session:s1","event":{"type":"session_view_changed","payload":{"revision":6}}}}"#))
        assert(viewChanged == "session:s1")
        assert(RexAgents.viewChangedSession(fromEvent: sessionEvent("block_closed", #"{"block_id":"b9"}"#)) == nil)
        assert(RexAgents.viewChangedSession(fromEvent: json(#"{"type":"hosts_changed"}"#)) == nil)

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
        // the order: waiting for you (the longest wait on top), failed, just finished (the latest first), working,
        // then the idle ones
        assert(board.rows.map(\.id) == ["b1", "b2", "f1", "d2", "d1", "w1", "w2", "stale", "idle"], "\(board.rows.map(\.id))")
        assert(board.rows.map(\.state) == [.waiting, .waiting, .failed, .finished, .finished, .working, .working, .idle, .idle])
        assert(board.active.map(\.id) == ["b1", "b2", "f1", "d2", "d1", "w1", "w2"])
        // the count: waiting plus failed; finished, working and idle agents aren't in it
        assert(board.needsYou == 3 && board.needing.map(\.id) == ["b1", "b2", "f1"])
        assert(board.tone == .failed && board.justFinished && board.summary == "3 need you · 2 working")
        assert(board.spoken == "2 waiting for you, 1 failed, 2 just finished, 2 working, 2 idle")
        // more than four agents: three bubbles, those who need you first, and how many more, the idle ones among them
        assert(board.bubbles.apps == [.claude, .codex, .grok] && board.bubbles.colour == 3 && board.bubbles.more == 6, "\(board.bubbles)")
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
        let unseen = AgentBoard([finished("d1", since: 9)], now: at(24))   // after that it's one of the idle
        assert(unseen.rows.map(\.state) == [.idle] && !unseen.justFinished && unseen.active.isEmpty)
        // waiting clears by itself: an agent Rex reports working again is only working
        let answered = AgentBoard([working("b1", .claude), waiting("b2", since: 16)], now: at(20))
        assert(answered.needsYou == 1 && answered.tone == .waiting && answered.summary == "1 needs you · 1 working")
        let quiet = AgentBoard([working("w1"), working("w2", .claude)], now: at(20))
        assert(quiet.tone == .quiet && quiet.needsYou == 0 && !quiet.justFinished && quiet.summary == "2 working" && quiet.tick == 0)
        assert(quiet.bubbles.apps == [.codex, .claude] && quiet.bubbles.colour == 2 && quiet.bubbles.more == 0)
        // the number under the ring: how many are working, until one needs you; then how many need you, on a ring
        // that is orange or red. (It was only ever who needs you: "0" under a grey ring with two agents at work.)
        assert(quiet.number == 2 && quiet.spoken == "2 working", "\(quiet.number)")
        assert(answered.number == 1 && answered.tone == .waiting, "one waits and one works: the one who waits")
        assert(board.number == 3 && board.tone == .failed && cleared.number == 2 && cleared.tone == .waiting)
        assert(AgentBoard([working("w1"), working("w2"), working("w3"), finished("d1", since: 19), idle], now: at(20)).number == 3)
        // nobody working or waiting: 0, which is then true. Finished and idle agents aren't in it
        assert(later.number == 0 && unseen.number == 0 && AgentBoard().number == 0 && AgentBoard().spoken == "No active agents")
        // idle agents are grey bubbles in the ring, and nothing more: no number, no colour, no tick on the sliver
        let resting = AgentBoard([idle, stale], now: at(20))
        assert(resting.rows.map(\.id) == ["stale", "idle"] && resting.active.isEmpty)
        assert(resting.bubbles.apps == [.claude, .codex] && resting.bubbles.colour == 0 && resting.bubbles.more == 0, "\(resting.bubbles)")
        assert(resting.needsYou == 0 && resting.number == 0 && resting.needing.isEmpty && resting.tone == .quiet && !resting.justFinished && resting.tick == 0)
        assert(resting.summary == "2 idle" && resting.spoken == "No active agents, 2 idle")
        assert(AgentBoard([working("w1"), idle], now: at(20)).summary == "1 working", "the header names the idle only when nobody else is there")
        // the longest idle first, by the time Rex gives for the idle or finished state; one with no time last
        func rested(_ id: String, since: Double?) -> BreakAgent {
            BreakAgent(id: id, app: .claude, blocked: false, idle: true, since: since.map(at))
        }
        let idlers = AgentBoard([rested("m", since: 100), rested("a-unknown", since: nil), rested("z", since: 0), finished("old-finish", since: 40),
                                 rested("y", since: 0)], now: at(200))
        assert(idlers.rows.map(\.id) == ["y", "z", "old-finish", "m", "a-unknown"], "\(idlers.rows.map(\.id))")
        assert(idlers.rows.map { $0.stateText(at(200)) } == ["Idle · 3 hr 20 min", "Idle · 3 hr 20 min", "Idle · 2 hr 40 min", "Idle · 1 hr 40 min", "Idle"])
        // a bubble for every agent, from none to seven in every mix: the active ones first, in colour (two at work
        // are two bubbles, never one plain icon), then the idle ones, grey. Past four agents, three bubbles and the
        // rest as "+N"; with up to three active, those are the idle agents not drawn
        for total in 0...7 {
            for busy in 0...total {
                let agents = (0..<busy).map { working("w\($0)", .claude) } + (busy..<total).map { rested("i\($0)", since: 0) }
                let shown = AgentBoard(agents.reversed(), now: at(20)).bubbles, drawn = total > 4 ? 3 : total
                assert(shown.apps.count == drawn && shown.more == total - drawn && shown.colour == min(busy, drawn), "\(busy) of \(total): \(shown)")
                if busy <= 3 { assert(shown.more == (total - busy) - (drawn - shown.colour), "\(busy) of \(total): +N is the idle agents not drawn") }
            }
        }
        // colour before grey whatever order Rex gave them in: who needs you, who finished, who works, then the idle
        let mixed = AgentBoard([idle, working("w", .claude), waiting("b", .grok, since: 16), finished("d", .antigravity, since: 17), rested("r", since: 0)], now: at(20))
        assert(mixed.bubbles.apps == [.grok, .antigravity, .claude] && mixed.bubbles.colour == 3 && mixed.bubbles.more == 2, "\(mixed.bubbles)")
        let fitted = AgentBoard([rested("r", since: 5), idle, working("w", .codex), waiting("b", .grok, since: 16)], now: at(20))
        assert(fitted.bubbles.apps == [.grok, .codex, .claude, .codex] && fitted.bubbles.colour == 2 && fitted.bubbles.more == 0, "\(fitted.bubbles)")
        assert(fitted.number == 1 && fitted.tone == .waiting && AgentBoard([working("w"), idle, rested("r", since: 0)], now: at(20)).number == 1, "idle agents aren't in the number")
        func idleText(_ minutes: Double) -> String { AgentBoard.Row(agent: rested("x", since: 0), state: .idle).stateText(at(minutes)) }
        assert(idleText(0.5) == "Idle" && idleText(41) == "Idle · 41 min" && idleText(120) == "Idle · 2 hr" && idleText(134) == "Idle · 2 hr 14 min")
        // past a day it's days and hours: the stale ones stand out by that alone
        assert(idleText(24 * 60) == "Idle · 1 day" && idleText(28 * 60 + 5) == "Idle · 1 day 4 hr" && idleText(51 * 60 + 12) == "Idle · 2 days 3 hr")
        // the time comes from Rex's record, for an idle state as for a finished one
        let stamp = "2026-10-26T01:35:14.24817-04:00", began = RexAgents.date(stamp)!
        let reported = RexAgents.agent(fromRecord: ["app": "codex", "state": "idle", "updated_at": stamp, "owner": ["pid": 4242, "name": "codex"]], block: "b")
        assert(reported?.idle == true && reported?.since == began && reported?.pid == 4242)
        assert(AgentBoard([reported!], now: began + 134 * 60).rows[0].stateText(began + 134 * 60) == "Idle · 2 hr 14 min")
        assert(AgentBoard() == AgentBoard([], now: at(0)))
        let four = AgentBoard([working("a"), working("b"), working("c"), waiting("d", .grok, since: 0)], now: at(1))
        assert(four.bubbles.apps == [.grok, .codex, .codex, .codex] && four.bubbles.colour == 4 && four.bubbles.more == 0, "four fit; the one who needs you is in front")
        // the minimized rail's tick: 4 pt for each who needs you, up to the rings' longest
        assert(AgentBoard([waiting("a", since: 0)], now: at(1)).tick == 8 && board.tick == 16)
        assert(AgentBoard((0..<9).map { waiting("a\($0)", since: 0) }, now: at(1)).tick == 20)

        // a lone agent sits on a disc like the others, so it can't pass for its app's usage ring: one disc in the
        // middle, larger than any of several, its icon (0.66 of the disc) about as large as the plain icon was
        let lone = AgentBoard.bubblePlaces(1)
        assert(lone.centres.count == 1 && lone.centres[0].x == 0 && lone.centres[0].y == 0)
        assert(lone.diameter > AgentBoard.bubblePlaces(2).diameter && lone.diameter * 0.66 >= 0.36, "a lone agent's disc: \(lone.diameter)")
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

    static func reader() {
        // a host leaves Rex's list while its dead stream waits to start again, and is back before the wait is over:
        // the old start's retry no longer counts, so only the new start has a stream
        var watching = WatchedServers()
        let local = watching.watch(""), first = watching.watch("studio")
        assert(watching.isCurrent("studio", start: first) && watching.contains("studio") && Set(watching.servers) == ["", "studio"])
        watching.unwatch("studio")
        assert(!watching.isCurrent("studio", start: first) && !watching.contains("studio"))
        let second = watching.watch("studio")
        assert(second != first && !watching.isCurrent("studio", start: first) && watching.isCurrent("studio", start: second))
        assert(watching.isCurrent("", start: local), "the other servers' starts stay as they were")
        watching.removeAll()
        assert(watching.servers.isEmpty && watching.watch("studio") != second, "a start from before a stop never matches a later one")

        // a server with nothing to say doesn't hold up another server's events: two pipes, the first never written to.
        // (Read through `FileHandle.bytes`, the second one's lines never came: the ring missed an agent at work.)
        final class Heard: @unchecked Sendable { var lines: [String] = [] }
        let quiet = Pipe(), busy = Pipe(), heard = Heard(), arrived = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        Task.detached { for await _ in RexAgents.lines(of: quiet.fileHandleForReading) {} }
        Thread.sleep(forTimeInterval: 0.2)   // the quiet one is waiting to read first
        Task.detached {
            for await line in RexAgents.lines(of: busy.fileHandleForReading) {
                heard.lines.append(line)
                if line == "four" { arrived.signal() }
            }
            ended.signal()
        }
        // lines that arrive together, and one that arrives in two parts
        for part in ["one\ntwo\nthr", "ee\n", "four\n"] {
            Thread.sleep(forTimeInterval: 0.2)
            busy.fileHandleForWriting.write(Data(part.utf8))
        }
        assert(arrived.wait(timeout: .now() + 5) == .success, "lines come as they are written, not when the pipe closes")
        try! busy.fileHandleForWriting.close()   // the stream ends with its pipe
        assert(ended.wait(timeout: .now() + 5) == .success, "a quiet stream held up another stream's lines")
        assert(heard.lines == ["one", "two", "three", "four"], "\(heard.lines)")

        // two clicks: only the latest counts
        let clicks = LatestRequest()
        let a = clicks.next()
        assert(clicks.isLatest(a))
        let b = clicks.next()
        assert(!clicks.isLatest(a) && clicks.isLatest(b))

        // what a row click sends to Rex, through a stand-in for the rex command that notes each call
        let fm = FileManager.default, dir = fm.temporaryDirectory.appending(path: "pulse-show-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let rex = dir.appending(path: "rex"), log = dir.appending(path: "calls.log")
        try! Data(#"""
        #!/bin/sh
        here="$(dirname "$0")"
        echo "$*" >> "$here/calls.log"
        case "$*" in
            *"-S studio client ls"*) cat "$here/there.json" ;;
            *"-S studio block ls -s session:s2"*) cat "$here/studio-s2.json" ;;
            *"client ls"*) cat "$here/here.json" ;;
            *"block ls -s session:s1"*) cat "$here/s1.json" ;;
            *"block ls -s session:s3"*) cat "$here/s3.json" ;;
            *"api call session.list"*) cat "$here/sessions.json" ;;
            *"block focus"*"block:b5"*) exit 1 ;;
        esac
        """#.utf8).write(to: rex)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rex.path)
        try! Data(#"{"clients":[{"client_id":"client:studio-app","info":{"kind":"app","label":"Studio Mac"},"principal":{"transport":"tailscale"}},{"client_id":"client:desk-app","info":{"kind":"app","label":"Desk Mac"},"principal":{"transport":"unix"}}]}"#.utf8).write(to: dir.appending(path: "here.json"))
        try! Data(#"{"clients":[{"client_id":"client:studio-own","info":{"kind":"app","label":"Studio Mac"},"principal":{"transport":"unix"}},{"client_id":"client:desk-visiting","info":{"kind":"app","label":"Desk Mac"},"principal":{"transport":"tailscale"}}]}"#.utf8).write(to: dir.appending(path: "there.json"))
        try! Data(#"{"blocks":[{"block_id":"block:b1","label":"pane","flavor":"com.superlogical.terminal.shell","window_id":"window:w2"},{"block_id":"block:b4","label":"detached","flavor":"com.superlogical.terminal.shell"},{"block_id":"block:b5","label":"closing","flavor":"com.superlogical.terminal.shell","window_id":"window:w2"}]}"#.utf8).write(to: dir.appending(path: "s1.json"))
        try! Data(#"{"blocks":[{"block_id":"block:b3","label":"moved","flavor":"com.superlogical.terminal.shell","window_id":"window:w3"}]}"#.utf8).write(to: dir.appending(path: "s3.json"))
        try! Data(#"{"blocks":[{"block_id":"block:b2","label":"far","flavor":"com.superlogical.terminal.shell","window_id":"window:w9"}]}"#.utf8).write(to: dir.appending(path: "studio-s2.json"))
        try! Data(#"{"sessions":[{"session_id":"session:s1"},{"session_id":"session:s3"}]}"#.utf8).write(to: dir.appending(path: "sessions.json"))
        func calls() -> [String] {
            defer { try? fm.removeItem(at: log) }
            return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
                .map { $0.replacingOccurrences(of: "--autostart=false --timeout 3s ", with: "") }
        }
        // stale window_id: the pane moved from w1 to w2 since the snapshot, so show resolves w2 before selecting
        var near = waiting("block:b1", since: 0); near.session = "session:s1"; near.window = "window:w1"
        var far = waiting("block:b2", since: 0); far.session = "session:s2"; far.window = "window:old"; far.host = "studio"
        RexAgents.show(near, rex: rex, thisMac: "Unknown")
        assert(calls() == ["block ls -s session:s1 --json", "block focus -s session:s1 block:b1", "client ls --json",
                           "-C client:desk-app do session.select session_id=session:s1 window_id=window:w2"])
        // a pane on the other Mac: resolved and focused there, and this Mac's app is asked through that host's server
        RexAgents.show(far, rex: rex, thisMac: "Unknown")
        assert(calls() == ["-S studio block ls -s session:s2 --json", "-S studio block focus -s session:s2 block:b2",
                           "client ls --json", "-S studio client ls --json",
                           "-S studio -C client:desk-visiting do session.select session_id=session:s2 window_id=window:w9"])
        // a pane that moved to another session is found across sessions before focusing and selecting
        var crossSession = waiting("block:b3", since: 0); crossSession.session = "session:s1"; crossSession.window = "window:w1"
        RexAgents.show(crossSession, rex: rex, thisMac: "Unknown")
        assert(calls() == ["block ls -s session:s1 --json", "api call session.list", "block ls -s session:s3 --json",
                           "block focus -s session:s3 block:b3", "client ls --json",
                           "-C client:desk-app do session.select session_id=session:s3 window_id=window:w3"])
        // a detached pane drops its stale window_id instead of jumping to an old tab
        var detached = waiting("block:b4", since: 0); detached.session = "session:s1"; detached.window = "window:w1"
        RexAgents.show(detached, rex: rex, thisMac: "Unknown")
        assert(calls() == ["block ls -s session:s1 --json", "block focus -s session:s1 block:b4", "client ls --json",
                           "-C client:desk-app do session.select session_id=session:s1"])
        // a closed pane absent from every session sends neither focus nor session.select
        var gone = waiting("block:gone", since: 0); gone.session = "session:s1"; gone.window = "window:w1"
        RexAgents.show(gone, rex: rex, thisMac: "Unknown")
        assert(calls() == ["block ls -s session:s1 --json", "api call session.list", "block ls -s session:s3 --json"])
        // if focus fails (e.g. the pane closed between resolve and focus), no session is selected
        var closing = waiting("block:b5", since: 0); closing.session = "session:s1"; closing.window = "window:w1"
        RexAgents.show(closing, rex: rex, thisMac: "Unknown")
        assert(calls() == ["block ls -s session:s1 --json", "block focus -s session:s1 block:b5"])
        // a click that a newer one has overtaken sends nothing more: none at all, or none after the request under way
        RexAgents.show(near, rex: rex, thisMac: "Unknown") { false }
        assert(calls().isEmpty)
        var asked = 0
        RexAgents.show(near, rex: rex, thisMac: "Unknown") { asked += 1; return asked == 1 }
        assert(calls() == ["block ls -s session:s1 --json"])
        asked = 0
        RexAgents.show(near, rex: rex, thisMac: "Unknown") { asked += 1; return asked <= 2 }
        assert(calls() == ["block ls -s session:s1 --json", "block focus -s session:s1 block:b1"])
        var unplaced = near; unplaced.session = ""
        RexAgents.show(unplaced, rex: rex, thisMac: "Unknown")
        assert(calls().isEmpty, "a stand-in agent has no pane to show")
    }

    /// The agents card under the keyboard, once its shortcut has opened it.
    static func keyboard() {
        // the shortcut opens the agents card, and closes it only when that card is the one open
        assert(AgentCardSelection.shortcutOpens(cardVisible: false, sideCard: nil) && AgentCardSelection.shortcutOpens(cardVisible: false, sideCard: "agents"))
        assert(AgentCardSelection.shortcutOpens(cardVisible: true, sideCard: nil) && AgentCardSelection.shortcutOpens(cardVisible: true, sideCard: "battery"),
               "over a usage card or the battery's, it opens the agents card")
        assert(!AgentCardSelection.shortcutOpens(cardVisible: true, sideCard: "agents"), "pressed again, it closes the card")

        let idle = BreakAgent(id: "i", app: .codex, blocked: false, idle: true, since: at(0))
        let agents = [working("w"), idle, waiting("b", since: 16), finished("d", since: 17)]
        let rows = AgentBoard(agents, now: at(20)).rows
        assert(rows.map(\.id) == ["b", "d", "w", "i"])
        var keys = AgentCardSelection()
        // it opens on the first row, who needs you most, and Return there is a click on that row
        assert(keys.row(in: rows)?.id == "b" && keys.press(.enter, rows: rows) == .show(rows[0].agent))
        // ↓ goes through the rows as listed, the idle ones last, and stops at the end
        var seen: [String] = []
        for _ in 0..<5 {
            assert(keys.press(.down, rows: rows) == .select)
            seen.append(keys.row(in: rows)!.id)
        }
        assert(seen == ["d", "w", "i", "i", "i"], "\(seen)")
        assert(keys.press(.enter, rows: rows) == .show(idle), "Return shows the selected agent, an idle one too")
        // ↑ goes back and stops at the first
        seen = []
        for _ in 0..<5 {
            assert(keys.press(.up, rows: rows) == .select)
            seen.append(keys.row(in: rows)!.id)
        }
        assert(seen == ["w", "d", "b", "b", "b"], "\(seen)")
        // the selection is the agent, not its place: when the rows move, it moves with them
        _ = keys.press(.down, rows: rows)
        _ = keys.press(.down, rows: rows)
        assert(keys.row(in: rows)?.id == "w")
        let moved = AgentBoard([waiting("w", .codex, since: 19), idle, waiting("b", since: 16), finished("d", since: 17)], now: at(20)).rows
        assert(moved.map(\.id) == ["b", "w", "d", "i"] && keys.row(in: moved)?.id == "w" && keys.press(.enter, rows: moved) == .show(moved[1].agent))
        assert(keys.press(.down, rows: moved) == .select && keys.row(in: moved)?.id == "d")
        // an agent that left the card: back to the first row
        let fewer = moved.filter { $0.id != "d" }
        assert(keys.row(in: fewer)?.id == "b" && keys.press(.down, rows: fewer) == .select && keys.row(in: fewer)?.id == "w")
        // Escape closes the card, wherever the selection is; an empty card has nothing to choose or show
        assert(keys.press(.escape, rows: rows) == .close)
        var none = AgentCardSelection()
        assert(none.row(in: []) == nil && none.press(.down, rows: []) == nil && none.press(.up, rows: []) == nil && none.press(.enter, rows: []) == nil)
        assert(none.press(.escape, rows: []) == .close)
    }

    /// The reader itself, against a stand-in for the rex command: a host is taken out of Rex's list while its stream
    /// still has a line on the way. That line must not put the host's agent back on the rail.
    static func removedHost() {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appending(path: "pulse-hosts-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ text: String, _ name: String) { try! Data(text.utf8).write(to: dir.appending(path: name)) }
        func status(_ block: String) -> String {
            #"{"type":"session_event","payload":{"session_id":"session:s9","event":{"type":"block_event","payload":{"block_id":""# + block
                + #"","name":"program_status_changed","payload":{"id":"","record":{"state":"working","app":"codex"}}}}}}"# + "\n"
        }
        // the host's stream says one line at once and, when Pulse ends it, one more: a line left in the pipe. This
        // Mac's stream says the list of hosts changed once the file `changed` is there.
        write(#"""
        #!/bin/sh
        here="$(dirname "$0")"
        case "$*" in
            *"-S studio events"*)
                trap 'kill $!; cat "$here/last-line.json"; echo "studio ended" >> "$here/calls.log"; exit 0' TERM
                cat "$here/first-line.json"
                sleep 600 & wait ;;
            *"events"*)
                trap 'kill $!; exit 0' TERM
                while [ ! -e "$here/changed" ]; do sleep 0.1; done
                echo '{"type":"hosts_changed"}'
                sleep 600 & wait ;;
            *"hosts list"*) cat "$here/hosts.json" ;;
            *"session.list"*) echo '{"sessions":[]}' ;;
        esac
        """#, "rex")
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "rex").path)
        write(#"{"hosts":[{"host":{"label":"studio"}}]}"#, "hosts.json")
        write(status("block:early"), "first-line.json")
        write(status("block:late"), "last-line.json")
        MainActor.assumeIsolated {
            let rex = RexAgents(find: { dir.appending(path: "rex") })
            // lets the reader's work on the main thread run, until `done` or for `seconds`
            func wait(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                return done()
            }
            rex.want(true, for: "check")
            let followed = wait(10) { rex.agents.map(\.id) == ["block:early"] }
            assert(followed, "a followed host's line is applied: \(rex.agents.map(\.id))")
            write(#"{"hosts":[]}"#, "hosts.json")
            write("", "changed")
            let ended = wait(10) { ((try? String(contentsOf: dir.appending(path: "calls.log"), encoding: .utf8)) ?? "").contains("studio ended") }
            assert(ended, "a host that left the list has its stream ended")
            _ = wait(1)   // time for the last line to arrive
            assert(rex.agents.isEmpty, "a line from a removed host's stream put its agent back: \(rex.agents.map(\.id))")
            rex.want(false, for: "check")
            _ = wait(0.3)
        }
    }

    /// A pane moved to another tab after the initial snapshot: `session_view_changed` refreshes its cached tab and
    /// label without waiting for the 10-minute snapshot.
    static func movedPane() {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appending(path: "pulse-moved-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ text: String, _ name: String) { try! Data(text.utf8).write(to: dir.appending(path: name)) }
        write(#"""
        #!/bin/sh
        here="$(dirname "$0")"
        case "$*" in
            *"events"*)
                trap 'kill $!; exit 0' TERM
                while [ ! -e "$here/moved" ]; do sleep 0.05; done
                echo '{"type":"session_event","payload":{"session_id":"session:s1","event":{"type":"session_view_changed","payload":{"revision":6}}}}'
                sleep 600 & wait ;;
            *"hosts list"*) echo '{"hosts":[]}' ;;
            *"session.list"*) echo '{"sessions":[{"session_id":"session:s1"}]}' ;;
            *"block ls -s session:s1"*) cat "$here/blocks.json" ;;
            *"program_status"*) echo '{"records":[{"app":"claude-code","state":"blocked","kind":"question","msg":"Ready?"}]}' ;;
        esac
        """#, "rex")
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "rex").path)
        write(#"{"blocks":[{"block_id":"block:b1","label":"old","flavor":"com.superlogical.terminal.shell","window_id":"window:w1"}]}"#, "blocks.json")
        MainActor.assumeIsolated {
            let rex = RexAgents(find: { dir.appending(path: "rex") })
            func wait(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                return done()
            }
            rex.want(true, for: "check")
            let initial = wait(10) { rex.agents.first?.window == "window:w1" && rex.agents.first?.label == "old" }
            assert(initial, "initial snapshot placed block:b1 in w1: \(rex.agents)")
            write(#"{"blocks":[{"block_id":"block:b1","label":"moved","flavor":"com.superlogical.terminal.shell","window_id":"window:w2"}]}"#, "blocks.json")
            write("", "moved")
            let refreshed = wait(10) { rex.agents.first?.window == "window:w2" && rex.agents.first?.label == "moved" }
            assert(refreshed, "session_view_changed should refresh the pane's tab and label: \(rex.agents)")
            rex.want(false, for: "check")
            _ = wait(0.3)
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

    /// An idle agent's context, from made-up session data in a scratch home folder.
    static func context() {
        // what the card says
        assert(AgentContext(tokens: 73_060, window: 258_400).text == "Context 28%" && AgentContext(tokens: 184_187, window: 256_000).text == "Context 71%")
        assert(AgentContext(tokens: 300_000, window: 256_000).text == "Context 100%")
        assert(AgentContext(tokens: 113_400, window: nil).text == "Context 113k tokens" && AgentContext(tokens: 1_250_000, window: nil).text == "Context 1.2M tokens")
        assert(AgentContext(tokens: 900, window: nil).text == "Context 900 tokens" && AgentContext(tokens: 5, window: 0).text == "Context 5 tokens")

        let fm = FileManager.default, home = fm.temporaryDirectory.appending(path: "pulse-context-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        func write(_ text: String, _ path: String) -> URL {
            let url = home.appending(path: path)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(text.utf8).write(to: url)
            return url
        }
        func idle(_ app: BreakAgent.App, pid: Int32? = 4242, since: Double? = 10, host: String = "") -> BreakAgent {
            BreakAgent(id: "b", app: app, blocked: false, idle: true, host: host, since: since.map(at), pid: pid)
        }
        var open: [String] = []
        let running = AgentContext.Processes(started: { _ in at(0) }, openFiles: { _ in open })
        func read(_ agent: BreakAgent, _ processes: AgentContext.Processes? = nil) -> AgentContext? {
            AgentContext.read(agent, home: home, processes: processes ?? running)
        }

        // Claude Code: the process's own session record, then the end of that session's transcript
        let session = "0f0e0d0c-1111-2222-3333-444455556666"
        let record = write(#"{"pid":4242,"sessionId":"\#(session)","cwd":"/Users/example/code/app","status":"idle"}"#, ".claude/sessions/4242.json")
        let transcript = [
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":9,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":5}}}"#,
            #"{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":12,"cache_read_input_tokens":80000,"cache_creation_input_tokens":3000,"output_tokens":988}}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":5,"cache_read_input_tokens":999999,"cache_creation_input_tokens":0,"output_tokens":1}}}"#,
            #"{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"type":"system","subtype":"turn_duration"}"#,
        ].joined(separator: "\n") + "\n"
        let named = write(transcript, ".claude/projects/-Users-example-code-app/\(session).jsonl")
        // the last reply of the main conversation: not a helper's, not a notice without tokens
        assert(read(idle(.claude)) == AgentContext(tokens: 84_000, window: nil))
        // a second copy of the session in another folder: an old one can't be told from the live one, even when one
        // of the two is in the folder named after the working folder
        let stray = write(transcript.replacingOccurrences(of: "80000", with: "70000"), ".claude/projects/old-place/\(session).jsonl")
        assert(read(idle(.claude)) == nil, "the same session's transcript in two folders")
        try! fm.removeItem(at: stray)
        assert(read(idle(.claude)) == AgentContext(tokens: 84_000, window: nil))
        assert(AgentContext.claudeSession(fromRecord: Data(#"{"pid":7,"sessionId":"abc-1"}"#.utf8), pid: 7) == "abc-1")
        assert(AgentContext.claudeContext(Data("not json\n".utf8)) == nil && AgentContext.claudeContext(Data()) == nil)
        // no certain match, nothing shown: the process gone; its number reused by something started after the status;
        // a pane on another Mac; no process or no time in the status; a record that is another process's
        assert(read(idle(.claude), .init(started: { _ in nil }, openFiles: { _ in [] })) == nil)
        assert(read(idle(.claude), .init(started: { _ in at(10.5) }, openFiles: { _ in [] })) == nil)
        assert(read(idle(.claude, host: "studio")) == nil && read(idle(.claude, pid: nil)) == nil && read(idle(.claude, since: nil)) == nil)
        assert(read(idle(.claude, pid: 4243)) == nil, "no record for that process")
        _ = write(#"{"pid":9999,"sessionId":"\#(session)"}"#, ".claude/sessions/4243.json")
        assert(read(idle(.claude, pid: 4243)) == nil, "the record names another process")
        assert(AgentContext.claudeSession(fromRecord: Data(#"{"pid":7,"sessionId":"../../etc/x"}"#.utf8), pid: 7) == nil, "a session id is a file name, never a path")
        // the transcript is found by its session's name when its folder isn't named after the working folder,
        // and not at all when it's in two folders or in none
        try! fm.moveItem(at: named, to: write("", ".claude/projects/renamed/placeholder").deletingLastPathComponent().appending(path: "\(session).jsonl"))
        assert(read(idle(.claude)) == AgentContext(tokens: 84_000, window: nil))
        _ = write(transcript, ".claude/projects/elsewhere/\(session).jsonl")
        assert(read(idle(.claude)) == nil, "two transcripts with one name")
        try! fm.removeItem(at: home.appending(path: ".claude/projects"))
        assert(read(idle(.claude)) == nil)
        _ = record

        // Codex: the session file the process holds open that is the conversation itself, not a helper's thread
        let own = write(#"{"type":"session_meta","payload":{"id":"t1","cwd":"/Users/example/code/app","source":"cli"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50000},"model_context_window":258400}}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":67285554},"last_token_usage":{"input_tokens":72863,"total_tokens":73060},"model_context_window":258400}}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"task_complete","time_to_first_token_ms":7862}}"# + "\n",
            ".codex/sessions/2026/11/12/rollout-a.jsonl").path
        let helper = write(#"{"type":"session_meta","payload":{"id":"t2","parent_thread_id":"t1","source":{"subagent":{}}}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":999},"model_context_window":258400}}}"# + "\n",
            ".codex/sessions/2026/11/12/rollout-b.jsonl").path
        open = [home.appending(path: ".codex/logs.sqlite").path, helper, own]
        assert(read(idle(.codex)) == AgentContext(tokens: 73_060, window: 258_400))
        let second = write(#"{"type":"session_meta","payload":{"id":"t3","source":"cli"}}"# + "\n", ".codex/sessions/2026/11/12/rollout-c.jsonl").path
        open = [own, second]
        assert(read(idle(.codex)) == nil, "two conversations open in one process: which is the pane's can't be told")
        // an open session file whose first line can't be read (it doesn't end within the first megabyte) might be a
        // second conversation: nothing is shown, whatever the other file says
        let unreadable = write(String(repeating: "x", count: (1 << 20) + 64) + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":11000},"model_context_window":100000}}}"# + "\n",
            ".codex/sessions/2026/11/12/rollout-d.jsonl").path
        open = [own, unreadable]
        assert(read(idle(.codex)) == nil, "one file that can't be told apart")
        open = [unreadable]
        assert(read(idle(.codex)) == nil)
        let notMeta = write(#"{"type":"something_else","payload":{}}"# + "\n", ".codex/sessions/2026/11/12/rollout-e.jsonl").path
        open = [own, notMeta]
        assert(read(idle(.codex)) == nil, "nor when a first line isn't the session's own description")
        assert(AgentContext.codexIsOwnThread(nil) == nil && AgentContext.codexIsOwnThread(Data("{}".utf8)) == nil)
        open = [helper]
        assert(read(idle(.codex)) == nil)
        open = []
        assert(read(idle(.codex)) == nil)
        assert(AgentContext.codexContext(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8)) == nil)

        // Grok: signals.json beside the event log the process holds open
        let events = write("{}\n", ".grok/sessions/%2FUsers%2Fexample%2Fcode%2Fapp/s1/events.jsonl").path
        _ = write(#"{"turnCount":7,"contextWindowUsage":71,"contextTokensUsed":184187,"contextWindowTokens":256000}"#, ".grok/sessions/%2FUsers%2Fexample%2Fcode%2Fapp/s1/signals.json")
        open = [home.appending(path: ".grok/logs/unified.jsonl").path, events]
        assert(read(idle(.grok)) == AgentContext(tokens: 184_187, window: 256_000) && read(idle(.grok))?.text == "Context 71%")
        open = [events, write("{}\n", ".grok/sessions/other/s2/events.jsonl").path]
        assert(read(idle(.grok)) == nil, "two sessions open")
        open = [write("{}\n", ".grok/sessions/other/s3/events.jsonl").path]
        assert(read(idle(.grok)) == nil, "no signals file")
        // Antigravity: nothing known to read
        open = [own, events]
        assert(read(idle(.antigravity)) == nil)

        // reading the end of a long file starts at a whole line
        let long = write("first line\nsecond line\nthird line\n", "long.txt")
        assert(AgentContext.tail(long, 15).map { String(decoding: $0, as: UTF8.self) } == "third line\n")
        assert(AgentContext.tail(long, 1000).map { String(decoding: $0, as: UTF8.self) } == "first line\nsecond line\nthird line\n")
        assert(AgentContext.firstLine(long).map { String(decoding: $0, as: UTF8.self) } == "first line" && AgentContext.tail(home.appending(path: "none"), 10) == nil)

        // each idle agent is looked up once for its idle spell, found or not: a miss would otherwise cost megabytes of
        // transcript every half minute while the card is open
        func resting(_ id: String, since: Double? = 10, pid: Int32? = 4242, host: String = "") -> BreakAgent {
            BreakAgent(id: id, app: .claude, blocked: false, idle: true, host: host, since: since.map(at), pid: pid)
        }
        var reads = AgentContext.Reads()
        let all = [resting("a"), resting("b"), resting("far", host: "studio"), resting("no-pid", pid: nil), resting("no-time", since: nil)]
        let firstAsk = reads.wanted(among: all).map(\.id)
        assert(firstAsk == ["a", "b"], "only agents on this Mac with a process and a time: \(firstAsk)")
        reads.read(all[0])   // whether or not a number was found
        assert(reads.covers("a") && !reads.covers("b"))
        let secondAsk = reads.wanted(among: all).map(\.id)
        assert(secondAsk == ["b"], "a miss isn't read again while the agent stays idle: \(secondAsk)")
        reads.read(all[1])
        let thirdAsk = reads.wanted(among: all).map(\.id)
        assert(thirdAsk.isEmpty)
        // it ran and went idle again: a new spell, looked up again; the other one's stays
        let anew = reads.wanted(among: [resting("a", since: 30), resting("b")]).map(\.id)
        assert(anew == ["a"] && !reads.covers("a") && reads.covers("b"))
        // no longer idle: forgotten, and looked up afresh when it rests again
        let afterLeaving = reads.wanted(among: []).map(\.id)
        assert(afterLeaving.isEmpty && !reads.covers("b"))
        let back = reads.wanted(among: [resting("b")]).map(\.id)
        assert(back == ["b"])

        // what macOS says about a process: this check's own
        let me = getpid(), mine = fm.temporaryDirectory.appending(path: "pulse-open-\(UUID().uuidString).txt")
        try! Data("x".utf8).write(to: mine)
        defer { try? fm.removeItem(at: mine) }
        let handle = try! FileHandle(forReadingFrom: mine)
        defer { try? handle.close() }
        let launched = AgentContext.started(me)
        assert(launched != nil && launched! <= Date() && Date().timeIntervalSince(launched!) < 600, "\(String(describing: launched))")
        assert(AgentContext.openFiles(me).contains { $0.hasSuffix(mine.lastPathComponent) }, "the file this check holds open")
        assert(AgentContext.started(Int32.max) == nil && AgentContext.openFiles(Int32.max).isEmpty, "no such process")
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
