import Foundation
import Security
import WebKit
import OSLog
import Synchronization

// MARK: - Shared helpers

private let home = FileManager.default.homeDirectoryForCurrentUser

/// Authenticated requests neither persist responses nor forward credentials through redirects.
final class ProviderHTTP: NSObject, URLSessionTaskDelegate {
    static let delegate = ProviderHTTP()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// App won't inherit the shell PATH when launched from Finder.
func locateBinary(_ name: String) -> URL? {
    let candidates = [
        home.appending(path: ".local/bin/\(name)"),
        home.appending(path: ".\(name)/bin/\(name)"),
        URL(filePath: "/opt/homebrew/bin/\(name)"),
        URL(filePath: "/usr/local/bin/\(name)"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// claude.ai and grok.com both refuse to render/serve for a UA without the Safari token.
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

private func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

// MARK: - Claude

/// Claude Code's OAuth credential, borrowed from its keychain item as rarely as possible.
/// Every read of the secret can raise an access prompt. The item's modification date is readable
/// without one, so the secret is re-read only when Claude Code has actually rotated it; a refusal is
/// remembered for that version of the item so a "Deny" is not asked again every poll. Claude Code
/// accumulates several items under the same service name over time; the newest wins.
final class ClaudeKeychain {
    static let shared = ClaudeKeychain()
    static let service = "Claude Code-credentials"
    struct Creds { var accessToken: String }
    private let lock = NSLock()
    private var cached: (modified: Date, creds: Creds?)?   // creds nil = refused or unparsable at that version

    func credentials() -> Creds? {
        lock.lock(); defer { lock.unlock() }
        guard let modified = Self.newestModified() else {
            // no keychain item: some installs write the file instead
            return (try? Data(contentsOf: home.appending(path: ".claude/.credentials.json"))).flatMap(Self.parse)
        }
        if let cached, cached.modified == modified { return cached.creds }
        let creds = Self.readSecret().flatMap(Self.parse)
        cached = (modified, creds)
        return creds
    }

    /// Drop the cached secret (e.g. after a 401) so the next poll re-reads the current item.
    func forget() { lock.lock(); cached = nil; lock.unlock() }

    /// Attributes only: no access prompt. Modification date of the newest item.
    private static func newestModified() -> Date? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return nil }
        return items.compactMap { $0[kSecAttrModificationDate] as? Date }.max()
    }

    /// The secret is read through /usr/bin/security, the tool Claude Code writes the item with: it
    /// sits in the item's ACL and in the "apple-tool" partition, so it never prompts. Pulse's own
    /// self-signed identity has no Team ID, so a direct SecItem read was granted per cdhash and
    /// every rebuild asked for the login password again. Runs only when the item changed.
    private static func readSecret() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines).utf8)
    }

    private static func parse(_ data: Data) -> Creds? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return Creds(accessToken: token)
    }
}

enum ClaudeAdapter {
    static func fetch() async -> AccountSnapshot {
        var snap = AccountSnapshot(id: .claude, displayName: "Claude", planLabel: "Anthropic",
                                   health: .needsAuth, windows: [], fetchedAt: .now, source: .officialProtocol)
        var failure: String?   // an answer that isn't about the sign-in: the web session may still work, and if not the last numbers stay

        // Preferred: Claude Code's own token against the endpoint its /usage reads. No WebKit, no cookies.
        if let creds = ClaudeKeychain.shared.credentials() {
            func get(_ path: String) async -> (Int, [String: Any]?) {
                var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!, timeoutInterval: 15)
                req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
                req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                guard let (data, resp) = try? await ProviderHTTP.session.data(for: req), let http = resp as? HTTPURLResponse else { return (0, nil) }
                return (http.statusCode, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            let (status, json) = await get("usage")
            if status == 200, let json {
                snap.windows = windows(from: json)
                if let org = await get("profile").1?["organization"] as? [String: Any] {
                    snap.planLabel = planLabel(org["plan_display_name"] as? String)
                }
                snap.windows = keepingSessionSlot(snap.windows, plan: snap.planLabel)
                if !snap.windows.isEmpty { snap.health = .ok; return snap }
            }
            if status == 401 {
                ClaudeKeychain.shared.forget()   // token rotated or expired: re-read next poll, use the web session now
            } else if status == 0 || status == 429 || status >= 500 {
                snap.health = .providerError     // offline or throttled: keep last good windows; the web session is not consulted
                snap.detail = status == 0 ? "Claude unreachable" : "Claude answered HTTP \(status)"
                return snap
            } else if status != 200 {
                failure = "Claude answered HTTP \(status)"
            }
        }

        // Fallback: Pulse's own claude.ai web session, only once someone has signed in with Connect… (on the card, the popover or in Settings).
        guard ClaudeWeb.connected else {
            if let failure {
                snap.health = .providerError
                snap.detail = failure
            }
            return snap
        }
        let web = await ClaudeWeb.shared.fetchUsage()
        if let usage = web.usage {
            snap.source = .officialUsagePage
            snap.windows = windows(from: usage)
            snap.health = snap.windows.isEmpty ? .providerError : .ok
            return snap
        }
        // A page that never loaded says nothing about the sign-in, so the last numbers stay.
        if !web.pageLoaded {
            snap.health = .providerError
            snap.detail = "claude.ai didn't load"
        } else if let failure {
            snap.health = .providerError
            snap.detail = failure
        }
        return snap
    }

    /// The profile's own plan name ("Ultra" on 2026-11-03), else the company. Tier IDs are not translated into plan
    /// names: such a table is how "Max 20x" went stale (the ID still read default_claude_max_20x after the rename).
    static func planLabel(_ displayName: String?) -> String {
        guard let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "Anthropic" }
        return name
    }

