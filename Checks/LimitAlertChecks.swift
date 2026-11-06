// Run: swiftc Sources/Pulse/Models.swift Checks/LimitAlertChecks.swift -o /tmp/pulse-limit-check && /tmp/pulse-limit-check
import Foundation

@main
enum LimitAlertChecks {
    /// What the rail draws from a failed fetch's numbers.
    static func staleChecks(reset: Date) {
        func shown(_ health: Health, _ resetsAt: Date?, at now: Date) -> UsageWindow {
            AccountSnapshot(id: .codex, displayName: "Codex", planLabel: "", health: health,
                            windows: [UsageWindow(id: "weekly_all", label: "Weekly", percentUsed: 99, resetsAt: resetsAt)],
                            fetchedAt: .now, source: .mock).shownWindows(now: now)[0]
        }
        let before = reset.addingTimeInterval(-60), after = reset.addingTimeInterval(60)
        assert(shown(.stale, reset, at: before).percentUsed == 99 && shown(.stale, reset, at: before).isNearLimit,
               "until its reset a stale number stands, badge included")
        assert(shown(.stale, reset, at: after).percentUsed == nil && !shown(.stale, reset, at: after).isNearLimit,
               "past its reset a stale number is unknown, and no longer near a limit")
        assert(shown(.stale, reset, at: reset).percentUsed == nil, "the reset moment itself counts as past")
        assert(shown(.stale, nil, at: after).percentUsed == 99, "with no reset time there's nothing to prove it wrong")
        assert(shown(.ok, reset, at: after).percentUsed == 99, "a live number is the provider's own, even just past its reset")

        // a fetch that ran out of time goes down the failed-fetch path: stale numbers stay, with its reason
        let none = AccountSnapshot.noAnswer(.claude)
        assert(none.health == .providerError && none.windows.isEmpty && none.healthMessage == "Claude didn't answer")
        let old = AccountSnapshot(id: .claude, displayName: "Claude", planLabel: "Ultra", health: .ok,
                                  windows: [UsageWindow(id: "weekly_all", label: "All", percentUsed: 55, resetsAt: reset)],
                                  fetchedAt: reset, source: .officialProtocol)
        let kept = none.staleKeeping(old)
        assert(kept.health == .stale && kept.windows.first?.percentUsed == 55 && kept.planLabel == "Ultra" && kept.fetchedAt == reset)
        assert(kept.healthMessage?.hasSuffix("Claude didn't answer") == true)
        print("Stale window checks passed: dimmed until its reset, unknown after it")
    }

    static func main() {
        let reset = Date(timeIntervalSinceReferenceDate: 814_567_884)
        func snap(_ pct: Double?, resets: Date? = reset, health: Health = .ok, id: String = "weekly_all") -> AccountSnapshot {
            AccountSnapshot(id: .codex, displayName: "Codex", planLabel: "", health: health,
                            windows: [UsageWindow(id: id, label: "Weekly", percentUsed: pct, resetsAt: resets)],
                            fetchedAt: .now, source: .mock)
        }
        var alerted: [String: Date] = [:]
        func fires(_ s: AccountSnapshot) -> Int { s.newlyNearLimit(alerted: &alerted).count }

        assert(fires(snap(97)) == 0)
        assert(fires(snap(98)) == 1)
        assert(fires(snap(98)) == 0 && fires(snap(98.9)) == 0)             // whole percents: 98.9 is still 98
        assert(fires(snap(99)) == 1 && fires(snap(99.6)) == 0)             // each step once per period
        assert(fires(snap(100)) == 1 && fires(snap(100)) == 0)
        assert(fires(snap(99, resets: reset.addingTimeInterval(0.47))) == 0)   // sub-second reset noise
        assert(fires(snap(99, resets: reset.addingTimeInterval(-90))) == 0)    // rebuilt from "seconds left"
        assert(fires(snap(96)) == 0 && fires(snap(98)) == 0)               // 95–98 keeps the latch
        assert(fires(snap(94)) == 0 && fires(snap(98)) == 1)               // under 95 rearms
        assert(fires(snap(99, resets: reset.addingTimeInterval(5 * 3600))) == 1)   // missed the reset, new window already high

        alerted = [:]
        assert(fires(snap(100, health: .stale)) == 0)                      // cached numbers at launch never alert
        assert(fires(snap(100, health: .providerError)) == 0)
        assert(fires(snap(nil)) == 0)
        assert(alerted.isEmpty)

        assert(fires(snap(99, resets: nil)) == 1 && fires(snap(99, resets: nil)) == 0)   // no reset time: only a drop rearms
        assert(fires(snap(94, resets: nil)) == 0 && fires(snap(98, resets: nil)) == 1)

        alerted = [:]
        var two = snap(99)
        two.windows.append(UsageWindow(id: "session_5h", label: "5-hour", percentUsed: 100, resetsAt: reset))
        assert(two.newlyNearLimit(alerted: &alerted).map(\.id) == ["weekly_all", "session_5h"])   // one alert names both
        assert(alerted.keys.sorted() == ["codex.session_5h", "codex.session_5h@100", "codex.session_5h@99",
                                         "codex.weekly_all", "codex.weekly_all@99"], "\(alerted.keys.sorted())")
        assert(fires(snap(100)) == 1)                                      // a jump past steps announced once, the rest later

        alerted = ["codex.weekly_all": reset]                              // marked before there were steps: 98 is done
        assert(fires(snap(98)) == 0 && fires(snap(99)) == 1)

        assert(UsageWindow(id: "w", label: "", percentUsed: 98, resetsAt: nil).isNearLimit)
        assert(!UsageWindow(id: "w", label: "", percentUsed: 97.9, resetsAt: nil).isNearLimit)
        alerted = [:]
        var claude = snap(100)
        claude.id = .claude
        assert(fires(claude) == 1)
        claude.windows[0].resetsAt = reset.addingTimeInterval(0.47)
        assert(fires(claude) == 0, "Claude subsecond reset noise stays suppressed")
        claude.windows[0].percentUsed = 0
        assert(fires(claude) == 0)
        claude.windows[0].percentUsed = 100
        assert(fires(claude) == 1, "Claude's existing low-usage rearm is unchanged")
        staleChecks(reset: reset)
        grokChecks(reset: reset)
        print("limit alert checks passed")
    }

