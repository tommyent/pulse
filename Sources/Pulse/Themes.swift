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

extension PulseThemeFile {
    /// Picks from the theme collection (`themes/` in the repository), bundled as their files, the same bytes as there.
    static let picks: [(id: String, file: PulseThemeFile)] = ["glacier", "orchard", "matcha-washi", "linen", "abyss", "forest-canopy",
                                                              "velvet", "synthwave-chrome", "espresso-brass", "newsprint"].compactMap { id in
        guard let url = Bundle.pulseResources.url(forResource: "Resources/themes/\(id)", withExtension: "json"),
              let data = try? Data(contentsOf: url), case .success(let file) = ThemeStore.decode(data) else { return nil }
        return (id, file)
    }
    /// The themes inside the app, under the ids settings and theme files use. Always there; their ids are reserved.
    static let builtIn = pulseOwn + picks
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
    @Published private(set) var warnings: [String: String] = [:]   // a theme that loads: what's hard to read in it
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
            case .success(let added):
                message = "Imported \(added.name) as \(added.id).json." + (added.hardToRead ? " Some of its text or colours are hard to read; Settings says which." : "")
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
            if scan.warnings != warnings { warnings = scan.warnings }
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
            return lines.isEmpty ? .success(file) : .failure(Problem(text: Self.bounded(lines)))
        } catch let error as DecodingError {
            return .failure(Problem(text: Self.bounded(lines + ["- \(describe(error))"])))
        } catch {
            return .failure(Problem(text: "- \(error)"))
        }
    }

    /// What's hard to read in a theme that loads, as Settings shows it; nil when nothing is.
    nonisolated static func warnings(_ file: PulseThemeFile) -> String? {
        let lines = file.warnings()
        return lines.isEmpty ? nil : bounded(lines.map { "- \($0)" })
    }

    /// At most 20 problems of at most 200 characters each: a diagnostic stays well under `ThemeFolder.maxDiagnosticBytes`.
    nonisolated static func bounded(_ lines: [String]) -> String {
        lines.prefix(20).map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 }.joined(separator: "\n")
    }

    /// Every key path the format has, as components, from the built-ins with each optional value filled: White's
    /// light disc colours, Black's porthole, and an author, a description and the Glass flag.
    nonisolated static let knownKeys: Set<[String]> = {
        var sample = PulseThemeFile.grooveWhite
        sample.author = "a"
        sample.look.glass = true
        sample.look.liquid = true
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

    /// Settings' Copy Agent Prompt: one line that sends a coding agent to the guide, in the folder its theme goes in.
    /// Without a name, the agent picks one.
    nonisolated static func agentPrompt(folder: URL, name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Read \"\(folder.appending(path: guideName).path(percentEncoded: false))\" and make a Pulse theme"
            + (name.isEmpty ? "" : " called \(name)") + "; save it as JSON in that folder."
    }

    /// A theme as Pulse writes it: pretty-printed, each shadow on one line.
    /// Strings are copied exactly as the encoder wrote them; only the layout between values changes, so a name, an
    /// author or a description with brackets in it comes out as it went in.
    nonisolated static func file(_ set: PulseThemeFile) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]   // the same bytes every time
        let text = Array(String(decoding: try! encoder.encode(set), as: UTF8.self).utf8)
        /// The index just past the string starting at `i` (a quote), its escapes included.
        func stringEnd(_ i: Int) -> Int {
            var j = i + 1
            while j < text.count, text[j] != UInt8(ascii: "\"") { j += text[j] == UInt8(ascii: "\\") ? 2 : 1 }
            return j + 1
        }
        /// The index of the `]` closing the array at `i` if it holds only plain values (no array or object), else nil.
        func flatEnd(_ i: Int) -> Int? {
            var j = i + 1
            while j < text.count {
                switch text[j] {
                case UInt8(ascii: "\""): j = stringEnd(j)
                case UInt8(ascii: "["), UInt8(ascii: "{"): return nil
                case UInt8(ascii: "]"): return j
                default: j += 1
                }
            }
            return nil
        }
        var out: [UInt8] = [], i = 0
        while i < text.count {
            switch text[i] {
            case UInt8(ascii: "\""):
                let end = stringEnd(i)
                out += text[i ..< end]; i = end
            case UInt8(ascii: "["):
                guard let close = flatEnd(i) else { out.append(text[i]); i += 1; continue }
                // a shadow and other lists of plain values on one line: "[a, b, c]", the values untouched
                out.append(UInt8(ascii: "["))
                var j = i + 1
                while j < close {
                    switch text[j] {
                    case UInt8(ascii: "\""): let end = stringEnd(j); out += text[j ..< end]; j = end
                    case UInt8(ascii: ","): out += Array(", ".utf8); j += 1
                    case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t"), UInt8(ascii: "\r"): j += 1
                    default: out.append(text[j]); j += 1
                    }
                }
                out.append(UInt8(ascii: "]")); i = close + 1
            default:
                out.append(text[i]); i += 1
            }
        }
        return Data(out + Array("\n".utf8))
    }
}

