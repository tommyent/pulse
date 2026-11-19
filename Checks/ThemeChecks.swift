// Theme files: built into SettingsStateChecks (it builds every source but PulseApp.swift) and run from its main.
import Combine
import SwiftUI

enum ThemeChecks {
    @MainActor static func run() {
        checkBuiltIns()
        checkRefusals()
        checkFormat()
        checkContrastFloor()
        checkGuide()
        checkFolder()
        checkOwnership()
        checkBounded()
        checkImportExport()
        checkDiagnosticOwnership()
        checkSlotLive()
        checkCapAndWatch()
        checkModesAndSlots()
        checkMigration()
        checkClassicInBothModes()
        checkAgentPrompt()
        print("Theme checks passed: built-ins round-trip, every refusal on the list, the format and portability, low contrast warned along whole gradients and on the counter, never refused, the guide's examples and keys, last good, .error files, live reload, built-in names, only Pulse's files touched, bounded reads off the main thread, import and export, a theme's appearance changed live with the app staying dark, the cap and the cache, the watch's teardown, modes and slots, migration, Classic identical in both modes, the agent prompt")
    }

    /// Settings' Copy Agent Prompt: the guide's whole path in quotes (spaces and all), the name when there is one.
    @MainActor static func checkAgentPrompt() {
        let folder = URL(filePath: "/tmp/Application Support/Pulse/Themes", directoryHint: .isDirectory)
        let guide = "Read \"/tmp/Application Support/Pulse/Themes/AGENTS.md\" and make a Pulse theme"
        assert(ThemeStore.agentPrompt(folder: folder, name: "  Ember Two ") == guide + " called Ember Two; save it as JSON in that folder.")
        assert(ThemeStore.agentPrompt(folder: folder, name: " \n") == guide + "; save it as JSON in that folder.", "no name: the agent picks one")
        checkCopyPromptButton()
    }

