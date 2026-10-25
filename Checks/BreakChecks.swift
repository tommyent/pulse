// Run from the project: swiftc Sources/Pulse/Breaks.swift Sources/Pulse/RexAgents.swift Checks/BreakChecks.swift -o /tmp/pulse-break-check && /tmp/pulse-break-check
import Foundation

@main
enum BreakChecks {
    static func main() {
        schedule()
        restore()
        history()
        interests()
        prompt()
        colours()
        settingsDecoding()
        rex()
        print("Break checks passed: due-based schedule, countdown, pause, snooze, voice hold, both away modes, locks, restore, history, sounds, interests, prompt, colours, settings and Rex parsing")
    }

    static func schedule() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        var on = BreakSettings(); on.enabled = true
        assert(on.microEvery == 20 * 60 && on.microLength == 20 && on.longEvery == 60 * 60 && on.longLength == 300 && on.awayMode == .idle)
        func next(_ s: BreakSchedule, _ m: Double) -> (Date, Date?) { let u = s.upcoming(at(m)); return (u.micro, u.long) }

        // spacing from when each break was due: a micro at 20 and 40 however long they took, the long one at 60 in
        // place of that micro, and the slots after it on the same grid
        var s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(19.9), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.remaining(at(20.25))!.left == 15 && s.remaining(at(20.25))!.total == 30)
        assert(s.tick(now: at(20.5), idle: 0, voiceActive: false) == .start(.micro))
        assert(s.tick(now: at(20.5 + 1.0 / 3), idle: 0, voiceActive: false) == .end(.micro, .taken, due: at(20)))
        assert(next(s, 21) == (at(40), at(60)))
        assert(s.tick(now: at(39.99), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(40), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.startNow(at(40.1)) == .start(.micro))
        assert(s.backToWork(at(40.2)) == .end(.micro, .endedEarly, due: at(40)))
        assert(next(s, 41) == (at(60), at(60)))
        assert(s.tick(now: at(60), idle: 0, voiceActive: false) == .countdown(.long))
        assert(s.tick(now: at(60.5), idle: 0, voiceActive: false) == .start(.long))
        s.pause(at(61))
        assert(s.phase == .paused(.long, remaining: 270))
        assert(s.tick(now: at(90), idle: 0, voiceActive: false) == nil && s.phase.isPaused)
        s.resume(at(90))
        assert(s.tick(now: at(94.5), idle: 0, voiceActive: false) == .end(.long, .taken, due: at(60)))
        assert(next(s, 95) == (at(100), at(120)))   // slots that passed during it are skipped, not stacked

        // a long break due within two minutes takes the place of a due micro break
        var near = on; near.longEvery = 21 * 60
        s = BreakSchedule(settings: near, now: t0)
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.long))
        assert(s.tick(now: at(20.5), idle: 0, voiceActive: false) == .start(.long))
        assert(s.tick(now: at(25.5), idle: 0, voiceActive: false) == .end(.long, .taken, due: at(21)))
        assert(next(s, 26) == (at(40), at(42)))

        // snooze: the same break five minutes later, the next one still on the grid
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.snooze(at(20.1)) == .end(.micro, .snoozed, due: at(20)) && s.phase == .working)
        assert(next(s, 21).0 == at(25.1))
        assert(s.tick(now: at(25), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(25.1), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.tick(now: at(25.6), idle: 0, voiceActive: false) == .start(.micro))
        assert(s.tick(now: at(25.6 + 1.0 / 3), idle: 0, voiceActive: false) == .end(.micro, .taken, due: at(20)))
        assert(next(s, 26).0 == at(40))

        // a voice call holds a break back and cancels its countdown; it comes after the call and the grid holds
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(20), idle: 0, voiceActive: true) == nil && s.phase == .working)
        assert(s.tick(now: at(26), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.tick(now: at(26.1), idle: 0, voiceActive: true) == .end(.micro, nil, due: at(20)))
        assert(s.tick(now: at(45), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.tick(now: at(45.5), idle: 0, voiceActive: false) == .start(.micro))
        assert(s.tick(now: at(45.5 + 1.0 / 3), idle: 0, voiceActive: false) == .end(.micro, .taken, due: at(20)))
        assert(next(s, 46).0 == at(60))   // the slot at 40 passed during the hold: skipped, not stacked

        // idle mode: no input counts from 5 minutes, as a micro break and, as long as a long one, a long break too;
        // reported once, the clocks following the time while it lasts
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(10), idle: 299, voiceActive: false) == nil && next(s, 10) == (at(20), at(60)))
        assert(s.tick(now: at(12), idle: 300, voiceActive: false) == .away([.micro: at(20), .long: at(60)]))
        assert(next(s, 12) == (at(32), at(72)))
        assert(s.tick(now: at(12.5), idle: 330, voiceActive: false) == nil && next(s, 12.5) == (at(32.5), at(72.5)))
        assert(s.tick(now: at(13), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(32.5), idle: 0, voiceActive: false) == .countdown(.micro))
        var longer = on; longer.longLength = 600
        s = BreakSchedule(settings: longer, now: t0)
        assert(s.tick(now: at(10), idle: 300, voiceActive: false) == .away([.micro: at(20)]))
        assert(s.tick(now: at(15), idle: 600, voiceActive: false) == .away([.long: at(60)]))
        // a few seconds of reading never count
        s = BreakSchedule(settings: on, now: t0)
        for m in stride(from: 1.0, through: 19.9, by: 0.5) { assert(s.tick(now: at(m), idle: 200, voiceActive: false) == nil) }
        assert(s.tick(now: at(20), idle: 200, voiceActive: false) == .countdown(.micro))

        // fixed mode: no input never counts, so breaks come while someone watches without touching anything
        var fixed = on; fixed.awayMode = .fixed
        s = BreakSchedule(settings: fixed, now: t0)
        assert(s.tick(now: at(19), idle: 3000, voiceActive: false) == nil)
        assert(s.tick(now: at(20), idle: 3000, voiceActive: false) == .countdown(.micro))

        // locked or asleep (both modes): nothing comes while locked, a countdown or a break on screen is interrupted,
        // and the time counts once it's over, as a micro break from its length, as both from a long one's
        for mode in BreakAwayMode.allCases {
            var m = on; m.awayMode = mode
            s = BreakSchedule(settings: m, now: t0)
            assert(s.tick(now: at(20), idle: 0, locked: true, voiceActive: false) == nil)
            assert(s.tick(now: at(20.1), idle: 0, voiceActive: false) == .countdown(.micro))
            assert(s.tick(now: at(20.2), idle: 0, locked: true, voiceActive: false) == .end(.micro, nil, due: at(20)))
            assert(s.away(10, now: at(20.3)) == nil)                       // shorter than a micro break: still due
            assert(s.tick(now: at(20.3), idle: 0, voiceActive: false) == .countdown(.micro))
            assert(s.tick(now: at(20.8), idle: 0, voiceActive: false) == .start(.micro))
            assert(s.tick(now: at(20.9), idle: 0, locked: true, voiceActive: false) == .end(.micro, nil, due: at(20)))
            assert(s.away(400, now: at(27)) == .away([.micro: at(20), .long: at(60)]))
            assert(next(s, 27) == (at(47), at(87)))
        }

        // Escape skips: recorded apart, the grid holds; turning breaks off during one skips it too
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.tick(now: at(20.5), idle: 0, voiceActive: false) == .start(.micro))
        assert(s.skip(at(20.6)) == .end(.micro, .skipped, due: at(20)) && next(s, 21).0 == at(40))
        assert(s.tick(now: at(40), idle: 0, voiceActive: false) == .countdown(.micro))
        var off = on; off.enabled = false
        s.settings = off
        assert(s.tick(now: at(40.1), idle: 0, voiceActive: false) == .end(.micro, .skipped, due: at(40)))
        assert(s.tick(now: at(500), idle: 0, voiceActive: false) == nil)
        s.settings = on   // turning breaks on starts the clocks then
        assert(s.tick(now: at(519), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(520), idle: 0, voiceActive: false) == .countdown(.micro))

        // without the long break only micro breaks come
        var microOnly = on; microOnly.longEnabled = false
        s = BreakSchedule(settings: microOnly, now: t0)
        assert(s.upcoming(at(1)).long == nil)
        for m in [20.0, 40, 60, 80] {
            assert(s.tick(now: at(m), idle: 0, voiceActive: false) == .countdown(.micro))
            assert(s.startNow(at(m)) == .start(.micro) && s.backToWork(at(m + 0.1)) == .end(.micro, .endedEarly, due: at(m)))
        }

        // a shorter interval chosen in Settings applies at once
        s = BreakSchedule(settings: on, now: t0)
        var ten = on; ten.microEvery = 600
        s.settings = ten
        assert(s.tick(now: at(1), idle: 0, voiceActive: false) == nil && next(s, 1).0 == at(11))

        // the simulatedBreak hook leaves the clocks alone
        s = BreakSchedule(settings: on, now: t0)
        assert(s.begin(.long, now: at(1)) == .countdown(.long) && s.begin(.long, now: at(1)) == nil)
        assert(s.tick(now: at(1.5), idle: 0, voiceActive: false) == .start(.long))
        assert(s.tick(now: at(6.5), idle: 0, voiceActive: false) == .end(.long, .taken, due: at(1)))
        assert(next(s, 7) == (at(20), at(60)))
        var hookOff = BreakSchedule(settings: off, now: t0)
        assert(hookOff.begin(.micro, now: at(1)) == nil)

        assert(BreakSchedule.slot(after: at(20), every: 600, past: at(20)) == at(30))
        assert(BreakSchedule.slot(after: at(20), every: 600, past: at(45)) == at(50))
        assert(breakLengthLabel(300) == "5-min break" && breakLengthLabel(20) == "20-sec break")
        let now = at(100)
        assert(nextBreakText(micro: at(107), long: at(142), now: now) == "Next: micro in 7 min · long in 42 min")
        assert(nextBreakText(micro: at(100.5), long: nil, now: now) == "Next: micro in under a minute")
        assert(nextBreakText(micro: at(165), long: nil, now: now) == "Next: micro in 1 h 5 min")
        assert(nextBreakText(micro: at(110), long: at(160), now: now) == "Next: micro in 10 min · long in 1 h")
    }

    static func restore() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        var on = BreakSettings(); on.enabled = true
        let saved = BreakClocks(nextMicro: at(40), nextLong: at(60), savedAt: at(29))

        // a quick restart (an update, a crash) carries on where it was
        var s = BreakSchedule(settings: on, now: at(30))
        assert(s.restore(saved, now: at(30), quitFor: 60, downFor: 0) == nil)
        assert(s.upcoming(at(30)).micro == at(40) && s.upcoming(at(30)).long == at(60))
        assert(s.tick(now: at(39.9), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(40), idle: 0, voiceActive: false) == .countdown(.micro))
        // overdue after a short quit: one countdown at launch
        s = BreakSchedule(settings: on, now: at(41))
        assert(s.restore(saved, now: at(41), quitFor: 120, downFor: 0) == nil)
        assert(s.tick(now: at(41), idle: 0, voiceActive: false) == .countdown(.micro))
        // both overdue: only the long one comes; the micro moves to its next slot, so no burst
        s = BreakSchedule(settings: on, now: at(65))
        assert(s.restore(BreakClocks(nextMicro: at(40), nextLong: at(60), savedAt: at(64)), now: at(65), quitFor: 60, downFor: 0) == nil)
        assert(s.tick(now: at(65), idle: 0, voiceActive: false) == .countdown(.long))
        assert(s.upcoming(at(65)).micro == at(80))
        assert(s.tick(now: at(65.5), idle: 0, voiceActive: false) == .start(.long))
        assert(s.tick(now: at(70.5), idle: 0, voiceActive: false) == .end(.long, .taken, due: at(60)))
        assert(s.tick(now: at(70.6), idle: 0, voiceActive: false) == nil)
        // idle mode: Pulse quit for 5 minutes or more counts as time away, like no input
        s = BreakSchedule(settings: on, now: at(50))
        assert(s.restore(BreakClocks(nextMicro: at(40), nextLong: at(60), savedAt: at(35)), now: at(50), quitFor: 900, downFor: 0)
               == .away([.micro: at(40), .long: at(60)]))
        assert(s.upcoming(at(50)).micro == at(70) && s.upcoming(at(50)).long == at(110))
        // fixed mode: only the Mac being off or asleep counts; Pulse merely quit doesn't
        var fixed = on; fixed.awayMode = .fixed
        s = BreakSchedule(settings: fixed, now: at(50))
        assert(s.restore(BreakClocks(nextMicro: at(40), nextLong: at(60), savedAt: at(35)), now: at(50), quitFor: 900, downFor: 0) == nil)
        assert(s.tick(now: at(50), idle: 0, voiceActive: false) == .countdown(.micro))
        s = BreakSchedule(settings: fixed, now: at(50))
        assert(s.restore(BreakClocks(nextMicro: at(40), nextLong: at(60), savedAt: at(35)), now: at(50), quitFor: 900, downFor: 600)
               == .away([.micro: at(40), .long: at(60)]))
        // a saved time further off than one interval (a shorter interval since, a clock change) restarts from now
        s = BreakSchedule(settings: on, now: at(30))
        assert(s.restore(BreakClocks(nextMicro: at(500), nextLong: at(900), savedAt: at(29)), now: at(30), quitFor: 60, downFor: 0) == nil)
        assert(s.upcoming(at(30)).micro == at(50) && s.upcoming(at(30)).long == at(90))
        // breaks off: nothing restored
        var off = on; off.enabled = false
        s = BreakSchedule(settings: off, now: at(30))
        assert(s.restore(saved, now: at(30), quitFor: 60, downFor: 0) == nil)
        assert(try! JSONDecoder().decode(BreakClocks.self, from: JSONEncoder().encode(saved)) == saved)
    }

    static func history() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var h = BreakHistory()
        for (i, o) in BreakSchedule.Outcome.allCases.enumerated() {
            h.add(BreakRecord(kind: i.isMultiple(of: 2) ? .micro : .long, due: t, at: t.addingTimeInterval(Double(i)), outcome: o))
        }
        let back = BreakHistory(jsonLines: h.jsonLines + Data("{not json\n".utf8))   // a torn last line is skipped
        assert(back.records == h.records && back.records.count == 5)
        assert(BreakHistory.summary(h.counts(since: t)) == "1 taken · 1 ended early · 1 snoozed · 1 skipped · 1 away")
        assert(BreakHistory.summary(h.counts(since: t.addingTimeInterval(3))) == "1 skipped · 1 away")
        assert(BreakHistory.summary([:]) == "none")
        var aged = h
        aged.add(BreakRecord(kind: .micro, due: t, at: t.addingTimeInterval(-91 * 86400), outcome: .taken))
        assert(aged.prune(now: t) && aged.records == h.records)
        assert(!aged.prune(now: t))
        assert(aged.prune(now: t.addingTimeInterval(BreakHistory.keep + 10)) && aged.records.isEmpty)
    }

    static func interests() {
        var list: [String] = []
        list = BreakInterests.adding("  tea ", to: list)
        list = BreakInterests.adding("Tea", to: list)
        list = BreakInterests.adding("bird   watching", to: list)
        list = BreakInterests.adding("   ", to: list)
        list = BreakInterests.adding(String(repeating: "x", count: 31), to: list)
        assert(list == ["tea", "bird watching"], "\(list)")
        for i in 0..<30 { list = BreakInterests.adding("word\(i)", to: list) }
        assert(list.count == BreakInterests.maxCount)
    }

    static func prompt() {
        let p = BreakIdeaPrompt.prompt(length: 300, level: 4, focus: "guitar", angle: "something to play", avoid: ["Water the plants."])
        assert(p.contains("5 minutes") && p.contains("\"guitar\"") && p.contains("adventurous") && p.contains("something to play"))
        assert(p.contains("Water the plants.") && !p.contains("very short") && !p.contains("odd"))
        let micro = BreakIdeaPrompt.prompt(length: 20, level: 0, focus: "tea", angle: "something for the body")
        assert(micro.contains("20 seconds") && micro.contains("very short") && micro.contains("easy") && micro.contains("\"tea\""))
        let odd = BreakIdeaPrompt.prompt(length: 300, level: 2, focus: nil, angle: "something to make or draw")
        assert(odd.contains("odd") && odd.contains("frog") && !odd.contains("Level:") && !odd.contains("interest \""))
        assert(BreakIdeaPrompt.duration(60) == "1 minute" && BreakIdeaPrompt.duration(120) == "2 minutes")
        assert(BreakIdeaPrompt.instructions.contains("travel") && BreakIdeaPrompt.instructions.contains("money"))
        for level in 0...4 { assert(BreakIdeaPrompt.prompt(length: 60, level: level, focus: "x", angle: "a").contains(BreakIdeaPrompt.levelWords[level])) }
        assert(BreakIdeaPrompt.angles(level: 0) == BreakIdeaPrompt.angles(level: 1) && BreakIdeaPrompt.angles(level: 3) == BreakIdeaPrompt.angles(level: 4))
        assert(Set(BreakIdeaPrompt.angles(level: 0)).isDisjoint(with: BreakIdeaPrompt.angles(level: 4)))

        // the interest: a different one from the last whenever there's a choice, the only one when there isn't
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 { assert(BreakIdeaPrompt.focus(from: ["tea", "guitar", "plants"], after: "tea", using: &rng) != "tea") }
        assert(BreakIdeaPrompt.focus(from: ["tea"], after: "tea", using: &rng) == "tea")
        assert(BreakIdeaPrompt.focus(from: [], after: nil, using: &rng) == nil)

        assert(BreakIdeaPrompt.interestsUsed("Repot a plant into a mug", from: ["plants", "tea", "guitar"]) == ["plants"])
        assert(BreakIdeaPrompt.interestsUsed("Brew some tea and play guitar", from: ["tea", "guitar"]) == ["tea", "guitar"])
        assert(BreakIdeaPrompt.interestsUsed("Stretch your calves", from: ["stretching"]) == ["stretching"])
        assert(BreakIdeaPrompt.interestsUsed("Go bird watching at the window", from: ["bird watching"]) == ["bird watching"])
        assert(BreakIdeaPrompt.interestsUsed("Stretch your arms", from: ["tea"]).isEmpty)
        assert(BreakIdeaPrompt.interestsUsed("Teach the cat a trick", from: ["tea"]).isEmpty)   // whole words, not any substring
    }

    static func colours() {
        assert(BreakColor.rgb(hex: "#3FB8AF") == 0x3FB8AF && BreakColor.rgb(hex: "3fb8af") == 0x3FB8AF)
        assert(BreakColor.rgb(hex: "#3FB8A") == nil && BreakColor.rgb(hex: "#3FB8AG") == nil && BreakColor.rgb(hex: "") == nil)
        assert(BreakColor.hex(0x3FB8AF) == "#3FB8AF")
        assert(BreakColor.pair("amber").glow == 0xC27532 && BreakColor.pair("ocean").bar == 0x62A8FF)
        assert(BreakColor.pair("#000000") == (0x000000, 0x595959))
        assert(BreakColor.pair("nonsense").glow == BreakColor.presets[0].glow)
        assert(BreakColor.mix(0xFFFFFF, white: 0.5) == 0xFFFFFF && BreakColor.mix(0x000000, white: 1) == 0xFFFFFF)
    }

    static func settingsDecoding() {
        let empty = try! JSONDecoder().decode(BreakSettings.self, from: Data("{}".utf8))
        assert(empty == BreakSettings())
        let partial = try! JSONDecoder().decode(BreakSettings.self, from: Data(#"{"enabled":true,"level":9,"interests":["tea"],"later":1}"#.utf8))
        assert(partial.enabled && partial.level == 4 && partial.interests == ["tea"] && partial.microEvery == 1200)
        var s = BreakSettings(); s.color = "#3FB8AF"; s.level = 3; s.longEnabled = false
        assert(try! JSONDecoder().decode(BreakSettings.self, from: JSONEncoder().encode(s)) == s)

        // sounds: one as a break starts, another when it runs its full length; none for Snooze, Escape, Back to Work
        // or an interruption; None is "" and survives a save
        let d = BreakSettings(), t = Date(timeIntervalSinceReferenceDate: 0)
        assert(d.startSound == "Blow" && d.endSound == "Glass" && empty.startSound == "Blow" && partial.endSound == "Glass")
        assert(d.sound(for: .start(.micro)) == "Blow" && d.sound(for: .start(.long)) == "Blow")
        assert(d.sound(for: .end(.long, .taken, due: t)) == "Glass")
        for o in [BreakSchedule.Outcome.endedEarly, .snoozed, .skipped, .away] { assert(d.sound(for: .end(.micro, o, due: t)) == nil) }
        assert(d.sound(for: .end(.micro, nil, due: t)) == nil && d.sound(for: .countdown(.micro)) == nil && d.sound(for: .away([.micro: t])) == nil)
        var quiet = d; quiet.startSound = ""; quiet.endSound = ""
        assert(quiet.sound(for: .start(.micro)) == nil && quiet.sound(for: .end(.micro, .taken, due: t)) == nil)
        assert(try! JSONDecoder().decode(BreakSettings.self, from: JSONEncoder().encode(quiet)) == quiet)
        var fixed = d; fixed.awayMode = .fixed
        assert(try! JSONDecoder().decode(BreakSettings.self, from: JSONEncoder().encode(fixed)).awayMode == .fixed)
        assert((try! JSONDecoder().decode(BreakSettings.self, from: Data(#"{"awayMode":"someday"}"#.utf8))).awayMode == .idle)
    }

    static func rex() {
        func json(_ s: String) -> Data { Data(s.utf8) }
        let status = json(#"{"records":[{"app":"claude-code","state":"working","msg":"Reading","updated_at":"x"},{"id":"build","state":"blocked","updated_at":"x"}]}"#)
        assert(RexAgents.agent(fromStatus: status, block: "b1") == BreakAgent(id: "b1", app: .claude, blocked: false, msg: "Reading"))
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"codex","state":"blocked","kind":"permission","updated_at":"x"}]}"#), block: "b2")?.blocked == true)
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"claude-code","state":"done","updated_at":"x"}]}"#), block: "b") == nil)
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"cargo","state":"working","updated_at":"x"}]}"#), block: "b") == nil)
        assert(RexAgents.agent(fromStatus: json(#"{"records":[]}"#), block: "b") == nil)
        assert(RexAgents.agent(fromStatus: json("not json"), block: "b") == nil)

        func event(_ name: String, _ payload: String) -> Data {
            json(#"{"type":"session_event","payload":{"session_id":"s","event":{"type":"block_event","payload":{"block_id":"b9","creator_name":"com.superlogical.terminal","name":"\#(name)","payload":\#(payload)}}}}"#)
        }
        let working = RexAgents.update(fromEvent: event("program_status_changed", #"{"id":"","record":{"state":"working","app":"antigravity","msg":"m"},"reason":"report"}"#))
        assert(working?.0 == "b9" && working?.1?.app == .antigravity && working?.1?.blocked == false)
        let idle = RexAgents.update(fromEvent: event("program_status_changed", #"{"id":"","record":{"state":"idle","app":"codex"},"reason":"report"}"#))
        assert(idle?.0 == "b9" && idle?.1 == nil)
        assert(RexAgents.update(fromEvent: event("program_status_changed", #"{"id":"child","record":{"state":"working","app":"codex"}}"#)) == nil)
        let removed = RexAgents.update(fromEvent: event("program_status_removed", #"{"ids":[""],"reason":"exit"}"#))
        assert(removed?.0 == "b9" && removed?.1 == nil)
        assert(RexAgents.update(fromEvent: event("title_changed", #"{"title":"x"}"#)) == nil)
        assert(RexAgents.update(fromEvent: json(#"{"type":"client_connected","payload":{}}"#)) == nil)

        let fake = RexAgents.simulated("claude-code working, claude-code blocked,codex, grok idle, nope working")
        assert(fake.map(\.app) == [.claude, .claude, .codex] && fake.map(\.blocked) == [false, true, false])
        assert(fake[0].label == "claude-code 1" && Set(fake.map(\.id)).count == 3)
        // with no Rex in a folder Pulse looks in, there's nothing to read
        assert(RexAgents.executable(home: URL(fileURLWithPath: "/nonexistent")) == nil
               || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rex")
               || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rex"))
    }
}
