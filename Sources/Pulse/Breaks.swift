import Foundation

/// Break reminders without any UI or system calls: the settings, the schedule, the interests list, the overlay's
/// colours and the idea prompt. The checks compile this file on its own.

enum BreakKind: String, Codable { case micro, long }

struct BreakSettings: Codable, Equatable {
    var enabled = false   // an overlay over every screen is opt-in
    var microEvery: TimeInterval = 20 * 60
    var microLength: TimeInterval = 20
    var longEnabled = true
    var longEvery: TimeInterval = 60 * 60
    var longLength: TimeInterval = 5 * 60
    var color = BreakColor.presets[0].name   // a preset's name, or "#RRGGBB"
    var showAgents = true
    var ideas = true
    var level = 1   // 0 easy … 4 adventurous
    var interests: [String] = []

    static let levels = ["Easy", "Gentle", "Playful", "Bold", "Adventurous"]

    func length(_ kind: BreakKind) -> TimeInterval { kind == .micro ? microLength : longLength }

    init() {}

    // Every field may be missing, so a state.json from an older or newer Pulse still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BreakSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        microEvery = try c.decodeIfPresent(TimeInterval.self, forKey: .microEvery) ?? d.microEvery
        microLength = try c.decodeIfPresent(TimeInterval.self, forKey: .microLength) ?? d.microLength
        longEnabled = try c.decodeIfPresent(Bool.self, forKey: .longEnabled) ?? d.longEnabled
        longEvery = try c.decodeIfPresent(TimeInterval.self, forKey: .longEvery) ?? d.longEvery
        longLength = try c.decodeIfPresent(TimeInterval.self, forKey: .longLength) ?? d.longLength
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        showAgents = try c.decodeIfPresent(Bool.self, forKey: .showAgents) ?? d.showAgents
        ideas = try c.decodeIfPresent(Bool.self, forKey: .ideas) ?? d.ideas
        level = min(4, max(0, try c.decodeIfPresent(Int.self, forKey: .level) ?? d.level))
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? d.interests
    }
}

/// "5-min break" / "20-sec break".
func breakLengthLabel(_ seconds: TimeInterval) -> String {
    seconds >= 60 ? "\(Int(seconds / 60))-min break" : "\(Int(seconds))-sec break"
}

/// The interests are keywords: typed, trimmed, one of each regardless of case, at most 20.
enum BreakInterests {
    static let maxCount = 20, maxLength = 30

    static func adding(_ typed: String, to list: [String]) -> [String] {
        let word = typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !word.isEmpty, word.count <= maxLength, list.count < maxCount,
              !list.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return list }
        return list + [word]
    }
}

/// The overlay's colour: a preset's glow and bar, or one custom colour whose bar is a lighter shade of it.
enum BreakColor {
    struct Preset { let name: String; let glow: UInt32; let bar: UInt32 }
    static let presets = [
        Preset(name: "amber", glow: 0xC27532, bar: 0xEE9A4F),
        Preset(name: "rose", glow: 0xB8435F, bar: 0xF2809A),
        Preset(name: "violet", glow: 0x6E52CF, bar: 0xA993FF),
        Preset(name: "ocean", glow: 0x2A6CC4, bar: 0x62A8FF),
        Preset(name: "sage", glow: 0x3F8F57, bar: 0x7FD193),
        Preset(name: "graphite", glow: 0x7C7C82, bar: 0xE3E3E8),
    ]

    /// "#3FB8AF", "3fb8af" → 0x3FB8AF. Six hex digits only.
    static func rgb(hex: String) -> UInt32? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(s, radix: 16)
    }

    static func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }

    /// (glow, bar) for a setting; an unknown value falls back to the first preset.
    static func pair(_ setting: String) -> (glow: UInt32, bar: UInt32) {
        if let p = presets.first(where: { $0.name == setting }) { return (p.glow, p.bar) }
        guard let c = rgb(hex: setting) else { return (presets[0].glow, presets[0].bar) }
        return (c, mix(c, white: 0.35))
    }

    static func mix(_ c: UInt32, white k: Double) -> UInt32 {
        let parts = [c >> 16, (c >> 8) & 0xFF, c & 0xFF].map { UInt32((Double($0) + (255 - Double($0)) * k).rounded()) }
        return parts[0] << 16 | parts[1] << 8 | parts[2]
    }
}

