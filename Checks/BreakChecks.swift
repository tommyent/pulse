// Run from the project: swiftc Sources/Pulse/Breaks.swift Sources/Pulse/RexAgents.swift Checks/BreakChecks.swift -o /tmp/pulse-break-check && /tmp/pulse-break-check
import Foundation

@main
enum BreakChecks {
    static func main() {
        schedule()
        interests()
        prompt()
        colours()
        settingsDecoding()
        rex()
        print("Break checks passed: schedule, countdown, pause, snooze, idle reset, voice hold, interests, prompt, colours, settings and Rex parsing")
    }

    static func schedule() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        var on = BreakSettings(); on.enabled = true
        assert(on.microEvery == 20 * 60 && on.microLength == 20 && on.longEvery == 60 * 60 && on.longLength == 300)

        // a micro break at 20 minutes: 30 s countdown, then it starts by itself, then ends after 20 s
        var s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(19.9), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.tick(now: at(20.25), idle: 0, voiceActive: false) == nil)
        assert(s.remaining(at(20.25))!.left == 15 && s.remaining(at(20.25))!.total == 30)
        assert(s.tick(now: at(20.5), idle: 0, voiceActive: false) == .start(.micro))
        assert(s.remaining(at(20.5))!.total == 20)
        assert(s.tick(now: at(20.5 + 1.0 / 3), idle: 0, voiceActive: false) == .end && s.phase == .working)

        // the next micro break comes 20 minutes after that one ended; at 60 the long break takes its place
        assert(s.tick(now: at(40.8), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(40.84), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.startNow(at(40.85)) == .start(.micro))   // clicking the countdown
        assert(s.backToWork(at(41)) == .end)               // ended early, it still counts as taken
        assert(s.tick(now: at(60), idle: 0, voiceActive: false) == .countdown(.long))
        assert(s.tick(now: at(60.5), idle: 0, voiceActive: false) == .start(.long))

        // pause holds the time left; resume picks it up; Back to Work ends it as taken
        s.pause(at(61))
        assert(s.phase == .paused(.long, remaining: 270))
        assert(s.tick(now: at(90), idle: 0, voiceActive: false) == nil && s.phase.isPaused)
        s.resume(at(90))
        assert(s.remaining(at(90))!.left == 270)
        assert(s.tick(now: at(94.4), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(94.5), idle: 0, voiceActive: false) == .end)
        assert(s.due(at: at(114.4)) == nil && s.due(at: at(114.5)) == .micro)   // both clocks restarted

        // snooze: the same break comes back five minutes later, from the countdown or from the break
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.snooze(at(20.1)) == .end && s.phase == .working)
        assert(s.tick(now: at(25), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(25.1), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.tick(now: at(25.6), idle: 0, voiceActive: false) == .start(.micro))
        assert(s.snooze(at(25.7)) == .end)
        assert(s.tick(now: at(30.69), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(30.7), idle: 0, voiceActive: false) == .countdown(.micro))

        // time away: idle for a micro break's length restarts the micro clock, for a long break's both
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(15), idle: 20, voiceActive: false) == nil)
        assert(s.tick(now: at(34.9), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(35), idle: 0, voiceActive: false) == .countdown(.micro))
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(10), idle: 19, voiceActive: false) == nil)   // shorter than a break: no reset
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.micro))
        s = BreakSchedule(settings: on, now: t0)
        s.away(301, now: at(50))                                             // a sleep or a locked screen
        assert(s.tick(now: at(69.9), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(70), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.due(at: at(109.9)) != .long && s.due(at: at(110)) == .long)

        // a voice call holds a break back, cancels a running countdown, and lets it come once the call ends
        s = BreakSchedule(settings: on, now: t0)
        assert(s.tick(now: at(20), idle: 0, voiceActive: true) == nil && s.phase == .working)
        assert(s.tick(now: at(25), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(s.tick(now: at(25.1), idle: 0, voiceActive: true) == .end && s.phase == .working)
        assert(s.tick(now: at(26), idle: 0, voiceActive: false) == .countdown(.micro))

        // off: nothing comes, and turning it on starts the clock then
        var off = on; off.enabled = false
        s = BreakSchedule(settings: off, now: t0)
        assert(s.tick(now: at(500), idle: 0, voiceActive: false) == nil)
        s.settings = on
        assert(s.tick(now: at(519), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(520), idle: 0, voiceActive: false) == .countdown(.micro))
        s.settings = off
        assert(s.tick(now: at(520.1), idle: 0, voiceActive: false) == .end)   // turned off mid-countdown

        // without the long break only micro breaks come
        var microOnly = on; microOnly.longEnabled = false
        s = BreakSchedule(settings: microOnly, now: t0)
        for minute in stride(from: 1.0, through: 59, by: 1) { _ = s.tick(now: at(minute), idle: 60, voiceActive: false) }
        assert(s.tick(now: at(79), idle: 0, voiceActive: false) == .countdown(.micro))

        // the simulatedBreak hook
        s = BreakSchedule(settings: on, now: t0)
        assert(s.begin(.long, now: at(1)) == .countdown(.long))
        assert(s.begin(.long, now: at(1)) == nil)
        assert(BreakSchedule(settings: off, now: t0).due(at: at(30)) == .micro)   // due ignores the switch; tick doesn't
        var hookOff = BreakSchedule(settings: off, now: t0)
        assert(hookOff.begin(.micro, now: at(1)) == nil)

        assert(breakLengthLabel(300) == "5-min break" && breakLengthLabel(20) == "20-sec break")
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
