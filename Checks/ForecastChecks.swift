// Run: swiftc Sources/Pulse/Models.swift Checks/ForecastChecks.swift -o /tmp/pulse-forecast-check && /tmp/pulse-forecast-check -AppleLocale en_US
// Also: TZ=Asia/Kolkata /tmp/pulse-forecast-check -AppleLocale en_GB   (a 24-hour clock, in a zone whose hours fall on UTC's half hours)
import Foundation

@main
enum ForecastChecks {
    static let start = Date(timeIntervalSinceReferenceDate: 815_000_000)
    static func at(_ hours: Double) -> Date { start.addingTimeInterval(hours * 3600) }
    static let farReset = at(7 * 24)

    static func fetch(_ used: Double?, at hours: Double, after old: AccountSnapshot? = nil, reset: Date? = farReset,
                      id: String = "weekly_all", health: Health = .ok) -> AccountSnapshot {
        AccountSnapshot(id: .codex, displayName: "Codex", planLabel: "", health: health,
                        windows: [UsageWindow(id: id, label: "Weekly", percentUsed: used, resetsAt: reset)],
                        fetchedAt: at(hours), source: .mock).keepingHistory(of: old)
    }

    /// One limit's readings in order, as (hours in, used percent), each going on from the last.
    static func run(_ readings: [(Double, Double)], reset: Date = farReset, id: String = "weekly_all") -> AccountSnapshot {
        readings.reduce(nil as AccountSnapshot?) { old, r in fetch(r.1, at: r.0, after: old, reset: reset, id: id) }!
    }

    /// The forecast is this many hours after the fetch.
    static func hits(_ snap: AccountSnapshot, in hours: Double) -> Bool {
        guard let hit = snap.windows[0].forecast else { return false }
        return abs(hit.timeIntervalSince(snap.fetchedAt) - hours * 3600) < 1
    }
    static func none(_ snap: AccountSnapshot) -> Bool { snap.windows[0].forecast == nil }
    static func samples(_ snap: AccountSnapshot) -> [UsageSample] { snap.windows[0].samples ?? [] }

    static func paceChecks() {
        assert(hits(run([(0, 20), (10, 30)]), in: 70), "10 points in 10 hours leaves 70 hours")
        assert(hits(run([(0, 10), (18, 20), (28, 30), (48, 40)]), in: 72), "from the newest reading a day ago: 20 points in 24 hours")
        assert(samples(run([(0, 10), (18, 20), (28, 30), (48, 40)])).map(\.used) == [20, 30, 40], "history keeps the baseline and what's newer")

        // Idle for days, then a burst: the rise counts over the last day, not over the days since the baseline's reading.
        let idle = stride(from: 0.0, through: 114, by: 6).map { ($0, 40.0) }
        assert(hits(run(idle + [(118, 55), (120, 70)]), in: 24), "30 points in the last 24 hours leaves 24 hours")

        // A rise inside one whole percent counts as use, and is recorded like any other.
        let fractional = run([(0, 20.2), (5, 20.7)], reset: at(10_000))
        assert(samples(fractional).map(\.used) == [20.2, 20.7] && fractional.windows[0].percentUsed == 20.7)
        assert(hits(fractional, in: 793), "0.5 points in 5 hours, got \(String(describing: fractional.windows[0].forecast))")
        assert(hits(run([(0, 20), (10, 30.6)]), in: 69.4 * 10 / 10.6))

        // Guards.
        assert(none(run([(0, 20), (19.0 / 60, 25)])) && hits(run([(0, 20), (20.0 / 60, 25)]), in: 5), "20 minutes of readings")
        assert(none(run([(0, 5), (1, 9.9)])) && hits(run([(0, 5), (1, 10)]), in: 18), "10% used")
        assert(none(run([(0, 50), (1, 100)])) && !none(run([(0, 50), (1, 99.9)])), "under 100%")
        assert(none(run([(0, 60), (20.0 / 60, 60)])), "a constant series has no pace")
        assert(none(run([(0, 60), (1, 60), (30, 60)])), "nor does it after a day")

        // First seen late, at a high percent: nothing is assumed from before the first reading.
        assert(none(run([(72, 75), (73, 75)])), "75% still at 75% an hour later")
        assert(hits(run([(72, 75), (72.5, 75), (73, 76)]), in: 24), "1 point in an hour leaves 24 hours, wherever it started")

        // Before the reset, and only then.
        assert(none(run([(0, 20), (5, 25)], reset: at(10))), "the pace outlasts the reset")
        assert(none(run([(0, 20), (5, 25)], reset: at(80))), "reaching it exactly at the reset is not before it")
        assert(!none(run([(0, 20), (5, 25)], reset: at(80.1))))

        // Bounded: a rise on every 2-minute poll for six days keeps a day of samples and the baseline, and a flat stretch adds none.
        let polls = stride(from: 0.0, to: 144, by: 1.0 / 30).map { ($0, $0 / 144 * 99) }
        let busy = samples(run(polls)).count
        assert(busy >= 720 && busy <= 722, "\(busy) samples")
        assert(samples(run(stride(from: 0.0, to: 144, by: 1.0 / 30).map { ($0, 50.5) })).count == 1, "a flat week is one sample")
        print("Forecast pace checks passed")
    }

