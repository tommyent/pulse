import SwiftUI

enum AccountID: String, Codable, CaseIterable, Identifiable {
    case claude, codex, grok, antigravity
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        }
    }
    /// Display P3, not sRGB: the same hues as before, deep enough to hold their own next to
    /// macOS's P3 system colours on wide-gamut displays (sRGB screens clip them to their nearest).
    var accent: Color {
        switch self {
        case .claude: Color(.displayP3, red: 1.0, green: 0.40, blue: 0.16)
        case .codex: Color(.displayP3, red: 0.22, green: 0.42, blue: 1.0)
        case .grok: Color(.displayP3, red: 1.0, green: 0.72, blue: 0.10)
        case .antigravity: Color(.displayP3, red: 0.60, green: 0.36, blue: 1.0)   // not green: the battery's ring is
        }
    }
    /// A later pool of models on one account (Antigravity's Claude and GPT) has its own colour, so its ring can't pass for the first.
    func accent(pool: Int) -> Color { pool == 0 ? accent : Color(.displayP3, red: 0.35, green: 0.72, blue: 1.0) }
    var glyph: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "circle.hexagongrid"
        case .grok: "line.diagonal"
        case .antigravity: "sparkle"
        }
    }
}

enum Health: String, Codable { case ok, needsAuth, missingClient, stale, providerError }
enum Source: String, Codable { case officialProtocol, officialUsagePage, cliStatus, mock }

struct UsageWindow: Codable, Identifiable {
    var id: String        // session_5h, weekly_all, weekly_model_<model>, period_<product>, or a provider's own
    var label: String
    var percentUsed: Double?   // 0–100
    var resetsAt: Date?
    var pool: String? = nil   // the group of models sharing this limit, where an account has several

    static let nearLimitPercent: Double = 98
    var isNearLimit: Bool { (percentUsed ?? 0) >= Self.nearLimitPercent }

    /// A product's share of Grok's credits, not a limit of its own: "66% left" of Grok Build would be wrong with 44% of the credits left.
    var isShare: Bool { id.hasPrefix("period_") && id != "period_all" }
    /// Whether "Show what's left" turns this window around. A share always reads as what was used.
    func showsLeft(_ remaining: Bool) -> Bool { remaining && !isShare }
    /// A limit on one model beside the account's general limits: Claude's per-model weeks, an Antigravity model's own limit.
    var isCap: Bool { id.hasPrefix("weekly_model") }
}

// A ring's parts go by what each window is, never by provider or model name.
extension [UsageWindow] {
    /// General limits, shortest first as the adapters list them, then caps, fullest first. A share of a limit gets no slot.
    /// A cap with no number waits behind the known ones, so it can't hide one that's nearly full, and holds its slot when there's no other.
    private var ranked: [UsageWindow] {
        filter { !$0.isCap && !$0.isShare } + filter(\.isCap).sorted { ($0.percentUsed ?? -1) > ($1.percentUsed ?? -1) }
    }
    var outerArc: UsageWindow? { ranked.first }
    var innerArc: UsageWindow? { ranked.dropFirst().first }
    /// The disc behind the logo.
    var disc: UsageWindow? { ranked.dropFirst(2).first }
    /// The account's longest general limit, usually its week, is nearly spent. A session or one model's cap near its limit isn't this.
    var longestLimitSpent: Bool { last { !$0.isCap && !$0.isShare }?.isNearLimit == true }

    /// One list per pool of models sharing limits, in the provider's order. Never empty: an account with no numbers still has its ring.
    var pools: [[UsageWindow]] {
        var names: [String?] = []
        for window in self where !names.contains(window.pool) { names.append(window.pool) }
        return names.isEmpty ? [[]] : names.map { name in filter { $0.pool == name } }
    }

    /// The pools that get a ring, with their place in `pools`, which sets the colour. A later pool can be switched off by name
    /// in Settings; the first goes with its account's own switch.
    func ringPools(hiding hidden: (String) -> Bool = { _ in false }) -> [(index: Int, windows: [UsageWindow])] {
        pools.enumerated()
            .filter { $0.offset == 0 || $0.element.first?.pool.map(hidden) != true }
            .map { (index: $0.offset, windows: $0.element) }
    }

