// Run from the project: swiftc Sources/Pulse/Breaks.swift Sources/Pulse/BreakTricks.swift Sources/Pulse/RexAgents.swift Checks/BreakChecks.swift -o /tmp/pulse-break-check && /tmp/pulse-break-check
import Foundation

@main
enum BreakChecks {
    static func main() async {
        schedule()
        restore()
        history()
        ideas()
        holidays()
        tricks()
        colours()
        settingsDecoding()
        rex()
        print("Break checks passed: due-based schedule, countdown, pause, snooze, voice hold, both away modes, locks, restore, history, sounds, ideas, holidays, tricks, sleepers, flights, ladders, colours, settings and Rex parsing")
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

        // Pause from the hover hint: nothing comes until it ends, time away leaves it, then the break due comes;
        // turning breaks off ends it
        s = BreakSchedule(settings: on, now: t0)
        s.pausedUntil = at(90)
        assert(next(s, 1) == (at(90), at(90)))
        assert(s.tick(now: at(20), idle: 0, voiceActive: false) == nil && s.tick(now: at(89.9), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(89.95), idle: 600, voiceActive: false) == .away([.micro: at(20), .long: at(60)]) && s.pausedUntil == at(90))
        assert(s.tick(now: at(90), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(109.9), idle: 0, voiceActive: false) == nil)
        assert(s.tick(now: at(110), idle: 0, voiceActive: false) == .countdown(.micro))
        s.pausedUntil = at(200)
        s.settings.enabled = false
        _ = s.tick(now: at(111), idle: 0, voiceActive: false)
        assert(s.pausedUntil == nil)

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
        var dismissed = BreakSchedule(settings: on, now: t0)   // the countdown's × skips before the break starts
        assert(dismissed.tick(now: at(20), idle: 0, voiceActive: false) == .countdown(.micro))
        assert(dismissed.skip(at(20.2)) == .end(.micro, .skipped, due: at(20)) && next(dismissed, 21).0 == at(40))
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
        assert(nextBreakText(micro: at(107), long: at(142), now: now) == "Next: micro in 7 min")
        assert(nextBreakText(micro: at(100.5), long: nil, now: now) == "Next: micro in under a minute")
        assert(nextBreakText(micro: at(165), long: nil, now: now) == "Next: micro in 1 h 5 min")
        // the long break takes the micro's place when they fall together, and goes first when it's sooner
        assert(nextBreakText(micro: at(107), long: at(107), now: now) == "Next: long in 7 min")
        assert(nextBreakText(micro: at(107), long: at(108.5), now: now) == "Next: long in 7 min")
        assert(nextBreakText(micro: at(120), long: at(105), now: now) == "Next: long in 5 min")
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

        // a pause outlives a restart until it ends; clocks saved before Pause existed still load
        s = BreakSchedule(settings: on, now: at(30))
        _ = s.restore(BreakClocks(nextMicro: at(40), nextLong: at(60), pausedUntil: at(90), savedAt: at(29)), now: at(30), quitFor: 60, downFor: 0)
        assert(s.pausedUntil == at(90) && s.upcoming(at(30)).micro == at(90))
        _ = s.restore(BreakClocks(nextMicro: at(40), nextLong: at(60), pausedUntil: at(20), savedAt: at(29)), now: at(30), quitFor: 60, downFor: 0)
        assert(s.pausedUntil == nil)
        assert(try! JSONDecoder().decode(BreakClocks.self, from: Data(#"{"nextMicro":0,"nextLong":60,"savedAt":0}"#.utf8)).pausedUntil == nil)
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

    static func ideas() {
        // the bundled list: all three levels, every idea named and filled in, no name twice
        let list = BreakIdeaList.parse(try! Data(contentsOf: URL(fileURLWithPath: "Sources/Pulse/Resources/break-ideas.json")))
        assert(list.count > 300 && Set(list.map(\.level)) == [0, 1, 2], "\(list.count)")
        assert(list.allSatisfy { !$0.name.isEmpty && !$0.text.isEmpty })
        assert(Set(list.map { $0.name.lowercased() }).count == list.count)
        assert(BreakIdeaList.parse(Data("nope".utf8)).isEmpty)
        let timed = list.filter { $0.text.contains("{seconds}") }
        assert(timed.count > 30, "the 30-second catalog suggestions must fit shorter micro breaks")
        for length in [10.0, 20.0, 300.0] {
            for idea in timed {
                let fitted = idea.fitting(length)
                assert(!fitted.name.contains("{seconds}") && !fitted.text.contains("{seconds}"))
                let seconds = Int(min(30, length))
                assert(fitted.text.contains("\(seconds) seconds") || fitted.text.contains("\(seconds)-second"), "\(fitted.text)")
            }
        }
        let custom = BreakIdea(text: "An idea with no timed instruction")
        assert(custom.fitting(20) == custom)

        let own = BreakIdeaList.own("  Water the fern \n\n\tHum a tune\n   \n")
        assert(own == [BreakIdea(text: "Water the fern"), BreakIdea(text: "Hum a tune")] && BreakIdeaList.own("").isEmpty)

        var rng = SystemRandomNumberGenerator()
        func pick(_ from: [BreakIdea], _ level: Int?, own: [BreakIdea] = [], recent: [String] = []) -> BreakIdea? {
            BreakIdeaList.pick(from: from, level: level, own: own, recent: recent, using: &rng)
        }
        // the level set in Settings; any level for Surprise me
        for _ in 0..<200 { assert(pick(list, 2)!.level == 2) }
        assert(Set((0..<300).map { _ in pick(list, nil)!.level }) == [0, 1, 2])
        // the person's own about one break in three, and only theirs when there's no list
        let mine = (0..<3000).filter { _ in pick(list, 0, own: own)!.name.isEmpty }.count
        assert((850...1150).contains(mine), "\(mine)")
        assert(pick([], 0, own: own)!.name.isEmpty && pick([], 0) == nil)
        // ideas shown lately wait until the rest have come up; then the one shown longest ago comes first
        let abc = ["A", "B", "C"].map { BreakIdea(name: $0.lowercased(), text: $0) }
        for _ in 0..<50 { assert(pick(abc, 0, recent: ["A", "C"])?.text == "B") }
        assert(pick(abc, 0, recent: ["B", "A", "C"])?.text == "B")

        var recent: [String] = []
        for i in 0..<105 { recent = BreakIdeaList.remember("idea \(i)", in: recent) }
        assert(recent.count == BreakIdeaList.keep && recent.first == "idea 5" && recent.last == "idea 104")
        recent = BreakIdeaList.remember("idea 10", in: recent)   // shown again: moves to the newest end, once
        assert(recent.count == BreakIdeaList.keep && recent.last == "idea 10" && recent.filter { $0 == "idea 10" }.count == 1)
        assert(spokenDuration(20) == "20 seconds" && spokenDuration(60) == "1 minute" && spokenDuration(120) == "2 minutes")
    }

    static func holidays() {
        let cal = Calendar(identifier: .gregorian)
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))! }
        assert(BreakHoliday.on(day(2026, 10, 31), calendar: cal)?.name == "halloween")
        assert(BreakHoliday.on(day(2026, 10, 30), calendar: cal) == nil && BreakHoliday.on(day(2026, 11, 1), calendar: cal) == nil)
        assert(BreakHoliday.on(day(2026, 11, 26), calendar: cal)?.name == "thanksgiving")   // fourth Thursday
        assert(BreakHoliday.on(day(2025, 11, 27), calendar: cal)?.name == "thanksgiving")
        assert(BreakHoliday.on(day(2026, 11, 19), calendar: cal) == nil && BreakHoliday.on(day(2026, 11, 27), calendar: cal) == nil)
        assert(BreakHoliday.on(day(2026, 3, 3), calendar: cal, simulated: "halloween")?.name == "halloween")
        assert(BreakHoliday.on(day(2026, 10, 31), calendar: cal, simulated: "nope") == nil)
        assert(BreakHoliday.start(duration: 25.8, left: 20) == 25.8 - 20 && BreakHoliday.start(duration: 25.8, left: 300) == 0)
        assert(BreakHoliday.start(duration: 25.8, left: 14.5) == 25.8 - 14.5)   // the video loaded late: still the ending
        assert(Set(BreakHoliday.all.map(\.name)).count == BreakHoliday.all.count)
        let off = try! JSONDecoder().decode(BreakSettings.self, from: Data(#"{"holidays":false}"#.utf8))
        assert(!off.holidays && BreakSettings().holidays)
    }

    static func tricks() {
        let W = 1440.0, floor = 882.0
        func actor(_ kind: TrickActor.Kind, home: Double, still: Bool = false) -> TrickActor {
            TrickActor(kind: kind, home: home, span: -86, width: 100, height: 108, footMargin: 10.0 / 208, still: still)
        }
        func jumping(_ p: TrickPose) -> Bool { if case .jump = p.move { true } else { false } }
        // never the same trick twice in a row, across rounds too, and every trick and flourish comes up
        for kind in [TrickActor.Kind.pet, .crab, .codex] {
            for seed in UInt64(0)..<20 {
                let a = actor(kind, home: 700)
                for list in [a.tricks, a.flourishes] {
                    let picks = (0..<200).map { BreakTricks.pick(list, index: Int(seed % 3), cycle: $0, seed: seed)! }
                    assert(zip(picks, picks.dropFirst()).allSatisfy { $0 != $1 }, "\(kind) \(seed)")
                    assert(Set(picks.prefix(list.count).map { "\($0)" }).count == list.count)
                }
            }
        }
        let button = CGRect(x: 640, y: 700, width: 160, height: 52), row = CGRect(x: 600, y: 520, width: 240, height: 60)
        let perches = [BreakPerch(kind: .button, rect: button), BreakPerch(kind: .ideaRow, rect: row)]
        // a still actor stays home on the floor, and the poses are a pure function of their inputs
        let still = actor(.crab, home: 300, still: true)
        assert(BreakTricks.poses([still], t: 50, floor: floor, width: W, perches: perches, seed: 1)
               == [TrickPose(x: 300, feet: floor - 10.0 / 208 * 108)])
        let pet = actor(.pet, home: 760)
        assert(BreakTricks.poses([pet], t: 33.3, floor: floor, width: W, perches: perches, seed: 7)
               == BreakTricks.poses([pet], t: 33.3, floor: floor, width: W, perches: perches, seed: 7))
        /// The first cycle an actor alone near the button spends on `trick`.
        func first(_ trick: BreakTrick, _ a: TrickActor, perches: [BreakPerch] = perches, seed: UInt64 = 7) -> Int {
            let turn = BreakTricks.turns([a], perches: perches, reach: 0.28 * W)[0]
            return (0..<100).first { BreakTricks.trick(a, index: 0, cycle: $0, seed: seed, turn: turn, row: true) == trick }!
        }
        // alone at its button it's up there every other cycle: a jump, a ladder, a climb, turn by turn
        assert((0..<6).map { BreakTricks.trick(pet, index: 0, cycle: $0, seed: 7, turn: BreakTricks.Turn(button: button, place: 0, count: 1), row: true) }
               .enumerated().allSatisfy { c, trick in c % 2 == 1 ? !(trick?.usesPerch ?? false) : trick == [.perch, .ladder, .climb][c / 2] })
        // the pet's perch cycle: on the button, feet on its top edge and its artwork's bottom just below it
        let perchCycle = first(.perch, pet)
        let run = abs(BreakTricks.landing(760, on: button, width: 100) - 760) / (0.08 * W)
        let onTop = BreakTricks.poses([pet], t: Double(perchCycle) * 12 + run + 0.6 + 1, floor: floor, width: W, perches: perches, seed: 7)[0]
        assert(onTop.feet == 700 && onTop.overControl && onTop.x >= 690 && onTop.x <= 750, "\(onTop)")
        assert(BreakTricks.spriteRect(pet, onTop).maxY == 700 + 10.0 / 208 * 108)
        // the climb ends up on the idea row; without one that turn is a ladder up the button
        let climbCycle = first(.climb, pet)
        let side = abs(Double(row.maxX) + 54 - BreakTricks.landing(760, on: button, width: 100)) / (0.08 * W)
        let high = BreakTricks.poses([pet], t: Double(climbCycle) * 12 + run + 0.6 + 0.6 + side + 0.6 + 0.35 + 0.5, floor: floor, width: W, perches: perches, seed: 7)[0]
        assert(high.feet == 520 && high.move == .wave, "\(high)")
        let noRow = BreakTricks.poses([pet], t: Double(climbCycle) * 12 + run + 0.6 + 1, floor: floor, width: W,
                                      perches: [perches[0]], seed: 7)[0]
        assert(noRow.move == .ladder && noRow.ladder != nil, "\(noRow)")
        // out of reach: a stroll instead, never over a control
        let far = actor(.pet, home: 100)
        for t in stride(from: 0.0, to: 600, by: 0.25) {
            assert(!BreakTricks.poses([far], t: t, floor: floor, width: W, perches: perches, seed: 7)[0].overControl)
        }
        // actors near one button take turns, the nearer first: never two up there at once, and each gets its go
        let line = BreakTricks.turns([actor(.crab, home: 690), actor(.crab, home: 740), actor(.crab, home: 720, still: true)],
                                     perches: perches, reach: 0.28 * W)
        assert(line == [1: BreakTricks.Turn(button: button, place: 0, count: 2), 0: BreakTricks.Turn(button: button, place: 1, count: 2)])
        var crowd = (0..<5).map { i in actor(.crab, home: 560 + Double(i) * 70) }
        for i in crowd.indices { crowd[i].phase = Double(i) * 3.1 }
        var wentUp = Set<Int>()
        for t in stride(from: 0.0, to: 400, by: 0.1) {
            let up = BreakTricks.poses(crowd, t: t, floor: floor, width: W, perches: [perches[0]], seed: 3).enumerated()
                .filter { _, p in p.feet == 700 && abs(p.x - Double(button.midX)) < 80 }.map(\.offset)   // standing on its top
            assert(up.count <= 1, "\(t): \(up) on the button at once")
            wentUp.formUnion(up)
        }
        assert(wentUp == Set(crowd.indices), "\(wentUp)")
        // a button too close under the idea for the sprite to stand on is nobody's
        let cramped = [BreakPerch(kind: .button, rect: button), BreakPerch(kind: .ideaRow, rect: CGRect(x: 600, y: 610, width: 240, height: 24))]
        assert(BreakTricks.turns([actor(.crab, home: 720)], perches: cramped, reach: 0.28 * W).isEmpty)
        assert(BreakTricks.turns([actor(.crab, home: 720)], perches: [cramped[0]], reach: 0.28 * W).count == 1)
        // words over part of a button: it stands only on the clear stretch, and strolls only along it
        let reroll = CGRect(x: 600, y: 640, width: 60, height: 20)
        assert(BreakTricks.footing(on: button, for: pet, clear: [reroll], near: 700) == 710...750)
        assert(BreakTricks.footing(on: button, for: pet, clear: [], near: 700) == 690...750)
        assert(BreakTricks.footing(on: button, for: pet, clear: [CGRect(x: 600, y: 200, width: 400, height: 20)], near: 700) == 690...750)   // far above
        for k in stride(from: 0.0, to: 12, by: 0.05) {
            let p = BreakTricks.perchPose(pet, k: k, ground: floor, speed: 0.08 * W, button: button, row: nil, footing: 710...750)
            if p.feet == 700 { assert(p.x >= 710 && p.x <= 750 && !BreakTricks.spriteRect(pet, p).intersects(reroll), "\(k) \(p)") }
        }
        let split = [BreakPerch(kind: .button, rect: button), BreakPerch(kind: .text, rect: reroll)]
        assert(BreakTricks.poses([pet], t: Double(perchCycle) * 12 + 1.5, floor: floor, width: W, perches: split, seed: 7)[0].overControl)
        // each walker lines up at its nearest button
        let pause = CGRect(x: 820, y: 700, width: 120, height: 52)
        let pair = BreakTricks.turns([actor(.crab, home: 700), actor(.pet, home: 1100)],
                                     perches: [BreakPerch(kind: .button, rect: button), BreakPerch(kind: .button, rect: pause)], reach: 0.28 * W)
        assert(pair == [0: BreakTricks.Turn(button: button, place: 0, count: 1), 1: BreakTricks.Turn(button: pause, place: 0, count: 1)], "\(pair)")
        // jumps start and end where they should and clear the top edge going up
        assert(BreakTricks.arc(882, 700, 0, apex: 80) == 882 && BreakTricks.arc(882, 700, 1, apex: 80) == 700)
        let apex = (882.0 - 700) / 4 + 0.08 * 108
        let lowest = stride(from: 0.0, through: 1, by: 0.01).map { BreakTricks.arc(882, 700, $0, apex: apex) }.min()!
        assert(lowest < 700 && lowest > 700 - 4, "\(lowest)")   // clears the top, by a few points only
        // from landing on the button, onward, it never pokes higher than standing on it
        for k in stride(from: 0.0, to: run + 0.6, by: 0.01) {
            let p = BreakTricks.perchPose(pet, k: k, ground: floor, speed: 0.08 * W, button: button, row: nil)
            assert(p.feet > 700 - 4, "\(k) \(p)")
        }
        assert(BreakTricks.landing(500, on: button, width: 100) == 690 && BreakTricks.landing(900, on: button, width: 100) == 750)
        assert(BreakTricks.landing(500, on: CGRect(x: 0, y: 0, width: 60, height: 10), width: 100) == 30)
        // the climb comes in and goes out beside the sentence: never more than its feet inside it
        for k in stride(from: run + 0.6, to: 12, by: 0.02) {   // from landing on the button
            let p = BreakTricks.perchPose(pet, k: k, ground: floor - 10.0 / 208 * 108, speed: 0.08 * W, button: button, row: row)
            let overlap = BreakTricks.spriteRect(pet, p).intersection(row)
            assert(overlap.isNull || overlap.height <= 10.0 / 208 * 108 + 0.01, "k \(k): \(overlap)")
        }
        // a still actor over a button still lets clicks through
        let parked = actor(.pet, home: 720, still: true)
        assert(BreakTricks.poses([parked], t: 9, floor: 760, width: W, perches: perches, seed: 1)[0].overControl)
        // every pose stays on screen, on both sides, at any moment
        for home in [40.0, 1400] {
            for kind in [TrickActor.Kind.pet, .crab, .codex] {
                var a = actor(kind, home: home); a.span = home < 700 ? -86 : 86
                for t in stride(from: 0.0, to: 240, by: 0.1) {
                    let x = BreakTricks.poses([a], t: t, floor: floor, width: W, perches: perches, seed: 3)[0].x
                    assert(x >= 50 && x <= W - 50, "\(kind) \(home) \(t): \(x)")
                }
            }
        }
        // a peek sinks out of sight and comes back up
        let crab = actor(.crab, home: 300)
        let peekCycle = (0..<100).first { BreakTricks.pick(crab.tricks, index: 0, cycle: $0, seed: 5) == .peek }!
        let at = { (j: Double) in BreakTricks.poses([crab], t: Double(peekCycle) * 12 + 3 + j, floor: floor, width: W, perches: [], seed: 5)[0] }
        assert(at(1.0).sunk > 100 && at(1.0).feet > at(0).feet && at(1.9).sunk == 0 && at(0).sunk == 0)
        // a leapfrog goes over a neighbour standing still, and is a plain stroll without one
        let nextDoor = actor(.crab, home: 300 - 86 + 190, still: true)
        let frogCycle = (0..<100).first { BreakTricks.pick(crab.tricks, index: 0, cycle: $0, seed: 5) == .leapfrog }!
        let mid = BreakTricks.poses([crab, nextDoor], t: Double(frogCycle) * 12 + 3 + 0.45, floor: floor, width: W, perches: [], seed: 5)[0]
        let over = BreakTricks.poses([crab, nextDoor], t: Double(frogCycle) * 12 + 3 + 0.95, floor: floor, width: W, perches: [], seed: 5)[0]
        assert(jumping(mid) && mid.feet < floor - 108 && over.x > nextDoor.home, "\(mid) \(over)")
        let alone = BreakTricks.poses([crab], t: Double(frogCycle) * 12 + 3 + 0.95, floor: floor, width: W, perches: [], seed: 5)[0]
        assert(alone.move == .stand && alone.x == 300 - 86)
        // a narrow screen with no room beside the idea, or words on the way there: a plain perch, never through the words
        let narrowRow = CGRect(x: 54, y: 520, width: 532, height: 30), narrowButton = CGRect(x: 420, y: 700, width: 160, height: 52)
        let narrow = actor(.pet, home: 560)
        for k in stride(from: 0.0, to: 12, by: 0.02) {
            let p = BreakTricks.perchPose(narrow, k: k, ground: floor, speed: 0.08 * 640, button: narrowButton, row: narrowRow,
                                          clear: [narrowRow], screen: 640)
            assert(p.feet != 520, "climbed with no room beside the idea: \(k)")
        }
        let words = CGRect(x: 820, y: 640, width: 80, height: 20)
        let blocked = BreakTricks.perchPose(pet, k: 5, ground: floor, speed: 0.08 * W, button: button, row: row, clear: [words], screen: W)
        assert(blocked == BreakTricks.perchPose(pet, k: 5, ground: floor, speed: 0.08 * W, button: button, row: nil))
        // a flip at the screen's edge keeps its turned box on screen
        var edge = actor(.crab, home: 1400); edge.span = 30
        for t in stride(from: 0.0, to: 600, by: 0.05) {
            let a = edge, p = BreakTricks.poses([a], t: t, floor: floor, width: W, perches: [], seed: 9)[0]
            let half = (a.width * abs(cos(p.turn)) + a.height * abs(sin(p.turn))) / 2
            assert(p.x + half <= W + 0.001 && p.x - half >= -0.001, "\(t) \(p)")
        }
        // the whole perch fits in its cycle at the farthest reach
        let farthest = actor(.pet, home: Double(button.midX) + 0.28 * W)
        let back = BreakTricks.perchPose(farthest, k: 11.99, ground: floor, speed: 0.08 * W, button: button, row: row)
        assert(back.x == farthest.home && back.feet == floor, "\(back)")
        // an idea far off to the side: the climb wouldn't fit its cycle, so it's a plain perch, home on time
        let wide = CGRect(x: 0, y: 520, width: 100, height: 60)
        let short = BreakTricks.perchPose(farthest, k: 11.99, ground: floor, speed: 0.08 * W, button: button, row: wide)
        assert(short.x == farthest.home && short.feet == floor)
        let noClimb = BreakTricks.perchPose(farthest, k: 6, ground: floor, speed: 0.08 * W, button: button, row: wide)
        assert(noClimb == BreakTricks.perchPose(farthest, k: 6, ground: floor, speed: 0.08 * W, button: button, row: nil))
        sleepers(W: W, floor: floor, actor: actor)
        flights(W: W, floor: floor, button: button, actor: actor)
        // a bounce hops out and back, giving only at the floor, then bounces on the spot, the first time highest
        let ground = floor - 10.0 / 208 * 108, bouncer = actor(.crab, home: 300)
        let hops = stride(from: 0.0, to: 3, by: 0.01).map { BreakTricks.strollPose(bouncer, k: $0, ground: ground, trick: .bounce) }
        assert(hops.allSatisfy { $0.squash == 0 || $0.feet > ground - 0.25 * 108 } && abs(hops.map(\.feet).min()! - (ground - 0.5 * 108)) < 1)
        let spot = stride(from: 3.0, to: 5, by: 0.01).map { BreakTricks.strollPose(bouncer, k: $0, ground: ground, trick: .bounce) }
        assert(spot.allSatisfy { $0.x == 300 - 86 } && spot.map(\.feet).min()! < ground - 0.85 * 108)
        // a ladder goes up in the button's rounded end; it climbs to the top, stands there, comes down, and the
        // ladder goes before it runs home
        let climber = actor(.codex, home: 560), foot = Double(button.minX) + 0.3 * Double(button.height)
        var onTopOfLadder = false, ladderUp = false
        for k in stride(from: 0.0, to: 12, by: 0.02) {
            let p = BreakTricks.ladderPose(climber, k: k, ground: ground, speed: 0.08 * W, button: button)
            if let l = p.ladder {
                ladderUp = true
                assert(abs(l.maxY - ground) < 0.001 && l.minY >= button.minY - 0.001 && abs(l.midX - foot) < 0.001, "\(k) \(l)")
            } else { assert(p.feet == ground, "off the ground with no ladder: \(k) \(p)") }
            if p.feet == 700 { onTopOfLadder = true }
            assert(p.feet >= 700 - 0.001 && p.feet <= ground + 0.001)
        }
        assert(onTopOfLadder && ladderUp)
        assert(BreakTricks.ladderPose(climber, k: 11.99, ground: ground, speed: 0.08 * W, button: button) == TrickPose(x: 560, feet: ground))
        // words where it would stand at the ladder's top: a plain perch instead
        let overLadder = CGRect(x: 600, y: 640, width: 80, height: 20)
        assert(BreakTricks.ladderPose(climber, k: 3, ground: ground, speed: 0.08 * W, button: button, clear: [overLadder])
               == BreakTricks.perchPose(climber, k: 3, ground: ground, speed: 0.08 * W, button: button, row: nil))
    }

    /// Idle actors sleep sitting until the break's last seconds, then get up; the Zs over them keep clear of a hat.
    static func sleepers(W: Double, floor: Double, actor: (TrickActor.Kind, Double, Bool) -> TrickActor) {
        var sleeper = actor(.codex, 300, true)
        sleeper.idle = true
        let ground = floor - 10.0 / 208 * 108, drop = 16.0 / 208 * 108
        func pose(_ t: Double, left: Double) -> TrickPose {
            BreakTricks.poses([sleeper], t: t, left: left, floor: floor, width: W, perches: [], seed: 1)[0]
        }
        let asleep = pose(20, left: 100)
        assert(asleep.move == .sleep && asleep.sunk == drop && asleep.feet == ground + drop && asleep.x == 300, "\(asleep)")
        assert(Set(stride(from: 0.0, to: 4, by: 0.5).map { pose($0, left: 100).squash }).count > 4)   // it breathes
        assert(pose(20, left: BreakTricks.wake - 0.3).move == .sit)
        let rising = (0..<10).map { pose(20, left: BreakTricks.wake - 0.75 - Double($0) * 0.1) }
        assert(zip(rising, rising.dropFirst()).allSatisfy { $0.sunk >= $1.sunk } && rising.first!.sunk > 0 && rising.last!.sunk < drop)
        // dimmed asleep and seated, brightening as it gets up, full once it stands
        assert(BreakTricks.sleeperOpacity(sleeper, asleep) == 0.45 && BreakTricks.sleeperOpacity(sleeper, pose(20, left: BreakTricks.wake - 0.3)) == 0.45)
        assert(zip(rising, rising.dropFirst()).allSatisfy { BreakTricks.sleeperOpacity(sleeper, $0) <= BreakTricks.sleeperOpacity(sleeper, $1) })
        assert(abs(BreakTricks.sleeperOpacity(sleeper, pose(20, left: 0)) - 1) < 1e-9)
        assert(pose(20, left: 1) == TrickPose(x: 300, feet: ground) && pose(20, left: 0) == TrickPose(x: 300, feet: ground))
        var crab = actor(.crab, 300, true)
        crab.idle = true
        assert(BreakTricks.poses([crab], t: 5, floor: floor, width: W, perches: [], seed: 1)[0].sunk == 2.921 / 17 * 108)
        // the head's top, for a hat: the artwork's top standing, lower by the seat sitting
        let standing = pose(20, left: 0), top = BreakTricks.headTop(sleeper, standing)
        assert(abs(top - (Double(BreakTricks.spriteRect(sleeper, standing).minY) + 30.0 / 208 * 108)) < 0.001)
        assert(abs(BreakTricks.headTop(sleeper, asleep) - (top + drop)) < 0.03 * 108)   // give or take a breath
        // three Zs a sleeper, clear of the hat's room and of controls above, staggered, gone once it's awake
        let above = CGRect(x: 250, y: 700, width: 200, height: 40)
        for t in stride(from: 0.0, to: 12, by: 0.05) {
            let p = pose(t, left: 100), zs = BreakTricks.snores(sleeper, p, index: 2, t: t, clear: [above])
            assert(zs.count == 3)
            for z in zs {
                let box = CGRect(x: z.x - 0.4 * z.size, y: z.y - 0.4 * z.size, width: 0.8 * z.size, height: 0.8 * z.size)
                assert(!box.intersects(BreakTricks.hatRoom(sleeper, p)) && box.minY >= above.maxY + 3 && z.opacity >= 0 && z.opacity <= 0.8,
                       "\(t) \(z)")
            }
        }
        assert(BreakTricks.snores(sleeper, asleep, index: 0, t: 3) != BreakTricks.snores(sleeper, asleep, index: 1, t: 3))
        assert(BreakTricks.snores(sleeper, pose(20, left: 1), index: 0, t: 20).isEmpty)
    }

    /// A fly goes up to the top of the screen, past the words and buttons, stays on screen with its hat, beats its
    /// wings and lands home on time; a helicopter spins down under its propeller cap and a rappel comes down a rope from
    /// the top. Where the screen is too short to fly, a fly flutters on the spot instead.
    static func flights(W: Double, floor: Double, button: CGRect, actor: (TrickActor.Kind, Double, Bool) -> TrickActor) {
        let ground = floor - 10.0 / 208 * 108
        for home in [120.0, 1320] {
            for kind in [TrickActor.Kind.pet, .crab, .codex] {
                var a = actor(kind, home, false)
                a.span = home < 700 ? 86 : -86
                let lift = BreakTricks.flightLift(a, ground: ground)!
                assert(ground - lift < 0.2 * floor, "\(kind) \(lift)")   // near the top
                for trick in [BreakTrick.fly, .helicopter, .rappel] {
                    var beats = Set<Bool>(), high = ground, spun = false, roped = false
                    for k in stride(from: 0.0, to: 8, by: 0.02) {
                        let p = BreakTricks.strollPose(a, k: k, ground: ground, trick: trick), r = BreakTricks.spriteRect(a, p)
                        assert(r.minY - BreakTricks.hatHeight(a) >= -0.001 && r.minX >= 0 && r.maxX <= W && p.feet <= ground + 0.001,
                               "\(trick) \(kind) \(k) \(p)")
                        if case let .fly(up) = p.move { beats.insert(up) }
                        high = min(high, p.feet)
                        spun = spun || p.propeller
                        if let top = p.rope.first {
                            roped = true
                            assert(top.y == 0 && p.rope.allSatisfy { $0.y <= ground + 0.001 }, "\(k) \(p.rope)")
                        }
                    }
                    assert(high < ground - 0.9 * lift, "\(trick) \(kind) \(high)")
                    assert(spun == (trick == .helicopter) && roped == (trick == .rappel), "\(trick)")
                    assert(trick == .rappel || beats == [true, false], "\(trick) \(beats)")
                    assert(abs(BreakTricks.strollPose(a, k: 7.99, ground: ground, trick: trick).x - home) < 2)
                    assert(BreakTricks.strollPose(a, k: 8, ground: ground, trick: trick) == TrickPose(x: home, feet: ground))
                }
            }
        }
        // a Codex pet spins on its way down; a crab, with no turn-around, sways
        let heli = actor(.codex, 300, false), crab = actor(.crab, 300, false)
        assert((0..<190).contains { if case .spin = BreakTricks.strollPose(heli, k: 3 + Double($0) * 0.02, ground: ground, trick: .helicopter).move { true } else { false } })
        assert((0..<190).contains { BreakTricks.strollPose(crab, k: 3 + Double($0) * 0.02, ground: ground, trick: .helicopter).turn != 0 })
        // too short a screen to fly: a flutter on the spot
        let low = actor(.codex, 760, false), lowGround = 150.0
        assert(BreakTricks.flightLift(low, ground: lowGround) == nil)
        let flutter = (0..<100).map { BreakTricks.strollPose(low, k: 3 + Double($0) * 0.02, ground: lowGround, trick: .fly) }
        assert(flutter.contains { if case .fly = $0.move { true } else { false } } && flutter.allSatisfy { $0.x == 760 - 86 })
        assert(flutter.map(\.feet).min()! < lowGround - 0.85 * 108)
        assert(BreakTricks.strollPose(low, k: 1, ground: lowGround, trick: .fly).move == .walk(right: false, fast: false))
    }

    static func colours() {
        assert(BreakColor.rgb(hex: "#3FB8AF") == 0x3FB8AF && BreakColor.rgb(hex: "3fb8af") == 0x3FB8AF)
        assert(BreakColor.rgb(hex: "#3FB8A") == nil && BreakColor.rgb(hex: "#3FB8AG") == nil && BreakColor.rgb(hex: "") == nil)
        assert(BreakColor.hex(0x3FB8AF) == "#3FB8AF")
        assert(BreakColor.pair("amber").glow == 0xC27532 && BreakColor.pair("ocean").bar == 0x62A8FF)
        assert(BreakColor.pair("#000000") == (0x000000, 0x595959))
        assert(BreakColor.pair("nonsense").glow == 0x6E52CF && BreakSettings().color == "violet")
        assert(BreakColor.mix(0xFFFFFF, white: 0.5) == 0xFFFFFF && BreakColor.mix(0x000000, white: 1) == 0xFFFFFF)
    }

    static func settingsDecoding() {
        let empty = try! JSONDecoder().decode(BreakSettings.self, from: Data("{}".utf8))
        assert(empty == BreakSettings())
        // an older Pulse's level and interests are dropped
        let partial = try! JSONDecoder().decode(BreakSettings.self, from:
            Data(#"{"enabled":true,"ideaLevel":9,"ownIdeas":"Hum a tune","level":4,"interests":["tea"],"later":1}"#.utf8))
        assert(partial.enabled && partial.ideaLevel == 2 && partial.ownIdeas == "Hum a tune" && partial.microEvery == 1200)
        var s = BreakSettings(); s.color = "#3FB8AF"; s.ideaLevel = 1; s.ownIdeas = "Hum\nTea"; s.longEnabled = false; s.waitForCalls = false
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
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"claude-code","state":"done","updated_at":"x"}]}"#), block: "b")
               == BreakAgent(id: "b", app: .claude, blocked: false, idle: true, done: true))
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"codex","state":"idle","updated_at":"x"}]}"#), block: "b")?.idle == true)
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"codex","state":"error","updated_at":"x"}]}"#), block: "b") == nil)
        // Grok Build reports itself as grok-build (seen in Rex 2026-10-25)
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"grok-build","effective_app":"grok-build","state":"working","updated_at":"x"}]}"#), block: "b")?.app == .grok)
        assert(BreakAgent.App(rex: "grok") == .grok && BreakAgent.App(rex: "codex") == .codex && BreakAgent.App(rex: "cargo") == nil)
        let ranks = [BreakAgent(id: "i", app: .codex, blocked: false, idle: true), BreakAgent(id: "w", app: .codex, blocked: false),
                     BreakAgent(id: "b", app: .claude, blocked: true)].map(\.rank)
        assert(ranks == [2, 1, 0])
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"cargo","state":"working","updated_at":"x"}]}"#), block: "b") == nil)
        assert(RexAgents.agent(fromStatus: json(#"{"records":[]}"#), block: "b") == nil)
        assert(RexAgents.agent(fromStatus: json("not json"), block: "b") == nil)

        func event(_ name: String, _ payload: String) -> Data {
            json(#"{"type":"session_event","payload":{"session_id":"s","event":{"type":"block_event","payload":{"block_id":"b9","creator_name":"com.superlogical.terminal","name":"\#(name)","payload":\#(payload)}}}}"#)
        }
        let working = RexAgents.update(fromEvent: event("program_status_changed", #"{"id":"","record":{"state":"working","app":"antigravity","msg":"m"},"reason":"report"}"#))
        assert(working?.0 == "b9" && working?.1?.app == .antigravity && working?.1?.blocked == false)
        let idle = RexAgents.update(fromEvent: event("program_status_changed", #"{"id":"","record":{"state":"idle","app":"codex"},"reason":"report"}"#))
        assert(idle?.0 == "b9" && idle?.1?.idle == true && idle?.1?.app == .codex)
        assert(RexAgents.update(fromEvent: event("program_status_changed", #"{"id":"child","record":{"state":"working","app":"codex"}}"#)) == nil)
        let removed = RexAgents.update(fromEvent: event("program_status_removed", #"{"ids":[""],"reason":"exit"}"#))
        assert(removed?.0 == "b9" && removed?.1 == nil)
        assert(RexAgents.update(fromEvent: event("title_changed", #"{"title":"x"}"#)) == nil)
        // lines as `rex events --all --json` printed them on 2026-10-25
        let real = RexAgents.update(fromEvent: json(#"{"type":"session_event","payload":{"session_id":"session:01a16d0f-261b-7c35-82d7-bda13076feab","event":{"type":"block_event","payload":{"block_id":"block:01a172a0-7669-763d-95f5-220283e9b039","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":{"state":"working","app":"claude-code","effective_app":"claude-code","msg":"Updating Rex parsing checks and rerunning the break checks","updated_at":"2026-10-25T08:06:28.040279-04:00","owner":{"pid":54978,"name":"2.1.310"}},"reason":"report"}}}}}"#))
        assert(real?.0 == "block:01a172a0-7669-763d-95f5-220283e9b039" && real?.1?.app == .claude && real?.1?.msg.hasPrefix("Updating") == true)
        let codexWorking = RexAgents.update(fromEvent: json(#"{"type":"session_event","payload":{"session_id":"session:01a16d0f-261b-7c35-82d7-bda13076feab","event":{"type":"block_event","payload":{"block_id":"block:01a172c2-9277-747c-9b98-6320420adfc1","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":{"state":"working","app":"codex","effective_app":"codex","updated_at":"2026-10-25T08:33:37.514381-04:00","owner":{"pid":80877,"name":"codex"}},"reason":"report"}}}}}"#))
        let codexDone = RexAgents.update(fromEvent: json(#"{"type":"session_event","payload":{"session_id":"session:01a16d0f-261b-7c35-82d7-bda13076feab","event":{"type":"block_event","payload":{"block_id":"block:01a172c2-9277-747c-9b98-6320420adfc1","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":{"state":"done","app":"codex","effective_app":"codex","updated_at":"2026-10-25T08:38:32.670275-04:00","owner":{"pid":80877,"name":"codex"}},"reason":"report"}}}}}"#))
        assert(codexWorking?.1?.app == .codex && codexWorking?.1?.idle == false && codexWorking?.1?.blocked == false)
        assert(codexDone?.0 == codexWorking?.0 && codexDone?.1?.idle == true && codexDone?.1?.done == false)   // finished long before this runs
        // a party hat only for a recent finish: Rex keeps "done" until the pane is looked at
        let stamp = "2026-10-26T01:35:14.24817-04:00", finished = RexAgents.date(stamp)!
        let record: [String: Any] = ["app": "claude-code", "state": "done", "updated_at": stamp]
        assert(RexAgents.agent(fromRecord: record, block: "b", now: finished + 60)?.done == true)
        assert(RexAgents.agent(fromRecord: record, block: "b", now: finished + 16 * 60) == BreakAgent(id: "b", app: .claude, blocked: false, idle: true))
        assert(abs(finished.timeIntervalSince(RexAgents.date("2026-10-26T05:35:14Z")!) - 0.24817) < 0.001)
        assert(RexAgents.agent(fromStatus: json(#"{"records":[{"app":"codex","state":"idle","updated_at":"x"}]}"#), block: "b")?.done == false)

        // who fits: five blocked Claude agents can't hide the one Codex agent, and the rest are counted
        let crowd = (0..<5).map { BreakAgent(id: "c\($0)", app: .claude, blocked: true) }
            + [BreakAgent(id: "x", app: .codex, blocked: false), BreakAgent(id: "g", app: .grok, blocked: false, idle: true)]
        let fit = BreakAgent.onScreen(crowd, lanes: 5, slots: 6)
        assert(fit.walkers.count == 5 && fit.walkers.contains { $0.app == .codex } && fit.walkers.first?.blocked == true)
        // the floor's overflow floats as rings, after the other apps
        assert(fit.floaters.map(\.id) == ["g", "c4"] && fit.hidden.isEmpty, "\(fit.floaters.map(\.id))")
        assert(BreakAgent.onScreen(crowd, lanes: 5, slots: 6).walkers.map(\.id) == fit.walkers.map(\.id))   // steady lanes
        let many = (0..<30).map { BreakAgent(id: String(format: "a%02d", $0), app: .claude, blocked: false, idle: true) }
            + [BreakAgent(id: "z", app: .grok, blocked: false, idle: true)]
        let full = BreakAgent.onScreen(many, lanes: 5, slots: 21)
        assert(full.walkers.count == 5 && full.floaters.count == 21 && full.floaters.first?.id == "z" && full.hidden.count == 5)
        // ring spots on narrow, ordinary, wide-short, ultrawide and tall screens: on screen, above the floor, clear of
        // the words and buttons with drift and shadow, and far enough apart that drifting rings never meet
        for (w, h, s) in [(1024.0, 640.0, 0.711), (1440, 900, 1), (2560, 1080, 1.3), (3440, 1440, 1.3), (1280, 1600, 0.889)] {
            let d = 5 * 14.4 * s, floorTop = h - 1.2 * w / 100 - 8 * 14.4 * s
            let words = [CGRect(x: w / 2 - 380 * s, y: h * 0.55, width: 760 * s, height: 30 * s),        // the idea
                         CGRect(x: w / 2 - 260 * s, y: h * 0.75, width: 520 * s, height: 52 * s),        // the buttons
                         CGRect(x: w / 2 - 250 * s, y: h * 0.15, width: 500 * s, height: 200 * s)]      // title and clock
            let spots = BreakTricks.floatSpots(width: w, ring: d, obstacles: words, floorTop: floorTop)
            let reach = d / 2 + BreakTricks.floatDrift * d + 0.18 * d
            assert(!spots.isEmpty, "\(w)x\(h)")
            for p in spots {
                let box = CGRect(x: p.x - reach, y: p.y - reach, width: 2 * reach, height: 2 * reach)
                assert(box.minX >= 0 && box.maxX <= w && box.minY >= 0 && box.maxY <= floorTop, "\(w)x\(h) \(p)")
                assert(!words.contains { $0.intersects(box) }, "\(w)x\(h) \(p)")
            }
            for (i, p) in spots.enumerated() {
                for q in spots[(i + 1)...] { assert(hypot(p.x - q.x, p.y - q.y) >= d * (1 + 2 * BreakTricks.floatDrift) - 0.001) }
            }
        }
        // when rings run out the last spot counts the rest; with no spots at all, everyone not walking is counted
        let thirty = (0..<30).map { BreakAgent(id: String(format: "b%02d", $0), app: .claude, blocked: false, idle: true) }
        let roomy = BreakAgent.crowd(thirty, lanes: 5, spots: 30, helpers: 2)
        assert(roomy.shown.floaters.count == 25 && roomy.helpers == 2 && roomy.more == 0)
        let tight = BreakAgent.crowd(thirty, lanes: 5, spots: 10, helpers: 2)
        assert(tight.shown.floaters.count == 9 && tight.helpers == 0 && tight.more == 25 - 9 + 2)
        let none = BreakAgent.crowd(thirty, lanes: 5, spots: 0, helpers: 1)
        assert(none.shown.floaters.isEmpty && none.more == 25 + 1)
        assert(BreakTricks.floatSpots(width: 1440, ring: 72, obstacles: [], floorTop: 100).isEmpty)   // a 250-point-tall screen
        let wide = BreakTricks.floatSpots(width: 1440, ring: 72, obstacles: [], floorTop: 800)
        assert(wide[0].x < 200 && wide[1].x > 1240 && wide[2].y < wide[0].y)   // a side, the other side, then the top
        assert(BreakAgent.onScreen([], lanes: 5, slots: 6).hidden.isEmpty)
        assert(RexAgents.update(fromEvent: json(#"{"type":"client_connected","payload":{}}"#)) == nil)
        // the other Macs' Rex servers, as `rex hosts list --json` gives them
        assert(RexAgents.hosts(fromList: json(#"{"home":{"label":"","endpoint":"unix:///x/server.sock","this_machine":true,"reached":true},"hosts":[{"host":{"id":"host:01a15f25-c30c-719a-b220-65bca927b363","label":"mini","endpoints":["https://mini.example.ts.net"],"added_from":"MacBook-Air.local","updated_at":"2026-10-21T15:47:52.716941Z"},"from":"home","held":false},{"host":{"label":""}}],"warnings":[]}"#)) == ["mini"])
        assert(RexAgents.hosts(fromList: json(#"{"hosts":[]}"#)).isEmpty && RexAgents.hosts(fromList: json("not json")).isEmpty)

        let fake = RexAgents.simulated("claude-code working, claude-code blocked,codex, grok idle, nope working")
        assert(fake.map(\.app) == [.claude, .claude, .codex, .grok] && fake.map(\.blocked) == [false, true, false, false])
        assert(fake[3].idle && fake[0].label == "claude-code 1" && Set(fake.map(\.id)).count == 4)
        // with no Rex in a folder Pulse looks in, there's nothing to read
        assert(RexAgents.executable(home: URL(fileURLWithPath: "/nonexistent")) == nil
               || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rex")
               || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rex"))
    }
}