    /// A rise that never crosses a whole percent must age out like any other, or a limit keeps warning through days of no use.
    static func fractionalRiseChecks() {
        let rise = stride(from: 0.0, through: 3, by: 0.5).map { ($0, 97.2 + $0 / 5) }   // 97.2 to 97.8 in the first three hours
        let flat = stride(from: 3.5, through: 30, by: 0.5).map { ($0, 97.8) }
        assert(hits(run(rise + flat.filter { $0.0 <= 20 }), in: 2.2 * 20 / 0.6), "still inside the day, the rise counts: 0.6 points in 20 hours")
        let idle = run(rise + flat)
        assert(none(idle), "27 hours with no use, got \(String(describing: idle.windows[0].forecast))")
        let spoken = idle.shownWindows(now: idle.fetchedAt).spokenValue(remaining: false, now: idle.fetchedAt)
        assert(!spoken.contains("at this rate"), spoken)
        print("Forecast fractional rise checks passed")
    }

    /// A sample exactly at the horizon in the middle of the history becomes the baseline.
    static func horizonChecks() {
        let middle = run([(0, 10), (24, 20), (48, 30)], reset: at(500))
        assert(samples(middle).map(\.used) == [20, 30], "\(samples(middle).map(\.used))")
        assert(hits(middle, in: 168), "10 points in 24 hours leaves 168 hours")
        print("Forecast horizon checks passed")
    }

    static func limitsChecks() {
        for share in ["period_GrokBuild", "period_GrokBot", "period_SomeNewProduct"] {
            let snap = fetch(40, at: 1, after: fetch(20, at: 0, id: share), id: share)
            assert(none(snap) && snap.windows[0].samples == nil, "\(share) is a share, with no history")
        }
        assert(!none(run([(0, 20), (5, 25)], id: "period_all")), "Grok's credits are a real limit")
        assert(!none(run([(0, 20), (5, 25)], id: "weekly_model_Fable")), "and so is a per-model cap")

        let noReset = fetch(40, at: 5, after: fetch(20, at: 0, reset: nil), reset: nil)
        assert(none(noReset) && noReset.windows[0].samples == nil, "no reset: no history, no forecast")
        let noPercent = fetch(nil, at: 5, after: fetch(20, at: 0))
        assert(none(noPercent) && noPercent.windows[0].samples == nil && noPercent.windows[0].percentUsed == nil)

        // Going without a reset or a percent starts over: an old session's numbers mustn't baseline the next one.
        let gone = fetch(nil, at: 5, after: run([(0, 20), (4, 80)]), reset: nil)
        let next = fetch(20, at: 6, after: gone)
        assert(samples(next).count == 1 && samples(next)[0].used == 20, "known → nil → known starts over")
        assert(samples(fetch(40, at: 6, after: fetch(20, at: 0, reset: nil))).count == 1, "nil → known starts over")

        // Results other than a live reading go on as they always have.
        for health in [Health.needsAuth, .missingClient, .stale, .providerError] {
            let snap = fetch(40, at: 5, after: fetch(20, at: 0), health: health)
            assert(none(snap) && snap.windows[0].samples == nil, "\(health) passes through")
        }
        print("Forecast limit checks passed")
    }

