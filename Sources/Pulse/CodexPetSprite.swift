import AppKit

/// The Codex pet sheet (8 columns × 11 rows of 192×208 cells, as the Codex app and CLI draw it).
/// Rows are named animations; each state lists its frame durations along its row.
enum CodexPetSprite {
    enum State: CaseIterable { case idle, waving, waiting, running, walkRight, walkLeft, jump, happy, oops, turn, turnBack }

    static let columns = 8, rows = 11

    /// (row, per-frame durations) per state, mirroring the Codex app's animation table.
    static func track(_ state: State) -> (row: Int, durations: [TimeInterval]) {
        switch state {
        case .idle:    (0, [0.28, 0.11, 0.11, 0.14, 0.14, 0.32])
        case .waving:  (3, [0.14, 0.14, 0.14, 0.28])
        case .waiting: (6, [0.15, 0.15, 0.15, 0.15, 0.15, 0.26])
        case .running: (7, [0.12, 0.12, 0.12, 0.12, 0.12, 0.22])
        case .walkRight: (1, Array(repeating: 0.1, count: 8))   // the break screen's pacing
        case .walkLeft: (2, Array(repeating: 0.1, count: 8))
        case .jump: (4, [0.12, 0.12, 0.16, 0.12, 0.2])
        // the break screen's tricks: a happy dance, an oops after a flip, and a turn-around in two rows
        case .happy: (8, [0.14, 0.14, 0.14, 0.14, 0.14, 0.2])
        case .oops: (5, Array(repeating: 0.12, count: 8))
        case .turn: (9, Array(repeating: 0.07, count: 8))
        case .turnBack: (10, Array(repeating: 0.07, count: 8))
        }
    }

    /// The share of a cell's height below the feet (measured on the sheet: feet at y 198 of 208, 188 when turning).
    static func footMargin(_ state: State) -> Double { state == .turn || state == .turnBack ? 20.0 / 208 : 10.0 / 208 }

    /// A turn-around at `progress` 0…1: row 9's eight frames, then row 10's.
    static func spin(_ progress: Double) -> (state: State, frame: Int) {
        let i = min(15, max(0, Int(progress * 16)))
        return i < 8 ? (.turn, i) : (.turnBack, i - 8)
    }

    /// A leap at `progress` 0…1 along row 4: crouch, rise, top, fall, land.
    static func leap(_ progress: Double) -> Int { [0.12, 0.35, 0.65, 0.88].firstIndex { progress < $0 } ?? 4 }

    /// Flying, from row 4: its arms-up frame with the wings up, its arms-out frame with them down.
    static func flap(up: Bool) -> Int { up ? 2 : 1 }

    /// Asleep: the idle frame with its eyes shut. The break screen sits it down, its legs hidden below the floor.
    static let asleep = 1

    /// Its back, from the turn-around row: on a ladder.
    static let back = 4

    static func frame(_ state: State, at elapsed: TimeInterval) -> Int {
        let durations = track(state).durations
        var remaining = max(0, elapsed).truncatingRemainder(dividingBy: durations.reduce(0, +))
        for (index, duration) in durations.enumerated() {
            if remaining < duration { return index }
            remaining -= duration
        }
        return 0
    }

    /// Frames for every state, cropped once from the sheet. Empty when the sheet is not the expected grid.
    static func frames(from url: URL) -> [State: [CGImage]] {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              image.width % columns == 0, image.height % rows == 0 else { return [:] }
        let w = image.width / columns, h = image.height / rows
        var out: [State: [CGImage]] = [:]
        for state in State.allCases {
            let (row, durations) = track(state)
            out[state] = durations.indices.compactMap { column in
                image.cropping(to: CGRect(x: column * w, y: row * h, width: w, height: h))
            }
        }
        return out
    }
}
