import SwiftUI

enum AccountID: String, Codable, CaseIterable, Identifiable {
    case claude, codex, grok
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }
    var accent: Color {
        switch self {
        case .claude: Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x45 / 255)  // #FF7A45
        case .codex: Color(red: 0x4D / 255, green: 0x7C / 255, blue: 0xFF / 255)   // #4D7CFF
        case .grok: Color(red: 0xFF / 255, green: 0xC1 / 255, blue: 0x4A / 255)    // #FFC14A
        }
    }
    var glyph: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "circle.hexagongrid"
        case .grok: "line.diagonal"
        }
    }
}

enum Health: String, Codable { case ok, needsAuth, missingClient, stale, providerError }
enum Source: String, Codable { case officialProtocol, officialUsagePage, cliStatus, mock }

struct UsageWindow: Codable, Identifiable {
    var id: String        // session_5h | weekly_all | weekly_model | weekly_pool
    var label: String
    var percentUsed: Double?   // 0–100
    var resetsAt: Date?
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

    /// Tightest window = the one nearest lockout.
    var tightestPercent: Double? {
        windows.compactMap(\.percentUsed).max()
    }

    var healthMessage: String? {
        switch health {
        case .ok: nil
        case .needsAuth: detail ?? "Connect \(displayName) — subscription login required"
        case .missingClient: "Install \(displayName) CLI"
        case .stale: "Stale — last updated \(fetchedAt.formatted(date: .omitted, time: .shortened))"
        case .providerError: detail ?? "\(displayName) usage unavailable"
        }
    }
}


/// "Resets in 51 min" / "Resets in 4h 12m" / "Resets Mon 3:00 AM" / "Resets Fri, Sep 25, 12:21 PM".
/// Time follows the user's locale and 12/24-hour setting. From six days out a weekday alone is
/// ambiguous ("Fri" seen on a Friday means next week), so the date is added.
func resetLabel(_ date: Date?, now: Date = .now) -> String {
    guard let date else { return "" }
    let s = date.timeIntervalSince(now)
    if s <= 0 { return "Resetting…" }
    if s < 3600 { return "Resets in \(Int(s / 60)) min" }
    if s < 24 * 3600 {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return "Resets in \(h)h \(m)m"
    }
    let day: Date.FormatStyle = s < 6 * 86400 ? .dateTime.weekday() : .dateTime.weekday().month().day()
    return "Resets " + date.formatted(day.hour().minute())
}
