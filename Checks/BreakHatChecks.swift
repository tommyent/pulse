// Run from the project: swiftc Sources/Pulse/BreakHats.swift Sources/Pulse/BreakTricks.swift Sources/Pulse/CodexPetSprite.swift Checks/BreakHatChecks.swift -o /tmp/pulse-hat-check && /tmp/pulse-hat-check
import SwiftUI

@main
enum BreakHatChecks {
    @MainActor static func main() {
        let cal = Calendar(identifier: .gregorian)
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }

        // the weeks the floor dresses up
        assert(BreakHatWeek.on(day(2026, 10, 24)) == nil)
        assert(BreakHatWeek.on(day(2026, 10, 25)) == .halloween && BreakHatWeek.on(day(2026, 10, 31)) == .halloween)
        assert(BreakHatWeek.on(day(2026, 11, 1)) == nil)
        // Thanksgiving 2026 is November 26, 2027 is November 25: Monday to Sunday around it
        assert(BreakHatWeek.on(day(2026, 11, 22)) == nil && BreakHatWeek.on(day(2026, 11, 23)) == .thanksgiving)
        assert(BreakHatWeek.on(day(2026, 11, 29)) == .thanksgiving && BreakHatWeek.on(day(2026, 11, 30)) == nil)
        assert(BreakHatWeek.on(day(2027, 11, 21)) == nil && BreakHatWeek.on(day(2027, 11, 22)) == .thanksgiving)
        assert(BreakHatWeek.on(day(2027, 11, 28)) == .thanksgiving)
        assert(BreakHatWeek.on(day(2026, 12, 1)) == .december && BreakHatWeek.on(day(2026, 12, 31)) == .december)
        assert(BreakHatWeek.on(day(2027, 1, 1)) == nil)
        assert(BreakHatWeek.on(day(2026, 5, 5), simulated: "halloween") == .halloween)
        assert(BreakHatWeek.on(day(2026, 5, 5), simulated: "nope") == nil)

        // sleepers and finished agents always look the part; everyone keeps their look for the break
        assert(BreakOutfit.pick(asleep: true, finished: false, crowd: 5, week: nil, roll: 1) == .asleep)
        assert(BreakOutfit.pick(asleep: true, finished: true, crowd: 5, week: nil, roll: 1) == .finished)
        assert(BreakOutfit.pick(asleep: false, finished: false, crowd: 9, week: nil, roll: 42)
               == BreakOutfit.pick(asleep: false, finished: false, crowd: 9, week: nil, roll: 42))
        assert(BreakOutfit.roll(id: "block:a", seed: 7) == BreakOutfit.roll(id: "block:a", seed: 7))
        assert(BreakOutfit.roll(id: "block:a", seed: 7) != BreakOutfit.roll(id: "block:b", seed: 7))
        assert(BreakOutfit.roll(id: "block:a", seed: 7) != BreakOutfit.roll(id: "block:a", seed: 8))

        // about a third dress up alone, 70% in a crowd; a holiday week draws from its own pool
        func dressed(crowd: Int, week: BreakHatWeek?) -> [BreakOutfit] {
            (0..<2000).map { BreakOutfit.pick(asleep: false, finished: false, crowd: crowd, week: week, roll: BreakOutfit.roll(id: "a\($0)", seed: 3)) }
                .filter { $0 != .working }
        }
        let alone = dressed(crowd: 1, week: nil).count, crowd = dressed(crowd: 21, week: nil).count
        assert(abs(alone - 600) < 90 && abs(crowd - 1400) < 90, "\(alone) \(crowd)")
        assert(Set(dressed(crowd: 21, week: nil)) == Set(BreakOutfit.dressUp(nil)))   // every look turns up
        assert(Set(dressed(crowd: 10, week: .halloween)).isSubset(of: BreakOutfit.dressUp(.halloween)))
        assert(BreakOutfit.pet(nil).hat == .crown && BreakOutfit.pet(.halloween) == BreakOutfit(hat: .witch, prop: .wand))

        // every piece has art at both sizes, and the pet's hat follows its head from frame to frame
        let everything = BreakOutfit.Hat.allCases.map { BreakOutfit(hat: $0) } + BreakOutfit.Wear.allCases.map { BreakOutfit(wear: $0) }
            + BreakOutfit.Prop.allCases.map { BreakOutfit(prop: $0) }
        for outfit in everything {
            let crab = ImageRenderer(content: CrabOutfit(outfit: outfit, width: 80)).cgImage
            let pet = ImageRenderer(content: PetOutfit(outfit: outfit, width: 72, frame: blank)).cgImage
            assert(crab != nil && pet != nil, "\(outfit)")
        }
        let sheet = URL(fileURLWithPath: "Sources/Pulse/Resources/codex-pet.webp")
        let frames = CodexPetSprite.frames(from: sheet)
        let rest = BreakPetHead.measure(frames[.idle]![0])
        assert(abs(rest.x) <= 1 && abs(rest.y) <= 1, "\(rest)")
        let jump = (frames[.jump] ?? []).map { BreakPetHead.measure($0).y }.min() ?? 0
        assert(jump < -10, "the jump row lifts the head: \(jump)")
        print("Break hat checks passed")
    }

    static let blank: CGImage = CGContext(data: nil, width: 192, height: 208, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