    /// Max always has a 5-hour limit, so a null `five_hour` must not change its ring's layout between refreshes: the slot stays, blank.
    /// shortcut: goes by the plan's name, and the claude.ai fallback has no plan name; a real idle Max reply would show if this ever runs.
    static func keepingSessionSlot(_ windows: [UsageWindow], plan: String) -> [UsageWindow] {
        guard plan.localizedCaseInsensitiveContains("max"), !windows.isEmpty, !windows.contains(where: { $0.id.hasPrefix("session_5h") }) else { return windows }
        return [UsageWindow(id: "session_5h_five_hour", label: "Current session", percentUsed: nil, resetsAt: nil)] + windows
    }

    /// Tolerant parse: any top-level object carrying `utilization` becomes a window.
    static func windows(from json: [String: Any]) -> [UsageWindow] {
        let labels: [String: (order: Int, id: String, label: String)] = [
            "five_hour": (0, "session_5h", "Current session"),
            "seven_day": (1, "weekly_all", "All models"),
            "seven_day_opus": (2, "weekly_model", "Opus"),
            "seven_day_sonnet": (3, "weekly_model", "Sonnet"),
        ]
        var out: [(Int, UsageWindow)] = []
        for (key, value) in json {
            guard let obj = value as? [String: Any],
                  let util = obj["utilization"] as? Double else { continue }
            let resets = (obj["resets_at"] as? String).flatMap(parseISO)
            // unknown per-model windows (e.g. one-off model codenames) stay hidden
            guard let meta = labels[key] else { continue }
            out.append((meta.order, UsageWindow(id: meta.id + "_" + key, label: meta.label,
                                               percentUsed: util, resetsAt: resets)))
        }
        for l in json["limits"] as? [[String: Any]] ?? [] where l["kind"] as? String == "weekly_scoped" {
            guard let name = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String else { continue }
            out.append((2, UsageWindow(id: "weekly_model_\(name)", label: name, percentUsed: l["percent"] as? Double,
                                       resetsAt: (l["resets_at"] as? String).flatMap(parseISO))))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

}

// MARK: - Codex

enum CodexAdapter {
    // Codex's own sign-in (~/.codex/auth.json) against the usage endpoint the Codex app reads.
    // Replaces spawning `codex app-server` every poll: one HTTPS call, real reset timestamps.
    static func fetch(authFile: URL = home.appending(path: ".codex/auth.json"),
                      cliFound: Bool = locateBinary("codex") != nil,
                      session: URLSession = ProviderHTTP.session) async -> AccountSnapshot {
        var snap = AccountSnapshot(id: .codex, displayName: "Codex", planLabel: "OpenAI",
                                   health: .needsAuth, windows: [], fetchedAt: .now, source: .officialProtocol)
        guard let auth = try? JSONSerialization.jsonObject(with: Data(contentsOf: authFile)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty
        else {
            // An auth file means Codex has run here, perhaps from a folder Pulse doesn't search, so it's only missing with neither.
            // shortcut: signed out with the CLI off the search path also reads as not installed; the README's fix is a link in ~/.local/bin.
            if !cliFound, !FileManager.default.fileExists(atPath: authFile.path) { snap.health = .missingClient }
            return snap
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return snap }                 // token rotated or signed out: run codex
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { snap.health = .providerError; return snap }
            if let plan = json["plan_type"] as? String { snap.planLabel = planLabel(plan) }
            snap.windows = windows(from: json)
            snap.health = snap.windows.isEmpty ? .providerError : .ok
        } catch { snap.health = .providerError }
        return snap
    }

    /// wham/usage gives only `plan_type`, an ID ("prolite" on 2026-11-03), never a display name; an ID not listed
    /// here shows the company rather than a guessed plan.
    static func planLabel(_ plan: String) -> String {
        ["plus": "ChatGPT Plus", "pro": "ChatGPT Pro", "prolite": "ChatGPT Pro Lite",
         "business": "ChatGPT Business", "team": "ChatGPT Team", "enterprise": "ChatGPT Enterprise"][plan] ?? "OpenAI"
    }

    /// `rate_limit.primary_window` / `secondary_window`: which one is the 5-hour window depends on
    /// the plan (a free plan's primary is the 30-day one), so windows are labelled by their length.
    static func windows(from json: [String: Any], now: Date = .now) -> [UsageWindow] {
        guard let limit = json["rate_limit"] as? [String: Any] else { return [] }
        var out: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = limit[key] as? [String: Any], let pct = w["used_percent"] as? Double else { continue }
            let seconds = w["limit_window_seconds"] as? Double ?? 0
            let resets = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (w["reset_after_seconds"] as? Double).map { now.addingTimeInterval($0) }
            let hours = seconds / 3600
            let (id, label): (String, String) = hours <= 0 ? ("window_\(key)", "Usage")
                : hours < 24 ? ("session_\(Int(hours))h", "\(Int(hours))-hour window")
                : hours <= 24 * 8 ? ("weekly_all", "Weekly") : ("monthly_all", "Monthly")
            out.append(UsageWindow(id: id, label: label, percentUsed: pct, resetsAt: resets))
        }
        // the rings lead with the tighter window, like the source app does
        return out.sorted { ($0.id.hasPrefix("session") ? 0 : 1) < ($1.id.hasPrefix("session") ? 0 : 1) }
    }
}

// MARK: - Grok

/// Why a Grok fetch produced nothing usable. `health` decides whether AppState keeps stale windows
/// (providerError) or asks the user to reconnect (needsAuth); `description` is the card's detail line.
enum GrokError: Error, CustomStringConvertible {
    case noCLIAuth                // ~/.grok/auth.json missing, unreadable, or not an auth.x.ai entry
    case refreshFailed(String)    // token endpoint rejected the refresh grant (e.g. invalid_grant)
    case unauthorized(String)     // 401/403 with a fresh token or the stored cookies
    case network(String)          // offline, timeout, 5xx
    case badPayload(String)       // 200 but nothing we can chart
    case local(String)            // auth file busy / unwritable

