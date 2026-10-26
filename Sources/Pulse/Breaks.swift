import Foundation

/// Break reminders without any UI or system calls: the settings, the schedule, the interests list, the overlay's
/// colours and the idea prompt. The checks compile this file on its own.

enum BreakKind: String, Codable { case micro, long }

/// What counts as a break taken without one on screen. `idle`: the screen locked, the Mac asleep, or 5 minutes with
/// no input. `fixed`: only locked or asleep, for people who watch the screen without touching it.
enum BreakAwayMode: String, Codable, CaseIterable { case idle, fixed }

struct BreakSettings: Codable, Equatable {
    var enabled = false   // an overlay over every screen is opt-in
    var microEvery: TimeInterval = 20 * 60
    var microLength: TimeInterval = 20
    var longEnabled = true
    var longEvery: TimeInterval = 60 * 60
    var longLength: TimeInterval = 5 * 60
    var color = BreakColor.presets[0].name   // a preset's name, or "#RRGGBB"
    var showAgents = true
    var partyMode = true  // hats, costumes and props on the agents
    var holidays = true   // a holiday's video behind the countdown, and its hats that week
    var ideas = true
    var level = 1   // 0 easy … 4 adventurous
    var interests: [String] = []
    var awayMode = BreakAwayMode.idle
    var startSound = "Blow"   // a sound's name, as Battery's pickers list them; "" is None
    var endSound = "Glass"

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
        partyMode = try c.decodeIfPresent(Bool.self, forKey: .partyMode) ?? d.partyMode
        holidays = try c.decodeIfPresent(Bool.self, forKey: .holidays) ?? d.holidays
        ideas = try c.decodeIfPresent(Bool.self, forKey: .ideas) ?? d.ideas
        level = min(4, max(0, try c.decodeIfPresent(Int.self, forKey: .level) ?? d.level))
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? d.interests
        awayMode = (try? c.decodeIfPresent(BreakAwayMode.self, forKey: .awayMode)) ?? d.awayMode
        startSound = try c.decodeIfPresent(String.self, forKey: .startSound) ?? d.startSound
        endSound = try c.decodeIfPresent(String.self, forKey: .endSound) ?? d.endSound
    }

    /// The sound a break event plays: one as a break starts, another when it runs its full length, so it can be taken
    /// with the eyes closed. Nothing for Snooze, Escape or Back to Work: then you're looking already.
    func sound(for event: BreakSchedule.Event) -> String? {
        let name: String = switch event {
        case .start: startSound
        case .end(_, .taken, _): endSound
        default: ""
        }
        return name.isEmpty ? nil : name
    }
}

/// A holiday that dresses the break screen: its video plays muted behind the countdown, its colours light the edges.
struct BreakHoliday: Equatable {
    let name: String
    let video: String           // Resources/<video>.mp4, and <video>-poster.jpg for Reduce Motion
    let glow: UInt32, bar: UInt32
    let matches: @Sendable (DateComponents) -> Bool

    static func == (a: Self, b: Self) -> Bool { a.name == b.name }

    static let all = [
        BreakHoliday(name: "halloween", video: "holiday-halloween", glow: 0xE8822A, bar: 0xFFB050) {
            $0.month == 10 && $0.day == 31
        },
        // US Thanksgiving: the fourth Thursday of November
        BreakHoliday(name: "thanksgiving", video: "holiday-thanksgiving", glow: 0xC8553D, bar: 0xE8B04A) {
            $0.month == 11 && $0.weekday == 5 && $0.weekdayOrdinal == 4
        },
    ]

