// Run from the project, as scripts/check.sh does. Payload shapes are cut down from the providers' real replies.
import Foundation

@main
enum UsageParserChecks {
    static func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func main() {
        // Claude with no session window: the plan that sends a null five_hour and its model cap in `limits`.
        let ultra = ClaudeAdapter.windows(from: json("""
        {"five_hour":null,"seven_day":{"utilization":57.0,"resets_at":"2026-11-08T11:00:00.484644+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"is_enabled":false,"utilization":null},
         "limits":[{"kind":"weekly_all","percent":57,"resets_at":"2026-11-08T11:00:00.484644+00:00","scope":null},
                   {"kind":"weekly_scoped","percent":0,"resets_at":"2026-11-08T11:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}
        """))
        assert(ultra.map(\.label) == ["All models", "Fable"], "\(ultra.map(\.label))")
        assert(ultra.map(\.percentUsed) == [57, 0] && ultra.allSatisfy { $0.resetsAt != nil })
        assert(ultra.map(\.id) == ["weekly_all_seven_day", "weekly_model_Fable"])

        // Claude with a session window: it leads, then all models, then the cap.
        let max = ClaudeAdapter.windows(from: json("""
        {"limits":[{"kind":"weekly_scoped","percent":11,"scope":{"model":{"display_name":"Fable"}}}],
         "seven_day":{"utilization":70.0},"five_hour":{"utilization":4.0,"resets_at":"2026-11-06T01:00:00+00:00"}}
        """))
        assert(max.map(\.label) == ["Current session", "All models", "Fable"], "\(max.map(\.label))")
        assert(max.map(\.percentUsed) == [4, 70, 11])

        // Max always has a 5-hour limit: a null one keeps its slot, blank. Ultra has none, and a Max with a session is left alone.
        let idle = ClaudeAdapter.keepingSessionSlot(ultra, plan: "Max 5x")
        assert(idle.map(\.id) == ["session_5h_five_hour", "weekly_all_seven_day", "weekly_model_Fable"] && idle[0].percentUsed == nil)
        assert(idle.outerArc?.id == "session_5h_five_hour" && idle.innerArc?.id == "weekly_all_seven_day" && idle.disc?.id == "weekly_model_Fable")
        assert(ClaudeAdapter.keepingSessionSlot(ultra, plan: "Ultra").map(\.id) == ultra.map(\.id))
        assert(ClaudeAdapter.keepingSessionSlot(max, plan: "Max 5x").map(\.id) == max.map(\.id))
        assert(ClaudeAdapter.keepingSessionSlot([], plan: "Max 5x").isEmpty, "no numbers at all stays a failed fetch")

        // A cap reported with no number stays, so its disc stays too, empty.
        let blankCap = ClaudeAdapter.windows(from: json(#"{"seven_day":{"utilization":70.0},"limits":[{"kind":"weekly_scoped","percent":null,"scope":{"model":{"display_name":"Fable"}}}]}"#))
        assert(blankCap.map(\.label) == ["All models", "Fable"] && blankCap[1].percentUsed == nil)

        // Antigravity: a model's own group joins the pool its first word names, else the first pool.
        func agy(_ cap: String) -> [UsageWindow] {
            AntigravityAdapter.windows(from: json("""
            {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
             {"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":1}]},
             {"name":"Claude and GPT models","buckets":[{"id":"3p-5h","window":"5h","remaining_fraction":1}]},
             {"name":"\(cap)","buckets":[{"id":"cap","window":"weekly","remaining_fraction":0.5}]}]}}}
            """))
        }
        assert(agy("Gemini 4 Argon").map(\.id) == ["gemini-5h", "weekly_model_cap", "3p-5h"])
        assert(agy("Claude Opus 5").map(\.id) == ["gemini-5h", "3p-5h", "weekly_model_cap"] && agy("Claude Opus 5")[2].pool == "Claude and GPT")
        assert(agy("GPT-OSS").last?.pool == "Claude and GPT")
        assert(agy("Something New").map(\.id) == ["gemini-5h", "weekly_model_cap", "3p-5h"], "no name match: the first pool")

        // Fields Claude adds that carry no window, or that Pulse doesn't name, stay off the rings.
        assert(ClaudeAdapter.windows(from: json(#"{"new_codename":{"utilization":50},"seven_day_cowork":null,"limits":[]}"#)).isEmpty)
        assert(ClaudeAdapter.windows(from: [:]).isEmpty)

        // Codex with one window, a null second one, and its real reset timestamp.
        let weekly = CodexAdapter.windows(from: json("""
        {"plan_type":"prolite","rate_limit":{"allowed":true,"primary_window":{"used_percent":89,"limit_window_seconds":604800,
         "reset_after_seconds":325809,"reset_at":1794247245},"secondary_window":null}}
        """))
        assert(weekly.count == 1 && weekly[0].id == "weekly_all" && weekly[0].label == "Weekly" && weekly[0].percentUsed == 89)
        assert(weekly[0].resetsAt == Date(timeIntervalSince1970: 1794247245))

        // Which window is primary depends on the plan: the shorter one leads, whichever it is.
        let swapped = CodexAdapter.windows(from: json("""
        {"rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":604800},
         "secondary_window":{"used_percent":5,"limit_window_seconds":18000}}}
        """))
        assert(swapped.map(\.id) == ["session_5h", "weekly_all"] && swapped.map(\.percentUsed) == [5, 30], "\(swapped.map(\.id))")
        assert(swapped[0].label == "5-hour window")

        // A free plan's 30-day window, and a reset given only as seconds from now.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monthly = CodexAdapter.windows(from: json("""
        {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":2592000,"reset_after_seconds":3600}}}
        """), now: now)
        assert(monthly.map(\.id) == ["monthly_all"] && monthly[0].label == "Monthly")
        assert(monthly[0].resetsAt == now.addingTimeInterval(3600))

        assert(CodexAdapter.windows(from: json(#"{"plan_type":"plus","rate_limit":null}"#)).isEmpty)
        print("Usage parser checks passed: Claude with and without a session window, Codex's windows whichever way round")
    }
}
