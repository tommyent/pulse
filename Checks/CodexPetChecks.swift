// Run from the project: swiftc Sources/Pulse/CodexPetSprite.swift Checks/CodexPetChecks.swift -o /tmp/pulse-pet-check && /tmp/pulse-pet-check
import AppKit
import SwiftUI

@main
enum CodexPetChecks {
    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        assert(kr == KERN_SUCCESS)
        return info.phys_footprint
    }

    static func main() {
        let before = footprintBytes()
        let url = URL(fileURLWithPath: "Sources/Pulse/Resources/codex-pet.webp")
        let tracks = CodexPetSprite.frames(from: url)
        let again = CodexPetSprite.frames(from: url)
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
            for frame in tracks[state]! {
                assert(frame.width == 192 && frame.height == 208, "\(state) size")
                assert(NSBitmapImageRep(cgImage: frame).colorAt(x: 96, y: 120)!.alphaComponent > 0.5, "\(state)")
            }
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
        // the break screen's picks: a leap through row 4 in order, two wing beats, and frames for sleeping and climbing
        let leap = stride(from: 0.0, to: 1, by: 0.01).map(CodexPetSprite.leap)
        assert(leap.first == 0 && leap.last == 4 && zip(leap, leap.dropFirst()).allSatisfy { $0 <= $1 } && Set(leap) == Set(0..<5))
        assert(CodexPetSprite.flap(up: true) != CodexPetSprite.flap(up: false))
        for (state, frame) in [(CodexPetSprite.State.jump, CodexPetSprite.flap(up: true)), (.jump, CodexPetSprite.flap(up: false)),
                               (.idle, CodexPetSprite.asleep), (.turn, CodexPetSprite.back)] {
            assert(NSBitmapImageRep(cgImage: tracks[state]![frame]).colorAt(x: 96, y: 120)!.alphaComponent > 0.5, "\(state) \(frame)")
        }
        assert(CodexPetSprite.footMargin(.idle) < CodexPetSprite.footMargin(.turn))
        assert(CodexPetSprite.frames(from: URL(fileURLWithPath: "/nonexistent-codex-pet.webp")).isEmpty)
        // A non-RGB sheet (grayscale) must fall back to sRGB instead of silently returning empty frames.
        let grayURL = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-gray-\(ProcessInfo.processInfo.processIdentifier).png")
        defer { try? FileManager.default.removeItem(at: grayURL) }
        let grayCtx = CGContext(data: nil, width: 8 * 8, height: 11 * 8, bitsPerComponent: 8, bytesPerRow: 8 * 8,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let grayRep = NSBitmapImageRep(cgImage: grayCtx.makeImage()!)
        try! grayRep.representation(using: .png, properties: [:])!.write(to: grayURL)
        let grayTracks = CodexPetSprite.frames(from: grayURL)
        assert(grayTracks.count == CodexPetSprite.State.allCases.count)
        for state in CodexPetSprite.State.allCases {
            assert(grayTracks[state]?.count == CodexPetSprite.track(state).durations.count, "grayscale \(state)")
        }
        // Rendering every cropped frame through SwiftUI (as the rail and break screen do) must not fault a 13.4 MiB sheet copy per frame.
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 48, height: 48), styleMask: .borderless, backing: .buffered, defer: false)
        for dict in [tracks, again] {
            for state in CodexPetSprite.State.allCases {
                for frame in dict[state] ?? [] {
                    let host = NSHostingView(rootView: Image(decorative: frame, scale: 1).resizable().interpolation(.none))
                    host.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
                    win.contentView = host
                    win.displayIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
                }
            }
        }
        let growthMiB = Double(footprintBytes().saturatingSubtract(before)) / 1_048_576
        assert(growthMiB < 60, String(format: "sprite frames grew footprint by %.1f MiB (expected < 60 MiB)", growthMiB))
        assert(ObjectIdentifier(frames[0]) == ObjectIdentifier(again[.idle]![0]), "repeated loads must share one decoded sheet")
        print("Pet checks passed: decoding, idle frames, transparency, timing, the break screen's frames and missing-asset fallback")
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