    var description: String {
        switch self {
        case .noCLIAuth: "Grok CLI not signed in — run `grok` once, or Connect Grok"
        case .refreshFailed(let why): "Grok CLI token refresh failed (\(why)) — run `grok` to sign in again"
        case .unauthorized(let what): "\(what) rejected — reconnect Grok"
        case .network(let why): "Grok unreachable (\(why))"
        case .badPayload(let why): "Grok returned no usage (\(why))"
        case .local(let why): "Grok CLI auth file: \(why)"
        }
    }
    var health: Health {
        switch self {
        case .network, .badPayload, .local: .providerError
        default: .needsAuth
        }
    }
}

private extension URLRequest {
    /// Every Grok call is bounded to 15s so a hung proxy can't stall the refresh loop.
    init(grok url: String) { self.init(url: URL(string: url)!, timeoutInterval: 15) }
}

/// Status + body, with transport failures mapped to `.network` and 401/403 to `.unauthorized`.
private func grokSend(_ req: URLRequest, what: String) async throws -> (Int, Data) {
    let data: Data, resp: URLResponse
    do { (data, resp) = try await ProviderHTTP.session.data(for: req) }
    catch { throw GrokError.network((error as? URLError)?.localizedDescription ?? "\(error)") }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 || status == 403 { throw GrokError.unauthorized(what) }
    if status >= 500 || status == 0 { throw GrokError.network("HTTP \(status)") }
    return (status, data)
}

/// The Grok Build CLI's OAuth session in ~/.grok/auth.json. Pulse refreshes it in place with the
/// same refresh grant the CLI uses, so the 6-hour access token doesn't force the user into the CLI.
actor GrokCLIAuth {
    static let shared = GrokCLIAuth()
    static let issuer = "https://auth.x.ai"
    /// token_endpoint from https://auth.x.ai/.well-known/openid-configuration
    static let tokenURL = "https://auth.x.ai/oauth2/token"
    private let file = home.appending(path: ".grok/auth.json")
    private var inflight: Task<Entry, Error>?

    struct Entry { let key: String; let userID: String?; let expiresAt: Date? }

    /// Refresh when the token is about to expire, or when `rejectedKey` (a fresh-looking token the
    /// server just refused) is still what's on disk. If the disk key already differs, someone else
    /// rotated it and that newer token should be tried before spending another refresh.
    static func needsRefresh(expiresAt: Date?, diskKey: String, rejectedKey: String?, now: Date = .now) -> Bool {
        if let rejectedKey, rejectedKey == diskKey { return true }
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) <= 60
    }

    /// A usable access token. Pass the key the server just rejected to force a refresh of it.
    func token(rejected: String? = nil) async throws -> Entry {
        let (_, _, entry) = try load()
        if !Self.needsRefresh(expiresAt: entry.expiresAt, diskKey: entry.key, rejectedKey: rejected) { return entry }
        if let inflight { return try await inflight.value }   // one refresh per process, others wait on it
        let task = Task { try await refresh(rejected: rejected) }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    private func load() throws -> (all: [String: Any], id: String, entry: Entry) {
        guard let data = try? Data(contentsOf: file),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GrokError.noCLIAuth }
        // keyed "<issuer>::<client-id>"; only trust an entry whose stored issuer + client match its key
        for (id, v) in all {
            guard let e = v as? [String: Any], id.hasPrefix(Self.issuer + "::"),
                  e["oidc_issuer"] as? String == Self.issuer,
                  id == "\(Self.issuer)::\(e["oidc_client_id"] as? String ?? "")",
                  let key = e["key"] as? String else { continue }
            let exp = (e["expires_at"] as? String).flatMap(parseISO)
            return (all, id, Entry(key: key, userID: e["user_id"] as? String, expiresAt: exp))
        }
        throw GrokError.noCLIAuth
    }

    private func refresh(rejected: String?) async throws -> Entry {
        // advisory lock on the CLI's lock file so two Pulse processes don't race a rotating refresh
        // token. Non-blocking with a short retry; unverified whether the CLI itself uses flock.
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw GrokError.local("cannot open lock") }
        defer { close(lock) }
        for attempt in 0..<10 {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { break }
            if attempt == 9 { throw GrokError.local("busy") }
            try await Task.sleep(for: .milliseconds(200))
        }
        defer { flock(lock, LOCK_UN) }

        // someone else may have refreshed while we waited for the lock
        let (all, id, current) = try load()
        if !Self.needsRefresh(expiresAt: current.expiresAt, diskKey: current.key, rejectedKey: rejected) { return current }
        guard let entry = all[id] as? [String: Any],
              let refreshToken = entry["refresh_token"] as? String,
              let clientID = entry["oidc_client_id"] as? String else { throw GrokError.noCLIAuth }

        var req = URLRequest(grok: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(formEncode(["grant_type": "refresh_token", "refresh_token": refreshToken,
                                        "client_id": clientID]).utf8)
        let (status, data): (Int, Data)
        do { (status, data) = try await grokSend(req, what: "refresh") }
        catch GrokError.unauthorized { throw GrokError.refreshFailed("HTTP 401") }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status != 429 else { throw GrokError.network("HTTP 429") }
        guard let json else { throw GrokError.network("refresh: not JSON") }
        guard status == 200, let access = json["access_token"] as? String else {
            // 400-class with an OAuth error code = the grant itself is dead; anything else is transient
            if let code = json["error"] as? String { throw GrokError.refreshFailed(code) }
            throw GrokError.network("refresh HTTP \(status)")
        }
        let expires = Date.now.addingTimeInterval(json["expires_in"] as? Double ?? 3600)

        // re-read: the CLI may have rewritten the file during the request. Merge only into an entry
        // that is still the same account and still holds the refresh token we spent; anything else
        // means the CLI signed out / switched / rotated concurrently, and its state wins.
        var (fresh, _, _) = try load()
        guard var mine = fresh[id] as? [String: Any] else { throw GrokError.local("CLI account removed during refresh") }
        guard mine["user_id"] as? String == entry["user_id"] as? String else { throw GrokError.local("CLI account switched during refresh") }
        if mine["refresh_token"] as? String != refreshToken {
            if let key = mine["key"] as? String, key != current.key {
                return Entry(key: key, userID: mine["user_id"] as? String,
                             expiresAt: (mine["expires_at"] as? String).flatMap(parseISO))
            }
            throw GrokError.local("auth.json changed during refresh")
        }
        mine["key"] = access
        mine["expires_at"] = ISO8601DateFormatter().string(from: expires)
        if let rotated = json["refresh_token"] as? String { mine["refresh_token"] = rotated }   // rotation must persist
        fresh[id] = mine
        try Self.save(fresh, to: file)
        return Entry(key: access, userID: current.userID, expiresAt: expires)
    }

