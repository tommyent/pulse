import AppKit
import Combine
import CoreServices
import SwiftUI

/// A theme Pulse can draw: a built-in, or a file in the Themes folder that passed every check.
struct PulseTheme: Equatable, Identifiable {
    let id: String   // the file's name without ".json"; what state.json keeps
    let file: PulseThemeFile
    var builtIn = false
}

/// Settings › Appearance: when Pulse is light or dark, and the theme for each.
enum AppearanceMode: String, Codable, CaseIterable { case auto, light, dark }

/// What the person chose: the mode, a light theme and a dark theme by id, and their Classic (Glass or Solid), which
/// draws in a slot whose theme Pulse doesn't have or that doesn't fit it.
struct ThemeChoice: Equatable {
    var mode: AppearanceMode = .auto
    var light = "classic-solid"
    var dark = "classic-solid"
    var classic = "classic-solid"
}

/// Pulse's themes: the built-ins, always there, and one JSON file per theme in Application Support/Pulse/Themes,
/// re-read when the folder changes. A file that fails a check never draws: Pulse keeps its last good version (or
/// Classic) and writes why to `<name>.error` beside it, removed once the file is fixed. The built-ins and the guide
/// are written into the folder at each launch as examples; files with a built-in's name are Pulse's and never read.
/// Every file is read and written on one background queue (`ThemeFolder`); the results are published on the main actor.
@MainActor final class ThemeStore: ObservableObject {
    static let shared = ThemeStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pulse/Themes"))

    nonisolated static let maxFileBytes = 64 * 1024
    nonisolated static let maxThemes = 50   // files read, beyond the built-ins
    nonisolated static let guideName = "AGENTS.md"
    nonisolated static let classicIDs = ["classic-glass", "classic-solid"]

    @Published private(set) var themes: [PulseTheme] = PulseThemeFile.builtIn.map { PulseTheme(id: $0.id, file: $0.file, builtIn: true) }
    @Published private(set) var problems: [String: String] = [:]   // a file's id: what its .error says
    @Published private(set) var notice: String?                    // about the folder as a whole (too many files)
    @Published private(set) var systemScheme: ColorScheme = .dark
    @Published private(set) var choice = ThemeChoice()             // as state.json has it

    let folder: URL
    private let io = DispatchQueue(label: "io.github.tommyent.pulse.themes")
    private let cache = ThemeFolder.Cache()   // touched on `io` only
    private var asked = 0
    private(set) var finished = 0             // the last folder job whose results are published
    nonisolated(unsafe) private var stream: FSEventStreamRef?   // main actor only; read by deinit, when nothing else can
    private var pending: DispatchWorkItem?

    init(folder: URL) { self.folder = folder }

    // MARK: what views draw with

    /// The mode in effect: the system's in Auto, else the one pinned.
    func mode(_ c: ThemeChoice) -> ColorScheme { c.mode == .auto ? systemScheme : c.mode == .light ? .light : .dark }

    /// What a slot draws: its chosen theme if Pulse has it and it fits the slot, else the person's Classic.
    func theme(for slot: ColorScheme, in c: ThemeChoice) -> PulseTheme {
        let id = slot == .light ? c.light : c.dark
        if let chosen = themes.first(where: { $0.id == id }), chosen.file.appearance.fits(slot) { return chosen }
        return themes.first { $0.id == c.classic } ?? themes.first { $0.id == "classic-solid" }!
    }
    /// The theme drawn now, the appearance its windows take, and its look (adjusted for Increase Contrast).
    func current(_ c: ThemeChoice) -> PulseTheme { theme(for: mode(c), in: c) }
    func scheme(_ c: ThemeChoice) -> ColorScheme { current(c).file.scheme }
    func skin(_ c: ThemeChoice, contrast: ColorSchemeContrast = .standard) -> PulseSkin {
        let look = current(c).file.look
        return contrast == .increased ? look.increasedContrast() : look
    }
    /// A slot's menu: every theme that can be light, or dark ("any" in both).
    func choices(for slot: ColorScheme) -> [PulseTheme] { themes.filter { $0.file.appearance.fits(slot) } }