    static func grokChecks(reset: Date) {
        var alerted: [String: Date] = [:]
        var now = reset.addingTimeInterval(-3600)
        func fires(_ percent: Double, end: Date? = nil, source: Source = .cliStatus,
                   health: Health = .ok, unknownReset: Bool = false) -> Int {
            let snap = AccountSnapshot(id: .grok, displayName: "Grok", planLabel: "", health: health,
                windows: [UsageWindow(id: "period_all", label: "Credits", percentUsed: percent,
                                      resetsAt: unknownReset ? nil : end ?? reset)],
                fetchedAt: now, source: source)
            return snap.newlyNearLimit(alerted: &alerted, now: now).count
        }
        assert(fires(100) == 1)
        assert(fires(0) == 0 && fires(100) == 0, "a dip must not undo dismissal")
        now = now.addingTimeInterval(1800)
        assert(fires(0) == 0 && fires(100) == 0, "even a sustained dip keeps dismissal")
        assert(fires(100, source: .officialUsagePage) == 0, "source switches keep dismissal")
        assert(fires(100, end: reset.addingTimeInterval(1800)) == 0, "future reset drift is not a reset")
        assert(fires(100, end: reset.addingTimeInterval(-1800)) == 0, "backward reset drift is not a reset")
        assert(fires(100, unknownReset: true) == 0, "missing reset cannot rearm")
        alerted = try! JSONDecoder().decode([String: Date].self, from: JSONEncoder().encode(alerted))
        assert(fires(100) == 0, "dismissal survives persisted-state round trip")
        now = reset.addingTimeInterval(1)
        assert(fires(100) == 0, "expired old payload cannot rearm")
        assert(fires(100, end: reset.addingTimeInterval(0.47)) == 0, "subsecond noise cannot rearm")
        let next = reset.addingTimeInterval(7 * 86400)
        assert(fires(100, end: next, health: .stale) == 0)
        assert(fires(98, end: next) == 1, "real reset rearms 98")
        assert(fires(99, end: next) == 1 && fires(99, end: next) == 0)
        assert(fires(100, end: next) == 1 && fires(100, end: next) == 0)
        alerted = [:]
        assert(fires(100, unknownReset: true) == 1)
        assert(fires(0, unknownReset: true) == 0 && fires(100, unknownReset: true) == 0)
        assert(fires(100, end: next) == 0, "learning an unknown reset does not repeat an alert")
        now = next.addingTimeInterval(1)
        assert(fires(100, end: next.addingTimeInterval(7 * 86400)) == 1)
        print("Grok dismissal and reset checks passed")
    }
}