    /// application/x-www-form-urlencoded (URLComponents leaves "+" bare, which servers read as a space)
    private func formEncode(_ fields: [String: String]) -> String {
        let ok = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok)!)" }
            .joined(separator: "&")
    }

    /// Whole-file rewrite (other accounts preserved), 0600 temp then atomic rename.
    static func save(_ all: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        var template = Array((file.path + ".pulse-XXXXXX").utf8CString)
        let fd = mkstemp(&template) // exclusive creation, mode 0600; cannot follow a planted symlink
        guard fd >= 0 else { throw GrokError.local("cannot create private temporary file") }
        let tmp = String(cString: template)
        defer { close(fd); unlink(tmp) }
        try FileHandle(fileDescriptor: fd).write(contentsOf: data)
        // rename keeps the new file's 0600 mode; replaceItemAt can preserve the old, broader mode.
        guard rename(tmp, file.path) == 0 else { throw GrokError.local("cannot replace auth file") }
    }
}

enum GrokAdapter {
    private static let log = Logger(subsystem: "io.github.tommyent.pulse", category: "grok-usage")

    // Only meter metadata: never log credentials, account identifiers, response bodies or error text.
    private static func logReading(_ snap: AccountSnapshot) {
        if snap.windows.isEmpty {
            log.notice("source=\(snap.source.rawValue, privacy: .public) window=none percent=unknown resetsAt=unknown health=\(snap.health.rawValue, privacy: .public)")
        }
        for window in snap.windows {
            let percent = window.percentUsed.map { String($0) } ?? "unknown"
            let reset = window.resetsAt?.ISO8601Format() ?? "unknown"
            log.notice("source=\(snap.source.rawValue, privacy: .public) window=\(window.id, privacy: .public) percent=\(percent, privacy: .public) resetsAt=\(reset, privacy: .public) health=\(snap.health.rawValue, privacy: .public)")
        }
    }

    // grok.com per-model rolling buckets (no reset timestamp; no weekly pool exposed) — cookie fallback only.
    static let models: [(model: String, label: String)] = [
        ("grok-4", "Grok 4 (2h window)"),
        ("grok-4-heavy", "Grok 4 Heavy (2h window)"),
        ("grok-3", "Grok 3 (2h window)"),
    ]

    static func fetch() async -> AccountSnapshot {
        // the billing reply names no plan (checked 2026-11-03), so the card names the company, not a guessed plan
        var snap = AccountSnapshot(id: .grok, displayName: "Grok", planLabel: "xAI",
                                   health: .needsAuth, windows: [], fetchedAt: .now, source: .cliStatus)
        var errors: [GrokError] = []

        // Preferred: CLI token -> CLI billing endpoint (weekly credit pool with Build/Chat split).
        do {
            snap.windows = try await fetchCLI()
            snap.health = .ok
            logReading(snap)
            return snap
        } catch let e as GrokError { errors.append(e) } catch { errors.append(.network("\(error)")) }
        snap.health = errors.last?.health ?? .providerError
        logReading(snap)

        // Fallback: grok.com web session captured by GrokLogin.
        if let cookies = await cookieHeader() {
            snap.source = .officialUsagePage
            do {
                snap.windows = try await webWindows(cookieHeader: cookies)
                snap.health = .ok
                logReading(snap)
                return snap
            } catch let e as GrokError { errors.append(e) } catch { errors.append(.network("\(error)")) }
            snap.health = errors.last?.health ?? .providerError
            logReading(snap)
        }

        // a transport failure on any path means "unknown", not "signed out": keep stale windows
        let primary = errors.first { $0.health == .providerError } ?? errors.first
        snap.health = primary?.health ?? .needsAuth
        snap.detail = primary?.description
        return snap
    }

    /// CLI path end to end. A token that is fresh on disk but rejected upstream (revoked, CLI signed
    /// out elsewhere) gets one forced refresh before we call it unauthorized.
    static func fetchCLI() async throws -> [UsageWindow] {
        let first = try await GrokCLIAuth.shared.token()
        do { return try await billing(first) }
        catch GrokError.unauthorized { return try await billing(GrokCLIAuth.shared.token(rejected: first.key)) }
    }