    /// What VoiceOver reads for a ring: what it draws, then any other window its badge stands for.
    func spokenValue(remaining: Bool, now: Date = .now) -> String {
        let drawn = [outerArc, innerArc, disc].compactMap { $0 }
        let others = filter { window in window.isNearLimit && !drawn.contains { $0.id == window.id } }
        return (drawn + others).enumerated().compactMap { index, window -> String? in
            guard let p = window.percentUsed else {
                return window.resetsAt.map { $0 <= now } == true ? "\(window.label) reset since the last update" : nil
            }
            var text = window.showsLeft(remaining) ? "\(window.label) has \(100 - Int(p))% left" : "\(window.label) \(Int(p))% used"
            if window.isNearLimit { text += ", near its limit" }
            if index == 0, window.resetsAt != nil {
                let reset = resetLabel(window.resetsAt, now: now)
                text += ", " + reset.prefix(1).lowercased() + reset.dropFirst()
            }
            return text
        }.joined(separator: "; ")
    }
}

struct AccountSnapshot: Codable, Identifiable {
    var id: AccountID
    var displayName: String
    var planLabel: String
    var health: Health
    var windows: [UsageWindow]
    var fetchedAt: Date
    var source: Source
    var detail: String? = nil   // provider-specific reason behind needsAuth / providerError

    /// A failed fetch keeps the last good windows on screen, marked stale, with this failure's reason.
    func staleKeeping(_ old: AccountSnapshot) -> AccountSnapshot {
        var stale = old
        stale.health = .stale
        stale.detail = detail
        return stale
    }

    /// A card opened before the first fetch lands: nothing is known yet, so it mustn't ask for a sign-in.
    static func checking(_ id: AccountID) -> AccountSnapshot {
        AccountSnapshot(id: id, displayName: id.displayName, planLabel: "", health: .providerError, windows: [],
                        fetchedAt: .now, source: .cliStatus, detail: "Checking \(id.displayName)…")
    }

    /// A fetch that ran out of time, for AppState to handle like any other failed fetch.
    static func noAnswer(_ id: AccountID) -> AccountSnapshot {
        AccountSnapshot(id: id, displayName: id.displayName, planLabel: "", health: .providerError, windows: [],
                        fetchedAt: .now, source: .cliStatus, detail: "\(id.displayName) didn't answer")
    }

    /// The windows to draw. Until its reset, a stale number can only have grown, so it stays, dimmed by the views, its
    /// near-limit badge included. Past its reset it's known to be wrong, so it becomes unknown instead of still reading 99%.
    /// The rail rereads this on every refresh pass (`refreshing` is published), so that shows within one poll of the reset.
    func shownWindows(now: Date = .now) -> [UsageWindow] {
        guard health == .stale else { return windows }
        return windows.map { w in
            guard let reset = w.resetsAt, reset <= now else { return w }
            var unknown = w
            unknown.percentUsed = nil
            return unknown
        }
    }

    /// Windows that just reached 98, 99 or 100%, each step announced once per reset period. `alerted` maps
    /// "account.window" (98, as before there were steps) and "account.window@99" / "@100" to the reset already
    /// announced; dropping under 95% rearms them except for Grok, whose dips do not prove a reset.
    /// A jump past several steps is one announcement.
    func newlyNearLimit(alerted: inout [String: Date], now: Date = .now) -> [UsageWindow] {
        guard health == .ok else { return [] }   // cached and stale numbers never alert
        var crossed: [UsageWindow] = []
        for w in windows {
            guard let p = w.percentUsed else { continue }
            let keys = [98: alertKey(w), 99: alertKey(w) + "@99", 100: alertKey(w) + "@100"]
            if p < 95, id != .grok { for k in keys.values { alerted[k] = nil }; continue }
            let reset = w.resetsAt ?? .distantPast
            // within 15 min is the same period: Claude's resets carry sub-second noise, Codex may rebuild it from seconds left
            let due = [98, 99, 100].compactMap { step -> String? in
                guard p >= Double(step), let key = keys[step] else { return nil }   // whole percents: 98.9 is still 98
                if id == .grok, let previous = alerted[key] {
                    // A changed future deadline or a missing deadline is not evidence of a reset.
                    if previous == .distantPast {
                        if reset > now { alerted[key] = reset }
                        return nil
                    }
                    guard previous <= now, reset > now,
                          reset.timeIntervalSince(previous) >= 15 * 60 else { return nil }
                    return key
                }
                return alerted[key].map({ abs($0.timeIntervalSince(reset)) < 15 * 60 }) == true ? nil : key
            }
            guard !due.isEmpty else { continue }
            for key in due { alerted[key] = reset }
            crossed.append(w)
        }
        return crossed
    }

    func alertKey(_ w: UsageWindow) -> String { "\(id.rawValue).\(w.id)" }

