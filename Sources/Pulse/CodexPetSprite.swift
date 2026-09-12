import AppKit

/// The Codex pet sheet (8 columns × 11 rows of 192×208 cells, as the Codex app and CLI draw it).
/// Rows are named animations; each state lists its frame durations along its row.
enum CodexPetSprite {
    enum State: CaseIterable { case idle, waving, waiting, running }

    static let columns = 8, rows = 11

    /// (row, per-frame durations) per state, mirroring the Codex app's animation table.
    static func track(_ state: State) -> (row: Int, durations: [TimeInterval]) {
        switch state {
        case .idle:    (0, [0.28, 0.11, 0.11, 0.14, 0.14, 0.32])
        case .waving:  (3, [0.14, 0.14, 0.14, 0.28])
        case .waiting: (6, [0.15, 0.15, 0.15, 0.15, 0.15, 0.26])
        case .running: (7, [0.12, 0.12, 0.12, 0.12, 0.12, 0.22])
        }
    }

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