    private static func billing(_ auth: GrokCLIAuth.Entry) async throws -> [UsageWindow] {
        var req = URLRequest(grok: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        req.setValue("Bearer \(auth.key)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")   // what the CLI itself sends
        if let uid = auth.userID { req.setValue(uid, forHTTPHeaderField: "x-userid") }
        let (status, data) = try await grokSend(req, what: "Grok CLI token")
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["config"] as? [String: Any] else { throw GrokError.badPayload("billing HTTP \(status)") }
        let windows = billingWindows(from: config)
        guard !windows.isEmpty else { throw GrokError.badPayload("no credit windows") }
        return windows
    }

    /// Parses `config` from /v1/billing. Two schemas seen in the wild:
    ///  - credits (`?format=credits`, unified billing): currentPeriod{type,end}, creditUsagePercent, productUsage[]
    ///  - legacy: used.val / monthlyLimit.val with billingPeriodStart/End
    /// The proxy emits protobuf JSON, which omits zero scalars: a credits payload without
    /// creditUsagePercent means 0% used, not "unknown". A legacy payload with monthlyLimit 0 has no
    /// meaningful percent, so the window carries nil and the ring shows a dash while staying connected.
    static func billingWindows(from config: [String: Any]) -> [UsageWindow] {
        func date(_ k: String, in d: [String: Any]) -> Date? {
            (d[k] as? String).flatMap { parseISO($0) ?? parseISO($0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) }
        }
        // money/credit wrappers: {"val": 12.5}, {"val": "1200"} (int64 as string), or {} (protobuf zero)
        func val(_ k: String) -> Double? {
            guard let box = config[k] as? [String: Any] else { return nil }
            if let d = box["val"] as? Double { return d }
            if let str = box["val"] as? String { return Double(str) }
            return box["val"] == nil ? 0 : nil
        }

        if let period = config["currentPeriod"] as? [String: Any] {
            let resets = date("end", in: period)
            let cycle = (period["type"] as? String).map { $0.contains("WEEKLY") ? " (weekly)" : $0.contains("MONTHLY") ? " (monthly)" : "" } ?? ""
            var out = [UsageWindow(id: "period_all", label: "Credits\(cycle)",
                                   percentUsed: config["creditUsagePercent"] as? Double ?? 0, resetsAt: resets)]
            let names = ["GrokBuild": "Grok Build", "GrokChat": "Grok Chat", "GrokImagine": "Grok Imagine"]
            for item in config["productUsage"] as? [[String: Any]] ?? [] {
                guard let product = item["product"] as? String else { continue }
                out.append(UsageWindow(id: "period_\(product)", label: names[product] ?? product,
                                       percentUsed: item["usagePercent"] as? Double ?? 0, resetsAt: resets))
            }
            return out
        }

        guard let used = val("used"), let limit = val("monthlyLimit") else { return [] }
        let start = date("billingPeriodStart", in: config), end = date("billingPeriodEnd", in: config)
        let weekly = start.flatMap { s in end.map { $0.timeIntervalSince(s) <= 8 * 86400 } } ?? false
        return [UsageWindow(id: "period_all", label: weekly ? "Credits (weekly)" : "Credits (monthly)",
                            percentUsed: limit > 0 ? min(used / limit * 100, 100) : nil, resetsAt: end)]
    }

    // MARK: web-session fallback

    /// "sso" is the cookie grok.com sets for a signed-in account. Anonymous rate-limits calls return 401
    /// in our probe, so the exact trigger for the early-closing login is unproven; requiring sso plus a
    /// real quota payload closes the "any cookies + HTTP 200" hole either way.
    static func cookieHeader(from cookies: [HTTPCookie]) -> String? {
        let mine = cookies.filter { $0.domain == "grok.com" || $0.domain.hasSuffix(".grok.com") }
        guard mine.contains(where: { $0.name == "sso" }) else { return nil }
        return mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Live cookies from the shared WebKit store (they rotate as the login webview browses),
    /// falling back to the header saved at connect time. Never connected: no header, so WebKit isn't woken.
    @MainActor
    static func cookieHeader() async -> String? {
        guard let saved = Keychain.read("grok-cookies") else { return nil }
        let live = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookieHeader(from: live) ?? saved
    }

    /// True only when the header carries a signed-in session that yields real quota numbers.
    static func validate(cookieHeader: String) async -> Bool {
        guard cookieHeader.contains("sso=") else { return false }
        return ((try? await webWindows(cookieHeader: cookieHeader))?.isEmpty == false)
    }

    private static func webWindows(cookieHeader: String) async throws -> [UsageWindow] {
        var out: [UsageWindow] = []
        for (model, label) in models {
            var req = URLRequest(grok: "https://grok.com/rest/rate-limits")
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: ["requestKind": "DEFAULT", "modelName": model])
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("https://grok.com", forHTTPHeaderField: "Origin")
            req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
            req.httpShouldHandleCookies = false
            let (status, data) = try await grokSend(req, what: "grok.com session")   // 401/403 propagate
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let total = json["totalQueries"] as? Double, total > 0,
                  let remaining = json["remainingQueries"] as? Double else { continue }
            out.append(UsageWindow(id: "session_\(model)", label: label,
                                   percentUsed: (1 - remaining / total) * 100, resetsAt: nil))
        }
        guard !out.isEmpty else { throw GrokError.badPayload("rate-limits had no query buckets") }
        return out
    }
}

// MARK: - Antigravity

/// When Pulse runs agy by itself. agy may open a browser sign-in on any run that can't authenticate, so whenever a run
/// might have been waiting for one, Pulse waits rather than run it each poll. One rule covers every fetch:
/// - A usable report, or a Refresh, clears everything below.
/// - A sign-out (`needsAuth`, from any sign of a sign-in in a run's output or log) pauses until a Refresh.
/// - Any other attempt without a usable report is a failure, whatever happened: killed, exited with no usage or an
///   error, outlived SIGKILL, never answered, couldn't be started safely. From then until a report or a Refresh, Pulse
///   allows itself at most three runs without new activity: 15, 30 and 60 minutes after the latest failure when it
///   was the network, and only the first of them, half an hour on, after any other failure. No failure gives a run
///   back. So a sign-in wait that looks like the network costs at most three tabs, any other at most one, while an
///   outage is still retried through its first hour and 45 minutes.
/// - Only fetches that never got as far as a usage run (`.noAttempt`: offline, agy missing or too old) change nothing.
/// - A change in agy's activity marker (`sessionMarker`, the owner's own agy use) allows a run at once, once per
///   change: two successful reads that differ. A read that fails (nil) keeps the last known value and allows nothing.
///   The marker is only compared for a change, never against the clock, and the waits are on the monotonic clock, so
///   setting the Mac's clock back or forward can neither fake activity nor move a run.
/// - A Refresh clicked while a run is in flight drops that run's result, and the Refresh's own pass decides.
struct AgyPause {
    typealias Instant = ContinuousClock.Instant
    enum Outcome { case report, signedOut, network, failed, noAttempt }
    private(set) var paused = false
    private var retry = false
    private var signedOut = false
    private var failure: (at: Instant, network: Bool, marker: Date?)?   // the latest failure since a report or Refresh
    private var spent = 0   // runs Pulse allowed itself since then without new activity
    private var timed = false   // this pass is one of them
    private var lastRead: Date?   // the last successful read of agy's activity marker; a failed (nil) read keeps it