/// When breaks come and what they're doing. Time is passed in, so the checks can run a day in a millisecond.
struct BreakSchedule {
    enum Phase: Equatable {
        case working
        case countdown(BreakKind, endsAt: Date)
        case onBreak(BreakKind, endsAt: Date)
        case paused(BreakKind, remaining: TimeInterval)

        var isCountdown: Bool { if case .countdown = self { true } else { false } }
        var isPaused: Bool { if case .paused = self { true } else { false } }
    }
    enum Event: Equatable { case countdown(BreakKind), start(BreakKind), end }

    static let countdown: TimeInterval = 30
    static let snooze: TimeInterval = 5 * 60

    var settings: BreakSettings
    private(set) var phase = Phase.working
    private(set) var lastMicro: Date
    private(set) var lastLong: Date
    private(set) var snoozedUntil: Date?

    init(settings: BreakSettings, now: Date) {
        self.settings = settings
        lastMicro = now
        lastLong = now
    }

    /// The break that's due now, if any. The long one takes the place of a micro break due at the same time.
    func due(at now: Date) -> BreakKind? {
        if let s = snoozedUntil, now < s { return nil }
        if settings.longEnabled, now.timeIntervalSince(lastLong) >= settings.longEvery { return .long }
        if now.timeIntervalSince(lastMicro) >= settings.microEvery { return .micro }
        return nil
    }

    /// Called about once a second. `idle` is how long the Mac has had no input or been locked; `voiceActive` holds
    /// new breaks back during a Pulse voice call.
    mutating func tick(now: Date, idle: TimeInterval, voiceActive: Bool) -> Event? {
        guard settings.enabled else {
            lastMicro = now; lastLong = now; snoozedUntil = nil   // turning breaks on starts the clock then
            if phase == .working { return nil }
            phase = .working
            return .end
        }
        if !settings.longEnabled { lastLong = now }
        switch phase {
        case .working:
            away(idle, now: now)
            guard !voiceActive, let kind = due(at: now) else { return nil }
            snoozedUntil = nil
            phase = .countdown(kind, endsAt: now.addingTimeInterval(Self.countdown))
            return .countdown(kind)
        case let .countdown(kind, endsAt):
            if voiceActive { phase = .working; return .end }   // it comes back when the call ends
            return now >= endsAt ? start(kind, now: now) : nil
        case let .onBreak(kind, endsAt):
            return now >= endsAt ? finish(kind, now: now) : nil
        case .paused:
            return nil
        }
    }

    /// Time away counts as a break: away for a micro break's length restarts the micro clock, for a long break's
    /// length both. The sleep that just ended comes in here too.
    mutating func away(_ seconds: TimeInterval, now: Date) {
        guard phase == .working else { return }
        if seconds >= settings.longLength { lastLong = now; lastMicro = now }
        else if seconds >= settings.microLength { lastMicro = now }
    }

    /// A countdown right now, whatever is due: the `simulatedBreak` test hook.
    mutating func begin(_ kind: BreakKind, now: Date) -> Event? {
        guard settings.enabled, phase == .working else { return nil }
        phase = .countdown(kind, endsAt: now.addingTimeInterval(Self.countdown))
        return .countdown(kind)
    }

    /// Clicking the countdown.
    mutating func startNow(_ now: Date) -> Event? {
        guard case let .countdown(kind, _) = phase else { return nil }
        return start(kind, now: now)
    }