    /// The button after a copy: green, "✓ Copied" for about 2 s, the same width as before (nothing beside it moves), and
    /// its label readable on the green. Drawn in a window that's never shown, where controls render.
    @MainActor static func checkCopyPromptButton() {
        _ = NSApplication.shared
        assert(CopyPromptButton.shown == .seconds(2))
        assert(CopyPromptButton.label(copied: true) == "✓ Copied" && CopyPromptButton.label(copied: false) == "Copy Agent Prompt")
        func draw(copied: Bool) -> (width: CGFloat, greenPixels: Int) {
            let host = NSHostingView(rootView: CopyPromptButton(copied: copied) {}.padding(8).background(Color(white: 0.12)))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            for _ in 0 ..< 6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded() }
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            var green = 0
            for x in 0 ..< rep.pixelsWide { for y in 0 ..< rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.greenComponent > 0.3, c.greenComponent > c.redComponent * 1.6, c.greenComponent > c.blueComponent * 1.4 { green += 1 }
            } }
            window.close()
            return (host.fittingSize.width, green)
        }
        let before = draw(copied: false), after = draw(copied: true)
        assert(before.greenPixels == 0 && after.greenPixels > 200, "green only once copied: \(before.greenPixels) then \(after.greenPixels)")
        assert(abs(before.width - after.width) < 0.5, "the button keeps its width: \(before.width) then \(after.width)")
        func luminance(_ c: Color.Resolved) -> Double { 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue) }
        let green = luminance(CopyPromptButton.green.resolve(in: EnvironmentValues()))
        assert(1.05 / (green + 0.05) >= 4.5, "white on the copied green reads: \(1.05 / (green + 0.05)):1")
    }

    // MARK: helpers

    /// A built-in's JSON with one value replaced (nil: the key removed). `path` is dot-separated; numbers index lists.
    static func edited(_ file: PulseThemeFile, _ path: String, _ value: Any?) -> Data {
        func put(_ object: Any, _ keys: ArraySlice<Substring>, _ value: Any?) -> Any {
            guard let key = keys.first else { return value ?? NSNull() }
            if var list = object as? [Any], let i = Int(key) { list[i] = put(list[i], keys.dropFirst(), value); return list }
            var dict = object as! [String: Any]
            if keys.count == 1, value == nil { dict[String(key)] = nil } else { dict[String(key)] = put(dict[String(key)] as Any, keys.dropFirst(), value) }
            return dict
        }
        let object = try! JSONSerialization.jsonObject(with: ThemeStore.file(file))
        return try! JSONSerialization.data(withJSONObject: put(object, path.split(separator: ".")[...], value))
    }

    /// Why a theme file is refused; fails the check if it's accepted.
    static func refusal(_ data: Data, _ what: String) -> String {
        guard case .failure(let problem) = ThemeStore.decode(data) else { fatalError("accepted: \(what)") }
        return problem.text
    }

    static func expectRefused(_ file: PulseThemeFile, _ path: String, _ value: Any?, mentioning words: [String]) {
        let text = refusal(edited(file, path, value), "\(path) = \(String(describing: value))")
        for w in words { assert(text.contains(w), "refusing \(path) = \(String(describing: value)) should mention \(w): \(text)") }
    }

    /// What's hard to read in a theme that loads; fails the check if it's refused or reads fine.
    static func warning(_ data: Data, _ what: String) -> String {
        guard case .success(let file) = ThemeStore.decode(data) else { fatalError("refused, not warned: \(what): \(refusal(data, what))") }
        guard let text = ThemeStore.warnings(file) else { fatalError("no warning: \(what)") }
        return text
    }

    static func expectWarned(_ file: PulseThemeFile, _ path: String, _ value: Any?, mentioning words: [String]) {
        let text = warning(edited(file, path, value), "\(path) = \(String(describing: value))")
        for w in words { assert(text.contains(w), "the warning for \(path) = \(String(describing: value)) should mention \(w): \(text)") }
    }

    /// Until the store's background job `number` is done and its results are published.
    @MainActor static func settle(_ store: ThemeStore, _ number: Int) {
        assert(waitUntil { store.finished >= number }, "theme job \(number) finished")
    }

    static func waitUntil(_ seconds: Double = 5, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    /// The guide's worked examples, in order: Ember (dark), Ember Glass (any), Paper (light).
    static let guideExamples: [Data] = {
        var out: [Data] = [], text = ThemeGuide.text[...]
        while let start = text.range(of: "```json\n") {
            let rest = text[start.upperBound...], end = rest.range(of: "\n```")!
            out.append(Data(rest[..<end.lowerBound].utf8))
            text = rest[end.upperBound...]
        }
        return out
    }()
    static var guideExample: Data { guideExamples[0] }

    static func folder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pulse-theme-\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A choice with one theme in both slots, Auto.
    static func both(_ id: String, classic: String = "classic-solid") -> ThemeChoice { ThemeChoice(mode: .auto, light: id, dark: id, classic: classic) }

    // MARK: the format

    static func checkBuiltIns() {
        assert(PulseThemeFile.builtIn.map(\.id) == ["classic-glass", "classic-solid", "groove", "groove-white", "groove-black",
                                                    "glacier", "orchard", "matcha-washi", "linen", "abyss", "forest-canopy",
                                                    "velvet", "synthwave-chrome", "espresso-brass", "newsprint"])
        // the picks are the collection's files, byte for byte: the app's copy, the repository's themes/, and what Pulse writes
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (id, file) in PulseThemeFile.picks {
            let bundled = try! Data(contentsOf: repo.appending(path: "Sources/Pulse/Resources/themes/\(id).json"))
            assert(bundled == ThemeStore.file(file), "\(id): the app's copy is written as Pulse writes theme files")
            assert(try! Data(contentsOf: repo.appending(path: "themes/\(id).json")) == bundled, "\(id): the same file as themes/\(id).json")
        }
        for (id, file) in PulseThemeFile.builtIn {
            guard case .success(let read) = ThemeStore.decode(ThemeStore.file(file)) else {
                fatalError("\(id) is refused by its own checks: \(refusal(ThemeStore.file(file), id))")
            }
            assert(read == file, "\(id) round-trips through its own JSON")
        }
        let text = String(decoding: ThemeStore.file(.groove), as: UTF8.self)
        assert(text.contains(##""wall" : [4.4, 4.4, 3.2, "#000000", 0.8]"##), "a shadow is written on one line")
        assert(text.contains(#""format" : 1"#) && text.contains(#""name" : "Groove""#) && text.contains(#""appearance" : "dark""#), text.prefix(300).description)
        assert(!text.contains(#""light""#) && !text.contains(#""dark" : {"#), "one look per file, no halves")
        assert(String(decoding: ThemeStore.file(.classicGlass), as: UTF8.self).contains(#""glass" : true"#), "Classic Glass is Classic with the glass flag")
        let glass = PulseThemeFile.classicGlass.look, solid = PulseThemeFile.classicSolid.look
        assert(glass.material == .glass && solid.material == .solid && { var g = glass; g.glass = nil; return g }() == solid, "Glass and Solid differ in the flag only")
        assert(PulseThemeFile.classicGlass.scheme == .dark && PulseThemeFile.classicSolid.scheme == .dark, "Classic draws dark, as always")
        assert(PulseThemeFile.grooveWhite.scheme == .light && PulseThemeFile.grooveBlack.scheme == .light && PulseThemeFile.groove.scheme == .dark)
    }

    static func checkRefusals() {
        // Sol's list: what the decoder used to accept
        expectRefused(.groove, "groove.barSlot", -10, mentioning: ["groove.barSlot", "outside"])
        expectRefused(.groove, "groove.outer.channel", -16, mentioning: ["groove.outer.channel"])
        expectRefused(.groove, "groove.wall", [4.4, 4.4, -3.2, "#000000", 0.8], mentioning: ["groove.wall blur"])
        expectRefused(.groove, "groove.wall", [4.4, 4.4, 3.2, "#000000", 1.5], mentioning: ["groove.wall opacity"])
        expectRefused(.groove, "groove.grain", 2, mentioning: ["groove.grain"])
        expectRefused(.groove, "stale", -0.1, mentioning: ["stale"])
        expectRefused(.groove, "groove.outer.radius", 70, mentioning: ["groove.outer"])
        expectRefused(.groove, "groove.wall", [4.4, 4.4, 3.2, "#000000", 0.8, 1], mentioning: ["groove.wall", "exactly"])
        expectRefused(.groove, "groove.floor", "#+12345", mentioning: ["groove.floor", "not a colour"])
        expectRefused(.groove, "groove.wall", [4.4, 4.4, 3.2, "#+12345", 0.8], mentioning: ["groove.wall", "not a colour"])
        expectRefused(.groove, "accents.codex", "#4E6FC", mentioning: ["accents.codex"])
        // the rest of the geometry, each its own refusal
        expectRefused(.groove, "groove.inner.radius", 40, mentioning: ["groove.inner", "into the outer channel"])
        expectRefused(.groove, "groove.outer.tube", 17, mentioning: ["groove.outer.tube", "wider than its channel"])
        expectRefused(.groove, "groove.hubSingle", 45, mentioning: ["groove.hubSingle", "covers"])
        expectRefused(.groove, "groove.hubDouble", 28, mentioning: ["groove.hubDouble", "covers"])
        expectRefused(.groove, "groove.barFill", 12, mentioning: ["groove.barFill", "wider"])
        expectRefused(.groove, "groove.barRadius", 6, mentioning: ["groove.barRadius", "half"])
        expectRefused(.groove, "groove.drop.0", [12, 16, 18, "#000000", 0.5], mentioning: ["groove.drop[0]", "12"])
        expectRefused(.grooveBlack, "groove.porthole.radius", 40, mentioning: ["groove.porthole.radius", "smaller"])
        expectRefused(.groove, "groove.type.0", [-2, -0.035, 0, "#FFFFFF", 0.85], mentioning: ["groove.type[0] x"])
        expectRefused(.groove, "groove.raise", Array(repeating: [1, 1, 1, "#FFFFFF", 0.1], count: 5), mentioning: ["at most 4"])
        // the format itself
        expectRefused(.groove, "groove.slabtop", "#000000", mentioning: ["groove.slabtop", "not a key"])
        // a root key with dots in it isn't the nested key it spells (Sol's review of 4f91bdb)
        var dotted = try! JSONSerialization.jsonObject(with: ThemeStore.file(.classicSolid)) as! [String: Any]
        dotted["ink.primary"] = "an unknown root key that flattens to a known path"
        assert(refusal(try! JSONSerialization.data(withJSONObject: dotted), "a dotted root key").contains("\"ink.primary\": not a key"))
        expectRefused(.groove, "groove.floor", nil, mentioning: ["groove.floor", "missing"])
        expectRefused(.groove, "stale", "half", mentioning: ["stale", "a number"])
        expectRefused(.groove, "name", "  ", mentioning: ["name"])
        assert(refusal(Data("{\"name\": \"x\",".utf8), "broken JSON").contains("not JSON"))
        var big = Data(ThemeStore.file(.groove))
        big.append(Data(repeating: 0x20, count: ThemeStore.maxFileBytes))
        assert(refusal(big, "a big file").contains("64 KB"))
        // what stays allowed: the wall left out or null
        for wall in [nil, NSNull()] as [Any?] {
            if case .failure(let p) = ThemeStore.decode(edited(.groove, "groove.wall", wall)) { fatalError("no wall is allowed: \(p.text)") }
        }
    }

    /// A version line, the appearance slot, optional author and description, and nothing that points outside the file.
    static func checkFormat() {
        // a newer format: only the plain message, whatever else the file holds
        let newer = String(decoding: edited(.groove, "format", 2), as: UTF8.self).replacingOccurrences(of: "\"name\"", with: "\"futureKey\":{\"x\":1},\"name\"")
        let newerText = refusal(Data(newer.utf8), "format 2")
        assert(newerText.contains("made for a newer Pulse") && newerText.contains("format 1") && !newerText.contains("futureKey"), newerText)
        expectRefused(.groove, "format", nil, mentioning: ["format: missing"])
        expectRefused(.groove, "format", 0, mentioning: ["format"])
        expectRefused(.groove, "format", 1.5, mentioning: ["whole number"])
        expectRefused(.groove, "format", "1", mentioning: ["whole number"])
        // appearance
        expectRefused(.groove, "appearance", nil, mentioning: ["appearance", "missing"])
        expectRefused(.groove, "appearance", "both", mentioning: ["appearance"])
        expectRefused(.classicSolid, "appearance", "light", mentioning: ["appearance", "dark only"])
        expectRefused(.classicSolid, "surface", "#F4F4F4", mentioning: ["appearance", "dark only"])   // "any" reads as light: a flat light theme
        expectRefused(.groove, "glass", true, mentioning: ["glass", "flat theme only"])
        // the glass prototype's halo: liquid themes only, a bounded shadow list
        expectRefused(.classicSolid, "halo", [[0, 0, 3, "#000000", 0.6]], mentioning: ["halo", "liquid theme only"])
        var liquid = PulseThemeFile.classicSolid
        liquid.look.liquid = true
        expectRefused(liquid, "halo", [[0, 0, 40, "#000000", 0.6]], mentioning: ["halo[0] blur", "outside"])
        liquid.look.halo = [[0, 0, 3, "#000000", 0.6], [0, 0, 10, "#000000", 0.35]]
        assert(ThemeStore.decode(ThemeStore.file(liquid)) == .success(liquid), "a liquid theme's halo round-trips")
        // author and description: optional, kept, bounded
        var credited = PulseThemeFile.groove
        credited.author = "Someone"
        credited.description = "Two lines,\nas a description may have."
        guard case .success(let read) = ThemeStore.decode(ThemeStore.file(credited)) else { fatalError("author and description are allowed") }
        assert(read.author == "Someone" && read.description == credited.description)
        expectRefused(.groove, "author", String(repeating: "a", count: 81), mentioning: ["author: 1 to 80"])
        expectRefused(.groove, "author", "line\nbreak", mentioning: ["author: no control characters"])
        expectRefused(.groove, "description", String(repeating: "a", count: 301), mentioning: ["description: 1 to 300"])
        // nothing outside the file: no key can name an image, another theme, a path or a URL
        for key in ["image", "extends", "include", "url", "path", "font"] {
            expectRefused(.groove, key, "elsewhere.json", mentioning: ["\(key): not a key"])
        }
        expectRefused(.groove, "groove.texture", "file:///tmp/a.png", mentioning: ["groove.texture: not a key"])
        let everyString = ThemeStore.knownKeys.map { $0.joined(separator: ".") }
        assert(!everyString.contains { ["image", "url", "path", "file", "extends", "include"].contains($0.split(separator: ".").last.map(String.init) ?? "") },
               "the format has no key that refers outside the file")
    }

    /// Hard-to-read themes load, with a warning that says where (the owner: low contrast warns, it doesn't refuse).
    static func checkContrastFloor() {
        for (id, file) in PulseThemeFile.builtIn { assert(file.warnings().isEmpty, "\(id) reads well: \(file.warnings())") }
        // text hard to read on the slab, each kind on its own
        expectWarned(.groove, "ink.secondary", "#45484F", mentioning: ["ink.secondary", "text needs 4.5:1"])
        expectWarned(.groove, "ink.primary", "#202226", mentioning: ["ink.primary", "1.00:1"])
        expectWarned(.grooveWhite, "ink.alert", "#FF6B61", mentioning: ["ink.alert", "text needs 4.5:1"])
        expectWarned(.groove, "stale", 0.3, mentioning: ["stale", "text needs 4.5:1"])
        // dark Groove's amber on White's floor: the reason Groove White deepens its colours
        expectWarned(.grooveWhite, "accents.grok", "#DBB572", mentioning: ["accents.grok", "groove.floor", "needs 3:1"])
        expectWarned(.groove, "accents.codex", "#2A3A66", mentioning: ["accents.codex", "groove.barFloor"])
        expectWarned(.groove, "groove.onFace", "#2B2D32", mentioning: ["groove.onFace", "a mark on the hub"])
        expectWarned(.groove, "ink.secondary", "#E6E6E640", mentioning: ["translucent"])
        // Sol's two 1:1 cases on 4f91bdb: text on both ends of the slab's gradient, and the agents' "+3" on its disc
        var ends = PulseThemeFile.groove
        let ink = ends.look.ink.primary!
        ends.look.groove!.slabTop = ink
        ends.look.groove!.slabBottom = ink
        let endsText = warning(ThemeStore.file(ends), "ink on both gradient ends")
        assert(endsText.contains("groove.slabTop") && endsText.contains("1.00:1"), endsText)
        var counter = PulseThemeFile.groove
        counter.look.groove!.bubble = "#000000"
        counter.look.groove!.bubbleInk = "#000000"
        let counterText = warning(ThemeStore.file(counter), "the counter on its disc")
        assert(counterText.contains("groove.bubbleInk #000000 on groove.bubble #000000: 1.00:1"), counterText)
        // the hub's gradient, and the counter's defaults on a face they can't be read on
        expectWarned(.groove, "groove.faceTop", "#F5F5F7", mentioning: ["groove.onFace", "groove.faceTop"])
        expectWarned(.groove, "groove.face", "#DEDEDE", mentioning: ["groove.bubbleInk (left out: light grey)"])
        // Fable's #BF2318 alert reads 4.24:1 on White's darker slab end; White's is deepened to pass
        expectWarned(.grooveWhite, "ink.alert", "#BF2318", mentioning: ["ink.alert", "groove.slabBottom"])
        // a flat theme is held to its surface
        expectWarned(.classicSolid, "accents.codex", "#202060", mentioning: ["accents.codex", "surface"])
        // Sol's re-review of ad17df2: grey text on a black-to-white slab passes at every stop (4.56:1 on black, 4.61:1
        // on white) and reads at 1:1 where the gradient crosses its own grey
        var grey = PulseThemeFile.groove
        grey.look.groove!.slabTop = "#000000"
        grey.look.groove!.slab = "#000000"
        grey.look.groove!.slabBottom = "#FFFFFF"
        grey.look.ink = PulseSkin.Ink(primary: "#757575", secondary: "#757575", alert: "#757575")
        grey.look.stale = 1
        assert(grey.look.ink.primary!.contrast(with: "#000000") >= 4.5 && grey.look.ink.primary!.contrast(with: "#FFFFFF") >= 4.5, "every stop passes")
        let greyText = warning(ThemeStore.file(grey), "grey text across a black-to-white slab")
        assert(greyText.contains("ink.primary #757575 on the gradient from groove.slab to groove.slabBottom") && greyText.contains("1.0"), greyText)
        // stops in different spaces are converted before they're mixed (Sol's round 3 review: an sRGB slab ending in a
        // Display P3 red hid a warning, the red read as if its components were sRGB). White on p3:0.92,0,0 is 4.37:1;
        // read as sRGB it would be 4.63:1.
        var mixedSpaces = PulseThemeFile.groove
        mixedSpaces.look.groove!.slabBottom = "p3:0.92,0,0"
        mixedSpaces.look.ink.primary = "#FFFFFF"
        let white: SkinColor = "#FFFFFF"
        assert(white.contrast(with: "p3:0.92,0,0") < 4.5 && white.contrast(with: "srgb:0.92,0,0") > 4.5)
        let mixedText = warning(ThemeStore.file(mixedSpaces), "white on a slab ending in a P3 red")
        assert(mixedText.contains("ink.primary #FFFFFF on the gradient from groove.slab to groove.slabBottom"), mixedText)
        // the hub's radial gradient the same way
        var hub = PulseThemeFile.groove
        hub.look.groove!.faceTop = "#FFFFFF"
        hub.look.groove!.face = "#000000"
        hub.look.groove!.faceBottom = "#000000"
        hub.look.groove!.onFace = "#7C7C7C"
        assert(hub.look.groove!.onFace.contrast(with: "#000000") >= 3 && hub.look.groove!.onFace.contrast(with: "#FFFFFF") >= 3)
        assert(warning(ThemeStore.file(hub), "a mark across the hub's gradient").contains("groove.onFace #7C7C7C on the gradient from groove.faceTop to groove.face"))
    }

    static func checkGuide() {
        assert(guideExamples.count == 3, "three worked examples")
        let expected: [(String, ThemeSlot)] = [("Ember", .dark), ("Ember Glass", .any), ("Paper", .light)]
        for (data, (name, slot)) in zip(guideExamples, expected) {
            guard case .success(let file) = ThemeStore.decode(data) else { fatalError("the guide's \(name) is refused: \(refusal(data, name))") }
            assert(file.name == name && file.appearance == slot && file.warnings().isEmpty, "\(name) is the guide's \(slot) example, and reads well")
        }
        assert(ThemeStore.decode(guideExamples[2]) == .success(ThemeGuide.paper), "the light example is Paper, as written")
        for key in ThemeStore.knownKeys {
            assert(ThemeGuide.text.contains(key.last!), "the guide describes \(key)")
        }
        for id in PulseThemeFile.builtIn.map(\.id) { assert(ThemeGuide.text.contains("`\(id).json`"), "the guide names \(id).json") }
    }

    // MARK: the folder

    @MainActor static func checkFolder() {
        let folder = folder("check")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(folder: folder)
        let fm = FileManager.default
        func listed(_ id: String) -> PulseTheme? { store.themes.first { $0.id == id } }
        settle(store, store.writeExamples())
        for (id, file) in PulseThemeFile.builtIn {
            assert(try! Data(contentsOf: folder.appending(path: "\(id).json")) == ThemeStore.file(file), "\(id) written as an example")
        }
        assert(fm.fileExists(atPath: folder.appending(path: "AGENTS.md").path), "the guide is written into the folder")
        settle(store, store.reload())
        let builtIns = PulseThemeFile.builtIn.map(\.id)
        assert(store.themes.map(\.id) == builtIns && store.problems.isEmpty, "the examples are the built-ins: \(store.problems)")

        let ember = folder.appending(path: "ember.json"), error = folder.appending(path: "ember.error")
        assert(store.watch())
        defer { store.stopWatching() }
        // live reload: a new file, then an edit, picked up without a call
        try! guideExample.write(to: ember)
        assert(waitUntil { listed("ember") != nil }, "a new theme file is listed by itself")
        assert(store.themes.map(\.id) == builtIns + ["ember"])
        let renamed = String(decoding: guideExample, as: UTF8.self).replacingOccurrences(of: "\"Ember\"", with: "\"Ember Two\"")
        try! Data(renamed.utf8).write(to: ember)
        assert(waitUntil { listed("ember")?.file.name == "Ember Two" }, "an edit is picked up by itself")
        // a bad edit: the last good version stays, the reason goes beside the file, Settings has it
        try! Data(renamed.replacingOccurrences(of: "#FF7A45", with: "#FF7A4").utf8).write(to: ember)
        assert(waitUntil { store.problems["ember"] != nil }, "a bad edit is noticed")
        assert(listed("ember")?.file.name == "Ember Two", "the last good version stays in use")
        assert(store.skin(both("ember")).accents.claude == "#FF7A45", "the bad value never draws")
        let reason = try! String(contentsOf: error, encoding: .utf8)
        assert(reason.contains("accents.claude") && reason.contains("last good version"), "the .error names the key: \(reason)")
        // fixed: the error file goes
        try! guideExample.write(to: ember)
        assert(waitUntil { !fm.fileExists(atPath: error.path) && store.problems["ember"] == nil }, "a fixed file's .error is removed")
        assert(listed("ember")?.file.name == "Ember")
        // a theme that was never good: the person's Classic draws, and the error says so
        let broken = folder.appending(path: "broken.json")
        try! Data("{\"format\": 1, \"name\": \"Broken\"}".utf8).write(to: broken)
        assert(waitUntil { store.problems["broken"] != nil })
        assert(listed("broken") == nil && store.current(both("broken", classic: "classic-glass")).id == "classic-glass")
        assert(try! String(contentsOf: folder.appending(path: "broken.error"), encoding: .utf8).contains("draws Classic"))
        try! fm.removeItem(at: broken)
        assert(waitUntil { !fm.fileExists(atPath: folder.appending(path: "broken.error").path) }, "a removed file's .error is removed")

        // hard to read: it loads and draws, Settings warns and says where, and there's no .error
        let dim = folder.appending(path: "dim.json")
        try! Data(String(decoding: guideExample, as: UTF8.self).replacingOccurrences(of: "#E8DDD8", with: "#3A302C").utf8).write(to: dim)
        assert(waitUntil { listed("dim") != nil && store.warnings["dim"] != nil }, "a hard-to-read theme loads, with a warning")
        assert(store.warnings["dim"]!.contains("ink.secondary #3A302C on surface") && store.problems["dim"] == nil, store.warnings["dim"]!)
        assert(store.current(both("dim")).id == "dim" && !fm.fileExists(atPath: folder.appending(path: "dim.error").path))
        // a broken edit keeps drawing the last good version, so its warning stays too (Sol's round 3 review)
        let warned = store.warnings["dim"]
        try! Data("{\"format\": 1".utf8).write(to: dim)
        assert(waitUntil { store.problems["dim"] != nil }, "the broken edit is noticed")
        assert(listed("dim") != nil && store.warnings["dim"] == warned, "the last good version and its warning stay: \(String(describing: store.warnings["dim"]))")
        try! fm.removeItem(at: dim)
        assert(waitUntil { store.warnings["dim"] == nil }, "the warning goes with the file")

        // a built-in's name: the built-in draws, the edit is reported, and the next launch's examples keep the edit aside
        try! edited(.groove, "name", "My Groove").write(to: folder.appending(path: "groove.json"))
        settle(store, store.reload())
        assert(listed("groove")?.file == .groove && store.problems["groove"]?.contains("Pulse's own") == true)
        settle(store, store.writeExamples())
        assert(try! Data(contentsOf: folder.appending(path: "groove.json")) == ThemeStore.file(.groove))
        assert(try! fm.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("groove.json.replaced-") }, "the edited copy is kept")
        settle(store, store.reload())
        assert(store.problems["groove"] == nil)

        // at most 50 theme files are read
        for i in 0 ..< ThemeStore.maxThemes { try! guideExample.write(to: folder.appending(path: String(format: "many-%02d.json", i))) }
        settle(store, store.reload())
        assert(store.themes.count == builtIns.count + ThemeStore.maxThemes, "\(store.themes.count) themes listed")
        assert(store.notice?.contains("at most \(ThemeStore.maxThemes)") == true && !store.problems.keys.contains { $0.hasPrefix("many-") },
               "the 51st file is in one notice, not a problem of its own: \(String(describing: store.notice))")
    }

    /// Pulse removes and replaces only what it wrote (Sol's review of 4f91bdb: an unrelated `.error` file, a `.error`
    /// folder, and an edited built-in whose backup name was taken were all lost).
    @MainActor static func checkOwnership() {
        let fm = FileManager.default
        let folder = folder("owned")
        defer { try? fm.removeItem(at: folder) }
        let store = ThemeStore(folder: folder)
        settle(store, store.writeExamples())
        // someone else's .error file and a .error folder: kept through reloads, fixed or not
        let unrelated = folder.appending(path: "unrelated.error"), notes = folder.appending(path: "notes.error")
        try! Data("disposable file".utf8).write(to: unrelated)
        try! fm.createDirectory(at: notes, withIntermediateDirectories: false)
        try! Data("disposable note".utf8).write(to: notes.appending(path: "note.txt"))
        // a .error file Pulse didn't write, beside a broken theme: left as it is, the problem still in Settings
        let theirs = folder.appending(path: "mine.error")
        try! Data("my own notes about mine.json".utf8).write(to: theirs)
        try! Data("{}".utf8).write(to: folder.appending(path: "mine.json"))
        settle(store, store.reload())
        settle(store, store.reload())
        assert(try! Data(contentsOf: unrelated) == Data("disposable file".utf8), "an unrelated .error file is kept")
        assert(try! Data(contentsOf: notes.appending(path: "note.txt")) == Data("disposable note".utf8), "a .error folder is kept")
        assert(try! Data(contentsOf: theirs) == Data("my own notes about mine.json".utf8), "a .error Pulse didn't write isn't overwritten")
        assert(store.problems["mine"] != nil, "the problem is still shown")
        try! fm.removeItem(at: folder.appending(path: "mine.json"))
        settle(store, store.reload())
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
        settle(store, store.writeExamples())
        assert(try! Data(contentsOf: groove) == edit, "the edit isn't overwritten when it can't be moved aside")
        settle(store, store.reload())
        assert(store.problems["groove"]?.contains("couldn't move your edit aside") == true, "and Settings says why: \(store.problems)")
        assert(store.themes.first { $0.id == "groove" }?.file == .groove, "the built-in still draws")
        // a folder or a link under a built-in's or the guide's name: left alone
        try! fm.removeItem(at: groove)
        try! fm.createDirectory(at: groove, withIntermediateDirectories: false)
        let guide = folder.appending(path: "AGENTS.md"), elsewhere = folder.appending(path: "elsewhere.md")
        try! fm.removeItem(at: guide)
        try! Data("not Pulse's".utf8).write(to: elsewhere)
        try! fm.createSymbolicLink(at: guide, withDestinationURL: elsewhere)
        settle(store, store.writeExamples())
        var isDir: ObjCBool = false
        assert(fm.fileExists(atPath: groove.path, isDirectory: &isDir) && isDir.boolValue, "a folder named groove.json is left alone")
        assert(try! fm.destinationOfSymbolicLink(atPath: guide.path) == elsewhere.path && (try! Data(contentsOf: elsewhere)) == Data("not Pulse's".utf8),
               "a linked AGENTS.md isn't replaced or written through")
    }

    /// Reads are bounded and off the main actor (Sol's review of 4f91bdb: a link to an 8 MiB file was read whole, a pipe
    /// held up the main thread, and every file past 50 got its own `.error`).
    @MainActor static func checkBounded() {
        let fm = FileManager.default
        let folder = folder("bounded"), outside = self.folder("outside")
        defer { try? fm.removeItem(at: folder); try? fm.removeItem(at: outside) }
        let store = ThemeStore(folder: folder)
        // an 8 MiB file, and links to it and to a good theme: refused without reading through the link
        var big = guideExample
        big.append(Data(repeating: 0x20, count: 8 << 20))
        try! big.write(to: outside.appending(path: "big.json"))
        try! guideExample.write(to: outside.appending(path: "good.json"))
        try! big.write(to: folder.appending(path: "big.json"))
        try! fm.createSymbolicLink(at: folder.appending(path: "linked-big.json"), withDestinationURL: outside.appending(path: "big.json"))
        try! fm.createSymbolicLink(at: folder.appending(path: "linked-good.json"), withDestinationURL: outside.appending(path: "good.json"))
        // pipes under a theme's, a built-in's and a .error's name, whose writer comes only after 750 ms
        try! Data("{}".utf8).write(to: folder.appending(path: "invalid.json"))
        for name in ["a-pipe.json", "groove.json", "invalid.error"] {
            let path = folder.appending(path: name).path
            assert(mkfifo(path, 0o600) == 0)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(750)) {
                let fd = open(path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 { close(fd) }
            }
        }
        // 60 good theme files: with the 5 above, 50 are read in order of name, and the rest get no .error of their own
        for i in 0 ..< 60 { try! guideExample.write(to: folder.appending(path: String(format: "many-%02d.json", i))) }
        let start = Date()
        store.reload()
        assert(Date().timeIntervalSince(start) < 0.25, "reload() leaves the folder to a background queue: \(Date().timeIntervalSince(start)) s on the main thread")
        assert(waitUntil { store.problems["linked-good"] != nil && store.problems["a-pipe"] != nil && store.problems["big"] != nil },
               "the pass finishes: \(store.problems.keys.sorted())")
        assert(Date().timeIntervalSince(start) < 0.7, "no pipe is waited on: \(Date().timeIntervalSince(start)) s")
        assert(store.problems["big"]!.contains("over 64 KB"))
        assert(store.problems["linked-big"]!.contains("a link") && store.problems["linked-good"]!.contains("a link"), "links are refused as links")
        assert(store.problems["a-pipe"]!.contains("not a regular file"))
        assert(store.problems["groove"] != nil && store.themes.first { $0.id == "groove" }?.file == .groove, "a pipe named groove.json leaves the built-in drawing")
        let errors = try! fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".error") }
        assert(!errors.contains { $0.hasPrefix("many-") }, "no .error for a file past the cap: \(errors.sorted())")
        assert(errors.count <= 11, "at most 10 .error files written, beside the pipe: \(errors.sorted())")
    }

    /// Sol's re-review of ad17df2: a `.error` is Pulse's by its mark, not by what it says, so a person's note that reads
    /// like Pulse's stays; a diagnostic is never bigger than Pulse can recognise and clear; hidden entries count
    /// toward the 500 a pass looks at.
    @MainActor static func checkDiagnosticOwnership() {
        let fm = FileManager.default
        let folder = folder("diagnostics")
        defer { try? fm.removeItem(at: folder) }
        let cache = ThemeFolder.Cache()
        // a note in Pulse's own words, beside no theme and beside a good one: kept
        let note = folder.appending(path: "note.error"), alike = folder.appending(path: "alike.error")
        try! Data("note.json can't be used, so I wrote this down to remember".utf8).write(to: note)
        try! Data("alike.json can't be used, so Pulse draws Classic instead.".utf8).write(to: alike)
        try! guideExample.write(to: folder.appending(path: "alike.json"))
        _ = ThemeFolder.scan(folder, cache: cache)
        assert(fm.fileExists(atPath: note.path) && fm.fileExists(atPath: alike.path), "notes in Pulse's words are kept")
        // Pulse's own diagnostic: marked, at most 8 KB even for a huge key, and cleared once the file is fixed
        let long = folder.appending(path: "long.json")
        var object = try! JSONSerialization.jsonObject(with: guideExample) as! [String: Any]
        object[String(repeating: "k", count: 19_000)] = 1
        try! JSONSerialization.data(withJSONObject: object).write(to: long)
        let longError = folder.appending(path: "long.error")
        _ = ThemeFolder.scan(folder, cache: cache)
        let size = (try! fm.attributesOfItem(atPath: longError.path)[.size] as! NSNumber).intValue
        assert(size <= ThemeFolder.maxDiagnosticBytes && ThemeFolder.isOurError(longError), "a diagnostic is \(size) bytes and marked")
        try! guideExample.write(to: long)
        _ = ThemeFolder.scan(folder, cache: cache)
        assert(!fm.fileExists(atPath: longError.path), "and it's cleared once the file is fixed")
        // a note that took the place of Pulse's diagnostic, in its words: not Pulse's, so neither cleared nor rewritten
        try! Data("{}".utf8).write(to: long)
        _ = ThemeFolder.scan(folder, cache: cache)
        try! fm.removeItem(at: longError)
        try! Data("long.json can't be used, my own copy".utf8).write(to: longError)
        _ = ThemeFolder.scan(folder, cache: cache)
        try! guideExample.write(to: long)
        _ = ThemeFolder.scan(folder, cache: cache)
        assert(try! String(contentsOf: longError, encoding: .utf8) == "long.json can't be used, my own copy", "a replaced diagnostic is the person's")
        // hidden entries count toward the 500
        let hidden = self.folder("hidden")
        defer { try? fm.removeItem(at: hidden) }
        for i in 0 ..< 520 { try! Data().write(to: hidden.appending(path: ".h\(i)")) }
        try! guideExample.write(to: hidden.appending(path: "ember.json"))
        let listing = ThemeFolder.names(hidden)
        assert(listing.more, "a folder of 520 hidden entries is past the 500 a pass looks at")
        assert(ThemeFolder.scan(hidden, cache: ThemeFolder.Cache()).notice?.contains("more than \(ThemeFolder.maxEntries) entries") == true)
    }

    /// Import… and a dropped file: the same checks as the folder's own files, copied in byte for byte under a free
    /// name. Export…: one self-contained file that imports again on another Mac as the same theme.
    @MainActor static func checkImportExport() {
        let fm = FileManager.default
        let folder = folder("import"), elsewhere = self.folder("elsewhere")
        defer { try? fm.removeItem(at: folder); try? fm.removeItem(at: elsewhere) }
        let store = ThemeStore(folder: folder)
        settle(store, store.writeExamples())
        var messages: [String] = []
        func take(_ url: URL) { settle(store, store.importTheme(url) { messages.append($0) }) }
        // a good file from elsewhere, named oddly: copied byte for byte, listed
        let source = elsewhere.appending(path: "My Ember!.json")
        try! guideExample.write(to: source)
        take(source)
        assert(try! Data(contentsOf: folder.appending(path: "my-ember.json")) == guideExample, "copied byte for byte under a tidy name")
        assert(store.themes.contains { $0.id == "my-ember" && $0.file.name == "Ember" } && messages.last == "Imported Ember as my-ember.json.", messages.description)
        let dim = elsewhere.appending(path: "dim.json")
        try! edited(.groove, "ink.secondary", "#45484F").write(to: dim)
        take(dim)
        assert(messages.last?.contains("Imported Groove as dim.json.") == true && messages.last?.contains("hard to read") == true, messages.description)
        // the same name again, and a built-in's name: a free name, never a replacement
        take(source)
        assert(fm.fileExists(atPath: folder.appending(path: "my-ember-2.json").path))
        let named = elsewhere.appending(path: "groove.json")
        try! guideExample.write(to: named)
        take(named)
        assert(try! Data(contentsOf: folder.appending(path: "groove.json")) == ThemeStore.file(.groove), "a built-in's file is never replaced")
        assert(fm.fileExists(atPath: folder.appending(path: "groove-2.json").path))
        // refused: a bad value, a newer format, a link, an oversized file; nothing is copied
        let before = Set(try! fm.contentsOfDirectory(atPath: folder.path))
        let bad = elsewhere.appending(path: "bad.json"), newer = elsewhere.appending(path: "newer.json")
        try! edited(.groove, "accents.codex", "#4E6FC").write(to: bad)
        try! edited(.groove, "format", 7).write(to: newer)
        let link = elsewhere.appending(path: "link.json"), huge = elsewhere.appending(path: "huge.json")
        try! fm.createSymbolicLink(at: link, withDestinationURL: source)
        var big = guideExample
        big.append(Data(repeating: 0x20, count: ThemeStore.maxFileBytes))
        try! big.write(to: huge)
        for url in [bad, newer, link, huge] { take(url) }
        assert(Set(try! fm.contentsOfDirectory(atPath: folder.path)) == before, "nothing refused is copied")
        let refusals = messages.suffix(4)
        assert(refusals.allSatisfy { $0.contains("wasn't imported") }, refusals.description)
        assert(refusals.contains { $0.contains("accents.codex") } && refusals.contains { $0.contains("made for a newer Pulse") }
               && refusals.contains { $0.contains("a link") } && refusals.contains { $0.contains("64 KB") }, refusals.description)
        // exported metadata comes back exactly (Sol's round 3 review: brackets inside strings were reformatted, and a
        // 299-character description grew past 300 and was refused): export, import, export again, byte for byte
        var meta = PulseThemeFile.groove
        meta.author = "Ana [ studio ] {north}, \"quoted\""
        meta.description = String(String(repeating: "A palette [warm,dusk,amber] for {evenings}, \"late\". ", count: 8).prefix(299))
        assert(meta.description!.count == 299)
        let once = ThemeStore.file(meta), metaFile = elsewhere.appending(path: "meta.json")
        try! once.write(to: metaFile)
        guard case .success(let back) = ThemeStore.decode(once) else { fatalError("an exported theme with bracketed metadata imports: \(refusal(once, "meta"))") }
        assert(back.author == meta.author && back.description == meta.description && back == meta, "metadata survives export: \(String(describing: back.author))")
        take(metaFile)
        let copied = try! Data(contentsOf: folder.appending(path: "meta.json"))
        assert(copied == once && ThemeStore.file(back) == once, "export, import and export again are byte-equal")
        // exported: one file holding the whole theme; on another Mac (another folder) it imports as the same theme
        let exported = elsewhere.appending(path: "exported.json")
        try! ThemeStore.file(.grooveWhite).write(to: exported)
        let other = self.folder("other-mac")
        defer { try? fm.removeItem(at: other) }
        guard case .success(let added) = ThemeFolder.importTheme(exported, into: other) else { fatalError("an exported theme imports") }
        guard case .success(let file) = ThemeFolder.load(other.appending(path: "\(added.id).json")) else { fatalError("and loads") }
        assert(file == .grooveWhite && added.name == "Groove White", "the exported file is the whole theme")
    }

    /// A theme's appearance changed while it's in use: the drawn theme comes from the new list each time, and the
    /// application's own appearance stays dark throughout (Sol's review of 4f91bdb: the sink read the list from before
    /// the reload, and cleared `NSApp.appearance` for every window).
    @MainActor static func checkSlotLive() {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)   // as PulseApp sets it at launch
        let fm = FileManager.default
        let folder = folder("live")
        defer { try? fm.removeItem(at: folder) }
        let store = ThemeStore(folder: folder), file = folder.appending(path: "selected.json")
        store.setSystem(.light)
        store.follow(Just(both("selected")))
        var steps: [(light: Bool, drawn: String, scheme: ColorScheme, app: NSAppearance.Name?)] = []
        for theme in [PulseThemeFile.groove, .grooveWhite, .groove] {
            try! ThemeStore.file(theme).write(to: file)
            settle(store, store.reload())
            assert(waitUntil { store.themes.first { $0.id == "selected" }?.file.appearance == theme.appearance }, "the reload is published")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            steps.append((theme.appearance == .light, store.current(store.choice).id, store.scheme(store.choice), NSApp.appearance?.name))
        }
        for step in steps {
            // light mode: the file draws while it's a light theme; while it's dark, the light slot falls back to Classic
            assert(step.drawn == (step.light ? "selected" : "classic-solid") && step.scheme == (step.light ? .light : .dark),
                   "the slot is resolved from the new list: \(steps)")
            assert(step.app == .darkAqua, "the application stays dark; only Pulse's themed windows follow the theme: \(steps)")
        }
    }

    /// A good theme pushed past the cap draws Classic and the notice says so, with no `.error` of its own; the cache
    /// holds only files read in the pass. The watch starts, stops, and outlives its store without reaching it.
    @MainActor static func checkCapAndWatch() {
        let fm = FileManager.default
        let folder = folder("cap")
        defer { try? fm.removeItem(at: folder) }
        let cache = ThemeFolder.Cache()
        try! ThemeStore.file(.groove).write(to: folder.appending(path: "zzz.json"))
        assert(ThemeFolder.scan(folder, cache: cache).found.map(\.id) == ["zzz"])
        for i in 0 ..< ThemeStore.maxThemes { try! ThemeStore.file(.classicSolid).write(to: folder.appending(path: String(format: "a-%03d.json", i))) }
        let scan = ThemeFolder.scan(folder, cache: cache)
        assert(!scan.found.contains { $0.id == "zzz" } && scan.issues["zzz"] == nil, "a file past the cap isn't drawn from the cache")
        assert(scan.notice?.contains("zzz.json") == true && scan.notice?.contains("draws Classic") == true, String(describing: scan.notice))
        assert(cache.lastGood.count == ThemeStore.maxThemes && cache.lastGood["zzz"] == nil, "the cache holds what was read: \(cache.lastGood.count)")
        assert(!fm.fileExists(atPath: folder.appending(path: "zzz.error").path))

        // the watch: started, then stopped; and a watched store let go of while the folder keeps changing
        let store = ThemeStore(folder: folder)
        assert(store.watch(), "the FSEvents stream starts")
        store.stopWatching()
        do {
            let gone = ThemeStore(folder: folder)
            assert(gone.watch())
        }
        for i in 0 ..< 5 { try! ThemeStore.file(.classicSolid).write(to: folder.appending(path: "late-\(i).json")) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // events for a released store: nothing to call, no crash
    }

    // MARK: Settings › Appearance

    /// The two menus, the three modes, a mismatched slot, and Increase Contrast.
    @MainActor static func checkModesAndSlots() {
        let folder = folder("modes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(folder: folder)
        // a light theme and a dark one of the person's own, beside the built-ins
        try! ThemeStore.file(ThemeGuide.paper).write(to: folder.appending(path: "paper.json"))
        try! guideExamples[1].write(to: folder.appending(path: "ember-glass.json"))
        settle(store, store.reload())
        assert(store.choices(for: .light).map(\.id) == ["classic-glass", "classic-solid", "groove-white", "groove-black",
                                                          "glacier", "orchard", "matcha-washi", "linen", "ember-glass", "paper"],
               "the light menu: \(store.choices(for: .light).map(\.id))")
        assert(store.choices(for: .dark).map(\.id) == ["classic-glass", "classic-solid", "groove", "abyss", "forest-canopy", "velvet",
                                                         "synthwave-chrome", "espresso-brass", "newsprint", "ember-glass"],
               "the dark menu: \(store.choices(for: .dark).map(\.id))")

        // Auto follows the system, live; Light and Dark keep to theirs
        var choice = ThemeChoice(mode: .auto, light: "groove-white", dark: "groove", classic: "classic-glass")
        store.setSystem(.light)
        assert(store.current(choice).id == "groove-white" && store.scheme(choice) == .light && store.skin(choice) == .grooveWhite)
        store.setSystem(.dark)
        assert(store.current(choice).id == "groove" && store.scheme(choice) == .dark && store.skin(choice) == .groove, "Auto follows a live change")
        choice.mode = .light
        assert(store.current(choice).id == "groove-white", "Light is pinned while the system is dark")
        store.setSystem(.light)
        choice.mode = .dark
        assert(store.current(choice).id == "groove" && store.scheme(choice) == .dark, "Dark is pinned while the system is light")
        // "any" draws the same in both; Classic stays dark in Light
        let classic = ThemeChoice(mode: .light, light: "classic-solid", dark: "classic-solid", classic: "classic-solid")
        assert(store.scheme(classic) == .dark && store.skin(classic) == .classic, "Classic in Light mode draws dark, as always")
        assert(store.skin(both("ember-glass")).glass == true && store.scheme(both("ember-glass")) == .dark)

        // a mismatched or unknown slot: the person's Classic draws there, and the menu shows it
        let mismatched = ThemeChoice(mode: .dark, light: "groove", dark: "groove-white", classic: "classic-glass")
        assert(store.theme(for: .dark, in: mismatched).id == "classic-glass" && store.theme(for: .light, in: mismatched).id == "classic-glass",
               "a light theme in the dark slot, and a dark one in the light slot, fall back to Classic")
        assert(store.theme(for: .light, in: ThemeChoice(mode: .light, light: "gone", dark: "groove", classic: "classic-solid")).id == "classic-solid")

        // Increase Contrast
        let white = store.skin(ThemeChoice(mode: .light, light: "groove-white", dark: "groove"), contrast: .increased)
        assert(white.ink.primary == "#000000" && white.groove?.onFace == "#000000" && white.accents == PulseSkin.grooveWhite.accents,
               "Increase Contrast on White: black ink, the deepened colours kept")
        let black = store.skin(ThemeChoice(mode: .light, light: "groove-black", dark: "groove"), contrast: .increased)
        assert(black.ink.primary == "#000000" && black.groove?.onFace == "#FFFFFF" && black.accents == PulseSkin.classic.accents,
               "Increase Contrast on Black: black ink on the slab, white marks on the dark hub, full colours on the black floor")
    }

    /// state.json from before Settings › Appearance, and after.
    static func checkMigration() {
        func persisted(_ json: String) -> AppState.Persisted { try! JSONDecoder().decode(AppState.Persisted.self, from: Data(json.utf8)) }
        let base = #""enabled":[],"order":[],"alwaysOnTop":true,"showOverlay":true"#
        // Classic with Glass, Classic with Solid: that Classic in both slots, Auto; nothing visibly changes
        assert(persisted("{\(base),\"appearance\":\"glass\"}").themeChoice == ThemeChoice(mode: .auto, light: "classic-glass", dark: "classic-glass", classic: "classic-glass"))
        assert(persisted("{\(base),\"appearance\":\"solid\"}").themeChoice == ThemeChoice(mode: .auto, light: "classic-solid", dark: "classic-solid", classic: "classic-solid"))
        assert(persisted("{\(base),\"glassTint\":false}").themeChoice.light == "classic-glass", "the older Tint setting still picks Glass")
        // Groove (the owner's Air): Auto, Groove White in light, Groove in dark
        assert(persisted("{\(base),\"appearance\":\"solid\",\"skin\":\"groove\"}").themeChoice == ThemeChoice(mode: .auto, light: "groove-white", dark: "groove", classic: "classic-solid"))
        assert(persisted("{\(base),\"skin\":\"groove-black\"}").themeChoice.light == "groove-black")
        // an unknown skin: that install's Classic
        assert(persisted("{\(base),\"appearance\":\"glass\",\"skin\":\"sunset\"}").themeChoice == ThemeChoice(mode: .auto, light: "classic-glass", dark: "classic-glass", classic: "classic-glass"))
        // a choice survives a save and a load; choosing writes all three and the Classic
        var p = persisted("{\(base),\"skin\":\"groove\"}")
        p.themeChoice = ThemeChoice(mode: .dark, light: "paper", dark: "classic-glass", classic: "classic-glass")
        let again = try! JSONDecoder().decode(AppState.Persisted.self, from: JSONEncoder().encode(p))
        assert(again.mode == .dark && again.lightTheme == "paper" && again.darkTheme == "classic-glass" && again.appearance == .glass)
        assert(again.themeChoice == p.themeChoice)
        // a mode this version doesn't know costs only the mode
        assert(persisted("{\(base),\"mode\":\"dusk\",\"lightTheme\":\"paper\"}").themeChoice.mode == .auto)
    }

    /// Classic draws byte for byte the same through Settings › Appearance in either mode, Glass and Solid, as with the
    /// values it always had (ClassicRenderChecks.sh compares those with f7e5f5c).
    @MainActor static func checkClassicInBothModes() {
        let store = ThemeStore(folder: folder("classic"))
        func render(_ scheme: ColorScheme, _ skin: PulseSkin, _ material: PulseAppearance) -> Data {
            let view = VStack(spacing: 12) {
                RingView(account: .claude, percent: 81, secondary: 40, size: 52)
                RingView(account: .codex, percent: 0, size: 52)
                BatteryRing(reading: BatteryReading(percent: 60, onAC: false, minutesLeft: nil), level: .ok, size: 52)
            }
            .padding(16).pulseSurface(in: Capsule()).padding(8).background(Color.white)
            .environment(\.colorScheme, scheme).environment(\.pulseSkin, skin).environment(\.pulseAppearance, material)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = renderer.cgImage!
            // raw RGBA in sRGB, as ClassicRender writes it
            let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: ctx.data!, count: image.width * image.height * 4)
        }
        // Solid: the pixels. Glass: Liquid Glass doesn't draw the same twice under ImageRenderer (measured: two renders of
        // one view differ), so its inputs: dark, Glass, and Classic's look (the flag aside, which no view reads).
        // The first two renders in a process differ from every later one (measured: a cache warming); after those, a
        // render repeats byte for byte, so the comparison starts there.
        for _ in 0 ..< 3 { _ = render(.dark, .classic, .solid) }
        let before = render(.dark, .classic, .solid)
        for mode in AppearanceMode.allCases {
            for system in [ColorScheme.light, .dark] {
                store.setSystem(system)
                for id in ThemeStore.classicIDs {
                    let choice = ThemeChoice(mode: mode, light: id, dark: id, classic: id)
                    var look = store.skin(choice)
                    let material = look.material
                    look.glass = nil
                    assert(store.scheme(choice) == .dark && look == .classic && material == (id == "classic-glass" ? .glass : .solid),
                           "\(id) in \(mode) with the system \(system) gets Classic's inputs")
                    if id == "classic-solid" {
                        assert(render(store.scheme(choice), store.skin(choice), material) == before, "\(id) in \(mode) with the system \(system) draws as Classic always did")
                    }
                }
            }
        }
    }
}
