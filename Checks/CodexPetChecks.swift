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
        assert(CodexPetSprite.frames(from: URL(fileURLWithPath: "/nonexistent-codex-pet.webp")).isEmpty)
        print("Pet checks passed: decoding, idle frames, transparency, timing and missing-asset fallback")
    }
}