    /// The holiday on `date`, or the one named by `simulated` (for testing on any day).
    static func on(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian), simulated: String? = nil) -> BreakHoliday? {
        if let simulated { return all.first { $0.name == simulated } }
        let c = calendar.dateComponents([.month, .day, .weekday, .weekdayOrdinal], from: date)
        return all.first { $0.matches(c) }
    }

    /// Where a break's video starts: with less time left than the video runs, its last part, so the ending is seen.
    static func start(duration: TimeInterval, left: TimeInterval) -> TimeInterval {
        max(0, duration - left)
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
///
/// Each kind has a due time on a fixed grid: the next one is due one interval after the previous one was *due*, so
/// "every 10 minutes" means every 10 minutes, however long the break, its countdown or a hold took. Slots that passed
/// meanwhile are skipped, never stacked.
struct BreakSchedule {
    enum Phase: Equatable {
        case working
        case countdown(BreakKind, endsAt: Date)
        case onBreak(BreakKind, endsAt: Date)
        case paused(BreakKind, remaining: TimeInterval)

        var isCountdown: Bool { if case .countdown = self { true } else { false } }
        var isPaused: Bool { if case .paused = self { true } else { false } }
        var isWorking: Bool { self == .working }
    }
    /// How a break ended, as the history keeps it.
    enum Outcome: String, Codable, CaseIterable { case taken, endedEarly, snoozed, skipped, away }
    enum Event: Equatable {
        case countdown(BreakKind)
        case start(BreakKind)
        /// `outcome` nil: interrupted (a voice call, a locked screen) and still due, so it comes back.
        case end(BreakKind, BreakSchedule.Outcome?, due: Date)
        /// Time away counted as these breaks, each with the time it was due.
        case away([BreakKind: Date])
    }

    static let countdown: TimeInterval = 30
    static let snooze: TimeInterval = 5 * 60
    static let idleAway: TimeInterval = 5 * 60   // no input this long counts as time away, unless the mode is fixed
    static let merge: TimeInterval = 2 * 60      // a long break due this soon takes the place of a due micro break

    var settings: BreakSettings
    private(set) var phase = Phase.working
    private(set) var nextMicro: Date
    private(set) var nextLong: Date
    private(set) var snoozedUntil: Date?
    private var currentDue: Date?                 // when the break counting down or on screen was due
    private var counts = true                     // false for a simulatedBreak, which leaves the clocks alone
    private var awayCounted: Set<BreakKind> = []  // what the current time away already counted, to report it once

    init(settings: BreakSettings, now: Date) {
        self.settings = settings
        nextMicro = now.addingTimeInterval(settings.microEvery)
        nextLong = now.addingTimeInterval(settings.longEvery)
    }

    /// The break that's due now, if any. A long break due within `merge` takes the place of a due micro break.
    func due(at now: Date) -> BreakKind? {
        if let s = snoozedUntil, now < s { return nil }
        if settings.longEnabled, now >= nextLong { return .long }
        guard now >= nextMicro else { return nil }
        return settings.longEnabled && nextLong.timeIntervalSince(now) <= Self.merge ? .long : .micro
    }

    /// When each kind comes next, a snooze included; nil for the long break when it's off.
    func upcoming(_ now: Date) -> (micro: Date, long: Date?) {
        let s = snoozedUntil ?? .distantPast
        return (max(nextMicro, s), settings.longEnabled ? max(nextLong, s) : nil)
    }

    /// Called about once a second. `idle`: seconds with no input; `locked`: the screen is locked (no countdown or
    /// overlay then; the controller reports how long when it unlocks); `voiceActive` holds new breaks back.
    mutating func tick(now: Date, idle: TimeInterval, locked: Bool = false, voiceActive: Bool) -> Event? {
        guard settings.enabled else {
            nextMicro = now.addingTimeInterval(settings.microEvery)   // turning breaks on starts the clocks then
            nextLong = now.addingTimeInterval(settings.longEvery)
            snoozedUntil = nil
            awayCounted = []
            return interrupt(.skipped)
        }
        if !settings.longEnabled { nextLong = now.addingTimeInterval(settings.longEvery) }
        // a shorter interval chosen in Settings applies at once
        nextMicro = min(nextMicro, now.addingTimeInterval(settings.microEvery))
        nextLong = min(nextLong, now.addingTimeInterval(settings.longEvery))
        switch phase {
        case .working:
            if settings.awayMode == .idle, idle >= Self.idleAway, !locked {
                if let e = away(idle, now: now) { return e }
            } else if !locked {
                awayCounted = []
            }
            guard !voiceActive, !locked, let kind = due(at: now) else { return nil }
            snoozedUntil = nil
            currentDue = kind == .long ? nextLong : nextMicro
            counts = true
            phase = .countdown(kind, endsAt: now.addingTimeInterval(Self.countdown))
            return .countdown(kind)
        case let .countdown(kind, endsAt):
            if voiceActive || locked { return interrupt(nil) }   // still due: it comes back after the call or the lock
            return now >= endsAt ? start(kind, now: now) : nil
        case let .onBreak(kind, endsAt):
            if locked { return interrupt(nil) }   // the lock decides: long enough counts as time away
            return now >= endsAt ? finish(kind, .taken, now: now) : nil
        case .paused:
            return locked ? interrupt(nil) : nil
        }
    }

    /// Time away counts as a break: as long as a micro break counts as one, as long as a long break as both. The
    /// clocks then restart from now. Called with the idle time on every tick it lasts, and once for a lock or sleep.
    mutating func away(_ seconds: TimeInterval, now: Date) -> Event? {
        guard settings.enabled, phase == .working else { return nil }
        var counted: [BreakKind: Date] = [:]
        if seconds >= settings.microLength {
            if !awayCounted.contains(.micro) { counted[.micro] = nextMicro }
            nextMicro = now.addingTimeInterval(settings.microEvery)
        }
        if settings.longEnabled, seconds >= settings.longLength {
            if !awayCounted.contains(.long) { counted[.long] = nextLong }
            nextLong = now.addingTimeInterval(settings.longEvery)
        }
        guard !counted.isEmpty else { return nil }
        snoozedUntil = nil
        awayCounted.formUnion(counted.keys)
        return .away(counted)
    }

    /// A countdown right now, whatever is due: the `simulatedBreak` test hook. It leaves the clocks as they are.
    mutating func begin(_ kind: BreakKind, now: Date) -> Event? {
        guard settings.enabled, phase == .working else { return nil }
        currentDue = now
        counts = false
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

    /// The same break comes back in five minutes; the ones after it keep their grid.
    mutating func snooze(_ now: Date) -> Event? {
        guard let kind = activeKind else { return nil }
        let due = currentDue ?? now
        phase = .working
        snoozedUntil = now.addingTimeInterval(Self.snooze)
        currentDue = nil
        return .end(kind, .snoozed, due: due)
    }

    /// Back to Work: ends the break as taken, early.
    mutating func backToWork(_ now: Date) -> Event? {
        switch phase {
        case let .onBreak(kind, _), let .paused(kind, _): finish(kind, .endedEarly, now: now)
        default: nil
        }
    }

    /// Escape, or the countdown's ×: dismisses the break without taking it. The next one keeps its grid.
    mutating func skip(_ now: Date) -> Event? {
        guard let kind = activeKind else { return nil }
        return finish(kind, .skipped, now: now)
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

    // MARK: surviving a restart

    var clocks: BreakClocks { BreakClocks(nextMicro: nextMicro, nextLong: nextLong) }

    /// Carries on from the clocks saved before Pulse quit. `quitFor` is how long Pulse wasn't running, `downFor` how
    /// much of that the Mac was off or asleep. Asleep or off counts as time away in both modes; the rest counts only
    /// in the idle mode and only from 5 minutes, as no input would. At most one break is left due, never a burst.
    mutating func restore(_ saved: BreakClocks, now: Date, quitFor: TimeInterval, downFor: TimeInterval) -> Event? {
        guard settings.enabled, phase == .working else { return nil }
        // a saved time further off than one interval (a shorter interval since, a clock change) restarts from now
        nextMicro = min(saved.nextMicro, now.addingTimeInterval(settings.microEvery))
        nextLong = settings.longEnabled ? min(saved.nextLong, now.addingTimeInterval(settings.longEvery))
                                        : now.addingTimeInterval(settings.longEvery)
        let awayFor = settings.awayMode == .idle && quitFor >= Self.idleAway ? quitFor : downFor
        let event = awayFor > 0 ? away(awayFor, now: now) : nil
        awayCounted = []
        // overdue: only one break comes, the long one if both are due; an overdue micro moves to its next slot
        if due(at: now) == .long, nextMicro <= now {
            nextMicro = Self.slot(after: nextMicro, every: settings.microEvery, past: now)
        }
        return event
    }

    // MARK: internals

    private var activeKind: BreakKind? {
        switch phase {
        case .working: nil
        case let .countdown(k, _), let .onBreak(k, _), let .paused(k, _): k
        }
    }

    /// The first slot of a grid starting at `due` that's later than `now`, at least one interval on.
    static func slot(after due: Date, every: TimeInterval, past now: Date) -> Date {
        guard every > 0 else { return now }
        let k = max(1, Int(floor(now.timeIntervalSince(due) / every)) + 1)
        return due.addingTimeInterval(Double(k) * every)
    }

    private mutating func interrupt(_ outcome: Outcome?) -> Event? {
        guard let kind = activeKind else { return nil }
        let due = currentDue ?? .distantPast
        phase = .working
        if outcome != nil { currentDue = nil }
        return .end(kind, outcome, due: due)
    }

    private mutating func start(_ kind: BreakKind, now: Date) -> Event {
        phase = .onBreak(kind, endsAt: now.addingTimeInterval(settings.length(kind)))
        return .start(kind)
    }

    private mutating func finish(_ kind: BreakKind, _ outcome: Outcome, now: Date) -> Event {
        let due = currentDue ?? now
        if counts {
            if kind == .long {
                nextLong = Self.slot(after: due, every: settings.longEvery, past: now)
                // the micro slot it took the place of, and any that passed during it
                if nextMicro <= now.addingTimeInterval(Self.merge) {
                    nextMicro = Self.slot(after: nextMicro, every: settings.microEvery, past: now)
                }
            } else {
                nextMicro = Self.slot(after: due, every: settings.microEvery, past: now)
            }
        }
        counts = true
        phase = .working
        snoozedUntil = nil
        currentDue = nil
        return .end(kind, outcome, due: due)
    }
}

/// The due times saved across a restart.
struct BreakClocks: Codable, Equatable {
    var nextMicro: Date
    var nextLong: Date
    var savedAt = Date()
}

/// Every break and how it ended, kept on this Mac for 90 days, one JSON object per line.
struct BreakRecord: Codable, Equatable {
    var kind: BreakKind
    var due: Date
    var at: Date
    var outcome: BreakSchedule.Outcome
}

struct BreakHistory {
    static let keep: TimeInterval = 90 * 86400
    private(set) var records: [BreakRecord] = []

    init(records: [BreakRecord] = []) { self.records = records }

    /// Lines that don't decode (a partial write) are skipped.
    init(jsonLines data: Data) {
        let d = JSONDecoder()
        records = data.split(separator: 0x0A).compactMap { try? d.decode(BreakRecord.self, from: Data($0)) }
    }

    static func line(_ r: BreakRecord) -> Data { ((try? JSONEncoder().encode(r)) ?? Data()) + Data([0x0A]) }
    var jsonLines: Data { records.reduce(into: Data()) { $0 += Self.line($1) } }

    mutating func add(_ r: BreakRecord) { records.append(r) }

    /// Drops what's older than 90 days; true when anything went.
    mutating func prune(now: Date) -> Bool {
        let before = records.count
        records.removeAll { now.timeIntervalSince($0.at) > Self.keep }
        return records.count != before
    }

    func counts(since start: Date) -> [BreakSchedule.Outcome: Int] {
        records.filter { $0.at >= start }.reduce(into: [:]) { $0[$1.outcome, default: 0] += 1 }
    }

    /// "5 taken · 1 skipped · 2 snoozed", in a fixed order; "none" when empty.
    static func summary(_ counts: [BreakSchedule.Outcome: Int]) -> String {
        let parts = BreakSchedule.Outcome.allCases.compactMap { o in counts[o].map { "\($0) \(o.label)" } }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }
}

extension BreakSchedule.Outcome {
    var label: String {
        switch self {
        case .taken: "taken"
        case .endedEarly: "ended early"
        case .snoozed: "snoozed"
        case .skipped: "skipped"
        case .away: "away"
        }
    }
}

/// "Next: micro in 7 min", or "Next: long in 7 min" when the long break comes first or takes the micro's place.
func nextBreakText(micro: Date, long: Date?, now: Date) -> String {
    func until(_ d: Date) -> String {
        let s = max(0, d.timeIntervalSince(now))
        if s < 60 { return "under a minute" }
        let m = Int((s / 60).rounded(.up))
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
    if let long, long.timeIntervalSince(micro) <= BreakSchedule.merge { return "Next: long in \(until(min(micro, long)))" }
    return "Next: micro in \(until(micro))"
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
        case ...1: ["something to notice with the senses", "something to tidy or arrange", "something calm to make or draw",
                    "something to listen to", "something gentle for the hands", "a slow breathing exercise", "a small kindness for later"]
        case 2: ["something silly to make or draw", "something to play", "a small game", "a tiny performance",
                 "something to build from what's around", "a made-up challenge", "something to invent or imagine"]
        default: ["something that moves the whole body", "a small dare or challenge", "something to try for the first time",
                  "a balance or coordination test", "a short burst of exercise", "something to learn by doing", "a quick physical game"]
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
            // no example ideas: the small model tends to hand them back
            lines.append("Make it odd, random, quirky and fun, something they'd never expect. Make it \(angle).")
        }
        lines.append("Be specific and concrete. Don't suggest stretching unless the interest is stretching.")
        if !avoid.isEmpty { lines.append("Don't repeat or reword any of these: \(avoid.joined(separator: " | "))") }
        return lines.joined(separator: "\n")
    }

    /// How many shown ideas Pulse remembers, across breaks and restarts.
    static let keep = 40

    /// `list` with `idea` as its newest entry, at most `keep` long.
    static func remember(_ idea: String, in list: [String]) -> [String] {
        Array((list.filter { $0 != idea } + [idea]).suffix(keep))
    }

    /// The newest ideas that fit in the prompt, newest first. The on-device model's 4,096-token window holds the
    /// instructions, the prompt, the schema and the answer, so the list stays near 1,500 characters (~400 tokens).
    static func avoidList(_ recent: [String], budget: Int = 1500) -> [String] {
        var out: [String] = [], used = 0
        for idea in recent.reversed() {
            used += idea.count + 3
            if used > budget { break }
            out.append(idea)
        }
        return out
    }

    private static let smallWords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "for", "with", "in", "on", "at",
                                                  "by", "your", "you", "it", "its", "some", "into", "up", "out", "then", "from", "as"]

    /// A sentence's content words, lowercased, small words dropped and plurals folded ("plants" counts as "plant").
    static func words(_ idea: String) -> Set<String> {
        Set(idea.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !smallWords.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 })
    }

    /// True when `idea` rewords one of `recent`: at least 70% of their content words shared (overlap over union), or
    /// all of one's words (two or more) inside the other's. One changed subject in a short idea ("sounds" for
    /// "colours") is new.
    static func isRepeat(_ idea: String, of recent: [String]) -> Bool { lastSeen(idea, in: recent) != nil }

    /// Where in `recent` (oldest first) the newest idea that `idea` rewords sits; nil when it rewords none.
    static func lastSeen(_ idea: String, in recent: [String]) -> Int? {
        let w = words(idea)
        guard !w.isEmpty else { return nil }
        return recent.lastIndex { r in
            let o = words(r), shared = w.intersection(o).count
            return Double(shared) / Double(w.union(o).count) >= 0.7 || (shared == min(w.count, o.count) && shared >= 2)
        }
    }

    /// Asks up to `attempts` times, all within one `timeout`, for an idea that isn't a repeat of `recent`. Each
    /// rejected answer joins the next try's avoid list. When every answer repeats, the one shown longest ago wins,
    /// since with narrow interests the model runs out of new ideas and a blank line is worse. nil when the model
    /// fails or time runs out; the deadline holds even when the model ignores cancellation, and its late answer is dropped.
    static func fresh(recent: [String], attempts: Int = 3, timeout: TimeInterval,
                      ask: @escaping @Sendable (_ avoid: [String], _ attempt: Int) async -> String?) async -> String? {
        let work = Task<String?, Never> {
            var rejected: [String] = []
            for attempt in 0..<attempts {
                guard !Task.isCancelled, let text = await ask(rejected.reversed() + avoidList(recent), attempt),
                      !Task.isCancelled else { return nil }
                if !isRepeat(text, of: recent + rejected) { return text }
                rejected.append(text)
            }
            return rejected.min { (lastSeen($0, in: recent) ?? -1) < (lastSeen($1, in: recent) ?? -1) }
        }
        let race = Race()
        let timer = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }   // cancelled: the answer came first
            work.cancel()
            race.finish(nil)
        }
        Task {
            let text = await work.value
            race.finish(text)   // claimed before the timer stops, so a timer waking in between can't take its place
            timer.cancel()
        }
        // the deadline, the answer and a cancelled caller each end the wait; whichever comes first wins
        return await withTaskCancellationHandler {
            await withCheckedContinuation { race.wait($0) }
        } onCancel: {
            work.cancel()
            race.finish(nil)
        }
    }

    /// One result for a continuation that several racers may try to finish, possibly before it's waited on.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<String?, Never>?
        private var result: String??   // set once: the winner's value

        func wait(_ c: CheckedContinuation<String?, Never>) {
            let ready: String?? = lock.withLock { if result == nil { waiting = c }; return result }
            if let ready { c.resume(returning: ready) }
        }

        func finish(_ value: String?) {
            let c: CheckedContinuation<String?, Never>? = lock.withLock {
                guard result == nil else { return nil }
                result = .some(value)
                defer { waiting = nil }
                return waiting
            }
            c?.resume(returning: value)
        }
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