    static func historyChecks() {
        // The reset moved: 15 minutes starts over, either way, and anything less goes on.
        let base = at(100)
        func moved(_ seconds: TimeInterval) -> AccountSnapshot {
            fetch(30, at: 5, after: fetch(20, at: 0, reset: base), reset: base.addingTimeInterval(seconds))
        }
        assert(samples(moved(0.47)).count == 2 && samples(moved(-90)).count == 2, "noise and a rebuilt reset")
        assert(samples(moved(899)).count == 2 && samples(moved(-899)).count == 2, "just under 15 minutes")
        assert(samples(moved(900)).count == 1 && samples(moved(-900)).count == 1, "15 minutes")
        assert(samples(moved(5 * 3600)).count == 1 && none(moved(5 * 3600)), "a new limit period")

        // A fall of more than 5 points starts over, and the card keeps the provider's real number whichever way it goes.
        let rose = [(0.0, 20.0), (5, 50)]
        let cut = run(rose + [(6, 44.9)])
        assert(samples(cut).count == 1 && samples(cut)[0].used == 44.9 && cut.windows[0].percentUsed == 44.9, "over 5 points")
        let dip = run(rose + [(6, 45)])
        assert(samples(dip).map(\.used) == [20, 50] && dip.windows[0].percentUsed == 45, "exactly 5 points is a dip")
        assert(hits(dip, in: 55 * 6 / 25), "a dip's pace ends at its real number: 25 points in 6 hours")
        assert(samples(run(rose + [(6, 47), (7, 48)])).map(\.used) == [20, 50], "no sample for climbing back")
        assert(samples(run(rose + [(6, 47), (7, 51)])).map(\.used) == [20, 50, 51], "a new high adds one")

        // A provider's halved reading with the same reset: quiet for 20 minutes, then the pace since the cut.
        let halved = [(0.0, 10.0), (24, 80), (24.1, 40)]
        assert(none(run(halved)) && samples(run(halved)).map(\.used) == [40], "starts over at 40")
        assert(hits(run(halved + [(25.1, 42)]), in: 29), "2 points in an hour since the cut")

        // A big fall with the reset barely moved is caught by the drop rule, as there's no test for an expired old reset.
        let early = fetch(1, at: 5.5, after: run([(0, 50), (5, 99)], reset: at(5.25)), reset: at(5.25).addingTimeInterval(600))
        assert(samples(early).map(\.used) == [1], "99% to 1%, the reset 10 minutes later")
        // Its low-use version keeps the old baseline, which can only understate the rise, by the 5 points a dip allows.
        let low = fetch(1, at: 5.5, after: run([(0, 3), (5, 6)], reset: at(5.25)), reset: at(5.25).addingTimeInterval(600))
        assert(samples(low).map(\.used) == [3, 6], "6% to 1% is a dip")
        let lowLater = fetch(12, at: 6.5, after: low, reset: at(5.25).addingTimeInterval(600))
        assert(samples(lowLater)[0].used == 3 && lowLater.windows[0].percentUsed == 12)

        // A long outage: the rise across it can't be taken for one day's use.
        let away = run([(0, 10), (72, 90)])
        assert(none(away) && samples(away).map(\.used) == [90], "three days away starts over")
        assert(hits(run([(0, 10), (72, 90), (73, 92)]), in: 4), "2 points in the hour since coming back")
        assert(samples(run([(0, 10), (24, 90)])).count == 2, "24 hours exactly goes on")
        assert(samples(fetch(90, at: 24 + 1.0 / 3600, after: fetch(10, at: 0))).count == 1, "a second past 24 hours doesn't")

        // Failed fetches keep the original fetch time, so a long provider failure counts as an outage and a short one doesn't.
        let failed = AccountSnapshot.noAnswer(.codex)
        let staleShort = failed.staleKeeping(run([(0, 20), (5, 30)]))
        assert(samples(fetch(40, at: 10, after: staleShort)).map(\.used) == [20, 30, 40], "history goes on after a short failure")
        assert(hits(fetch(40, at: 10, after: staleShort), in: 60 * 10 / 20))
        let staleLong = failed.staleKeeping(run([(0, 20), (5, 30)]))
        assert(samples(fetch(40, at: 30, after: staleLong)).map(\.used) == [40], "and starts over after a long one")

        // The clock went backward past the last sample.
        let back = run([(0, 20), (10, 30), (9, 30)])
        assert(samples(back).count == 1 && samples(back)[0].at == at(9) && none(back))

        // Each limit keeps its own history, whatever order the provider lists them in.
        func two(_ a: Double, _ b: Double, at hours: Double, after old: AccountSnapshot?, flip: Bool) -> AccountSnapshot {
            let week = UsageWindow(id: "weekly_all", label: "Weekly", percentUsed: a, resetsAt: farReset)
            let session = UsageWindow(id: "session_5h", label: "5-hour", percentUsed: b, resetsAt: farReset)
            return AccountSnapshot(id: .codex, displayName: "Codex", planLabel: "", health: .ok, windows: flip ? [session, week] : [week, session],
                                   fetchedAt: at(hours), source: .mock).keepingHistory(of: old)
        }
        let swapped = two(30, 70, at: 10, after: two(20, 40, at: 0, after: nil, flip: false), flip: true)
        assert(swapped.windows[0].samples?.map(\.used) == [40, 70] && swapped.windows[1].samples?.map(\.used) == [20, 30])
        print("Forecast history checks passed")
    }

