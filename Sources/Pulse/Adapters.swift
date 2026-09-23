import Foundation
import Security
import WebKit

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
    struct Creds { var accessToken: String; var tier: String? }
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
        return Creds(accessToken: token, tier: (oauth["rateLimitTier"] as? String) ?? (oauth["subscriptionType"] as? String))
    }
}

enum ClaudeAdapter {
    static func fetch() async -> AccountSnapshot {
        var snap = AccountSnapshot(id: .claude, displayName: "Claude", planLabel: "Claude",
                                   health: .needsAuth, windows: [], fetchedAt: .now, source: .officialProtocol)

        // Preferred: Claude Code's own token against the endpoint its /usage reads. No WebKit, no cookies.
        if let creds = ClaudeKeychain.shared.credentials() {
            snap.planLabel = planLabel(creds.tier)
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
                // the credential's rateLimitTier lags plan changes; the organization's current tier does not
                if let org = await get("profile").1?["organization"] as? [String: Any], let tier = org["rate_limit_tier"] as? String {
                    snap.planLabel = planLabel(tier)
                }
                if !snap.windows.isEmpty { snap.health = .ok; return snap }
            }
            if status == 401 {
                ClaudeKeychain.shared.forget()   // token rotated or expired: re-read next poll, use the web session now
            } else if status == 0 || status == 429 || status >= 500 {
                snap.health = .providerError     // offline or throttled: keep last good windows; the web session is not consulted
                return snap
            }
        }

        // Fallback: Pulse's own claude.ai web session (Connect… in Settings).
        if let (tier, usage) = await ClaudeWeb.shared.fetchUsage() {
            snap.source = .officialUsagePage
            snap.planLabel = planLabel(tier)
            snap.windows = windows(from: usage)
            snap.health = snap.windows.isEmpty ? .providerError : .ok
            return snap
        }
        return snap
    }

    static func planLabel(_ tier: String?) -> String {
        guard let tier else { return "Claude" }
        if tier.contains("max_20") { return "Max 20x" }
        if tier.contains("max_5") { return "Max 5x" }
        if tier.contains("pro") { return "Pro" }
        if tier == "max" { return "Max" }
        return "Claude"
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
            guard let pct = l["percent"] as? Double,
                  let name = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String else { continue }
            out.append((2, UsageWindow(id: "weekly_model_\(name)", label: name, percentUsed: pct,
                                       resetsAt: (l["resets_at"] as? String).flatMap(parseISO))))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

}

// MARK: - Codex