    /// What survives a relaunch, saved in Pulse's settings apart from the card's snapshot (which an offline skip
    /// rewrites): a sign-out, or a failure with what's left of its budget. Its waits start again from the launch.
    struct Hold: Codable, Equatable {
        var signedOut = false, network = false, spent = 0
    }
    var hold: Hold? {
        signedOut ? Hold(signedOut: true) : failure.map { Hold(network: $0.network, spent: spent) }
    }
    init() {}
    init(restoring hold: Hold?, now: Instant = .now, marker: Date?) {
        lastRead = marker
        guard let hold else { return }
        if hold.signedOut { signedOut = true } else { failure = (now, hold.network, marker); spent = hold.spent }
        paused = true
    }

    mutating func manualRefresh(whileRefreshing: Bool) {
        paused = false; signedOut = false; failure = nil; spent = 0
        if whileRefreshing { retry = true }
    }
    mutating func passStarted(now: Instant = .now, marker: Date?) {
        retry = false; timed = false
        if let marker { lastRead = marker }
        guard !signedOut else { paused = true; return }
        guard var failure else { paused = false; return }
        if failure.marker == nil { failure.marker = lastRead; self.failure = failure }   // the first read since is the baseline
        // activity: only two successful reads that differ
        if let marker, let base = failure.marker, marker != base { paused = false; return }
        let wait: Duration? = failure.network ? (spent < 3 ? .seconds(15 * 60) * (1 << spent) : nil)
                                              : (spent == 0 ? .seconds(30 * 60) : nil)
        timed = wait.map { now - failure.at >= $0 } ?? false
        paused = !timed
    }
    mutating func update(with snap: AccountSnapshot, now: Instant = .now, marker: Date?) {
        if let marker { lastRead = marker }
        guard !retry else { return }
        let outcome = AntigravityAdapter.outcome(of: snap)
        if timed, outcome != .noAttempt { spent += 1 }
        timed = false
        switch outcome {
        case .report: signedOut = false; failure = nil; spent = 0
        case .signedOut: signedOut = true
        case .network, .failed: failure = (now, outcome == .network, lastRead)
        case .noAttempt: break
        }
        paused = signedOut || failure != nil
    }
}

/// The Antigravity CLI's own usage report (`agy -p /usage`). agy asks Google as itself, so Pulse never
/// reads the Google token; Google's quota API refuses that token from any other client. The report is
/// a local command: no model prompt, no tokens, no conversation.
enum AntigravityAdapter {
    /// A run Pulse had to kill, or couldn't start safely: agy may wait there for a browser sign-in it opened itself.
    static let stalled = "Antigravity CLI stalled, maybe waiting for sign-in. Pulse checks again once agy has run, or click Refresh"
    /// A run whose own log shows the network (`cause(of:)`): `AgyPause` tries it again in a while.
    static let networkTimeout = "Antigravity CLI timed out (network); Pulse tries again in a while, or click Refresh"
    static let networkError = "Antigravity CLI hit a network error; Pulse tries again in a while, or click Refresh"
    static let noUsage = "Antigravity CLI returned no usage. Pulse checks again once agy has run, or click Refresh"
    static let signIn = "Run agy once to sign in to Antigravity, then click Refresh"
    static let offline = "Offline, Antigravity check skipped"
    static let tooOld = "Update the Antigravity CLI (agy 1.1.11 or later)"

    /// What a fetch's snapshot means for `AgyPause`. Only the snapshots named here are anything but a failed usage
    /// attempt, so any other reason, `noAnswer` and reasons added later included, holds agy back.
    static func outcome(of snap: AccountSnapshot) -> AgyPause.Outcome {
        switch (snap.health, snap.detail) {
        case (.ok, _): .report
        case (.needsAuth, _): .signedOut
        case (.missingClient, _), (_, offline?), (_, tooOld?): .noAttempt
        case (_, networkTimeout?), (_, networkError?): .network
        default: .failed
        }
    }

    /// agy's activity marker: the modification date of its own log folder, which each session that logs there changes
    /// by adding a file (agy's log pruning changes it too, also at a session's start). Pulse's runs pass `--log-file`,
    /// so they never do. Only a change means anything; the date itself may be ahead of or behind the clock.
    static func sessionMarker() -> Date? {
        try? home.appending(path: ".gemini/antigravity-cli/log").resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    static func fetch() async -> AccountSnapshot {
        var snap = AccountSnapshot(id: .antigravity, displayName: "Antigravity", planLabel: "Google",
                                   health: .missingClient, windows: [], fetchedAt: .now, source: .cliStatus)
        guard let agy = locateBinary("agy") else { return snap }
        snap.health = .providerError
        // a version run that couldn't start or had to be killed fails closed, like a usage run
        guard let version = await run(agy, ["--version"], timeout: .seconds(10)), !version.killed else {
            snap.detail = stalled
            return snap
        }
        guard supportsUsageReport(String(decoding: version.out, as: UTF8.self)) else {
            snap.detail = tooOld
            return snap
        }
        // agy takes a network error during its token refresh for a sign-out and opens a browser sign-in,
        // even in print mode, so it only runs when Google's token endpoint answers (any HTTP status).
        var probe = URLRequest(url: URL(string: "https://oauth2.googleapis.com/")!, timeoutInterval: 5)
        probe.httpMethod = "HEAD"
        guard (try? await ProviderHTTP.session.data(for: probe)) != nil else {
            snap.detail = offline
            return snap
        }
        // agy's log goes in the folder `run` removes, not one more file per refresh in ~/.gemini. An older agy that refuses the flag runs without it.
        let usage = ["-p", "/usage", "--output-format", "json", "--print-timeout", "45s"]
        var answer = await run(agy, usage + ["--log-file", "agy.log"], timeout: .seconds(60))
        if let refused = answer, !refused.killed, String(decoding: refused.err, as: UTF8.self).contains("not defined") {
            answer = await run(agy, usage, timeout: .seconds(60))
        }
        guard let report = answer else {
            snap.detail = stalled   // couldn't be started safely: fail closed
            return snap
        }
        if !report.killed, let json = try? JSONSerialization.jsonObject(with: report.out) as? [String: Any] {
            snap.windows = windows(from: json)
        }
        guard snap.windows.isEmpty else {
            snap.health = .ok
            return snap
        }
        // no usable report, whether agy was killed or exited by itself: the same reading of its output and log
        switch cause(of: report) {
        case .signedOut: snap.health = .needsAuth; snap.detail = signIn
        case .network: snap.detail = report.killed ? networkTimeout : networkError
        case .stalled: snap.detail = report.killed ? stalled : noUsage
        }
        return snap
    }

    /// Print mode before agy 1.1.11 sent unknown slash commands to the model as a prompt, so older
    /// or unrecognised versions are never asked for `/usage`.
    static func supportsUsageReport(_ version: String) -> Bool {
        guard let r = version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return false }
        return !version[r].split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes([1, 1, 11])
    }

