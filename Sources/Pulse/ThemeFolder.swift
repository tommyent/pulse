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
        var lastGood: [String: PulseSkinSet] = [:]
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

    /// Up to `max` names in the folder (hidden ones left out), and whether there were more.
    static func names(_ folder: URL, max: Int = maxEntries) -> (names: [String], more: Bool) {
        guard let dir = opendir(folder.path) else { return ([], false) }
        defer { closedir(dir) }
        var out: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name.hasPrefix(".") { continue }
            if out.count == max { return (out, true) }
            out.append(name)
        }
        return (out, false)
    }

    /// The first line of every `.error` Pulse writes; a `.error` file without it isn't Pulse's.
    static func errorHeader(_ id: String) -> String { "\(id).json can't be used" }

    /// An `<id>.error` Pulse wrote: a regular file starting with Pulse's first line for that id.
    static func isOurError(_ url: URL, id: String) -> Bool {
        guard case .data(let data) = read(url, limit: 16 * 1024) else { return false }
        return String(decoding: data.prefix(400), as: UTF8.self).hasPrefix(errorHeader(id))
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
        for (id, set) in PulseSkinSet.builtIn {
            let url = folder.appending(path: "\(id).json"), shipped = ThemeStore.file(set)
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
        var read = 0, skipped: [String] = []
        for id in files {
            let url = folder.appending(path: "\(id).json")
            if let builtIn = PulseSkinSet.builtIn.first(where: { $0.id == id }) {
                if differs(url, from: ThemeStore.file(builtIn.set)) {
                    let next = cache.kept[id].map { "At launch \($0)." } ?? "The next launch puts it back, keeping your copy beside it as \(id).json.replaced-<time>."
                    scan.issues[id] = "\(id).json is Pulse's own \(builtIn.set.name), written as an example: edits to it never apply. \(next) Copy it under a new name to make a theme of your own."
                }
                continue
            }
            guard read < ThemeStore.maxThemes else { skipped.append(id); continue }
            read += 1
            switch load(url) {
            case .success(let set):
                cache.lastGood[id] = set
                scan.found.append(PulseTheme(id: id, set: set))
            case .failure(let problem):
                scan.issues[id] = problem.text
                if let good = cache.lastGood[id] { scan.found.append(PulseTheme(id: id, set: good)) }
            }
        }
        for id in cache.lastGood.keys where !files.contains(id) { cache.lastGood[id] = nil }
        var notes: [String] = []
        if listing.more { notes.append("The Themes folder has more than \(maxEntries) entries; Pulse looked at the first \(maxEntries) it was given.") }
        if !skipped.isEmpty {
            let named = skipped.prefix(3).map { "\($0).json" }.joined(separator: ", ")
            notes.append("Pulse reads at most \(ThemeStore.maxThemes) theme files, in order of name; \(skipped.count) more aren't read (\(named)\(skipped.count > 3 ? ", …" : "")).")
        }
        scan.notice = notes.isEmpty ? nil : notes.joined(separator: " ")

        // .error files: Pulse's own only. Removed where nothing is wrong (a fixed or removed file); written for the
        // first `maxProblems` problems. Any other `.error` entry (someone's file, a folder, a link) is never touched.
        for name in listing.names where name.hasSuffix(".error") {
            let id = String(name.dropLast(6)), url = folder.appending(path: name)
            if scan.issues[id] == nil, isOurError(url, id: id) { try? fm.removeItem(at: url) }
        }
        let builtIns = Set(PulseSkinSet.builtIn.map(\.id))
        for id in scan.issues.keys.sorted(by: { (builtIns.contains($0) ? 0 : 1, $0) < (builtIns.contains($1) ? 0 : 1, $1) }).prefix(maxProblems) {
            let url = folder.appending(path: "\(id).error")
            let builtIn = PulseSkinSet.builtIn.first { $0.id == id }?.set.name
            let shown = builtIn.map { "its own \($0)" } ?? (cache.lastGood[id] == nil ? "Classic" : "its last good version")
            let data = Data("\(errorHeader(id)), so Pulse draws \(shown) instead. Fix it and Pulse reads it again by itself; \(ThemeStore.guideName) here describes every key.\n\n\(scan.issues[id]!)\n".utf8)
            guard kind(url) == nil || isOurError(url, id: id) else { continue }
            if differs(url, from: data) { try? data.write(to: url, options: .atomic) }
        }
        return scan
    }

    /// A theme file, or why it can't be used: a regular file of at most 64 KB, then everything `ThemeStore.decode` checks.
    static func load(_ url: URL) -> Result<PulseSkinSet, ThemeStore.Problem> {
        switch read(url, limit: ThemeStore.maxFileBytes) {
        case .data(let data): return ThemeStore.decode(data)
        case .tooBig: return .failure(.init(text: "- the file is over \(ThemeStore.maxFileBytes / 1024) KB; a theme file is at most \(ThemeStore.maxFileBytes / 1024) KB"))
        case .missing: return .failure(.init(text: "- the file went away while Pulse read it"))
        case .notRegular(let what): return .failure(.init(text: "- it's \(what); a theme is a regular file"))
        case .unreadable(let why): return .failure(.init(text: "- the file can't be read: \(why)"))
        }
    }
}
