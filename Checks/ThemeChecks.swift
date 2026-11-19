// Theme files: built into SettingsStateChecks (it builds every source but PulseApp.swift) and run from its main.
import SwiftUI

enum ThemeChecks {
    @MainActor static func run() {
        checkBuiltIns()
        checkRefusals()
        checkContrastFloor()
        checkGuide()
        checkFolder()
        checkOwnership()
        checkAppearance()
        print("Theme checks passed: built-ins round-trip, every refusal on the list, the contrast floor, the guide's example and keys, last good, .error files, live reload, built-in names, appearance")
    }

    // MARK: helpers

    /// A built-in's JSON with one value replaced (nil: the key removed). `path` is dot-separated; numbers index lists.
    static func edited(_ set: PulseSkinSet, _ path: String, _ value: Any?) -> Data {
        func put(_ object: Any, _ keys: ArraySlice<Substring>, _ value: Any?) -> Any {
            guard let key = keys.first else { return value ?? NSNull() }
            if var list = object as? [Any], let i = Int(key) { list[i] = put(list[i], keys.dropFirst(), value); return list }
            var dict = object as! [String: Any]
            if keys.count == 1, value == nil { dict[String(key)] = nil } else { dict[String(key)] = put(dict[String(key)] as Any, keys.dropFirst(), value) }
            return dict
        }
        let object = try! JSONSerialization.jsonObject(with: ThemeStore.file(set))
        return try! JSONSerialization.data(withJSONObject: put(object, path.split(separator: ".")[...], value))
    }

    /// Why a theme file is refused; fails the check if it's accepted.
    static func refusal(_ data: Data, _ what: String) -> String {
        guard case .failure(let problem) = ThemeStore.decode(data) else { fatalError("accepted: \(what)") }
        return problem.text
    }

    static func expectRefused(_ set: PulseSkinSet, _ path: String, _ value: Any?, mentioning words: [String]) {
        let text = refusal(edited(set, path, value), "\(path) = \(String(describing: value))")
        for w in words { assert(text.contains(w), "refusing \(path) = \(String(describing: value)) should mention \(w): \(text)") }
    }

