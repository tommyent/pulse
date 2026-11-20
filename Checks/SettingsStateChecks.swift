// Run from the project: swiftc $(find Sources/Pulse -name "*.swift" ! -name PulseApp.swift) Checks/SettingsStateChecks.swift -o /tmp/pulse-state-check && /tmp/pulse-state-check
// Builds every source but the app's entry point, so it stands in for the two things PulseApp.swift defines.
import SwiftUI

// the sources' Resources, as the app's bundle holds them (the built-in themes' files)
extension Bundle { static let pulseResources = Bundle(path: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/Pulse").path)! }
final class OverlayHostingView<Content: View>: NSHostingView<Content> {}

@main
enum SettingsStateChecks {
    @MainActor static func main() {
        // What this build is, for About Pulse and the foot of Settings: a release shows its version and build, any other
        // build its commit too (package.sh writes PulseCommit for those), and a bundle without Info.plist says so.
        let release: [String: Any] = ["CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "10"]
        assert(AboutPulse.line(release) == "Pulse 0.5.0 (10)", AboutPulse.line(release))
        assert(AboutPulse.build(release) == "10", "the About panel's version is the build alone for a release")
        let test = release.merging(["PulseCommit": "3d439a4"]) { $1 }
        assert(AboutPulse.line(test) == "Pulse 0.5.0 (10, 3d439a4)", AboutPulse.line(test))
        assert(AboutPulse.build(test) == "10, 3d439a4", "a test build's About panel shows its commit")
        assert(AboutPulse.line([:]) == "Pulse (development build)", AboutPulse.line([:]))

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
        assert(p.agentSettings == nil && p.agents == AgentSettings() && !p.agents.showOnRail, "a state from before the agents ring leaves it off")
        assert(p.hiddenPools == nil, "a state from before pool switches shows every pool")
        assert(p.agyHold == nil, "a state from before the Antigravity hold holds nothing back")
        var held = AppState.Persisted()
        held.agyHold = AgyPause.Hold(network: true, spent: 2)
        let heldBack = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(held))
        assert(heldBack.agyHold == AgyPause.Hold(network: true, spent: 2), "the Antigravity hold survives a save and a load")
        var switched = AppState.Persisted()
        switched.hiddenPools = ["antigravity.Claude and GPT"]
        let reread = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(switched))
        assert(reread.hiddenPools == ["antigravity.Claude and GPT"], "a switched-off pool stays off after a relaunch")
        // prototype glass levels: the level and wallpapers survive a save; an unknown level costs only itself
        var levelled = AppState.Persisted()
        levelled.glassLevel = .frosted; levelled.wallpaperLight = "light-1a2b3c4d.jpg"; levelled.wallpaperDark = "pulse"
        levelled.railFocusLight = CGPoint(x: 0.1, y: 0.4)
        levelled.railFocusDark = CGPoint(x: 0.8, y: 0.6)
        levelled.setRailCrop(WallpaperCrop(focus: levelled.railFocusDark!, zoom: 2, rotated: true), light: false)
        let levelledBack = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(levelled))
        assert(levelledBack.glassLevel == .frosted && levelledBack.wallpaperLight == "light-1a2b3c4d.jpg" && levelledBack.wallpaperDark == "pulse")
        let classicGlass = ThemeStore.shared.themes.first { $0.id == "classic-glass" }!
        let classicSolid = ThemeStore.shared.themes.first { $0.id == "classic-solid" }!
        assert(levelledBack.glass(for: classicGlass, slot: .light)?.wallpaper == levelled.wallpaperLight)
        assert(levelledBack.glass(for: classicGlass, slot: .dark)?.wallpaper == levelled.wallpaperDark)
        assert(levelledBack.glass(for: classicGlass, slot: .light)?.wallpaperCrop.focus == levelled.railFocusLight)
        assert(levelledBack.glass(for: classicGlass, slot: .dark)?.wallpaperCrop.focus == levelled.railFocusDark)
        levelled.wallpaperDark = "replacement.jpg"
        assert(levelled.railRotatedDark == nil && levelled.railZoomDark == nil && levelled.railFocusDark == nil && levelled.railFocusLight == levelledBack.railFocusLight)
        let wide = CGSize(width: 400, height: 100), tall = CGSize(width: 20, height: 100)
        assert(WallpaperCrop().rect(image: wide, panel: tall) == CGRect(x: 190, y: 0, width: 20, height: 100))
        assert(WallpaperCrop(focus: .zero).rect(image: wide, panel: tall) == CGRect(x: 0, y: 0, width: 20, height: 100))
        assert(WallpaperCrop(focus: CGPoint(x: 1, y: 1)).rect(image: tall, panel: wide) == CGRect(x: 0, y: 95, width: 20, height: 5))
        assert(levelledBack.glass(for: classicGlass, slot: .light)?.wallpaperCrop.zoom == 1)
        assert(levelledBack.glass(for: classicGlass, slot: .dark)?.wallpaperCrop.zoom == 2)
        assert(levelledBack.glass(for: classicGlass, slot: .dark)?.wallpaperCrop.rotated == true)
        assert(levelledBack.glass(for: classicGlass, slot: .light)?.wallpaperCrop.rotated == false)
        let quarterTurn = WallpaperCrop(focus: .zero, zoom: 2, rotated: true)
        assert(quarterTurn.rect(image: tall, panel: wide) == CGRect(x: 0, y: 0, width: 10, height: 40))
        assert(quarterTurn.rect(image: wide, panel: tall) == CGRect(x: 0, y: 0, width: 200, height: 40))
        checkWallpaperRendering()
        let upperLeft = WallpaperCrop(focus: .zero, zoom: 2).rect(image: tall, panel: wide)
        let lowerRight = WallpaperCrop(focus: CGPoint(x: 1, y: 1), zoom: 2).rect(image: tall, panel: wide)
        assert(upperLeft == CGRect(x: 0, y: 0, width: 10, height: 2.5))
        assert(lowerRight == CGRect(x: 10, y: 97.5, width: 10, height: 2.5))
        assert(WallpaperCrop(zoom: 0).zoom == 1 && WallpaperCrop(zoom: 100).zoom == 4)
        // Reusing the same image, size and finish must still sample the new part of the picture.
        let split = CGContext(data: nil, width: 200, height: 40, bitsPerComponent: 8, bytesPerRow: 800,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        split.setFillColor(CGColor(gray: 0, alpha: 1))
        split.fill(CGRect(x: 0, y: 0, width: 200, height: 40))
        split.setFillColor(CGColor(gray: 1, alpha: 1))
        split.fill(CGRect(x: 100, y: 0, width: 100, height: 40))
        let picture = (image: split.makeImage()!, key: "split-wallpaper-check")
        assert(WallpaperReader.read(picture, size: tall, level: .liquid, crop: WallpaperCrop(focus: .zero))?.light == true)
        assert(WallpaperReader.read(picture, size: tall, level: .liquid, crop: WallpaperCrop(focus: CGPoint(x: 1, y: 0)))?.light == false)
        let focus = CGPoint(x: 0.23, y: 0.5)
        let mixed = WallpaperReader.read(picture, size: wide, level: .liquid, crop: WallpaperCrop(focus: focus))!
        let black = WallpaperReader.read(picture, size: wide, level: .liquid, crop: WallpaperCrop(focus: focus, zoom: 4))!
        assert(mixed.wash > 0 && black.light && black.wash == 0)
        assert(levelledBack.glass(for: classicSolid, slot: .light) == nil)

        assert(try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"glassLevel":"shiny","showPet":false}"#.utf8)).glassLevel == nil)
        // the words on a wallpaper: dark on white, light on black, and a wash only when neither reaches 4.5:1
        let onWhite = WallpaperReading.choose(dark: 1, bright: 1), onBlack = WallpaperReading.choose(dark: 0, bright: 0)
        assert(!onWhite.light && onWhite.wash == 0 && onWhite.contrast > 15 && onBlack.light && onBlack.wash == 0 && onBlack.contrast > 15)
        let busy = WallpaperReading.choose(dark: 0.02, bright: 0.6)   // dark shadows and bright highlights in one panel
        assert(busy.wash > 0 && busy.contrast >= WallpaperReading.target, "a busy picture gets a wash up to 4.5:1: \(busy)")
        assert(Wallpaper.isApples(URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic"))
               && !Wallpaper.isApples(URL(fileURLWithPath: "/Users/someone/Downloads/photo.jpeg")))
        assert(Wallpaper.isFileName("dark-1a2b3c4d.jpeg") && !Wallpaper.isFileName("../state.json") && !Wallpaper.isFileName(".hidden.jpg"))
        assert(Bundle.pulseResources.url(forResource: "Resources/wallpapers/default-dark", withExtension: "jpg") != nil
               && Bundle.pulseResources.url(forResource: "Resources/wallpapers/default-light", withExtension: "jpg") != nil, "Pulse's own two pictures ship")

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
        changed.agents.showOnRail = true
        changed.agents.waitMinutes = 10
        let back = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(changed))
        assert(back.breaks.enabled && back.breaks.ownIdeas == "Hum a tune" && back.battery == p.battery && back.dock == .bottom)
        assert(back.tucked == true && back.tuckPeek == true, "a tucked rail stays tucked across launches")
        assert(back.agents.showOnRail && back.agents.waitMinutes == 10 && back.agents.holdDuringCalls, "the agents ring stays on across launches")
        let newerAgents = try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"enabled":["claude"],"agentSettings":{"showOnRail":true,"waitMinutes":"soon","sound":"Glass"}}"#.utf8))
        assert(newerAgents.agents.showOnRail && newerAgents.agents.sound == "Glass" && newerAgents.agents.waitMinutes == 5, "one unreadable agents value costs only itself")

        // the agents card's shortcut: the default (⌥⌘K) unless changed, and held only while the agents ring is on the rail.
        // A saved state holds no value for the default, so it follows the default when that changes
        assert(p.agentsHotKey == nil && back.agentsHotKey == nil, "a state from before the shortcut has the default")
        assert(back.agentsShortcut(rexFound: true).combo == .agentsDefault && back.agentsShortcut(rexFound: true).note == nil)
        assert(back.agentsShortcut(rexFound: false).combo == nil && back.agentsShortcut(rexFound: false).note == nil, "without Rex there is no ring, and no shortcut is held")
        assert(p.agentsShortcut(rexFound: true).combo == nil, "nor with the ring switched off")
        var hidden = back
        hidden.showOverlay = false
        assert(hidden.agentsShortcut(rexFound: true).combo == nil, "nor with the rings hidden")
        var keyed = back
        keyed.agentsHotKey = HotKeyCombo(keyCode: 11, carbonModifiers: 4352, label: "⌃⌘B")
        let rekeyed = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(keyed))
        assert(rekeyed.agentsShortcut(rexFound: true).combo?.label == "⌃⌘B", "a changed shortcut stays across launches")
        keyed.agentsHotKey = HotKeyCombo.none
        let cleared = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(keyed))
        assert(cleared.agentsHotKey == HotKeyCombo.none && cleared.agentsShortcut(rexFound: true).combo == nil && cleared.agentsShortcut(rexFound: true).note == nil,
               "a cleared shortcut stays cleared: it isn't the default again")
        // the voice shortcut's own combination is never taken from it: Settings says so instead
        keyed.agentsHotKey = keyed.voiceHotKey   // this state's saved voice shortcut, ⌥⇧Space
        keyed.showPet = true
        assert(keyed.agentsShortcut(rexFound: true).combo == nil && keyed.agentsShortcut(rexFound: true).note?.contains("⌥⇧Space") == true)
        keyed.voiceHotKey = nil   // the voice shortcut back at its default, ⌃⌥Space
        assert(keyed.agentsShortcut(rexFound: true).combo?.label == "⌥⇧Space", "free once the voice shortcut is another one")
        keyed.agentsHotKey = HotKeyCombo.voiceDefault
        assert(keyed.agentsShortcut(rexFound: true).combo == nil && keyed.agentsShortcut(rexFound: true).note?.contains("⌃⌥Space") == true)
        keyed.showPet = false
        assert(keyed.agentsShortcut(rexFound: true).combo == .voiceDefault, "or once the pet, and its shortcut with it, is hidden")

        // the oldest form: only the keys Pulse has always written
        let oldest = try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"enabled":["claude"],"order":["claude"],"alwaysOnTop":true,"showOverlay":true}"#.utf8))
        assert(oldest.battery == BatterySettings() && oldest.breaks == BreakSettings() && oldest.dock == nil && oldest.appearance == .solid
               && oldest.tucked == nil && oldest.tuckPeek == nil)
        checkUnreadableValues()
        checkTrackRendering()
        checkSkins()
        ThemeChecks.run()
        checkSettingsPanes()
        print("Settings state checks passed: saved values preserved, Tint migrated, unreadable values cost only themselves and are kept in a copy, plain track grey without keylines in both looks")
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

    /// Settings' sidebar: every pane is there, in order, with a symbol that exists; a pane opened by name (Break
    /// settings… opens Breaks) selects its row; and a row chosen in the list opens its pane.
    @MainActor private static func checkSettingsPanes() {
        _ = NSApplication.shared
        // the layout itself fills whatever the window is, down to the minimum, so the pane can scroll
        let layout = NSHostingController(rootView: SettingsLayout(selection: .constant(.agents)) { Form { Text("pane") }.formStyle(.grouped) })
        for room in [600.0, 420] {
            assert(layout.sizeThatFits(in: CGSize(width: SettingsPane.sidebarWidth + 1 + SettingsPane.paneWidth, height: room)).height == room)
        }
        // the sidebar's list with Launch at login under it fits in the shortest window
        let sidebar = NSHostingController(rootView: SettingsSidebar(selection: .constant(.appearance), footer: AnyView(Toggle("Launch at login", isOn: .constant(true)).toggleStyle(.checkbox).padding(.horizontal, 10))))
        let needs = sidebar.sizeThatFits(in: CGSize(width: SettingsPane.sidebarWidth, height: 0)).height
        assert(needs <= SettingsPane.minHeight, "the sidebar needs \(needs) pt, more than the shortest window")

        assert(SettingsPane.allCases.map(\.title) == ["Appearance", "Accounts", "Rings", "Battery", "Codex pet", "Agents", "Breaks"],
               "no General pane: Launch at login is under the sidebar's list")
        for pane in SettingsPane.allCases { assert(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil, "\(pane.symbol) exists") }

        // captions take the theme's secondary ink: Classic's grey in Classic, as before; dark grey on Groove White
        var env = EnvironmentValues()
        assert(PulseSecondary().resolve(in: env) == PulsePalette.secondary.resolve(in: env), "Classic's captions are Classic's grey")
        env.pulseSkin = .grooveWhite
        assert(PulseSecondary().resolve(in: env) == PulseSkin.grooveWhite.secondary.resolve(in: env), "Groove White's captions are its own")
        assert(PulseSkin.grooveWhite.ink.secondary.contrast(with: PulseSkin.grooveWhite.groove!.slab) >= 4.5)

        // ↓ from Appearance reaches every pane in order and stops at Breaks; ↑ goes back and stops at Appearance
        var walked = [SettingsPane.appearance]
        for _ in 0 ..< 10 { walked.append(SettingsPane.allCases.moved(from: walked.last!, by: 1)) }
        assert(Array(walked.prefix(7)) == SettingsPane.allCases && walked.last == .breaks, "↓ reaches every pane: \(walked.map(\.title))")
        assert(SettingsPane.allCases.moved(from: .breaks, by: -6) == .appearance && SettingsPane.allCases.moved(from: .appearance, by: -1) == .appearance)

        // Scan the rendered selection and its label on both ends of the theme brightness range.
        final class Box: ObservableObject { @Published var pane = SettingsPane.appearance }
        struct Host: View {
            @ObservedObject var box: Box
            let scheme: ColorScheme
            var body: some View {
                SettingsSidebar(selection: $box.pane).frame(height: 600)
                    .background(scheme == .dark ? Color.black : .white)
                    .environment(\.colorScheme, scheme)
            }
        }
        for scheme in [ColorScheme.dark, .light] {
            let box = Box()
            let host = NSHostingView(rootView: Host(box: box, scheme: scheme))
            host.frame = NSRect(x: 0, y: 0, width: SettingsPane.sidebarWidth, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            var centres: [Int] = []
            for pane in SettingsPane.allCases {
                box.pane = pane
                for _ in 0 ..< 6 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    host.layoutSubtreeIfNeeded()
                }
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let scale = CGFloat(rep.pixelsHigh) / host.bounds.height
                func sample(_ x: Int, _ y: Int) -> NSColor {
                    rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))!.usingColorSpace(.sRGB)!
                }
                // Clear space after the longest label, away from the keyboard outline.
                let rows = (0 ..< Int(host.bounds.height)).filter { y in
                    let c = sample(158, y)
                    let change = scheme == .dark ? c.redComponent : 1 - c.redComponent
                    return (0.04 ... 0.50).contains(change)
                        && abs(c.redComponent - c.greenComponent) < 0.015 && abs(c.redComponent - c.blueComponent) < 0.015
                }
                let samples = Set(rows)
                let interior = rows.filter { samples.contains($0 - 2) && samples.contains($0 + 2) }
                guard let first = interior.first, let last = interior.last else { fatalError("Missing neutral highlight for \(pane), \(scheme)") }
                assert(last - first < 40 && rows.count >= 14, "Expected one highlight for \(pane), \(scheme), got \(first)...\(last) (\(rows.count) samples)")
                let centre = (first + last) / 2
                centres.append(centre)
                func luminance(_ c: NSColor) -> CGFloat {
                    let rgb = Color(c).resolve(in: EnvironmentValues())
                    return CGFloat(0.2126 * rgb.linearRed + 0.7152 * rgb.linearGreen + 0.0722 * rgb.linearBlue)
                }
                let fill = luminance(sample(158, centre))
                let readable = (centre-7 ... centre+7).contains { y in
                    (42 ..< 125).contains { x in
                        let ink = luminance(sample(x, y))
                        return (max(fill, ink) + 0.05) / (min(fill, ink) + 0.05) >= 4.5
                    }
                }
                assert(readable, "Selected label must contrast with its fill: \(pane), \(scheme)")
            }
            let gaps = zip(centres.dropFirst(), centres).map { $0 - $1 }
            assert(gaps.allSatisfy { $0 > 0 && abs($0 - gaps[0]) <= 1 }, "Each pane highlights its own row")
            window.close()
        }

        let width = SettingsPane.sidebarWidth + 1 + SettingsPane.paneWidth

        // results people come back to (a theme import, a test push) outlive the pane they were shown in: the pane is
        // rebuilt each time it's chosen, so they're kept in SettingsResults, which a rebuilt pane reads
        let results = SettingsResults.shared
        final class Panes: ObservableObject { @Published var pane = SettingsPane.appearance }
        struct Switcher: View {
            @ObservedObject var panes: Panes
            let store: ThemeStore
            var body: some View {
                SettingsLayout(selection: $panes.pane) {
                    switch panes.pane {
                    case .appearance: AppearanceSettings(saved: .constant(AppState.Persisted()), themes: store)
                    default: Form { BatterySettingsSection(settings: .constant(BatterySettings())) }
                    }
                }
            }
        }
        let panes = Panes(), store = ThemeStore(folder: FileManager.default.temporaryDirectory.appending(path: "panes-\(UUID().uuidString)"))
        let switcher = NSHostingView(rootView: Switcher(panes: panes, store: store))
        switcher.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let switchWindow = NSWindow(contentRect: switcher.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        switchWindow.contentView = switcher
        func spin() { for _ in 0 ..< 6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); switcher.layoutSubtreeIfNeeded() } }
        spin()
        results.themeImport = "Imported Ember as ember.json."
        results.testPush = "Sent"
        let originalFrame = switchWindow.frame
        for pane in [SettingsPane.battery, .appearance, .battery, .appearance] {
            panes.pane = pane
            spin()
            assert(switchWindow.frame == originalFrame, "changing panes preserves the window frame")
        }
        assert(results.themeImport == "Imported Ember as ember.json." && results.testPush == "Sent", "results survive pane switches")
        switchWindow.close()
    }

    /// Skins are plain values with fixed keys, so a skin can later come from a JSON file; the setting picks one by name.
    @MainActor private static func checkSkins() {
        let p = try! JSONDecoder().decode(AppState.Persisted.self, from: Data(#"{"enabled":[],"order":[],"alwaysOnTop":true,"showOverlay":true}"#.utf8))
        let themes = ThemeStore.shared   // the built-ins only: nothing read from a folder here
        assert(p.skin == nil && themes.skin(p.themeChoice) == .classic, "a state from before skins stays Classic")
        var groove = AppState.Persisted()
        groove.skin = "groove"
        let reread = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(groove))
        themes.setSystem(.dark)
        assert(reread.skin == "groove" && themes.skin(reread.themeChoice) == .groove, "Groove stays picked after a relaunch")
        let unknown = ThemeChoice(mode: .auto, light: "a-skin-this-version-lacks", dark: "a-skin-this-version-lacks", classic: "classic-solid")
        assert(themes.skin(unknown) == .classic && themes.theme(for: .dark, in: unknown).id == "classic-solid",
               "an unknown theme draws, and shows as, the person's Classic")

        for (_, file) in PulseThemeFile.builtIn {
            let json = try! JSONEncoder().encode(file)
            assert(try! JSONDecoder().decode(PulseThemeFile.self, from: json) == file, "\(file.name) survives JSON")
        }
        let file = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(PulseThemeFile.groove)) as! [String: Any]
        assert(file["name"] as? String == "Groove" && file["appearance"] as? String == "dark" && file["format"] as? Int == 1)
        let accents = file["accents"] as! [String: Any], g = file["groove"] as! [String: Any]
        assert(accents["claude"] as? String == "#CF7C5E" && accents["antigravity2"] as? String == "#79AAD2", "colours are hex strings")
        assert((g["wall"] as? [Any])?.count == 5 && (g["wall"] as! [Any])[3] as? String == "#000000", "shadows are [x, y, blur, colour, opacity]")
        assert((g["outer"] as? [String: Any])?["channel"] as? Double == 16, "depths are numbers")
        // a theme file with a bad colour or shadow is refused, not drawn black
        let broken = String(data: try! JSONEncoder().encode(PulseThemeFile.groove), encoding: .utf8)!
        assert((try? JSONDecoder().decode(PulseThemeFile.self, from: Data(broken.replacingOccurrences(of: "#CF7C5E", with: "#CF7C5").utf8))) == nil)
        assert((try? JSONDecoder().decode(PulseThemeFile.self, from: Data(broken.replacingOccurrences(of: "[4.4,4.4,3.2,\"#000000\",0.8]", with: "[4.4,4.4,\"#000000\",0.8]").utf8))) == nil)

        // Classic's colours are exactly the values in the code before skins with ClassicColours.patch (ClassicRenderChecks.sh
        // compares whole renders)
        let env = EnvironmentValues()
        func same(_ a: Color, _ b: Color) -> Bool { a.resolve(in: env) == b.resolve(in: env) }
        let c = PulseSkin.classic
        assert(same(c.accent(.claude), Color(.displayP3, red: 1.0, green: 0.40, blue: 0.16)))
        assert(same(c.accent(.codex), Color(.displayP3, red: 0.08, green: 0.32, blue: 1.0)))
        assert(same(c.accent(.grok), Color(.displayP3, red: 1.0, green: 0.72, blue: 0.10)))
        assert(same(c.accent(.antigravity), Color(.displayP3, red: 0.46, green: 0.16, blue: 0.98)))
        assert(same(c.accent(.antigravity, pool: 1), Color(.displayP3, red: 0.20, green: 0.80, blue: 0.95)))
        assert(same(c.surface.color, Color(.sRGB, red: 6.0 / 255, green: 6.0 / 255, blue: 8.0 / 255, opacity: 1)))
        assert(same(c.track.color, Color(.sRGB, red: 48.0 / 255, green: 48.0 / 255, blue: 51.0 / 255, opacity: 1)))
        assert(same(c.secondary, Color(.sRGB, red: 0.9, green: 0.9, blue: 0.9, opacity: 1)))
        assert(c.groove == nil && AccountID.codex.accent == c.accent(.codex))
        // the colour forms a skin file can use, and ones it can't
        for good in ["#FF6629", "#FF662980", "p3:#FF6629", "srgb:0.07,0.07,0.08", "p3:1,0.40,0.16", "0.5,0.5,0.5,0.25"] {
            assert((try? SkinColor(good)) != nil, "\(good) is a colour")
        }
        for bad in ["#+12345", "#FF66", "FF6629", "p3:1,0.4", "srgb:1.2,0,0", "srgb:-0.1,0,0", "p3:1,0.4,0.16,1,1", "lab:1,2,3"] {
            assert((try? SkinColor(bad)) == nil, "\(bad) is refused")
        }

        // Increase Contrast: full colours, white ink, nothing shading the colour
        let contrast = themes.skin(ThemeChoice(mode: .dark, light: "groove-white", dark: "groove"), contrast: .increased)
        assert(contrast.accents == PulseSkin.classic.accents && contrast.groove?.wall == nil && contrast.ink.primary == "#FFFFFF")
        assert(contrast.groove?.raise == PulseSkin.groove.groove?.raise, "the slab keeps its shape")

        // A Groove bar at 0 shows no fill, not a dot; at 50 the fill starts at the slot's left end
        for (value, lit) in [(0.0, false), (50, true)] {
            let bar = ImageRenderer(content: GrooveBar(groove: PulseSkin.groove.groove!, value: value, colour: Color(rgb: 0xFF0000))
                .frame(width: 200).padding(8).background(Color.black))
            bar.scale = 2
            let image = bar.cgImage!
            let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // the dot's middle: 8 pt padding, 2 pt inset, half the 6 pt fill, at 2x
            let pixel = context(ctx, x: (8 + 2 + 3) * 2, y: image.height / 2, width: image.width)
            assert((pixel[0] > 150) == lit, "Groove bar at \(value): \(pixel)")
        }

        // A Groove ring's empty channel is its dark floor, not Classic's grey track, over a light backdrop too
        let renderer = ImageRenderer(content: RingView(account: .claude, percent: 0, size: 52, showPercent: false).padding(8).background(Color.white)
            .environment(\.colorScheme, .dark).environment(\.pulseSkin, .groove))
        renderer.scale = 2
        let image = renderer.cgImage!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // mid-channel on the right: the centre of the ring plus 46.5 of its 100 units, at 2x
        let x = Int((8 + 26 + 0.465 * 52) * 2), y = image.height / 2
        let floor = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self).advanced(by: (y * image.width + x) * 4), count: 4))
        assert(floor[3] == 255 && floor[0] < 30 && floor[1] < 30 && floor[2] < 30, "an empty Groove channel is dark and opaque: \(floor)")
    }

    /// Orientation on the rail and wallpaper coverage under the menu window’s native rim.
    @MainActor private static func checkWallpaperRendering() {
        func bitmap(_ w: Int, _ h: Int) -> CGContext {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        }
        let source = bitmap(24, 96)
        source.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        source.fill(CGRect(x: 0, y: 48, width: 24, height: 48))
        source.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        source.fill(CGRect(x: 0, y: 0, width: 24, height: 48))
        let layer = WallpaperLayer(level: .liquid, picture: source.makeImage(), reading: nil,
                                   shape: Rectangle(), crop: WallpaperCrop(rotated: true))
        let rendered = ImageRenderer(content: layer.frame(width: 96, height: 24)).cgImage!
        let result = bitmap(96, 24)
        result.draw(rendered, in: CGRect(x: 0, y: 0, width: 96, height: 24))
        let left = context(result, x: 20, y: 12, width: 96)
        let right = context(result, x: 76, y: 12, width: 96)
        assert(left[0] > 240 && left[2] < 15 && right[0] < 15 && right[2] > 240,
               "the top of the upright wallpaper maps to the left of the rail: \(left), \(right)")

        source.setFillColor(gray: 1, alpha: 1)
        source.fill(CGRect(x: 0, y: 0, width: 24, height: 96))
        let menu = WallpaperLayer(level: .liquid, picture: source.makeImage(), reading: nil,
                                  shape: Rectangle(), drawsGlassRim: false)
        let bright = ImageRenderer(content: menu.frame(width: 96, height: 24).background(.black)).cgImage!
        result.draw(bright, in: CGRect(x: 0, y: 0, width: 96, height: 24))
        for (x, y) in [(48, 0), (48, 23), (0, 12), (95, 12)] {
            let pixel = context(result, x: x, y: y, width: 96)
            assert(pixel == [255, 255, 255, 255], "wallpaper reaches each edge of the menu surface")
        }

        // An existing saved rail selection also drives the wide card and tall menu at their own aspect ratios.
        let crop = WallpaperCrop(focus: CGPoint(x: 0.2, y: 0.18), zoom: 2.72, rotated: true)
        let glass = GlassSetting(level: .liquid, wallpaper: "pulse", wallpaperCrop: crop, light: false)
        let picture = Wallpaper.picture(glass)!.image
        for (width, height) in [(40, 180), (180, 64), (80, 190)] {
            let surface = Color.clear.frame(width: CGFloat(width), height: CGFloat(height))
                .pulseSurface(in: Rectangle(), bordered: false).environment(\.glassSetting, glass)
            let expected = WallpaperLayer(level: .liquid, picture: picture, reading: nil, shape: Rectangle(), crop: crop, drawsGlassRim: false)
            func samples(_ view: some View) -> [[UInt8]] {
                let cg = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height))).cgImage!
                let buffer = bitmap(width, height)
                buffer.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                return [1, 2, 3].map { n in context(buffer, x: width * n / 4, y: height * n / 4, width: width) }
            }
            assert(samples(surface) == samples(expected), "every linked surface must render the selected detail")
            let centered = WallpaperLayer(level: .liquid, picture: picture, reading: nil, shape: Rectangle(), drawsGlassRim: false)
            assert(samples(expected) != samples(centered), "the chosen fixture must distinguish a centered crop")
        }

        // Resizing a panel magnifies the same softened detail. The transition on the photograph stays proportional.
        let edge = bitmap(512, 512)
        edge.setFillColor(gray: 0, alpha: 1)
        edge.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        edge.setFillColor(gray: 1, alpha: 1)
        edge.fill(CGRect(x: 256, y: 0, width: 256, height: 512))
        let edgeImage = edge.makeImage()!
        func transition(_ level: GlassLevel, width: Int, height: Int) -> Int {
            let surface = WallpaperLayer(level: level, picture: edgeImage, reading: nil, shape: Rectangle(),
                                         crop: WallpaperCrop(zoom: 2), usesWallpaperFinish: true, drawsGlassRim: false)
            let cg = ImageRenderer(content: surface.frame(width: CGFloat(width), height: CGFloat(height))).cgImage!
            let buffer = bitmap(width, height)
            buffer.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (0..<width).filter { (24...231).contains(context(buffer, x: $0, y: height / 2, width: width)[0]) }.count
        }
        let resting = GlassLevel.allCases.map { transition($0, width: 96, height: 320) }
        let hovered = GlassLevel.allCases.map { transition($0, width: 192, height: 640) }
        assert(resting[0] < resting[1] && resting[1] < resting[2], "each finish has a distinct edge: \(resting)")
        for (small, big) in zip(resting, hovered) {
            assert(abs(2 * small - big) <= 2, "hover must retain the finish of the same source detail: \(resting), \(hovered)")
        }

        // A label on difficult pixels gets an outline. The same label on legible pixels leaves its background alone.
        for lightInk in [true, false] {
            func label(_ outline: Bool, matchingInk: Bool) -> [UInt8] {
                let ink = lightInk ? Color.white : .black
                let contrasting = lightInk ? Color.black : .white
                let view = Text("98%").foregroundStyle(ink).frame(width: 80, height: 30)
                    .backgroundPreferenceValue(Text.LayoutKey.self) { labels in
                        if outline { WallpaperLabelContrast(labels: labels, lightInk: lightInk) }
                    }
                    .background(matchingInk ? ink : contrasting)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let cg = renderer.cgImage!
                let buffer = bitmap(cg.width, cg.height)
                buffer.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                return Array(UnsafeBufferPointer(start: buffer.data!.assumingMemoryBound(to: UInt8.self), count: buffer.bytesPerRow * cg.height))
            }
            let helped = label(true, matchingInk: true), plain = label(false, matchingInk: true)
            assert(zip(helped, plain).contains { abs(Int($0) - Int($1)) > 70 }, "the outline distinguishes otherwise invisible letters")
            assert(helped.prefix(160 * 4 * 5) == plain.prefix(160 * 4 * 5), "clear wallpaper above the letters stays untouched")
            assert(label(true, matchingInk: false) == label(false, matchingInk: false), "legible letters receive no visible outline")
        }
    }

    private static func context(_ ctx: CGContext, x: Int, y: Int, width: Int) -> [UInt8] {
        Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self).advanced(by: (y * width + x) * 4), count: 4))
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
                        assert(sample == [48, 48, 51, 255],
                               "ring and battery tracks must be the one fixed track grey, opaque in both looks and sizes over any backdrop: \(sample)")
                        let edgeX = Int(ceil(8 - size * 0.12))
                        let edgePixel = context.data!.assumingMemoryBound(to: UInt8.self)
                            .advanced(by: ((image.height / 2) * image.width + edgeX) * 4)
                        let edge = Array(UnsafeBufferPointer(start: edgePixel, count: 4))
                        assert(edge == [48, 48, 51, 255],
                               "the outer track must remain the plain track grey without a light keyline: \(edge)")
                    }
                }
            }
        }
    }
}