// MARK: - checks on a theme's values

extension PulseThemeFile {
    /// Everything wrong with a decoded theme, each as "key: why". Empty: Pulse may draw it.
    func problems() -> [String] { check().problems }

    /// What's hard to read in a theme that can be used: each pair under the floor, with where. Empty for the built-ins.
    func warnings() -> [String] { check().warnings }

    /// Problems (the theme can't be used) and warnings (it can, but some text or colour is hard to read).
    func check() -> (problems: [String], warnings: [String]) {
        var out: [String] = [], warnings: [String] = []
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
        if look.groove == nil, look.liquid != true, scheme == .light {
            out.append("appearance: a flat theme (no groove) uses Classic's drawing, which is dark only; give it a dark surface, or groove")
        }
        if look.glass != nil, look.groove != nil { out.append("glass: for a flat theme only; a theme with groove draws its own slab") }
        out += look.problems("", appearance: scheme, warnings: &warnings)
        return (out, warnings)
    }
}

extension PulseSkin {
    /// Ranges, the rings' geometry and the contrast floor (Fable's: 4.5:1 for text on its slab, 3:1 for a ring's or a
    /// bar's colour on the floor it lies on, and for marks on a ring's hub).
    func problems(_ at: String, appearance: ColorScheme, warnings: inout [String]) -> [String] {
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
        /// The worst contrast of `colour(ground)` against a gradient's every colour (`SkinColor.samples`), if under
        /// `needed`: where it is, e.g. "groove.slabTop to groove.slab (at 40%): 1.00:1, text needs 4.5:1".
        func along(_ stops: [(String, SkinColor)], needed: Double, what: String, _ colour: (LinearRGB) -> LinearRGB) -> String? {
            var worst: (ratio: Double, at: String)?
            for sample in SkinColor.samples(stops.map(\.1)) {
                let r = colour(sample.color).contrast(with: sample.color)
                if r < needed, r < (worst?.ratio ?? .infinity) {
                    let segment = stops.count == 1 ? "\(at)\(stops[0].0) \(stops[0].1.hex)"
                        : "the gradient from \(at)\(stops[sample.segment].0) to \(at)\(stops[sample.segment + 1].0) (at \(Int((sample.t * 100).rounded()))%)"
                    worst = (r, segment)
                }
            }
            return worst.map { "\($0.at): \($0.ratio.formatted(.number.precision(.fractionLength(2)))):1, \(what) needs \(needed.formatted()):1" }
        }
        func opaque(_ path: String, _ c: SkinColor) -> Bool {
            if c.alpha < 1 { warnings.append("\(at)\(path): translucent, so how well it reads depends on what's behind it") }
            return c.alpha == 1
        }
        func floor(_ path: String, _ c: SkinColor, on groundPath: String, _ ground: SkinColor, _ needed: Double, _ what: String) {
            guard opaque(path, c), opaque(groundPath, ground) else { return }
            let r = c.contrast(with: ground)
            if r < needed {
                warnings.append("\(at)\(path) \(c.hex) on \(at)\(groundPath) \(ground.hex): \(r.formatted(.number.precision(.fractionLength(2)))):1, \(what) needs \(needed.formatted()):1")
            }
        }
        // text lies anywhere on the slab, so on every colour its gradient passes through, not only its stops
        let slab: [(String, SkinColor)] = groove.map { [("groove.slabTop", $0.slabTop), ("groove.slab", $0.slab), ("groove.slabBottom", $0.slabBottom)] }
            ?? [("surface", surface)]
        if slab.allSatisfy({ opaque($0.0, $0.1) }) {
            for (path, c) in [("ink.primary", ink.primary), ("ink.secondary", ink.secondary), ("ink.alert", ink.alert)] {
                guard let c, opaque(path, c) else { continue }
                along(slab, needed: 4.5, what: "text") { _ in c.linear }.map { warnings.append("\(at)\(path) \(c.hex) on \($0)") }
            }
            if primaryInk.alpha == 1 {   // a number from an earlier refresh, drawn at `stale`
                along(slab, needed: 4.5, what: "text") { primaryInk.linear.over($0, opacity: stale) }
                    .map { warnings.append("\(at)stale: ink at \(stale.formatted()) on \($0)") }
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
        let hub = [("groove.faceTop", g.faceTop), ("groove.face", g.face), ("groove.faceBottom", g.faceBottom)]
        if opaque("groove.onFace", g.onFace), hub.allSatisfy({ opaque($0.0, $0.1) }) {
            along(hub, needed: 3, what: "a mark on the hub") { _ in g.onFace.linear }.map { warnings.append("\(at)groove.onFace \(g.onFace.hex) on \($0)") }
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

/// A colour where any two can be mixed and measured: linear light, sRGB primaries, values past 0 to 1 kept (a P3 red).
struct LinearRGB: Equatable {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    static func decode(_ v: Double) -> Double { v.sign == .minus ? -decode(-v) : v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Double) -> Double { v.sign == .minus ? -encode(-v) : v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    var luminance: Double { max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b) }
    func contrast(with other: LinearRGB) -> Double {
        let (x, y) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (x + 0.05) / (y + 0.05)
    }
    /// `t` of the way to `other`: in sRGB's encoded values, or in linear light.
    func mixed(_ other: LinearRGB, _ t: Double, encoded: Bool) -> LinearRGB {
        func mix(_ a: Double, _ b: Double) -> Double {
            encoded ? Self.decode(Self.encode(a) * (1 - t) + Self.encode(b) * t) : a * (1 - t) + b * t
        }
        return LinearRGB(mix(r, other.r), mix(g, other.g), mix(b, other.b))
    }
    /// This colour at `opacity` over `ground`, blended in sRGB's encoded values as compositing does.
    func over(_ ground: LinearRGB, opacity: Double) -> LinearRGB { ground.mixed(self, opacity, encoded: true) }
}

extension SkinColor {
    var alpha: Double { components[3] }

    /// Every colour a gradient through `stops` passes, closely enough to find its worst point: 64 steps between each
    /// pair, mixed both in sRGB's encoded values and in linear light (renderers differ). Each stop is first converted
    /// to one space (linear extended sRGB), so an sRGB stop beside a Display P3 one mixes as the two colours they are.
    static func samples(_ stops: [SkinColor]) -> [(color: LinearRGB, segment: Int, t: Double)] {
        let linear = stops.map(\.linear)
        guard linear.count > 1 else { return linear.map { ($0, 0, 0) } }
        var out: [(LinearRGB, Int, Double)] = []
        for segment in 0 ..< linear.count - 1 {
            let a = linear[segment], b = linear[segment + 1]
            for step in 0 ... 64 {
                let t = Double(step) / 64
                out.append((a.mixed(b, t, encoded: true), segment, t))
                out.append((a.mixed(b, t, encoded: false), segment, t))
            }
        }
        return out
    }

    /// The colour in linear extended sRGB: Display P3 converted with its standard matrix, nothing clamped.
    var linear: LinearRGB {
        let v = components.prefix(3).map(LinearRGB.decode)
        guard hex.hasPrefix("p3:") else { return LinearRGB(v[0], v[1], v[2]) }
        return LinearRGB(1.2249401 * v[0] - 0.2249404 * v[1],
                         -0.0420569 * v[0] + 1.0420571 * v[1],
                         -0.0196376 * v[0] - 0.0786361 * v[1] + 1.0982735 * v[2])
    }

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