    /// The time alone today; from any other day the date too, so a days-old reading can't pass for this morning's.
    func lastUpdated(now: Date = .now) -> String {
        Calendar.current.isDate(fetchedAt, inSameDayAs: now) ? fetchedAt.formatted(date: .omitted, time: .shortened)
            : fetchedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var healthMessage: String? {
        switch health {
        case .ok: nil
        case .needsAuth: detail ?? signInMessage
        case .missingClient: "Install \(displayName) CLI"
        case .stale: "Stale — last updated \(lastUpdated())" + (detail.map { ". \($0)" } ?? "")
        case .providerError: detail ?? "\(displayName) usage unavailable"
        }
    }

    /// Here rather than in the adapters, so a needsAuth snapshot saved by an older build also says what to do.
    private var signInMessage: String {
        switch id {
        case .claude: "Sign in to Claude Code, or use Connect"
        case .codex: "Run `codex login` in Terminal"
        case .grok, .antigravity: "Sign in to \(displayName)"   // their adapters always give their own reason
        }
    }

    /// The sign-in Pulse can open itself. Codex and Antigravity sign in only through their own CLIs.
    var connectTitle: String? {
        health == .needsAuth && (id == .claude || id == .grok) ? "Connect \(displayName)…" : nil
    }
}


/// Keeps one stuck provider from stopping the rest. A task group waits for every child, and a fetch blocked on a `security`
/// prompt or a WebKit call ignores cancellation, so `answer` waits on a stream instead: past `limit` the fetch counts as
/// failed and is cancelled. If it still doesn't end it isn't started again until it does, since each new one would only
/// queue behind the same prompt or lock and hold another thread. The default limit leaves room for the slowest honest
/// failure: Grok's CLI path timing out at every step before its web fallback, about 109 s.
@MainActor
final class ProviderFetches {
    private let limit: Duration
    private let fetch: @Sendable (AccountID) async -> AccountSnapshot
    private var running: Set<AccountID> = []

    init(limit: Duration = .seconds(120), fetch: @escaping @Sendable (AccountID) async -> AccountSnapshot) {
        self.limit = limit
        self.fetch = fetch
    }

    /// nil: the provider's last fetch still hasn't ended, so there's nothing new; its snapshot already says it didn't answer.
    func answer(_ id: AccountID) async -> AccountSnapshot? {
        guard running.insert(id).inserted else { return nil }
        let (answers, sink) = AsyncStream.makeStream(of: AccountSnapshot.self)
        let work = Task {
            let snap = await fetch(id)
            running.remove(id)   // before the answer, so a pass straight after this one can fetch again
            sink.yield(snap)
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            if !Task.isCancelled { sink.yield(.noAnswer(id)) }
        }
        let first = await answers.first { _ in true }
        timer.cancel()
        work.cancel()
        sink.finish()   // a late answer goes nowhere
        return first
    }
}

/// Everyone asking for one slow thing waits on a single attempt, until `finish` or `limit`. An earlier attempt's limit never
/// wakes a later attempt's waiters.
@MainActor
final class SharedWait {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var attempt = 0

    /// Joins the attempt in flight, or calls `start` to begin one.
    func join(limit: Duration, start: () -> Void) async {
        await withCheckedContinuation { cont in
            waiting.append(cont)
            guard waiting.count == 1 else { return }
            attempt += 1
            let mine = attempt
            start()
            Task {
                try? await Task.sleep(for: limit)
                if attempt == mine { finish() }
            }
        }
    }

    func finish() {
        let done = waiting
        waiting = []
        attempt += 1
        done.forEach { $0.resume() }
    }
}

/// "Resets in 51 min" / "Resets in 4h 12m" / "Resets Mon 3:00 AM" / "Resets Fri, Sep 25, 12:21 PM".
/// Time follows the user's locale and 12/24-hour setting. From six days out a weekday alone is
/// ambiguous ("Fri" seen on a Friday means next week), so the date is added.
func resetLabel(_ date: Date?, now: Date = .now) -> String {
    guard let date else { return "" }
    let s = date.timeIntervalSince(now)
    if s <= 0 { return "Resetting…" }
    // Rounded: a provider's reset wobbles by under a second, and one reset must not read as both 5:59 and 6:00.
    let minutes = max(1, Int((s / 60).rounded()))
    if minutes < 60 { return "Resets in \(minutes) min" }
    if minutes < 24 * 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
    let day: Date.FormatStyle = s < 6 * 86400 ? .dateTime.weekday() : .dateTime.weekday().month().day()
    let rounded = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    return "Resets " + rounded.formatted(day.hour().minute())
}
