// Run from the project: swiftc $(find Sources/Pulse -name "*.swift" ! -name PulseApp.swift) Checks/SettingsStateChecks.swift -o /tmp/pulse-state-check && /tmp/pulse-state-check
// Builds every source but the app's entry point, so it stands in for the two things PulseApp.swift defines.
import SwiftUI

extension Bundle { static let pulseResources = Bundle.main }
final class OverlayHostingView<Content: View>: NSHostingView<Content> {}

@main
enum SettingsStateChecks {
    static func main() {
        // a state.json written before breaks existed: every value it holds survives, and breaks get their defaults
        let legacy = Data("""
        {"enabled":["claude","codex","grok"],"order":["codex","claude","grok","antigravity"],"alwaysOnTop":false,
         "showOverlay":true,"lightMode":true,"glassTint":false,"dock":"bottom","showPet":false,"showRemaining":true,
         "voiceHotKey":{"keyCode":49,"carbonModifiers":6144,"label":"⌥⇧Space"},
         "limitAlerts":{"claude.session_5h":782000000},
         "batterySettings":{"showInRail":false,"alerts":true,"lowPercent":30,"criticalPercent":15,"lowSound":"Glass",
                            "lowLoops":false,"criticalSound":null,"criticalLoops":true,"pushover":false}}
        """.utf8)
        let p = try! JSONDecoder().decode(AppState.Persisted.self, from: legacy)
        assert(p.enabled == [.claude, .codex, .grok] && p.order == [.codex, .claude, .grok, .antigravity])
        assert(!p.alwaysOnTop && p.showOverlay && p.lightMode == true && p.glassTint == false && p.dock == .bottom)
        assert(p.showPet == false && p.showRemaining == true && p.voiceHotKey?.label == "⌥⇧Space")
        assert(p.limitAlerts?["claude.session_5h"] == Date(timeIntervalSinceReferenceDate: 782000000))
        assert(p.battery.lowPercent == 30 && p.battery.criticalPercent == 15 && !p.battery.showInRail && p.battery.criticalSound == nil)
        assert(p.breakSettings == nil && p.breaks == BreakSettings())

        // saved again, the file keeps every old key as it was and adds breakSettings only once breaks are changed
        let again = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        let before = try! JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        for key in before.keys { assert(again[key] != nil, "lost \(key)") }
        assert(again["breakSettings"] == nil)
        var changed = p
        changed.breaks.enabled = true
        changed.breaks.interests = ["tea"]
        let back = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(changed))
        assert(back.breaks.enabled && back.breaks.interests == ["tea"] && back.battery == p.battery && back.dock == .bottom)

        // the oldest form: only the keys Pulse has always written
        let oldest = try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"enabled":["claude"],"order":["claude"],"alwaysOnTop":true,"showOverlay":true}"#.utf8))
        assert(oldest.battery == BatterySettings() && oldest.breaks == BreakSettings() && oldest.dock == nil)
        print("Settings state checks passed: an existing state.json keeps every value and gets the Breaks defaults")
    }
}