    static func fiveHourChecks() {
        let reset = at(5)
        func session(_ readings: [(Double, Double)]) -> AccountSnapshot { run(readings, reset: reset, id: "session_5h") }
        assert(none(session([(0, 0), (19.0 / 60, 10)])), "a burst under 20 minutes in")
        assert(hits(session([(0, 0), (20.0 / 60, 10)]), in: 3), "10 points in 20 minutes leaves 3 hours")
        assert(none(session([(0, 0), (20.0 / 60, 10), (4, 10)])), "at the same 10% four hours in, the session lasts")
        assert(hits(session([(0, 0), (4, 90)]), in: 4.0 / 9) && forecastLabel(at(4 + 4.0 / 9), now: at(4)) == "At this rate you hit the limit in about 25 min")
        let next = fetch(5, at: 5.5, after: session([(0, 0), (4, 90)]), reset: at(10.5), id: "session_5h")
        assert(samples(next).map(\.used) == [5], "the next session starts over")
        print("Forecast five-hour checks passed")
    }

    /// Only a fresh, live reading shows a forecast, and the stored history outlives it.
    static func freshnessChecks() {
        let snap = run([(0, 20), (10, 30)])
        assert(snap.windows[0].forecast != nil)
        func shown(_ s: AccountSnapshot, _ seconds: TimeInterval) -> UsageWindow { s.shownWindows(now: s.fetchedAt.addingTimeInterval(seconds))[0] }
        assert(shown(snap, 0).forecast != nil && shown(snap, 10 * 60).forecast != nil, "up to 10 minutes old")
        assert(shown(snap, 10 * 60 + 1).forecast == nil && shown(snap, 10 * 60 + 1).percentUsed == 30, "older, the number stays and the forecast doesn't")

        var stale = snap
        stale.health = .stale
        assert(shown(stale, 0).forecast == nil, "stale, before its reset")
        assert(shown(stale, 0).percentUsed == 30, "keeps its number until the reset")
        assert(stale.shownWindows(now: farReset)[0].percentUsed == nil, "and not past it")
        assert(stale.windows[0].forecast != nil && shown(stale, 0).samples?.count == 2, "the stored snapshot keeps it all")

        var noReset = stale
        noReset.windows[0].resetsAt = nil
        assert(shown(noReset, 0).forecast == nil && shown(noReset, 0).percentUsed == 30, "stale with no reset time")
        let kept = AccountSnapshot.noAnswer(.codex).staleKeeping(snap)
        assert(kept.shownWindows(now: kept.fetchedAt)[0].forecast == nil, "a failed fetch's copy")
        print("Forecast freshness checks passed")
    }

    /// What VoiceOver reads comes from the same label and the same shown windows as the row.
    static func spokenChecks() {
        let now = at(10)
        let line = forecastLabel(at(80), now: now)!
        let spoken = "at this rate you hit the limit " + line.dropFirst("At this rate you hit the limit ".count)
        var session = UsageWindow(id: "session_5h", label: "Session", percentUsed: 30, resetsAt: nil, forecast: at(80))
        var week = UsageWindow(id: "weekly_all", label: "Week", percentUsed: 30, resetsAt: nil, forecast: at(80))
        assert([session, week].spokenValue(remaining: false, now: now) == "Session 30% used, \(spoken); Week 30% used, \(spoken)")
        assert([session].spokenValue(remaining: true, now: now) == "Session has 70% left, \(spoken)", "the same words either way round")
        let caps = ["a", "b", "c", "d"].map { UsageWindow(id: "weekly_model_\($0)", label: $0, percentUsed: 99, resetsAt: nil, forecast: at(80)) }
        assert(caps.spokenValue(remaining: false, now: now).components(separatedBy: spoken).count == 5, "a near-limit window with no place on the ring too")
        session.forecast = now
        week.forecast = nil
        assert([session, week].spokenValue(remaining: false, now: now) == "Session 30% used; Week 30% used", "passed, or none")
        print("Forecast spoken checks passed")
    }