    // MARK: the folder

    /// At launch: the examples and the guide into the folder, every file read, the folder watched, the system's
    /// appearance followed, and the person's choice mirrored. The application itself stays dark (`NSApp.appearance`,
    /// set at launch as always); only Pulse's own themed windows take a theme's appearance (`PulsePresentation`), so
    /// other windows (the Grok sign-in, the Codex approval alerts) keep the dark they always had.
    func start(_ state: AppState) {
        writeExamples()
        reload()
        watch()
        followSystem()
        follow(state.$persisted.map(\.themeChoice))
    }

    /// The person's choice, as a publisher gives it. Only the ids: a view resolves them against `themes` when it draws,
    /// so a reload is read from the new list, never the one before it.
    func follow<P: Publisher>(_ choices: P) where P.Output == ThemeChoice, P.Failure == Never {
        followed = choices.removeDuplicates().sink { [weak self] c in
            MainActor.assumeIsolated { if self?.choice != c { self?.choice = c } }
        }
    }
    private var followed: AnyCancellable?

    func setSystem(_ scheme: ColorScheme) { if systemScheme != scheme { systemScheme = scheme } }

    /// The system's appearance, from its own setting: `NSApp`'s effective appearance is Pulse's dark, not the system's.
    private func followSystem() {
        readSystem()
        systemWatch = DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"),
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSystem() }
        }
    }
    private func readSystem() {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        setSystem(style == "Dark" ? .dark : .light)
    }
    private var systemWatch: NSObjectProtocol?

    /// Writes the examples and the guide in the background (`ThemeFolder.writeExamples`). Returns the job's number:
    /// `finished` reaches it once done.
    @discardableResult func writeExamples() -> Int {
        run { folder, cache in cache.kept = ThemeFolder.writeExamples(folder); return nil }
    }

    /// Reads every theme file again in the background; what changed is published on the main actor, nothing else.
    @discardableResult func reload() -> Int {
        run { folder, cache in ThemeFolder.scan(folder, cache: cache) }
    }

    /// A theme file from anywhere (Settings' Import…, or one dropped on Settings), checked as the folder's own are and
    /// copied in under a free name, then the folder read again. `done` gets what to tell the person, on the main actor.
    @discardableResult func importTheme(_ source: URL, done: @escaping @MainActor (String) -> Void = { _ in }) -> Int {
        let number = run { folder, cache in
            let result = ThemeFolder.importTheme(source, into: folder)
            let message: String
            switch result {
            case .success(let added): message = "Imported \(added.name) as \(added.id).json."
            case .failure(let problem): message = "\(source.lastPathComponent) wasn't imported:\n\(problem.text)"
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(message) } }
            return ThemeFolder.scan(folder, cache: cache)
        }
        return number
    }

    private func run(_ job: @escaping @Sendable (URL, ThemeFolder.Cache) -> ThemeFolder.Scan?) -> Int {
        asked += 1
        let number = asked, folder = folder, cache = cache
        io.async { [weak self] in
            let scan = job(folder, cache)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(scan, number) } }
        }
        return number
    }

    private func publish(_ scan: ThemeFolder.Scan?, _ number: Int) {
        if let scan {
            let all = PulseThemeFile.builtIn.map { PulseTheme(id: $0.id, file: $0.file, builtIn: true) } + scan.found
            if all != themes { themes = all }
            if scan.issues != problems { problems = scan.issues }
            if scan.notice != notice { notice = scan.notice }
        }
        finished = max(finished, number)
    }

    /// A change in the folder: read it again once things settle (an editor's save is several events).
    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// FSEvents on the folder: the system tells Pulse when something in it changes, and nothing runs in between.
    /// The stream holds this box, not the store: a callback after the store is gone finds nothing to call.
    private final class WatchBox {
        weak var store: ThemeStore?
        init(_ store: ThemeStore) { self.store = store }
    }

    /// Whether the folder is watched: false if the stream couldn't be made or started (Pulse then reads it at launch only).
    @discardableResult func watch() -> Bool {
        guard stream == nil else { return true }
        let box = Unmanaged.passRetained(WatchBox(self))
        defer { box.release() }   // the stream keeps its own reference through `retain`
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(),
                                           retain: { info in UnsafeRawPointer(Unmanaged<WatchBox>.fromOpaque(info!).retain().toOpaque()) },
                                           release: { info in Unmanaged<WatchBox>.fromOpaque(info!).release() },
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let box = Unmanaged<WatchBox>.fromOpaque(info!).takeUnretainedValue()
            MainActor.assumeIsolated { box.store?.scheduleReload() }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return false }
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    /// The stream stopped, invalidated and released together, and any reload still waiting cancelled.
    func stopWatching() {
        pending?.cancel()
        pending = nil
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    // MARK: one file

    struct Problem: Error, Equatable { let text: String }

    /// A theme file's bytes, or why it can't be used: its format first (a newer one is refused with that alone), then
    /// unknown and missing keys, every value's type and range, the rings' geometry and the contrast floor.
    nonisolated static func decode(_ data: Data) -> Result<PulseThemeFile, Problem> {
        guard data.count <= maxFileBytes else { return .failure(Problem(text: "- a theme file is at most \(maxFileBytes / 1024) KB")) }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "\(error)"
            return .failure(Problem(text: "- not JSON: \(detail)"))
        }
        guard let object = raw as? [String: Any] else { return .failure(Problem(text: "- a theme file is one JSON object, { … }")) }
        let current = PulseThemeFile.currentFormat
        switch object["format"] {
        case nil: return .failure(Problem(text: "- format: missing; a theme file says which format it's written in, \"format\": \(current)"))
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue == n.doubleValue.rounded():
            if n.intValue > current {
                return .failure(Problem(text: "- format \(n.intValue): this theme was made for a newer Pulse, which writes format \(n.intValue); this Pulse reads format \(current). Update Pulse to use it."))
            }
            if n.intValue < 1 { return .failure(Problem(text: "- format: \(n.intValue) isn't a format; this Pulse reads format \(current)")) }
        default: return .failure(Problem(text: "- format: should be a whole number, \(current)"))
        }
        var lines = unknownKeys(raw).map { "- \($0): not a key Pulse knows (a typo, or a newer Pulse's)" }
        do {
            let file = try JSONDecoder().decode(PulseThemeFile.self, from: data)
            lines += file.problems().map { "- \($0)" }
            return lines.isEmpty ? .success(file) : .failure(Problem(text: lines.prefix(20).joined(separator: "\n")))
        } catch let error as DecodingError {
            return .failure(Problem(text: (lines + ["- \(describe(error))"]).prefix(20).joined(separator: "\n")))
        } catch {
            return .failure(Problem(text: "- \(error)"))
        }
    }

    /// Every key path the format has, as components, from the built-ins with each optional value filled: White's
    /// light disc colours, Black's porthole, and an author, a description and the Glass flag.
    nonisolated static let knownKeys: Set<[String]> = {
        var sample = PulseThemeFile.grooveWhite
        sample.author = "a"
        sample.look.glass = true
        sample.look.groove?.porthole = PulseSkin.grooveBlack.groove?.porthole
        var keys = Set<[String]>()
        collectKeys(try! JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)), []) { keys.insert($0) }
        return keys
    }()

    /// Each key in a JSON object, as components, never a joined string, so a key with dots in it can't pass for a
    /// nested one.
    nonisolated private static func collectKeys(_ object: Any, _ path: [String], _ found: ([String]) -> Void) {
        guard let dict = object as? [String: Any] else { return }
        for (key, value) in dict {
            found(path + [key])
            collectKeys(value, path + [key], found)
        }
    }

    nonisolated private static func unknownKeys(_ raw: Any) -> [String] {
        var unknown: [String] = []
        collectKeys(raw, []) { path in
            if !knownKeys.contains(path) { unknown.append(path.map { $0.contains(".") ? "\"\($0)\"" : $0 }.joined(separator: ".")) }
        }
        return unknown.sorted()
    }

    nonisolated private static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().replacingOccurrences(of: ".[", with: "[").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case .keyNotFound(let key, let c): return "\(path(c.codingPath + [key])): missing"
        case .typeMismatch(let type, let c):
            let kind = type == String.self ? "a string" : type == Double.self || type == CGFloat.self ? "a number" : "\(type)"
            return "\(path(c.codingPath)): should be \(kind)"
        case .valueNotFound(_, let c): return "\(path(c.codingPath)): missing"
        case .dataCorrupted(let c): return "\(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return "\(error)"
        }
    }

    /// A theme as Pulse writes it: pretty-printed, each shadow on one line.
    nonisolated static func file(_ set: PulseThemeFile) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]   // the same bytes every time
        let text = String(decoding: try! encoder.encode(set), as: UTF8.self)
        let joined = text.replacing(#/\[\s*([^\[\]\{\}]*?)\s*\]/#) { match in
            "[" + match.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ") + "]"
        }
        return Data((joined + "\n").utf8)
    }
}