    mutating func pause(_ now: Date) {
        guard case let .onBreak(kind, endsAt) = phase else { return }
        phase = .paused(kind, remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    mutating func resume(_ now: Date) {
        guard case let .paused(kind, remaining) = phase else { return }
        phase = .onBreak(kind, endsAt: now.addingTimeInterval(remaining))
    }

    /// The same break comes back in five minutes.
    mutating func snooze(_ now: Date) -> Event? {
        guard phase != .working else { return nil }
        phase = .working
        snoozedUntil = now.addingTimeInterval(Self.snooze)
        return .end
    }

    /// Ends the break as taken.
    mutating func backToWork(_ now: Date) -> Event? {
        switch phase {
        case let .onBreak(kind, _), let .paused(kind, _): return finish(kind, now: now)
        default: return nil
        }
    }

    /// Seconds left on the countdown or the break, and how long that whole span is.
    func remaining(_ now: Date) -> (left: TimeInterval, total: TimeInterval)? {
        switch phase {
        case .working: return nil
        case let .countdown(_, endsAt): return (max(0, endsAt.timeIntervalSince(now)), Self.countdown)
        case let .onBreak(kind, endsAt): return (max(0, endsAt.timeIntervalSince(now)), settings.length(kind))
        case let .paused(kind, remaining): return (remaining, settings.length(kind))
        }
    }

    private mutating func start(_ kind: BreakKind, now: Date) -> Event {
        phase = .onBreak(kind, endsAt: now.addingTimeInterval(settings.length(kind)))
        return .start(kind)
    }

    private mutating func finish(_ kind: BreakKind, now: Date) -> Event {
        if kind == .long { lastLong = now }
        lastMicro = now
        snoozedUntil = nil
        phase = .working
        return .end
    }
}

/// What the on-device model is asked for. Reroll keeps the interests and level; Surprise me drops the interests.
enum BreakIdeaPrompt {
    static let instructions = """
        You suggest one thing a person can do during a short break from their computer. \
        It must fit in the break's length and be doable right where they are, at home or at their desk, \
        away from the screen. Never suggest anything that needs travel, money, buying, booking, other people, \
        or a vehicle. Keep it safe and kind. Write one short sentence that starts with a verb, under 20 words.
        """

    static let levelWords = [
        "easy: calm and still, almost no effort",
        "gentle: relaxing, with a little movement or care",
        "playful: fun, silly or creative",
        "bold: active, it gets the body going or takes a little nerve",
        "adventurous: surprising and daring, something they've never done at a desk, but safe",
    ]

    /// What kind of thing the idea is, picked at random per request so Reroll doesn't keep landing on the same thing.
    /// Calm levels get calm kinds, bold levels active ones.
    static func angles(level: Int) -> [String] {
        switch level {
        case ...1: ["something to notice with the senses", "something to tidy or arrange", "something calm to make or draw"]
        case 2: ["something silly to make or draw", "something to play", "a small game"]
        default: ["something that moves the whole body", "a small dare or challenge", "something to try for the first time"]
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int(seconds / 60)) minute\(seconds >= 120 ? "s" : "")" : "\(Int(seconds)) seconds"
    }

    /// `focus` is the one interest this idea is about (nil for a surprise); `angle` one of `angles`.
    static func prompt(length: TimeInterval, level: Int, focus: String?, angle: String, avoid: [String] = []) -> String {
        var lines = ["The break lasts \(duration(length)). Suggest something that takes about that long, not longer."]
        if length < 60 { lines.append("It's very short: one quick action they can finish in \(duration(length)).") }
        if let focus {
            lines.append("It must be clearly about their interest \"\(focus)\", and name it.")
            lines.append("Make it \(angle). Level: \(levelWords[min(4, max(0, level))]).")
        } else {
            lines.append("Make it odd, random, quirky and fun, something they'd never expect, like \"draw a frog sitting on top of a doghouse\" or \"walk barefoot across the yard\". Make it \(angle).")
        }
        lines.append("Be specific and concrete. Don't suggest stretching unless the interest is stretching.")
        if !avoid.isEmpty { lines.append("Don't repeat or reword any of these: \(avoid.joined(separator: " | "))") }
        return lines.joined(separator: "\n")
    }

    /// The interest to build on: any but the one used last, so rerolls move between them.
    static func focus(from interests: [String], after last: String?, using rng: inout some RandomNumberGenerator) -> String? {
        let choices = interests.count > 1 ? interests.filter { $0 != last } : interests
        return choices.randomElement(using: &rng)
    }

    /// The interests a sentence names, as whole words: "plant" counts for "plants" and "stretch" for "stretching",
    /// "teach" doesn't count for "tea".
    static func interestsUsed(_ idea: String, from interests: [String]) -> [String] {
        let text = idea.lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return interests.filter { interest in
            let i = interest.lowercased()
            if i.contains(" ") { return text.contains(i) }
            let singular = i.hasSuffix("s") ? String(i.dropLast()) : i
            var forms = [i, singular, singular + "s", singular + "es"]
            if i.hasSuffix("ing"), i.count > 5 { let stem = String(i.dropLast(3)); forms += [stem, stem + "s", stem + "es"] }
            return forms.contains { words.contains($0) }
        }
    }
}