enum CodexAdapter {
    // Codex's own sign-in (~/.codex/auth.json) against the usage endpoint the Codex app reads.
    // Replaces spawning `codex app-server` every poll: one HTTPS call, real reset timestamps.
    static func fetch() async -> AccountSnapshot {
        var snap = AccountSnapshot(id: .codex, displayName: "Codex", planLabel: "Codex",
                                   health: .needsAuth, windows: [], fetchedAt: .now, source: .officialProtocol)
        guard let auth = try? JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: ".codex/auth.json"))) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty
        else { return snap }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await ProviderHTTP.session.data(for: req)
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

    static func planLabel(_ plan: String) -> String {
        ["plus": "ChatGPT Plus", "pro": "ChatGPT Pro", "prolite": "ChatGPT Pro Lite",
         "business": "ChatGPT Business", "team": "ChatGPT Team", "enterprise": "ChatGPT Enterprise"][plan]
            ?? "ChatGPT \(plan.capitalized)"
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
    // grok.com per-model rolling buckets (no reset timestamp; no weekly pool exposed) — cookie fallback only.
    static let models: [(model: String, label: String)] = [
        ("grok-4", "Grok 4 (2h window)"),
        ("grok-4-heavy", "Grok 4 Heavy (2h window)"),
        ("grok-3", "Grok 3 (2h window)"),
    ]

    static func fetch() async -> AccountSnapshot {
        var snap = AccountSnapshot(id: .grok, displayName: "Grok", planLabel: "SuperGrok",
                                   health: .needsAuth, windows: [], fetchedAt: .now, source: .cliStatus)
        var errors: [GrokError] = []

        // Preferred: CLI token -> CLI billing endpoint (weekly credit pool with Build/Chat split).
        do {
            snap.windows = try await fetchCLI()
            snap.health = .ok
            return snap
        } catch let e as GrokError { errors.append(e) } catch { errors.append(.network("\(error)")) }

        // Fallback: grok.com web session captured by GrokLogin.
        if let cookies = await cookieHeader() {
            snap.source = .officialUsagePage
            do {
                snap.windows = try await webWindows(cookieHeader: cookies)
                snap.health = .ok
                return snap
            } catch let e as GrokError { errors.append(e) } catch { errors.append(.network("\(error)")) }
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
    /// falling back to the header saved at connect time.
    @MainActor
    static func cookieHeader() async -> String? {
        let live = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookieHeader(from: live) ?? Keychain.read("grok-cookies")
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

/// The Antigravity CLI's own usage report (`agy -p /usage`). agy asks Google as itself, so Pulse never
/// reads the Google token; Google's quota API refuses that token from any other client. The report is
/// a local command: no model prompt, no tokens, no conversation.
enum AntigravityAdapter {
    static func fetch() async -> AccountSnapshot {
        var snap = AccountSnapshot(id: .antigravity, displayName: "Antigravity", planLabel: "Google account",
                                   health: .missingClient, windows: [], fetchedAt: .now, source: .cliStatus)
        guard let agy = locateBinary("agy") else { return snap }
        snap.health = .providerError
        guard let version = await run(agy, ["--version"], timeout: .seconds(10)) else {
            snap.detail = "Antigravity CLI did not start"
            return snap
        }
        guard supportsUsageReport(String(decoding: version.out, as: UTF8.self)) else {
            snap.detail = "Update the Antigravity CLI (agy 1.1.11 or later)"
            return snap
        }
        guard let report = await run(agy, ["-p", "/usage", "--output-format", "json", "--print-timeout", "45s"],
                                     timeout: .seconds(60)) else {
            snap.detail = "Antigravity CLI timed out"
            return snap
        }
        if let json = try? JSONSerialization.jsonObject(with: report.out) as? [String: Any] {
            snap.windows = windows(from: json)
        }
        if !snap.windows.isEmpty {
            snap.health = .ok
        } else if signedOut(report.err + report.out) {
            snap.health = .needsAuth
            snap.detail = "Run agy once to sign in to Antigravity"
        } else {
            snap.detail = "Antigravity CLI returned no usage"
        }
        return snap
    }

    /// Print mode before agy 1.1.11 sent unknown slash commands to the model as a prompt, so older
    /// or unrecognised versions are never asked for `/usage`.
    static func supportsUsageReport(_ version: String) -> Bool {
        guard let r = version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return false }
        return !version[r].split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes([1, 1, 11])
    }

    /// `command.data.groups[]` are separate pools (Gemini; Claude and GPT), each with a 5-hour and a
    /// weekly bucket. The pool nearest its limit leads, so the ring shows it; the card lists both.
    static func windows(from json: [String: Any]) -> [UsageWindow] {
        guard json["status"] as? String == "SUCCESS",
              let command = json["command"] as? [String: Any], command["name"] as? String == "usage",
              let groups = (command["data"] as? [String: Any])?["groups"] as? [[String: Any]] else { return [] }
        let pools: [[UsageWindow]] = groups.map { group in
            let pool = (group["name"] as? String ?? "Quota")
                .replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
            return (group["buckets"] as? [[String: Any]] ?? []).compactMap { b -> UsageWindow? in
                guard let id = b["id"] as? String, b["disabled"] as? Bool != true else { return nil }
                let window = b["window"] as? String
                let label = window == "5h" ? "5-hour" : window == "weekly" ? "weekly" : b["name"] as? String ?? id
                return UsageWindow(id: id, label: "\(pool) · \(label)",
                                   percentUsed: (b["remaining_fraction"] as? Double).map { (1 - $0) * 100 },
                                   resetsAt: (b["reset_time"] as? String).flatMap(parseISO))
            }
            .sorted { $0.label.hasSuffix("5-hour") && !$1.label.hasSuffix("5-hour") }   // session first, like Codex
        }
        return pools.filter { !$0.isEmpty }
            .sorted { ($0.compactMap(\.percentUsed).max() ?? 0) > ($1.compactMap(\.percentUsed).max() ?? 0) }
            .flatMap { $0 }
    }

    /// Only consulted when the report had no usage: agy also prints "not signed in" briefly while it
    /// silently refreshes a working login.
    static func signedOut(_ output: Data) -> Bool {
        let text = String(decoding: output, as: UTF8.self).lowercased()
        return ["not logged in", "not signed in", "login method", "unauthenticated",
                "authentication required", "login required", "please log in", "please sign in"]
            .contains { text.contains($0) }
    }

    /// Runs agy in a private temp folder with no stdin. Output goes to files, not pipes, so a full pipe
    /// can never stall it and no thread blocks while it runs.
    private static func run(_ agy: URL, _ args: [String], timeout: Duration) async -> (out: Data, err: Data)? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "pulse-agy-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }
        let outURL = dir.appending(path: "out"), errURL = dir.appending(path: "err")
        guard fm.createFile(atPath: outURL.path, contents: nil), fm.createFile(atPath: errURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL)
        else { return nil }
        let p = Process()
        p.executableURL = agy
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out; p.standardError = err
        guard (try? p.run()) != nil else { return nil }
        let deadline = ContinuousClock.now + timeout
        while p.isRunning {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(100))) != nil else {
                p.terminate()
                return nil
            }
        }
        return ((try? Data(contentsOf: outURL)) ?? Data(), (try? Data(contentsOf: errURL)) ?? Data())
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