    /// `command.data.groups[]` are pools ("Gemini Models", "Claude and GPT models"), each with a 5-hour and a
    /// weekly bucket, plus groups named for one model ("Gemini 4 Argon") that cap only that model.
    /// Pools keep the order reported, so a ring always means the same pool. Nothing in the report ties a model's group
    /// to a pool, so it joins the pool its first word names, else the first pool.
    static func windows(from json: [String: Any]) -> [UsageWindow] {
        guard json["status"] as? String == "SUCCESS",
              let command = json["command"] as? [String: Any], command["name"] as? String == "usage",
              let groups = (command["data"] as? [String: Any])?["groups"] as? [[String: Any]] else { return [] }
        var pools: [(name: String, windows: [UsageWindow])] = [], caps: [(group: String, window: UsageWindow)] = []
        for group in groups {
            let name = group["name"] as? String ?? "Quota"
            let isPool = name.range(of: "models", options: .caseInsensitive) != nil
            let pool = name.replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
            let windows = (group["buckets"] as? [[String: Any]] ?? []).compactMap { b -> UsageWindow? in
                guard let id = b["id"] as? String, b["disabled"] as? Bool != true else { return nil }
                let window = b["window"] as? String
                let label = window == "5h" ? "5-hour" : window == "weekly" ? "weekly" : b["name"] as? String ?? id
                return UsageWindow(id: isPool ? id : "weekly_model_\(id)", label: "\(pool) · \(label)",
                                   percentUsed: (b["remaining_fraction"] as? Double).map { (((1 - $0) * 100) * 10_000).rounded() / 10_000 },   // 1 - 0.8 lands just under 20, which would show as 19
                                   resetsAt: (b["reset_time"] as? String).flatMap(parseISO), pool: isPool ? pool : nil)
            }
            if !isPool {
                caps += windows.map { (name, $0) }
            } else if !windows.isEmpty {
                pools.append((pool, windows.sorted { $0.label.hasSuffix("5-hour") && !$1.label.hasSuffix("5-hour") }))   // session first, like Codex
            }
        }
        guard !pools.isEmpty else { return caps.map(\.window) }
        for (group, window) in caps {
            let word = group.split { !$0.isLetter }.first.map { $0.lowercased() } ?? ""
            let home = pools.firstIndex { $0.name.lowercased().contains(word) } ?? 0
            var cap = window
            cap.pool = pools[home].name
            pools[home].windows.append(cap)
        }
        return pools.flatMap(\.windows)
    }

    /// Part of `cause(of:)`, so only consulted when a run gave no usage: agy also prints "not signed in" briefly while it
    /// silently refreshes a working login.
    static func signedOut(_ output: Data) -> Bool {
        let text = String(decoding: output, as: UTF8.self).lowercased()
        return ["not logged in", "not signed in", "login method", "unauthenticated",
                "authentication required", "login required", "please log in", "please sign in"]
            .contains { text.contains($0) }
    }

    enum Cause { case signedOut, network, stalled }

    /// Why a run gave no usable report, killed or not, from its output and log; when in doubt, a sign-in or a stall,
    /// never the network. Any sign of a sign-in makes it a sign-out, even beside network errors (a token refresh
    /// that hits the network can itself send agy to a sign-in): agy's browser sign-in lines, or anything `signedOut`
    /// matches once the two lines agy logs at the start of every session, working ones too, are taken out. The
    /// network needs network errors, a log read whole, and agy gone; anything else is a stall.
    static func cause(of run: Run) -> Cause {
        let text = String(decoding: run.out + run.err + run.log, as: UTF8.self).lowercased()
            .replacingOccurrences(of: "you are not logged into antigravity", with: "")
            .replacingOccurrences(of: "skipped (not logged in)", with: "")
        let browser = ["waiting for authentication", "opening browser", "open browser", "authorize the application",
                       "local browser", "accounts.google.com/o/oauth2", "oauth callback", "oauth2 flow"]
        if browser.contains(where: text.contains) || signedOut(Data(text.utf8)) { return .signedOut }
        let network = ["i/o timeout", "context deadline exceeded", "dial tcp", "no such host", "operation timed out",
                       "network is unreachable", "network is down", "connection refused", "connection reset",
                       "tls handshake timeout"]
        guard !run.survived, run.logComplete, !run.log.isEmpty, network.contains(where: text.contains) else { return .stalled }
        return .network
    }

