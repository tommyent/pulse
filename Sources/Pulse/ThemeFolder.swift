import Darwin
import Foundation

/// The Themes folder's file work, done on `ThemeStore`'s background queue, never the main actor. Every read is bounded
/// and comes from one descriptor opened on a regular file (not a link, a pipe or a folder); Pulse writes and removes
/// only the files it owns: the three examples, the guide, and the `.error` files that start with its own first line.
enum ThemeFolder {
    static let maxEntries = 500     // directory entries looked at
    static let maxProblems = 10     // `.error` files written in one pass (the three built-ins come first)

    /// What a pass found: the themes that draw, what's wrong with each file, and anything about the folder as a whole.
    struct Scan: Sendable {
        var found: [PulseTheme] = []
        var issues: [String: String] = [:]
        var notice: String?
    }

    /// What the queue keeps between passes: each file's last good version, and what launch left alone.
    final class Cache: @unchecked Sendable {   // used on the store's queue only
        var lastGood: [String: PulseThemeFile] = [:]
        var kept: [String: String] = [:]
    }

    // MARK: reading

    enum Read: Equatable {
        case data(Data)
        case tooBig
        case missing
        case notRegular(String)
        case unreadable(String)
    }

    /// At most `limit` bytes of a regular file, read from the one descriptor that was checked: no link is followed,
    /// opening doesn't wait on a pipe, and a file that grows or is swapped after the check can't be read past `limit`.
    static func read(_ url: URL, limit: Int) -> Read {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return .missing
            case ELOOP: return .notRegular("a link")
            default: return .unreadable(String(cString: strerror(errno)))
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable(String(cString: strerror(errno))) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notRegular(info.st_mode & S_IFMT == S_IFDIR ? "a folder" : "not a regular file") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= limit {
            let n = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data.count > limit ? .tooBig : .data(data)
    }

    /// An entry itself, without following a link.
    static func kind(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }

    /// The names among the folder's first `max` entries, hidden ones read but left out, and whether there were more.
    static func names(_ folder: URL, max: Int = maxEntries) -> (names: [String], more: Bool) {
        guard let dir = opendir(folder.path) else { return ([], false) }
        defer { closedir(dir) }
        var out: [String] = [], seen = 0
        while let entry = readdir(dir) {
            seen += 1   // every entry counts, hidden ones too
            if seen > max { return (out, true) }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if !name.hasPrefix(".") { out.append(name) }
        }
        return (out, false)
    }

    /// The first line of every `.error` Pulse writes (for people; ownership is the mark below).
    static func errorHeader(_ id: String) -> String { "\(id).json can't be used" }

    /// The extended attribute Pulse sets on each `.error` file it writes: what makes one Pulse's, whatever it says.
    static let diagnosticMark = "io.github.tommyent.pulse.diagnostic"
    static let maxDiagnosticBytes = 8 * 1024

    /// A `.error` Pulse wrote: a regular file (not a link to one) carrying Pulse's mark.
    static func isOurError(_ url: URL) -> Bool {
        kind(url) == S_IFREG && getxattr(url.path, diagnosticMark, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// A diagnostic, marked as Pulse's before it takes its name: written beside it, marked, then renamed into place.
    /// With no file there the rename is exclusive, so a file someone makes meanwhile is never replaced; an existing
    /// one is replaced only if it's Pulse's.
    static func writeDiagnostic(_ data: Data, to url: URL) {
        let exists = kind(url) != nil
        guard !exists || isOurError(url) else { return }
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard (try? data.prefix(maxDiagnosticBytes).write(to: temp, options: .withoutOverwriting)) != nil else { return }
        let placed = setxattr(temp.path, diagnosticMark, "1", 1, 0, XATTR_NOFOLLOW) == 0
            && (exists ? rename(temp.path, url.path) : renamex_np(temp.path, url.path, UInt32(RENAME_EXCL))) == 0
        if !placed { unlink(temp.path) }
    }

    /// A file of Pulse's that differs from `content` (missing counts as different).
    static func differs(_ url: URL, from content: Data) -> Bool { read(url, limit: content.count) != .data(content) }

    // MARK: writing

    /// The built-ins as files to copy, and the guide. A built-in's file that differs from what this version ships (an
    /// edit, or an older version's) is first moved aside as `<name>.json.replaced-<time>`; if that move fails (the name
    /// is taken, the folder is read-only) the edit stays where it is and the file isn't rewritten. Pulse replaces only
    /// regular files: a link or a folder under one of these names is left as it is. Returns what it left, and why.
    static func writeExamples(_ folder: URL) -> [String: String] {
        let fm = FileManager.default
        var kept: [String: String] = [:]
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (id, file) in PulseThemeFile.builtIn {
            let url = folder.appending(path: "\(id).json"), shipped = ThemeStore.file(file)
            guard let kind = kind(url) else { try? shipped.write(to: url, options: .atomic); continue }
            guard kind == S_IFREG else { kept[id] = "it isn't a regular file (a link or a folder), so Pulse leaves it alone"; continue }
            guard differs(url, from: shipped) else { continue }
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            let aside = folder.appending(path: "\(id).json.replaced-\(stamp)")
            do { try fm.moveItem(at: url, to: aside) } catch {   // moveItem never replaces an existing file
                kept[id] = "Pulse couldn't move your edit aside to \(aside.lastPathComponent) (\(error.localizedDescription)), so it left the file as it is"
                continue
            }
            try? shipped.write(to: url, options: .atomic)
        }
        let guide = folder.appending(path: ThemeStore.guideName), text = Data(ThemeGuide.text.utf8)
        if kind(guide) == nil || (kind(guide) == S_IFREG && differs(guide, from: text)) { try? text.write(to: guide, options: .atomic) }
        return kept
    }

    // MARK: one pass

    /// Every theme file read and checked: at most `maxEntries` names looked at and `maxThemes` theme files read, in
    /// order of name; past that, one notice for the lot. `.error` files written for at most `maxProblems` files.
    static func scan(_ folder: URL, cache: Cache) -> Scan {
        let fm = FileManager.default
        var scan = Scan()
        let listing = names(folder)
        let files = listing.names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        var readIDs: Set<String> = [], skipped: [String] = []
        for id in files {
            let url = folder.appending(path: "\(id).json")
            if let builtIn = PulseThemeFile.builtIn.first(where: { $0.id == id }) {
                if differs(url, from: ThemeStore.file(builtIn.file)) {
                    let next = cache.kept[id].map { "At launch \($0)." } ?? "The next launch puts it back, keeping your copy beside it as \(id).json.replaced-<time>."
                    scan.issues[id] = "\(id).json is Pulse's own \(builtIn.file.name), written as an example: edits to it never apply. \(next) Copy it under a new name to make a theme of your own."
                }
                continue
            }
            guard readIDs.count < ThemeStore.maxThemes else { skipped.append(id); continue }
            readIDs.insert(id)
            switch load(url) {
            case .success(let file):
                cache.lastGood[id] = file
                scan.found.append(PulseTheme(id: id, file: file))
            case .failure(let problem):
                scan.issues[id] = problem.text
                if let good = cache.lastGood[id] { scan.found.append(PulseTheme(id: id, file: good)) }
            }
        }
        // the cache holds files read in this pass only: at most `maxThemes`, and a file past the cap is not drawn from it
        cache.lastGood = cache.lastGood.filter { readIDs.contains($0.key) }
        var notes: [String] = []
        if listing.more { notes.append("The Themes folder has more than \(maxEntries) entries; Pulse looked at the first \(maxEntries) it was given.") }
        if !skipped.isEmpty {
            let named = skipped.prefix(3).map { "\($0).json" }.joined(separator: ", ")
            notes.append("Pulse reads at most \(ThemeStore.maxThemes) theme files, in order of name; \(skipped.count) more aren't read (\(named)\(skipped.count > 3 ? ", …" : "")), and one of those chosen in Settings draws Classic.")
        }
        scan.notice = notes.isEmpty ? nil : notes.joined(separator: " ")

        // .error files: Pulse's own only (its mark, not what they say). Removed where nothing is wrong (a fixed or removed
        // file); written for the first `maxProblems` problems. Any other `.error` entry (someone's file, a folder, a
        // link, a note that happens to read like Pulse's) is never touched.
        for name in listing.names where name.hasSuffix(".error") {
            let id = String(name.dropLast(6)), url = folder.appending(path: name)
            if scan.issues[id] == nil, isOurError(url) { try? fm.removeItem(at: url) }
        }
        let builtIns = Set(PulseThemeFile.builtIn.map(\.id))
        for id in scan.issues.keys.sorted(by: { (builtIns.contains($0) ? 0 : 1, $0) < (builtIns.contains($1) ? 0 : 1, $1) }).prefix(maxProblems) {
            let url = folder.appending(path: "\(id).error")
            let builtIn = PulseThemeFile.builtIn.first { $0.id == id }?.file.name
            let shown = builtIn.map { "its own \($0)" } ?? (cache.lastGood[id] == nil ? "Classic" : "its last good version")
            let data = Data("\(errorHeader(id)), so Pulse draws \(shown) instead. Fix it and Pulse reads it again by itself; \(ThemeStore.guideName) here describes every key.\n\n\(scan.issues[id]!)\n".utf8)
                .prefix(maxDiagnosticBytes)
            if differs(url, from: data) { writeDiagnostic(data, to: url) }
        }
        return scan
    }

    /// A theme file, or why it can't be used: a regular file of at most 64 KB, then everything `ThemeStore.decode` checks.
    static func load(_ url: URL) -> Result<PulseThemeFile, ThemeStore.Problem> {
        switch read(url, limit: ThemeStore.maxFileBytes) {
        case .data(let data): return ThemeStore.decode(data)
        case .tooBig: return .failure(.init(text: "- the file is over \(ThemeStore.maxFileBytes / 1024) KB; a theme file is at most \(ThemeStore.maxFileBytes / 1024) KB"))
        case .missing: return .failure(.init(text: "- the file went away while Pulse read it"))
        case .notRegular(let what): return .failure(.init(text: "- it's \(what); a theme is a regular file"))
        case .unreadable(let why): return .failure(.init(text: "- the file can't be read: \(why)"))
        }
    }

    // MARK: importing

    /// A theme file from anywhere, read and checked exactly as the folder's own files are, then copied into the folder,
    /// byte for byte, under a name of its own: the source's name in lower case, letters, digits and dashes only, with
    /// "-2", "-3"… if that name is taken or is a built-in's. Never replaces a file.
    static func importTheme(_ source: URL, into folder: URL) -> Result<(id: String, name: String), ThemeStore.Problem> {
        let data: Data
        switch read(source, limit: ThemeStore.maxFileBytes) {
        case .data(let d): data = d
        case .tooBig: return .failure(.init(text: "- the file is over \(ThemeStore.maxFileBytes / 1024) KB; a theme file is at most \(ThemeStore.maxFileBytes / 1024) KB"))
        case .missing: return .failure(.init(text: "- the file isn't there"))
        case .notRegular(let what): return .failure(.init(text: "- it's \(what); a theme is a regular file"))
        case .unreadable(let why): return .failure(.init(text: "- the file can't be read: \(why)"))
        }
        let file: PulseThemeFile
        switch ThemeStore.decode(data) {
        case .success(let f): file = f
        case .failure(let problem): return .failure(problem)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent.lowercased()
            .map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-").prefix(40)
        let base = stem.isEmpty ? "theme" : String(stem)
        let reserved = Set(PulseThemeFile.builtIn.map(\.id))
        for n in 1 ... 100 {
            let id = n == 1 ? base : "\(base)-\(n)"
            guard !reserved.contains(id), kind(folder.appending(path: "\(id).json")) == nil else { continue }
            do {
                try data.write(to: folder.appending(path: "\(id).json"), options: .withoutOverwriting)
                return .success((id, file.name))
            } catch {
                return .failure(.init(text: "- it couldn't be copied into the Themes folder: \(error.localizedDescription)"))
            }
        }
        return .failure(.init(text: "- there's no free name for it in the Themes folder"))
    }
}
