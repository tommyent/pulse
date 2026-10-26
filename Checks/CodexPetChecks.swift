// Run from the project: swiftc Sources/Pulse/CodexPetSprite.swift Checks/CodexPetChecks.swift -o /tmp/pulse-pet-check && /tmp/pulse-pet-check
import AppKit

@main
enum CodexPetChecks {
    static func main() {
        let url = URL(fileURLWithPath: "Sources/Pulse/Resources/codex-pet.webp")
        let tracks = CodexPetSprite.frames(from: url)
        assert(tracks.count == CodexPetSprite.State.allCases.count)
        let frames = tracks[.idle]!
        assert(frames.count == 6)
        assert(frames.allSatisfy { $0.width == 192 && $0.height == 208 })
        for frame in frames {
            let bitmap = NSBitmapImageRep(cgImage: frame)
            // Idle artwork occupies the center; its corners must stay transparent.
            assert(bitmap.colorAt(x: 96, y: 100)!.alphaComponent > 0.9)
            assert(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0)
        }
        for state in CodexPetSprite.State.allCases {
            let durations = CodexPetSprite.track(state).durations
            assert(tracks[state]?.count == durations.count)
            let cycle = durations.reduce(0, +)
            var start = 0.0
            for (index, duration) in durations.enumerated() {
                assert(CodexPetSprite.frame(state, at: start + duration / 2) == index)
                assert(CodexPetSprite.frame(state, at: cycle + start + duration / 2) == index)
                start += duration
            }
            assert(CodexPetSprite.frame(state, at: -1) == 0)
        }
        // the turn-around plays row 9 then row 10, every frame once, in order
        let spin = stride(from: 0.0, to: 1.0, by: 1.0 / 64).map { CodexPetSprite.spin($0) }
        assert(spin.first! == (.turn, 0) && spin.last! == (.turnBack, 7))
        var steps: [String] = []
        for s in spin where steps.last != "\(s.state)\(s.frame)" { steps.append("\(s.state)\(s.frame)") }
        assert(steps == (0..<8).map { "turn\($0)" } + (0..<8).map { "turnBack\($0)" })
        assert(CodexPetSprite.spin(-1) == (.turn, 0) && CodexPetSprite.spin(2) == (.turnBack, 7))
        // every new row has art in each of its frames
        for state in [CodexPetSprite.State.happy, .oops, .turn, .turnBack] {
            for frame in tracks[state]! { assert(NSBitmapImageRep(cgImage: frame).colorAt(x: 96, y: 120)!.alphaComponent > 0.5, "\(state)") }
        }
        assert(CodexPetSprite.footMargin(.idle) < CodexPetSprite.footMargin(.turn))
        assert(CodexPetSprite.frames(from: URL(fileURLWithPath: "/nonexistent-codex-pet.webp")).isEmpty)
        print("Pet checks passed: decoding, idle frames, transparency, timing and missing-asset fallback")
    }
}