    /// One agy run. `killed`: it passed its timeout and Pulse ended it. `survived`: something in its process group was
    /// still there after SIGKILL, so nothing it left behind can be trusted. `logComplete`: all of `log` was read.
    struct Run {
        var out = Data(), err = Data(), log = Data()
        var killed = false, survived = false, logComplete = true
    }

    /// Runs agy in a private temp folder with no stdin, in a process group of its own. Output goes to files, not
    /// pipes, so a full pipe can never stall it and no thread blocks while it runs. A run past `timeout` gets SIGTERM
    /// (agy flushes its log), then SIGKILL for the whole group, and `run` returns only once agy is reaped and the group
    /// is empty, or as `survived` when it isn't; the temp folder goes after that. Every run hands back its
    /// `agy.log`, when it wrote one, for `cause(of:)`.
    static func run(_ agy: URL, _ args: [String], timeout: Duration) async -> Run? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "pulse-agy-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }
        let outURL = dir.appending(path: "out"), errURL = dir.appending(path: "err")
        // nothing starts for a fetch already given up on, or while an earlier run's group may still be there
        guard !Task.isCancelled, survivorsGone(),
              let pid = spawnInOwnGroup(agy, args, in: dir, out: outURL, err: errURL) else { return nil }
        var result = Run()
        let deadline = ContinuousClock.now + timeout
        while leader(pid) == .running, ContinuousClock.now < deadline, !Task.isCancelled { await nap() }
        if leader(pid) == .running {
            // agy stays unreaped (a zombie once it exits) until the last group signal: its pid, and so the group's
            // id, can't be handed to another process before then
            result.killed = true
            kill(-pid, SIGTERM)   // agy flushes its log
            await waitFor(within: .seconds(1)) { leader(pid) != .running }
            if leader(pid) != .gone { kill(-pid, SIGKILL) }
            await waitFor(within: .seconds(2)) { leader(pid) != .running }
            if leader(pid) == .running {
                result.survived = true   // left unreaped, so its id stays reserved
            } else {
                reap(pid)
                result.survived = !(await waitFor(within: .seconds(2)) { groupGone(pid) })
            }
            if result.survived { survivors.withLock { _ = $0.insert(pid) } }
        } else {
            reap(pid)   // exited by itself: anything it left running in its group, such as an updater, finishes
        }
        (result.log, result.logComplete) = readLog(dir.appending(path: "agy.log"))
        result.out = (try? Data(contentsOf: outURL)) ?? Data()
        result.err = (try? Data(contentsOf: errURL)) ?? Data()
        return result
    }

    /// Groups of runs that came back `survived`. No agy starts until every one is confirmed gone.
    static let survivors = Mutex<Set<pid_t>>([])

    private static func survivorsGone() -> Bool {
        survivors.withLock { groups in
            groups = groups.filter { pid in
                if leader(pid) == .exited { reap(pid) }   // its group, while it has anyone in it, keeps the id reserved
                return leader(pid) == .running || !groupGone(pid)
            }
            return groups.isEmpty
        }
    }

    /// posix_spawn rather than Process: Process can't give the child a process group of its own, and agy's
    /// descendants must be killable with it. Only stdin, stdout and stderr are inherited. If any part of that can't
    /// be set up, nothing starts.
    static func spawnInOwnGroup(_ exe: URL, _ args: [String], in dir: URL, out: URL, err: URL) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        let setup = [
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addopen(&actions, 1, out.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600),
            posix_spawn_file_actions_addopen(&actions, 2, err.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600),
            posix_spawn_file_actions_addchdir(&actions, dir.path),
            posix_spawnattr_setsigdefault(&attr, &all),   // Pulse's own ignored signals don't carry over
            posix_spawnattr_setsigmask(&attr, &none),
            posix_spawnattr_setpgroup(&attr, 0),
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                  | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)),
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { return nil }
        let argv = ([exe.path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, exe.path, &actions, &attr, argv, environ) == 0 ? pid : nil
    }

    /// A run's log: all of it up to `limit`, else its first and last halves of that, not complete. A sign-in line
    /// near the start can't be lost to the tail, and a log too big to read whole is never taken for the network.
    static func readLog(_ url: URL, limit: Int = 4 << 20) -> (Data, complete: Bool) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (Data(), true) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        guard size > UInt64(limit) else { return ((try? h.readToEnd()) ?? Data(), true) }
        var data = (try? h.read(upToCount: limit / 2)) ?? Data()
        try? h.seek(toOffset: size - UInt64(limit / 2))
        data += (try? h.readToEnd()) ?? Data()
        return (data, false)
    }

    enum Leader { case running, exited, gone }

    /// agy's own state, seen without reaping it (`WNOWAIT`): `exited` is a zombie still holding its pid; `gone` means
    /// it isn't Pulse's child to wait for any more, so its pid may already be someone else's and is never signalled.
    private static func leader(_ pid: pid_t) -> Leader {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return .gone }
        return info.si_pid == pid ? .exited : .running
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
    }

    /// Nobody is left in agy's group. Only ESRCH says so; EPERM or any other error counts as someone still there.
    private static func groupGone(_ pid: pid_t) -> Bool { kill(-pid, 0) == -1 && errno == ESRCH }

    /// Waits up to `limit` for `done`, checking every tenth of a second.
    @discardableResult
    private static func waitFor(within limit: Duration, _ done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            await nap()
        }
        return true
    }

    /// A tenth of a second, even in a cancelled task, where `Task.sleep` returns at once: ending agy must wait for it.
    private static func nap() async {
        if Task.isCancelled { usleep(100_000) } else { try? await Task.sleep(for: .milliseconds(100)) }
    }
}

func fetchSnapshot(_ id: AccountID) async -> AccountSnapshot {
    switch id {
    case .claude: await ClaudeAdapter.fetch()
    case .codex: await CodexAdapter.fetch()
    case .grok: await GrokAdapter.fetch()
    case .antigravity: await AntigravityAdapter.fetch()
    }
}
