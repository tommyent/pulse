// Run from the project: swiftc $(find Sources/Pulse -name "*.swift" ! -name PulseApp.swift) Checks/SettingsStateChecks.swift -o /tmp/pulse-state-check && /tmp/pulse-state-check
// Builds every source but the app's entry point, so it stands in for the two things PulseApp.swift defines.
import SwiftUI

extension Bundle { static let pulseResources = Bundle.main }
final class OverlayHostingView<Content: View>: NSHostingView<Content> {}

@main
enum SettingsStateChecks {
    @MainActor static func main() {
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
        assert(!p.alwaysOnTop && p.showOverlay && p.appearance == .glass && p.dock == .bottom)
        assert(p.showPet == false && p.showRemaining == true && p.voiceHotKey?.label == "⌥⇧Space")
        assert(p.limitAlerts?["claude.session_5h"] == Date(timeIntervalSinceReferenceDate: 782000000))
        assert(p.battery.lowPercent == 30 && p.battery.criticalPercent == 15 && !p.battery.showInRail && p.battery.criticalSound == nil)
        assert(p.breakSettings == nil && p.breaks == BreakSettings())

        // Saving migrates Tint to Appearance, drops obsolete appearance keys, and preserves unrelated settings.
        let again = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        let before = try! JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        for key in before.keys where key != "lightMode" && key != "glassTint" { assert(again[key] != nil, "lost \(key)") }
        assert(again["appearance"] as? String == "glass" && again["glassTint"] == nil && again["lightMode"] == nil)
        for obsolete in ["true", "false", "null", "\"obsolete\""] {
            let data = Data("{\"enabled\":[],\"order\":[],\"alwaysOnTop\":true,\"showOverlay\":true,\"lightMode\":\(obsolete)}".utf8)
            let decoded = try! JSONDecoder().decode(AppState.Persisted.self, from: data)
            let encoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
            assert(encoded["lightMode"] == nil && decoded.showOverlay, "unknown legacy values never affect current settings")
        }
        for (old, expected) in [("true", PulseAppearance.solid), ("false", .glass), ("null", .solid), ("\"obsolete\"", .solid)] {
            let data = Data("{\"enabled\":[],\"order\":[],\"alwaysOnTop\":true,\"showOverlay\":true,\"glassTint\":\(old)}".utf8)
            let migrated = try! JSONDecoder().decode(AppState.Persisted.self, from: data)
            assert(migrated.appearance == expected)
            let encoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
            assert(encoded["glassTint"] == nil && encoded["appearance"] as? String == expected.rawValue)
            for look in [PulseAppearance.glass, .solid] {
                var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                object["appearance"] = look.rawValue
                let explicit = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONSerialization.data(withJSONObject: object))
                assert(explicit.appearance == look, "the current selection takes precedence over the old Tint key")
            }
        }
        assert(again["breakSettings"] == nil)
        var changed = p
        changed.breaks.enabled = true
        changed.breaks.ownIdeas = "Hum a tune"
        let back = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(changed))
        assert(back.breaks.enabled && back.breaks.ownIdeas == "Hum a tune" && back.battery == p.battery && back.dock == .bottom)

        // the oldest form: only the keys Pulse has always written
        let oldest = try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"enabled":["claude"],"order":["claude"],"alwaysOnTop":true,"showOverlay":true}"#.utf8))
        assert(oldest.battery == BatterySettings() && oldest.breaks == BreakSettings() && oldest.dock == nil && oldest.appearance == .solid)
        checkTrackRendering()
        print("Settings state checks passed: saved values preserved, Tint migrated, ring and battery tracks match menu grey in both looks")
    }

    @MainActor private static func checkTrackRendering() {
        for appearance in [PulseAppearance.glass, .solid] {
            for background in [Color.black, .white] {
                for size: CGFloat in [28, 52] {
                    let views = [
                        AnyView(RingView(account: .claude, percent: 0, size: size, showPercent: false)),
                        AnyView(BatteryRing(reading: BatteryReading(percent: 0, onAC: false, minutesLeft: nil),
                                            level: .critical, size: size, showPercent: false))
                    ]
                    for view in views {
                        let renderer = ImageRenderer(content: view.padding(4).background(background)
                            .environment(\.colorScheme, .dark).environment(\.pulseAppearance, appearance))
                        renderer.scale = 2
                        let image = renderer.cgImage!
                        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        let pixel = context.data!.assumingMemoryBound(to: UInt8.self).advanced(by: ((image.height / 2) * image.width + 10) * 4)
                        let sample = Array(UnsafeBufferPointer(start: pixel, count: 4))
                        assert(sample == [37, 37, 39, 255],
                               "ring and battery tracks must match the menu grey, opaque in both looks and sizes over any backdrop: \(sample)")
                    }
                }
            }
        }
    }
}
