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
        changed.tucked = true
        changed.tuckPeek = true
        let back = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(changed))
        assert(back.breaks.enabled && back.breaks.ownIdeas == "Hum a tune" && back.battery == p.battery && back.dock == .bottom)
        assert(back.tucked == true && back.tuckPeek == true, "a tucked rail stays tucked across launches")

        // the oldest form: only the keys Pulse has always written
        let oldest = try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"enabled":["claude"],"order":["claude"],"alwaysOnTop":true,"showOverlay":true}"#.utf8))
        assert(oldest.battery == BatterySettings() && oldest.breaks == BreakSettings() && oldest.dock == nil && oldest.appearance == .solid
               && oldest.tucked == nil && oldest.tuckPeek == nil)
        checkUnreadableValues()
        checkTrackRendering()
        print("Settings state checks passed: saved values preserved, Tint migrated, unreadable values cost only themselves and are kept in a copy, plain menu-grey tracks without keylines in both looks")
    }

    @MainActor private static func checkUnreadableValues() {
        // What a newer Pulse might write: every value this one can read survives each one it can't.
        let newer = try! JSONDecoder().decode(AppState.Persisted.self, from: Data("""
        {"enabled":["grok","some-new-provider"],"order":["grok","some-new-provider","claude"],"alwaysOnTop":false,"showOverlay":true,
         "dock":"some-new-edge","showPet":false,"voiceHotKey":{"keyCode":"not a number"},"limitAlerts":"not a dictionary",
         "batterySettings":{"lowPercent":30},"unknownKey":1,
         "breakSettings":{"enabled":true,"ownIdeas":"Hum a tune","color":17,"microEvery":"soon","microLength":30}}
        """.utf8))
        assert(newer.enabled == [.grok] && newer.order == [.grok, .claude], "only the unknown accounts go")
        assert(!newer.alwaysOnTop && newer.showPet == false, "the rest of the file survives")
        assert(newer.dock == nil && newer.voiceHotKey == nil && newer.limitAlerts == nil && newer.batterySettings == nil)
        assert(newer.breaks.enabled && newer.breaks.ownIdeas == "Hum a tune" && newer.breaks.microLength == 30,
               "own ideas survive a bad value beside them")
        assert(newer.breaks.color == BreakSettings().color && newer.breaks.microEvery == BreakSettings().microEvery)

        // Wrong types in the keys Pulse has always written cost only those values too.
        let wrong = try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"enabled":7,"order":"x","alwaysOnTop":"yes","showOverlay":[],"showPet":false}"#.utf8))
        let fresh = AppState.Persisted()
        assert(wrong.enabled == fresh.enabled && wrong.order == fresh.order && wrong.alwaysOnTop == fresh.alwaysOnTop
               && wrong.showOverlay == fresh.showOverlay && wrong.showPet == false)

        // Anything Pulse can't read is copied before the next save can erase it, each version of the file once.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "pulse-state-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        let url = dir.appending(path: "state.json")
        func copies() -> [String] { try! fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("state-unreadable-") }.sorted() }
        func text(_ name: String) -> String { try! String(contentsOf: dir.appending(path: name), encoding: .utf8) }

        let none = AppState.Persisted.load(from: url)
        assert(none.settings.enabled == fresh.enabled && none.canReplace && copies().isEmpty, "no file: defaults, nothing to keep")

        let good = #"{"enabled":["claude"],"order":["claude"],"alwaysOnTop":false,"showOverlay":true}"#
        try! Data(good.utf8).write(to: url)
        let clean = AppState.Persisted.load(from: url)
        assert(clean.settings.enabled == [.claude] && clean.canReplace && copies().isEmpty, "a file read in full needs no copy")

        // Partly read: the rest of the settings are used, and the file is kept, whichever value it was.
        for (i, partial) in [
            ##"{"enabled":["claude"],"alwaysOnTop":false,"breakSettings":{"enabled":true,"ownIdeas":["Hum a tune","Stretch"],"color":"#112233"}}"##,
            #"{"enabled":["claude"],"alwaysOnTop":false,"limitAlerts":{"claude.weekly":782000000,"codex.weekly":"nope"}}"#,
            #"{"enabled":["claude"],"alwaysOnTop":false,"batterySettings":{"lowPercent":30}}"#,
            #"{"enabled":["claude","some-new-provider"],"alwaysOnTop":false}"#,
            #"{"enabled":["claude",{"id":"new"}],"alwaysOnTop":false}"#,
            #"{"enabled":["claude"],"alwaysOnTop":false,"dock":"some-new-edge"}"#,
        ].enumerated() {
            try! Data(partial.utf8).write(to: url)
            let before = copies()
            let loaded = AppState.Persisted.load(from: url)
            let added = copies().filter { !before.contains($0) }
            assert(!loaded.settings.alwaysOnTop && loaded.canReplace, "the readable values are used: \(partial)")
            assert(added.count == 1 && text(added[0]) == partial, "the file is copied as it was: \(partial)")
            assert(try! String(contentsOf: url, encoding: .utf8) == partial, "the file itself is left for the next save")
            _ = AppState.Persisted.load(from: url)
            assert(copies().count == before.count + 1, "another launch on the same file adds no second copy, case \(i)")
        }
        assert(fm.fileExists(atPath: url.path))
        let ideas = ##"{"breakSettings":{"enabled":true,"ownIdeas":["Hum a tune"],"color":"#112233"}}"##
        try! Data(ideas.utf8).write(to: url)
        let lost = AppState.Persisted.load(from: url).settings
        assert(lost.breaks.enabled && lost.breaks.color == "#112233" && lost.breaks.ownIdeas == "", "only the bad value goes")

        // Not settings at all: defaults, with the file kept, and a save afterwards can't touch the copy.
        for bad in ["{\"enabled\":[\"claude\"", "", "[1,2]", "\"just text\""] {
            try! Data(bad.utf8).write(to: url)
            let before = copies()
            let loaded = AppState.Persisted.load(from: url)
            let added = copies().filter { !before.contains($0) }
            assert(loaded.settings.alwaysOnTop == fresh.alwaysOnTop && loaded.settings.enabled == fresh.enabled && loaded.canReplace, "defaults for: \(bad)")
            assert(added.count == 1 && text(added[0]) == bad, "kept as it was: \(bad)")
            try! JSONEncoder().encode(loaded.settings).write(to: url, options: .atomic)   // the next save
            assert(text(added[0]) == bad, "a save can't touch it")
            assert(AppState.Persisted.load(from: url).settings.alwaysOnTop == fresh.alwaysOnTop && copies().count == before.count + 1, "the saved defaults read back in full")
        }

        // A file that's there but can't be opened may be perfectly good: it's left alone, and saves wait.
        try! Data(good.utf8).write(to: url)
        let count = copies().count
        try! fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let closed = AppState.Persisted.load(from: url)
        try! fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        assert(!closed.canReplace && closed.settings.enabled == fresh.enabled && copies().count == count, "no copy, and no saving over it")
        assert(text("state.json") == good)

        // Nowhere to keep a copy: saves wait too, so the only copy isn't overwritten.
        try! Data(#"{"alwaysOnTop":false,"dock":"another-new-edge"}"#.utf8).write(to: url)
        try! fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let nowhere = AppState.Persisted.load(from: url)
        try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        assert(!nowhere.canReplace && !nowhere.settings.alwaysOnTop && copies().count == count)
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
                        let edgeX = Int(ceil(8 - size * 0.12))
                        let edgePixel = context.data!.assumingMemoryBound(to: UInt8.self)
                            .advanced(by: ((image.height / 2) * image.width + edgeX) * 4)
                        let edge = Array(UnsafeBufferPointer(start: edgePixel, count: 4))
                        assert(edge == [37, 37, 39, 255],
                               "the outer track must remain plain menu grey without a light keyline: \(edge)")
                    }
                }
            }
        }
    }
}