    static func savedFileChecks() throws {
        let saved = Data(#"{"id":"codex","displayName":"Codex","planLabel":"OpenAI","health":"ok","fetchedAt":0,"source":"officialProtocol","windows":[{"id":"weekly_all","label":"Weekly","percentUsed":60,"resetsAt":1000}]}"#.utf8)
        let old = try JSONDecoder().decode(AccountSnapshot.self, from: saved)
        assert(old.windows[0].percentUsed == 60 && old.windows[0].samples == nil && old.windows[0].forecast == nil, "an older snapshots.json")
        let cached = fetch(61, at: 0, after: old, reset: Date(timeIntervalSinceReferenceDate: 1000))
        assert(samples(cached).count == 1, "its first fetch begins the history")

        let round = try JSONDecoder().decode(AccountSnapshot.self, from: JSONEncoder().encode(run([(0, 20), (10, 30)])))
        assert(round.windows[0].samples?.map(\.used) == [20, 30] && round.windows[0].forecast != nil, "history survives a restart")
        assert(hits(fetch(32, at: 11, after: round), in: 68 * 11 / 12), "and goes on from there")
        print("Forecast saved-file checks passed")
    }

    static func wordingChecks() {
        let id = Locale.current.identifier
        assert(id == "en_US" || id == "en_GB", "run with -AppleLocale en_US or en_GB, got \(id)")
        let us = id == "en_US"
        let cal = Calendar.current
        func local(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
        }
        let now = local(9, 12)   // a Monday at noon
        let line = "At this rate you hit the limit "
        func label(_ s: TimeInterval) -> String? { forecastLabel(now.addingTimeInterval(s), now: now) }

        assert(forecastLabel(nil, now: now) == nil)
        assert(label(0) == nil && label(-60) == nil, "passed")
        for (seconds, words) in [(1, "in under 5 min"), (12, "in under 5 min"), (299, "in under 5 min"), (300, "in about 5 min"),
                                 (599, "in about 5 min"), (600, "in about 10 min"), (40 * 60 + 59, "in about 40 min"), (3599, "in about 55 min"),
                                 (3600, "in about 1 hour"), (7199, "in about 1 hour"), (7200, "in about 2 hours"),
                                 (4 * 3600 + 59 * 60, "in about 4 hours"), (24 * 3600 - 1, "in about 23 hours")] {
            assert(label(TimeInterval(seconds)) == line + words, "\(seconds) s: \(label(TimeInterval(seconds)) ?? "nil")")
        }

        // the system puts a narrow no-break space before AM and PM
        func when(_ date: Date, from: Date = now) -> String { (forecastLabel(date, now: from) ?? "nil").replacingOccurrences(of: "\u{202F}", with: " ") }
        assert(when(local(10, 12)) == line + (us ? "Tue 12 PM" : "Tue 12:00"), "24 hours exactly: \(when(local(10, 12)))")
        assert(when(local(10, 15)) == line + (us ? "Tue 3 PM" : "Tue 15:00"), when(local(10, 15)))
        assert(when(local(10, 15, 40)) == line + (us ? "Tue 3 PM" : "Tue 15:00"), "the local hour, down: \(when(local(10, 15, 40)))")
        assert(when(local(10, 14, 59, 59)) == line + (us ? "Tue 2 PM" : "Tue 14:00"), "never the next hour")
        let late = local(9, 22, 30)
        assert(when(local(11, 0, 5), from: late) == line + (us ? "Wed 12 AM" : "Wed 00:00"), "local midnight: \(when(local(11, 0, 5), from: late))")
        assert(when(local(10, 23, 50), from: late) == line + (us ? "Tue 11 PM" : "Tue 23:00"), "never tomorrow's")

        let beforeSix = when(now.addingTimeInterval(6 * 86400 - 1))
        assert(!beforeSix.contains("Nov"), "under six days: the weekday alone, got \(beforeSix)")
        let sixDays = when(now.addingTimeInterval(6 * 86400))
        assert(sixDays.contains("Sun") && sixDays.contains("Nov") && sixDays.contains("15") && sixDays.contains(us ? "12 PM" : "12:00"),
               "six days out names the date: \(sixDays)")
        print("Forecast wording checks passed in \(id), \(TimeZone.current.identifier)")
    }

    static func main() {
        paceChecks()
        fractionalRiseChecks()
        horizonChecks()
        limitsChecks()
        historyChecks()
        fiveHourChecks()
        freshnessChecks()
        spokenChecks()
        try! savedFileChecks()
        wordingChecks()
        print("forecast checks passed")
    }
}