    static func waitUntil(_ seconds: Double = 5, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    static let guideExample: Data = {
        let text = ThemeGuide.text
        let start = text.range(of: "```json\n")!.upperBound, end = text.range(of: "\n```", range: start ..< text.endIndex)!.lowerBound
        return Data(text[start ..< end].utf8)
    }()

    // MARK: the checks

    static func checkBuiltIns() {
        for (id, set) in PulseSkinSet.builtIn {
            guard case .success(let read) = ThemeStore.decode(ThemeStore.file(set)) else {
                fatalError("\(id) is refused by its own checks: \(refusal(ThemeStore.file(set), id))")
            }
            assert(read == set, "\(id) round-trips through its own JSON")
        }
        let text = String(decoding: ThemeStore.file(.groove), as: UTF8.self)
        assert(text.contains(##""wall" : [4.4, 4.4, 3.2, "#000000", 0.8]"##), "a shadow is written on one line")
        assert(text.contains(#""name" : "Groove""#) && text.contains(#""light" : {"#), "Groove's file has its light half")
    }

    static func checkRefusals() {
        // Sol's list: what the decoder used to accept
        expectRefused(.groove, "dark.groove.barSlot", -10, mentioning: ["dark.groove.barSlot", "outside"])
        expectRefused(.groove, "dark.groove.outer.channel", -16, mentioning: ["dark.groove.outer.channel"])
        expectRefused(.groove, "dark.groove.wall", [4.4, 4.4, -3.2, "#000000", 0.8], mentioning: ["dark.groove.wall blur"])
        expectRefused(.groove, "dark.groove.wall", [4.4, 4.4, 3.2, "#000000", 1.5], mentioning: ["dark.groove.wall opacity"])
        expectRefused(.groove, "dark.groove.grain", 2, mentioning: ["dark.groove.grain"])
        expectRefused(.groove, "dark.stale", -0.1, mentioning: ["dark.stale"])
        expectRefused(.groove, "dark.groove.outer.radius", 70, mentioning: ["dark.groove.outer"])
        expectRefused(.groove, "dark.groove.wall", [4.4, 4.4, 3.2, "#000000", 0.8, 1], mentioning: ["dark.groove.wall", "exactly"])
        expectRefused(.groove, "dark.groove.floor", "#+12345", mentioning: ["dark.groove.floor", "not a colour"])
        expectRefused(.groove, "dark.groove.wall", [4.4, 4.4, 3.2, "#+12345", 0.8], mentioning: ["dark.groove.wall", "not a colour"])
        expectRefused(.groove, "dark.accents.codex", "#4E6FC", mentioning: ["dark.accents.codex"])
        // the rest of the geometry, each its own refusal
        expectRefused(.groove, "dark.groove.inner.radius", 40, mentioning: ["dark.groove.inner", "into the outer channel"])
        expectRefused(.groove, "dark.groove.outer.tube", 17, mentioning: ["dark.groove.outer.tube", "wider than its channel"])
        expectRefused(.groove, "dark.groove.hubSingle", 45, mentioning: ["dark.groove.hubSingle", "covers"])
        expectRefused(.groove, "dark.groove.hubDouble", 28, mentioning: ["dark.groove.hubDouble", "covers"])
        expectRefused(.groove, "dark.groove.barFill", 12, mentioning: ["dark.groove.barFill", "wider"])
        expectRefused(.groove, "dark.groove.barRadius", 6, mentioning: ["dark.groove.barRadius", "half"])
        expectRefused(.groove, "dark.groove.drop.0", [12, 16, 18, "#000000", 0.5], mentioning: ["dark.groove.drop[0]", "12"])
        expectRefused(.grooveBlack, "light.groove.porthole.radius", 40, mentioning: ["light.groove.porthole.radius", "smaller"])
        expectRefused(.groove, "dark.groove.type.0", [-2, -0.035, 0, "#FFFFFF", 0.85], mentioning: ["dark.groove.type[0] x"])
        expectRefused(.groove, "dark.groove.raise", Array(repeating: [1, 1, 1, "#FFFFFF", 0.1], count: 5), mentioning: ["at most 4"])
        // the format itself
        expectRefused(.groove, "dark.groove.slabtop", "#000000", mentioning: ["dark.groove.slabtop", "not a key"])
        expectRefused(.groove, "light.groove.flor", "#000000", mentioning: ["light.groove.flor", "not a key"])
        expectRefused(.groove, "dark.groove.floor", nil, mentioning: ["dark.groove.floor", "missing"])
        expectRefused(.groove, "dark.stale", "half", mentioning: ["dark.stale", "a number"])
        expectRefused(.groove, "name", "  ", mentioning: ["name"])
        expectRefused(.groove, "light.groove", nil, mentioning: ["light.groove", "dark only"])
        assert(refusal(Data("{\"name\": \"x\",".utf8), "broken JSON").contains("not JSON"))
        var big = Data(ThemeStore.file(.groove))
        big.append(Data(repeating: 0x20, count: ThemeStore.maxFileBytes))
        assert(refusal(big, "a big file").contains("64 KB"))
        // what stays allowed: the wall left out or null, and every optional colour
        for wall in [nil, NSNull()] as [Any?] {
            if case .failure(let p) = ThemeStore.decode(edited(.groove, "dark.groove.wall", wall)) { fatalError("no wall is allowed: \(p.text)") }
        }
    }

    static func checkContrastFloor() {
        // text hard to read on the slab, each kind on its own
        expectRefused(.groove, "dark.ink.secondary", "#45484F", mentioning: ["dark.ink.secondary", "text needs 4.5:1"])
        expectRefused(.groove, "dark.ink.primary", "#202226", mentioning: ["dark.ink.primary", "1.00:1"])
        expectRefused(.groove, "light.ink.alert", "#FF6B61", mentioning: ["light.ink.alert", "text needs 4.5:1"])
        expectRefused(.groove, "dark.stale", 0.3, mentioning: ["dark.stale", "text needs 4.5:1"])
        // dark Groove's amber on White's floor: the reason Groove's light half deepens its colours
        expectRefused(.groove, "light.accents.grok", "#DBB572", mentioning: ["light.accents.grok", "light.groove.floor", "needs 3:1"])
        expectRefused(.groove, "dark.accents.codex", "#2A3A66", mentioning: ["dark.accents.codex", "dark.groove.barFloor"])
        expectRefused(.groove, "dark.groove.onFace", "#2B2D32", mentioning: ["dark.groove.onFace", "a mark on the hub"])
        expectRefused(.groove, "dark.ink.secondary", "#E6E6E640", mentioning: ["must be opaque"])
        // a flat theme is held to its surface
        expectRefused(.classic, "dark.accents.codex", "#202060", mentioning: ["dark.accents.codex", "dark.surface"])
    }

    static func checkGuide() {
        guard case .success(let ember) = ThemeStore.decode(guideExample) else { fatalError("the guide's example is refused: \(refusal(guideExample, "guide"))") }
        assert(ember.name == "Ember" && ember.dark.groove == nil && ember.light == nil)
        for key in ThemeStore.knownKeys {
            let last = key.split(separator: ".").last!
            assert(ThemeGuide.text.contains(last), "the guide describes \(key)")
        }
    }

    @MainActor static func checkFolder() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pulse-theme-check-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(folder: folder)
        let fm = FileManager.default
        store.writeExamples()
        for (id, set) in PulseSkinSet.builtIn { assert(try! Data(contentsOf: folder.appending(path: "\(id).json")) == ThemeStore.file(set), "\(id) written as an example") }
        assert(fm.fileExists(atPath: folder.appending(path: "AGENTS.md").path), "the guide is written into the folder")
        store.reload()
        assert(store.themes.map(\.id) == ["classic", "groove", "groove-black"] && store.problems.isEmpty, "the examples are the built-ins: \(store.problems)")

        let ember = folder.appending(path: "ember.json"), error = folder.appending(path: "ember.error")
        store.watch()
        // live reload: a new file, then an edit, picked up without a call
        try! guideExample.write(to: ember)
        assert(waitUntil { store.theme("ember").id == "ember" }, "a new theme file is listed by itself")
        assert(store.themes.map(\.id) == ["classic", "groove", "groove-black", "ember"])
        let renamed = String(decoding: guideExample, as: UTF8.self).replacingOccurrences(of: "\"Ember\"", with: "\"Ember Two\"")
        try! Data(renamed.utf8).write(to: ember)
        assert(waitUntil { store.theme("ember").set.name == "Ember Two" }, "an edit is picked up by itself")
        // a bad edit: the last good version stays, the reason goes beside the file, Settings has it
        try! Data(renamed.replacingOccurrences(of: "#FF7A45", with: "#FF7A4").utf8).write(to: ember)
        assert(waitUntil { store.problems["ember"] != nil }, "a bad edit is noticed")
        assert(store.theme("ember").set.name == "Ember Two", "the last good version stays in use")
        assert(store.skin("ember").accents.claude == "#FF7A45", "the bad value never draws")
        let reason = try! String(contentsOf: error, encoding: .utf8)
        assert(reason.contains("dark.accents.claude") && reason.contains("last good version"), "the .error names the key: \(reason)")
        // fixed: the error file goes
        try! guideExample.write(to: ember)
        assert(waitUntil { !fm.fileExists(atPath: error.path) && store.problems["ember"] == nil }, "a fixed file's .error is removed")
        assert(store.theme("ember").set.name == "Ember")
        // a theme that was never good: Classic draws, and the error says so
        let broken = folder.appending(path: "broken.json")
        try! Data("{\"name\": \"Broken\"}".utf8).write(to: broken)
        assert(waitUntil { store.problems["broken"] != nil })
        assert(store.theme("broken").id == "classic" && store.skin("broken") == .classic)
        assert(try! String(contentsOf: folder.appending(path: "broken.error"), encoding: .utf8).contains("draws Classic"))
        try! fm.removeItem(at: broken)
        assert(waitUntil { !fm.fileExists(atPath: folder.appending(path: "broken.error").path) }, "a removed file's .error is removed")

        // a built-in's name: the built-in draws, the edit is reported, and the next launch's examples keep the edit aside
        try! edited(.groove, "name", "My Groove").write(to: folder.appending(path: "groove.json"))
        store.reload()
        assert(store.theme("groove").set == .groove && store.problems["groove"]?.contains("Pulse's own") == true)
        store.writeExamples()
        assert(try! Data(contentsOf: folder.appending(path: "groove.json")) == ThemeStore.file(.groove))
        assert(try! fm.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("groove.json.replaced-") }, "the edited copy is kept")
        store.reload()
        assert(store.problems["groove"] == nil)

        // at most 50 theme files are read
        for i in 0 ..< ThemeStore.maxThemes { try! guideExample.write(to: folder.appending(path: String(format: "many-%02d.json", i))) }
        store.reload()
        assert(store.themes.count == 3 + ThemeStore.maxThemes, "\(store.themes.count) themes listed")
        assert(store.problems.values.filter { $0.contains("at most \(ThemeStore.maxThemes)") }.count == 1, "the 51st file is reported, not read")
    }

    /// Pulse removes and replaces only what it wrote (Sol's review of 4f91bdb: an unrelated `.error` file, a `.error`
    /// folder, and an edited built-in whose backup name was taken were all lost).
    @MainActor static func checkOwnership() {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "pulse-theme-owned-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: folder) }
        let store = ThemeStore(folder: folder)
        store.writeExamples()
        // someone else's .error file and a .error folder: kept through reloads, fixed or not
        let unrelated = folder.appending(path: "unrelated.error"), notes = folder.appending(path: "notes.error")
        try! Data("disposable file".utf8).write(to: unrelated)
        try! fm.createDirectory(at: notes, withIntermediateDirectories: false)
        try! Data("disposable note".utf8).write(to: notes.appending(path: "note.txt"))
        // a .error file Pulse didn't write, beside a broken theme: left as it is, the problem still in Settings
        let theirs = folder.appending(path: "mine.error")
        try! Data("my own notes about mine.json".utf8).write(to: theirs)
        try! Data("{}".utf8).write(to: folder.appending(path: "mine.json"))
        store.reload()
        store.reload()
        assert(try! Data(contentsOf: unrelated) == Data("disposable file".utf8), "an unrelated .error file is kept")
        assert(try! Data(contentsOf: notes.appending(path: "note.txt")) == Data("disposable note".utf8), "a .error folder is kept")
        assert(try! Data(contentsOf: theirs) == Data("my own notes about mine.json".utf8), "a .error Pulse didn't write isn't overwritten")
        assert(store.problems["mine"] != nil, "the problem is still shown")
        try! fm.removeItem(at: folder.appending(path: "mine.json"))
        store.reload()
        assert(fm.fileExists(atPath: theirs.path), "nor removed once its theme is gone")

        // an edited built-in whose backup names are all taken: the edit stays, and the reason is shown
        let groove = folder.appending(path: "groove.json"), edit = Data("the user's original edit".utf8)
        try! edit.write(to: groove)
        let now = Date()
        for offset in -2 ... 10 {
            let stamp = now.addingTimeInterval(Double(offset)).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            try! Data("an older backup".utf8).write(to: folder.appending(path: "groove.json.replaced-\(stamp)"))
        }
        store.writeExamples()
        assert(try! Data(contentsOf: groove) == edit, "the edit isn't overwritten when it can't be moved aside")
        store.reload()
        assert(store.problems["groove"]?.contains("couldn't move your edit aside") == true, "and Settings says why: \(store.problems)")
        assert(store.theme("groove").set == .groove, "the built-in still draws")
        // a folder or a link under a built-in's or the guide's name: left alone
        try! fm.removeItem(at: groove)
        try! fm.createDirectory(at: groove, withIntermediateDirectories: false)
        let guide = folder.appending(path: "AGENTS.md"), elsewhere = folder.appending(path: "elsewhere.md")
        try! fm.removeItem(at: guide)
        try! Data("not Pulse's".utf8).write(to: elsewhere)
        try! fm.createSymbolicLink(at: guide, withDestinationURL: elsewhere)
        store.writeExamples()
        var isDir: ObjCBool = false
        assert(fm.fileExists(atPath: groove.path, isDirectory: &isDir) && isDir.boolValue, "a folder named groove.json is left alone")
        assert(try! fm.destinationOfSymbolicLink(atPath: guide.path) == elsewhere.path && (try! Data(contentsOf: elsewhere)) == Data("not Pulse's".utf8),
               "a linked AGENTS.md isn't replaced or written through")
    }

    @MainActor static func checkAppearance() {
        let store = ThemeStore(folder: FileManager.default.temporaryDirectory.appending(path: "pulse-theme-none-\(UUID().uuidString)"))
        store.setSystem(.light)
        assert(store.scheme("classic") == .dark && store.skin(nil) == .classic, "Classic stays dark in Light Mode")
        assert(store.scheme("groove") == .light && store.skin("groove") == .grooveWhite, "Groove follows the system: White")
        assert(store.skin("groove-black") == .grooveBlack)
        let white = store.skin("groove", contrast: .increased)
        assert(white.ink.primary == "#000000" && white.groove?.onFace == "#000000" && white.accents == PulseSkin.grooveWhite.accents,
               "Increase Contrast on White: black ink, the deepened colours kept")
        let black = store.skin("groove-black", contrast: .increased)
        assert(black.ink.primary == "#000000" && black.groove?.onFace == "#FFFFFF" && black.accents == PulseSkin.classic.accents,
               "Increase Contrast on Black: black ink on the slab, white marks on the dark hub, full colours on the black floor")
        store.setSystem(.dark)
        assert(store.skin("groove") == .groove && store.skin("groove-black") == .groove, "both Groove themes are Groove in Dark Mode")
    }
}