// MARK: - checks on a theme's values

extension PulseThemeFile {
    /// Everything wrong with a decoded theme, each as "key: why". Empty: Pulse may draw it.
    func problems() -> [String] {
        var out: [String] = []
        func text(_ key: String, _ value: String?, max: Int, lines: Bool = false) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count > max { out.append("\(key): 1 to \(max) characters") }
            if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !(lines && $0 == "\n") }) {
                out.append("\(key): no control characters\(lines ? " (line breaks are fine)" : "")")
            }
        }
        text("name", name, max: 40)
        text("author", author, max: 80)
        text("description", description, max: 300, lines: true)
        if look.groove == nil, scheme == .light {
            out.append("appearance: a flat theme (no groove) uses Classic's drawing, which is dark only; give it a dark surface, or groove")
        }
        if look.glass != nil, look.groove != nil { out.append("glass: for a flat theme only; a theme with groove draws its own slab") }
        out += look.problems("", appearance: scheme)
        return out
    }
}

extension PulseSkin {
    /// Ranges, the rings' geometry and the contrast floor (Fable's: 4.5:1 for text on its slab, 3:1 for a ring's or a
    /// bar's colour on the floor it lies on, and for marks on a ring's hub).
    func problems(_ at: String, appearance: ColorScheme) -> [String] {
        var out: [String] = []
        func range(_ path: String, _ v: Double, _ r: ClosedRange<Double>) {
            if !r.contains(v) { out.append("\(at)\(path): \(v.formatted()) is outside \(r.lowerBound.formatted()) to \(r.upperBound.formatted())") }
        }
        func shadow(_ path: String, _ s: SkinShadow, reach: Double = 20, blur: Double = 24) {
            range("\(path) x", Double(s.x), -reach ... reach); range("\(path) y", Double(s.y), -reach ... reach)
            range("\(path) blur", Double(s.blur), 0 ... blur); range("\(path) opacity", s.opacity, 0 ... 1)
        }
        func shadows(_ path: String, _ list: [SkinShadow], max: Int = 4, reach: Double = 20, blur: Double = 24) {
            if list.count > max { out.append("\(at)\(path): at most \(max) shadows") }
            for (i, s) in list.enumerated() { shadow("\(path)[\(i)]", s, reach: reach, blur: blur) }
        }
        range("stale", stale, 0 ... 1)

        // the contrast floor
        let assumedInk: SkinColor = appearance == .dark ? "#FFFFFF" : "#000000"   // the system's label colour
        let primaryInk = ink.primary ?? assumedInk
        func opaque(_ path: String, _ c: SkinColor) -> Bool {
            if c.alpha < 1 { out.append("\(at)\(path): must be opaque (contrast is checked against it)") }
            return c.alpha == 1
        }
        func floor(_ path: String, _ c: SkinColor, on groundPath: String, _ ground: SkinColor, _ needed: Double, _ what: String) {
            guard opaque(path, c), opaque(groundPath, ground) else { return }
            let r = c.contrast(with: ground)
            if r < needed {
                out.append("\(at)\(path) \(c.hex) on \(at)\(groundPath) \(ground.hex): \(r.formatted(.number.precision(.fractionLength(2)))):1, \(what) needs \(needed.formatted()):1")
            }
        }
        // text lies anywhere on the slab, so on every colour of its gradient: its middle and both ends
        let grounds = groove.map { [("groove.slab", $0.slab), ("groove.slabTop", $0.slabTop), ("groove.slabBottom", $0.slabBottom)] }
            ?? [("surface", surface)]
        for (groundPath, ground) in grounds {
            for (path, c) in [("ink.primary", ink.primary), ("ink.secondary", ink.secondary), ("ink.alert", ink.alert)] {
                if let c { floor(path, c, on: groundPath, ground, 4.5, "text") }
            }
            if primaryInk.alpha == 1, ground.alpha == 1 {   // a number from an earlier refresh, drawn at `stale`
                let r = primaryInk.over(ground, opacity: stale).contrast(with: ground)
                if r < 4.5 { out.append("\(at)stale: ink at \(stale.formatted()) on \(at)\(groundPath) is \(r.formatted(.number.precision(.fractionLength(2)))):1, text needs 4.5:1") }
            }
        }
        let colours: [(String, SkinColor?)] = [("claude", accents.claude), ("codex", accents.codex), ("grok", accents.grok),
                                               ("antigravity", accents.antigravity), ("antigravity2", accents.antigravity2),
                                               ("battery", accents.battery), ("breakBar", accents.breakBar)]
        let floors = groove.map { [("groove.floor", $0.floor), ("groove.barFloor", $0.barFloor)] } ?? [("surface", surface)]
        for (name, c) in colours {
            guard let c else { continue }
            for (fp, f) in floors { floor("accents.\(name)", c, on: fp, f, 3, "a ring's colour") }
        }

        guard let g = groove else { return out }
        for (path, face) in [("groove.face", g.face), ("groove.faceTop", g.faceTop), ("groove.faceBottom", g.faceBottom)] {
            floor("groove.onFace", g.onFace, on: path, face, 3, "a mark on the hub")
        }
        // the agents ring's "+3", on its own disc; left out, the two are Pulse's light grey on the face lifted 9% toward
        // white (blended here in sRGB, close to the perceptual mix that draws it)
        let disc = g.bubble ?? (g.face.alpha == 1 ? (try! SkinColor("#FFFFFF")).over(g.face, opacity: 0.09) : g.face)
        floor(g.bubbleInk == nil ? "groove.bubbleInk (left out: light grey)" : "groove.bubbleInk", g.bubbleInk ?? "srgb:0.87,0.87,0.87",
              on: g.bubble == nil ? "groove.bubble (left out: the face lifted)" : "groove.bubble", disc, 4.5, "text")

        // sizes and the rings' geometry, in ring units: 100 is the ring's size, and it draws in a box of 120
        range("groove.grain", g.grain, 0 ... 1)
        for (path, t) in [("groove.outer", g.outer), ("groove.inner", g.inner)] {
            range("\(path).radius", t.radius, 1 ... 60); range("\(path).channel", t.channel, 0.5 ... 30); range("\(path).tube", t.tube, 0.5 ... 30)
            if t.tube > t.channel { out.append("\(at)\(path).tube: wider than its channel (\(t.channel.formatted()))") }
        }
        let outerEdge = g.outer.radius + g.outer.channel / 2, outerInside = g.outer.radius - g.outer.channel / 2
        let innerEdge = g.inner.radius + g.inner.channel / 2, innerInside = g.inner.radius - g.inner.channel / 2
        if outerEdge > 60 { out.append("\(at)groove.outer: reaches \(outerEdge.formatted()), past the ring's box (60)") }
        if innerEdge > outerInside { out.append("\(at)groove.inner: reaches \(innerEdge.formatted()), into the outer channel (from \(outerInside.formatted()))") }
        range("groove.hubSingle", g.hubSingle, 3 ... 60); range("groove.hubDouble", g.hubDouble, 3 ... 60)
        if g.hubSingle > outerInside { out.append("\(at)groove.hubSingle: \(g.hubSingle.formatted()) covers the outer channel (from \(outerInside.formatted()))") }
        if g.hubDouble > innerInside { out.append("\(at)groove.hubDouble: \(g.hubDouble.formatted()) covers the inner channel (from \(innerInside.formatted()))") }
        if let p = g.porthole {
            range("groove.porthole.radius", p.radius, 1 ... 58)
            if p.radius < outerEdge { out.append("\(at)groove.porthole.radius: smaller than the outer channel (\(outerEdge.formatted()))") }
            shadow("groove.porthole.lip", p.lip, reach: 2, blur: 2); shadows("groove.porthole.inner", p.inner, reach: 10, blur: 10)
        }
        range("groove.barSlot", g.barSlot, 2 ... 20); range("groove.barFill", g.barFill, 1 ... 20); range("groove.barRadius", g.barRadius, 0 ... 10)
        if g.barFill > g.barSlot { out.append("\(at)groove.barFill: wider than groove.barSlot") }
        if g.barRadius * 2 > g.barSlot { out.append("\(at)groove.barRadius: more than half of groove.barSlot") }

        // shadows: offsets and blurs that stay near what they shade (cost and the panel's 12 pt margin)
        shadows("groove.raise", g.raise)
        shadows("groove.drop", g.drop, max: 2)
        for (i, s) in g.drop.enumerated() where max(abs(s.x), abs(s.y)) + s.blur > 12 {
            out.append("\(at)groove.drop[\(i)]: reaches \((max(abs(s.x), abs(s.y)) + s.blur).formatted()) pt; the panel leaves 12")
        }
        shadow("groove.pressLip", g.pressLip, reach: 3, blur: 3)
        shadows("groove.pressInner", g.pressInner); shadow("groove.tubeBleed", g.tubeBleed); shadow("groove.tubeInner", g.tubeInner)
        if let wall = g.wall { shadow("groove.wall", wall) }
        shadows("groove.dome", g.dome); shadow("groove.bubbleDrop", g.bubbleDrop, reach: 4, blur: 4); shadows("groove.bubbleInner", g.bubbleInner)
        shadows("groove.logoDrop", g.logoDrop, reach: 8, blur: 8); shadows("groove.logoInner", g.logoInner)
        shadows("groove.type", g.type, reach: 0.5, blur: 0.5)   // in ems
        shadows("groove.glyph", g.glyph, reach: 8, blur: 8)
        shadows("groove.barPress", g.barPress, reach: 4, blur: 4); shadow("groove.barLip", g.barLip, reach: 3, blur: 3)
        shadows("groove.fillInner", g.fillInner, reach: 4, blur: 4); shadow("groove.fillDrop", g.fillDrop, reach: 3, blur: 3)
        return out
    }
}

extension SkinColor {
    var alpha: Double { components[3] }

    /// WCAG's contrast ratio, 1 to 21.
    func contrast(with other: SkinColor) -> Double {
        let (a, b) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (a + 0.05) / (b + 0.05)
    }

    /// This colour at `opacity` over `ground`, blended as written (in the ground's space).
    func over(_ ground: SkinColor, opacity: Double) -> SkinColor {
        let mixed = (0 ..< 3).map { components[$0] * opacity + ground.components[$0] * (1 - opacity) }
        return try! SkinColor((ground.hex.hasPrefix("p3:") ? "p3:" : "srgb:") + mixed.map { String(max(0, min(1, $0))) }.joined(separator: ","))
    }
}
