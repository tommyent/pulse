import SwiftUI

/// What an agent on the break screen wears: a hat, something over its body, something in its hand. Picked once per
/// break (`pick`), so nobody changes clothes mid-break, except the propeller cap while flying.
struct BreakOutfit: Hashable {
    enum Hat: String, CaseIterable { case nightcap, hardHat, party, propeller, beret, topHat, cowboy, chef, headphones, crown, witch, pilgrim, santa }
    enum Wear: String, CaseIterable { case shades, laptop, ghost }
    enum Prop: String, CaseIterable { case wrench, wand, phone }
    var hat: Hat? = nil
    var wear: Wear? = nil
    var prop: Prop? = nil

    static let asleep = BreakOutfit(hat: .nightcap)
    static let working = BreakOutfit(hat: .hardHat, prop: .wrench)
    static let finished = BreakOutfit(hat: .party)
    static let flying = BreakOutfit(hat: .propeller)

    /// The mischief a working agent may wear instead of its hard hat; a holiday week has its own.
    static func dressUp(_ week: BreakHatWeek?) -> [BreakOutfit] {
        switch week {
        case .halloween: [BreakOutfit(hat: .witch, prop: .wand), BreakOutfit(wear: .ghost), BreakOutfit(wear: .shades)]
        case .thanksgiving: [BreakOutfit(hat: .pilgrim), BreakOutfit(hat: .chef)]
        case .december: [BreakOutfit(hat: .santa)]
        case nil: [BreakOutfit(hat: .beret), BreakOutfit(hat: .topHat), BreakOutfit(hat: .cowboy), BreakOutfit(hat: .chef),
                   BreakOutfit(hat: .headphones), BreakOutfit(wear: .shades), BreakOutfit(hat: .headphones, wear: .laptop),
                   BreakOutfit(hat: .beret, prop: .phone)]
        }
    }

    /// How many working agents dress up: about a third on a quiet floor, up to 70% in a crowd of 21 or more.
    static func dressShare(crowd: Int) -> Double { min(0.7, 0.3 + 0.02 * Double(max(0, crowd - 1))) }

    /// The look an agent keeps for a whole break. `roll`: its own number for this break (`roll(id:seed:)`).
    static func pick(asleep: Bool, finished: Bool, crowd: Int, week: BreakHatWeek?, roll: UInt64) -> BreakOutfit {
        if finished { return .finished }
        if asleep { return .asleep }
        var rng = BreakTricks.SplitMix(state: roll)
        guard Double(rng.next() >> 11) / Double(1 << 53) < dressShare(crowd: crowd) else { return .working }
        let pool = dressUp(week)
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    /// The big pet: a crown, or the holiday week's hat.
    static func pet(_ week: BreakHatWeek?) -> BreakOutfit {
        switch week {
        case .halloween: BreakOutfit(hat: .witch, prop: .wand)
        case .thanksgiving: BreakOutfit(hat: .pilgrim)
        case .december: BreakOutfit(hat: .santa)
        case nil: BreakOutfit(hat: .crown)
        }
    }

    /// A number per agent per break: FNV-1a over its id, mixed with the break's seed. Stable across redraws and runs.
    static func roll(id: String, seed: UInt64) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h ^ seed
    }
}

/// The weeks the floor dresses up: Halloween's (October 25 to 31), Thanksgiving's (Monday to Sunday around the fourth
/// Thursday of November) and all of December. Longer than the holiday films, which play on the day itself.
enum BreakHatWeek: String, CaseIterable {
    case halloween, thanksgiving, december

    /// `simulated`: a holiday name for testing on any day, as `simulatedHoliday` gives it.
    static func on(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian), simulated: String? = nil) -> BreakHatWeek? {
        if let simulated { return BreakHatWeek(rawValue: simulated) }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let month = c.month, let day = c.day else { return nil }
        switch month {
        case 10 where day >= 25: return .halloween
        case 11:
            guard let first = calendar.date(from: DateComponents(year: c.year, month: 11, day: 1)) else { return nil }
            let thursday = 1 + (5 - calendar.component(.weekday, from: first) + 7) % 7 + 21   // weekday 5 is Thursday
            return abs(day - thursday) <= 3 ? .thanksgiving : nil
        case 12: return .december
        default: return nil
        }
    }
}

// MARK: - the crab's chunky pixels

/// Pixel art on the crab's 24-unit grid. A hat's `sink` is how many of its rows go below the head line; wear goes with
/// its top-left at `at`; a prop's `grip` pixel goes in the right hand.
private struct CrabArt {
    let rows: [String]
    let colors: [Character: UInt32]
    var sink = 1.0
    var scale = 1.0
    var at = CGPoint.zero
    var grip: (Int, Int)? = nil
    var outline = false   // a faint light edge, so dark pieces show on the dark break screen
}

private let crabHats: [BreakOutfit.Hat: CrabArt] = [
    .nightcap: CrabArt(rows: ["...........WW.", "..........WWWW", ".........B.WW.", "........BB....", ".......BLB....", "......LBBL....",
                              ".....BBLLBB...", "....LLBBLLBB..", "...BBLLBBLLBB.", "..WWWWWWWWWWW.", ".WWWWWWWWWWWWW"],
                       colors: ["W": 0xF2F4FF, "B": 0x4F6BFF, "L": 0x9DB2FF], sink: 1.5),
    .hardHat: CrabArt(rows: [".....YYYY.....", "...YYYYYYYY...", "..YYYYYyYYYYY.", ".YYYYYYyYYYYYY", ".YYYYYYyYYYYYY", "YYYYYYYYYYYYYY",
                             "yyyyyyyyyyyyyy"], colors: ["Y": 0xFFC83D, "y": 0xD99A12]),
    .party: CrabArt(rows: ["......WW......", ".....WWWW.....", "......WW......", "......MM......", ".....MMMM.....", ".....MYMM.....",
                           "....MMMMCM....", "....MMMMMM....", "...MCMMMYMM...", "...MMMMMMMM...", "..MMYMMMMCMM..", "..MMMMMMMMMM..",
                           ".YYYYYYYYYYYY."], colors: ["W": 0xFFFFFF, "M": 0xE8459A, "Y": 0xFFD84A, "C": 0x4FE0E8]),
    .propeller: CrabArt(rows: ["RRRRRRKKBBBBBB", "......KK......", "....RRYYBB....", "...RRRYYBBB...", "..GRRRYYBBBG..", ".GGRRRYYBBBGG.",
                               ".GGRRRYYBBBGG.", "KKKKKKKKKKKKKK"],
                        colors: ["R": 0xF0483E, "B": 0x3D7BFF, "Y": 0xFFD23F, "G": 0x3DCB6C, "K": 0x2B3A8C], outline: true),
    .beret: CrabArt(rows: ["........K.....", "....RRRRRRRR..", "..RRRRRRRRRRRR", ".RRRRRRRRRRRRR", ".rrrrrrrrrrrr."],
                    colors: ["K": 0x5A1424, "R": 0xC22D45, "r": 0x861C2F], sink: 1.5),
    .topHat: CrabArt(rows: ["...KKKKKKKK...", "...KhKKKKKK...", "...KhKKKKKK...", "...KhKKKKKK...", "...RRRRRRRR...", "...KKKKKKKK...",
                            "KKKKKKKKKKKKKK"], colors: ["K": 0x24222E, "h": 0x4A4760, "R": 0xD9384A], outline: true),
    .cowboy: CrabArt(rows: ["....NN..NN....", "....NNNNNN....", "....NNNNNN....", "...NNNNNNNN...", "...dddddddd...", "N.NNNNNNNNNN.N",
                            "NNNNNNNNNNNNNN", ".NNNNNNNNNNNN."], colors: ["N": 0xB9783E, "d": 0x6B3F1E], sink: 1.5),
    .chef: CrabArt(rows: ["..WW..WW..WW..", ".WWWWWWWWWWWW.", ".WWWWWWWWWWWW.", "..WWWWWWWWWW..", "...WWWWWWWW...", "...gggggggg...",
                          "...WWWWWWWW..."], colors: ["W": 0xFAFAF7, "g": 0xC9CCD6]),
    .headphones: CrabArt(rows: ["...KKKKKKKK...", "..K........K..", ".K..........K.", ".K..........K.", "RR..........RR", "RR..........RR",
                                "RR..........RR"], colors: ["K": 0xDADDE8, "R": 0xFF5A5F], sink: 4.5, scale: 1.25),
    .crown: CrabArt(rows: [".Y....YY....Y.", ".YY..YYYY..YY.", ".YYYYYYYYYYYY.", ".YYRYYBBYYRYY.", ".YYYYYYYYYYYY.", ".oooooooooooo."],
                    colors: ["Y": 0xFFCF3A, "o": 0xC98A10, "R": 0xE8344E, "B": 0x3FA9F5]),
    .witch: CrabArt(rows: ["..........KK..", ".........KK...", "........KKK...", ".......KKKK...", "......KKKKK...", ".....KKKKKKK..",
                           ".....OOOOOOO..", "....KKKKKKKKK.", "KKKKKKKKKKKKKK"], colors: ["K": 0x47286E, "O": 0xFF8C1A], outline: true),
    .pilgrim: CrabArt(rows: ["...KKKKKKKK...", "...KhKKKKKK...", "...KhKKKKKK...", "...NNYYYYNN...", "...NNYKKYNN...", "...NNYYYYNN...",
                             "KKKKKKKKKKKKKK", ".KKKKKKKKKKKK."], colors: ["K": 0x2A2630, "h": 0x4D4757, "N": 0x7A4A24, "Y": 0xE8B84A],
                      sink: 1.5, outline: true),
    .santa: CrabArt(rows: ["..........WW..", ".........WWWW.", "........RR.WW.", ".......RRR....", "......RRRR....", ".....RRRRRR...",
                           "....RRRRRRRR..", "..WWWWWWWWWWW.", ".WWWWWWWWWWWWW"], colors: ["W": 0xF7F7F7, "R": 0xE0303A], sink: 1.5),
]

private let crabWear: [BreakOutfit.Wear: CrabArt] = [
    .ghost: CrabArt(rows: ["......WWWWWWWW......", "....WWWWWWWWWWWW....", "...WWWWWWWWWWWWWW...", "..WWWWWWWWWWWWWWWW..",
                           "..WWWWWWWWWWWWWWWW..", ".WWWWWWWWWWWWWWWWWg.", ".WWWWWWWWWWWWWWWWWg.", ".WWWKKWWWWWWWWKKWWg.",
                           ".WWWKKWWWWWWWWKKWWg.", ".WWWWWWWWWWWWWWWWWg.", "WWWWWWWWWKKWWWWWWWgg", "WWWWWWWWWWWWWWWWWWgg",
                           "WWWWWWWWWWWWWWWWWWgg", "WWWWWWWWWWWWWWWWWWgg", "WWWWWWWWWWWWWWWWWWgg", "WW.WWWW..WWWWW.WWW.g",
                           "W...WW....WW....W..."], colors: ["W": 0xF4F6FF, "g": 0xC9D0E8, "K": 0x14121C], at: CGPoint(x: 2, y: -3)),
    .shades: CrabArt(rows: [".KKKKKKKKKKKKKKKKKK...", "KKKK..KKKKKKKK..KKKKKK", "KKKK..KKKKKKKK..KKKK.K", "KKKK..KKKKKKKK..KKKK..",
                            ".KKKKKKK...KKKKKKKK..."], colors: ["K": 0x24222E], at: CGPoint(x: 2, y: 3), outline: true),
    .laptop: CrabArt(rows: ["SSSSSSSSSSSS", "SSSSSSSSSSSS", "SSSSSOOSSSSS", "SSSSSSSSSSSS", "SSSSSSSSSSSS", "ssssssssssss", "kkkkkkkkkkkk"],
                     colors: ["S": 0xC9CED8, "s": 0x9DA3B0, "k": 0x6B7180, "O": 0xFF8C1A], at: CGPoint(x: 6, y: 7)),
]

private let crabProps: [BreakOutfit.Prop: CrabArt] = [
    .wand: CrabArt(rows: ["..Y..", ".YYY.", "YYYYY", ".Y.Y.", "..N..", "..N..", "..N..", "..N.."],
                   colors: ["Y": 0xFFD84A, "N": 0x3A2A1A], grip: (2, 7), outline: true),
    .wrench: CrabArt(rows: ["G.G", "GGG", ".G.", ".G.", ".G.", ".G."], colors: ["G": 0xB8C0CC], grip: (1, 5)),
    .phone: CrabArt(rows: ["KKK", "KBK", "KBK", "KKK"], colors: ["K": 0x24222E, "B": 0x6FA8FF], grip: (1, 3), outline: true),
]

private func cgColor(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
}

/// One image pixel per art pixel, with a pixel of room on each side for the outline.
private func rasterize(_ art: CrabArt) -> CGImage? {
    let w = (art.rows.map(\.count).max() ?? 0) + 2, h = art.rows.count + 2
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
    let cells = art.rows.enumerated().flatMap { y, row in row.enumerated().compactMap { x, ch in ch == "." ? nil : (x + 1, y + 1, ch) } }
    if art.outline {
        let filled = Set(cells.map { $0.0 * 1000 + $0.1 })
        c.setFillColor(cgColor(0xFFFFFF, 0.28))
        for (x, y, _) in cells {
            // none below the last row: under a brim it would draw a light line across the crab
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] where y + dy <= art.rows.count && !filled.contains((x + dx) * 1000 + y + dy) {
                c.fill(CGRect(x: x + dx, y: y + dy, width: 1, height: 1))
            }
        }
    }
    for (x, y, ch) in cells {
        c.setFillColor(cgColor(art.colors[ch] ?? 0xFF00FF))
        c.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }
    return c.makeImage()
}

@MainActor private var crabCache: [String: CGImage] = [:]

@MainActor private func crabImage(_ key: String, _ art: CrabArt) -> CGImage? {
    if let image = crabCache[key] { return image }
    let image = rasterize(art)
    crabCache[key] = image
    return image
}

/// An outfit over a `ClaudeCrab` of the same width, in its frame. `bodyTop`: the body's top on the 24-unit grid (1 when
/// standing; lower when it crouches, a little higher on a bob); `hand`: the right arm's tip.
struct CrabOutfit: View {
    let outfit: BreakOutfit
    let width: CGFloat
    var bodyTop: CGFloat = 1
    var hand = CGPoint(x: 22.5, y: 7.5)

    var body: some View {
        let u = width / 24, lift = bodyTop - 1
        ZStack(alignment: .topLeading) {
            if let wear = outfit.wear, let art = crabWear[wear], let image = crabImage("wear." + wear.rawValue, art) {
                piece(image, px: u, x: (art.at.x - 1) * u, y: (art.at.y - 1 + lift) * u)
            }
            if let hat = outfit.hat, let art = crabHats[hat], let image = crabImage("hat." + hat.rawValue, art) {
                let px = u * 1.05 * art.scale
                piece(image, px: px, x: 12 * u - CGFloat(image.width) * px / 2, y: bodyTop * u - (CGFloat(art.rows.count) - art.sink + 1) * px)
            }
            if let prop = outfit.prop, let art = crabProps[prop], let (gx, gy) = art.grip, let image = crabImage("prop." + prop.rawValue, art) {
                piece(image, px: u, x: hand.x * u - (CGFloat(gx) + 1.5) * u, y: (hand.y + lift) * u - (CGFloat(gy) + 1.5) * u)
            }
        }
        .frame(width: width, height: width * 17 / 24, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func piece(_ image: CGImage, px: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.none)
            .frame(width: CGFloat(image.width) * px, height: CGFloat(image.height) * px)
            .offset(x: x, y: y)
    }
}

// MARK: - the Codex pet's fine pixels

private let ink: UInt32 = 0x060B12

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, r: CGFloat = 0) -> CGPath {
    CGPath(roundedRect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cornerWidth: r, cornerHeight: r, transform: nil)
}
private func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
}
private func poly(_ points: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath(); return p }
private func fill(_ c: CGContext, _ p: CGPath, _ rgb: UInt32) { c.addPath(p); c.setFillColor(cgColor(rgb)); c.fillPath() }
private func stroke(_ c: CGContext, _ p: CGPath, _ rgb: UInt32, _ width: CGFloat) {
    c.addPath(p); c.setStrokeColor(cgColor(rgb)); c.setLineWidth(width); c.setLineJoin(.round); c.strokePath()
}

/// One shape the sprite's way: a base colour, a darker crescent on the lower right, a near-black outline.
private func part(_ c: CGContext, _ p: CGPath, _ base: UInt32, shade: UInt32? = nil, line: UInt32 = ink, evenOdd: Bool = false) {
    let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
    c.saveGState()
    c.addPath(p); c.clip(using: rule)
    if let shade {
        c.setFillColor(cgColor(shade)); c.addPath(p); c.fillPath(using: rule)
        var t = CGAffineTransform(translationX: -7, y: -5)
        if let moved = p.copy(using: &t) { c.setFillColor(cgColor(base)); c.addPath(moved); c.fillPath(using: rule) }
    } else {
        c.setFillColor(cgColor(base)); c.addPath(p); c.fillPath(using: rule)
    }
    c.restoreGState()
    stroke(c, p, line, 3)
}

// In the cell's coordinates, measured on idle frame 0: the cloud's middle is x 97, a brim belongs at y 45, the right hand
// is near (150, 170).
private func drawHat(_ hat: BreakOutfit.Hat, _ c: CGContext) {
    switch hat {
    case .nightcap:
        let cap = CGMutablePath()
        cap.move(to: pt(54, 48)); cap.addCurve(to: pt(150, -12), control1: pt(56, 0), control2: pt(112, -26))
        cap.addCurve(to: pt(140, 48), control1: pt(138, 8), control2: pt(130, 30)); cap.closeSubpath()
        part(c, cap, 0x4F6BFF)
        c.saveGState(); c.addPath(cap); c.clip()
        for y in stride(from: CGFloat(-30), to: 48, by: 18) { fill(c, box(0, y, 260, y + 8), 0x9DB2FF) }
        c.restoreGState()
        stroke(c, cap, ink, 3)
        part(c, box(46, 38, 148, 56, r: 9), 0xF2F4FF, shade: 0xC5CCE6)
        part(c, oval(152, -14, 11, 11), 0xF2F4FF, shade: 0xC5CCE6)
    case .hardHat:
        let dome = CGMutablePath()
        dome.move(to: pt(52, 46)); dome.addCurve(to: pt(97, 2), control1: pt(52, 18), control2: pt(70, 2))
        dome.addCurve(to: pt(142, 46), control1: pt(124, 2), control2: pt(142, 18)); dome.closeSubpath()
        part(c, dome, 0xFFC83D, shade: 0xD99A12)
        fill(c, box(91, 5, 103, 44), 0xE8AE22)
        fill(c, box(64, 16, 72, 32, r: 3), 0xFFE9A0)
        part(c, box(36, 40, 158, 54, r: 7), 0xFFC83D, shade: 0xD99A12)
    case .party:
        part(c, poly([pt(60, 50), pt(134, 50), pt(97, -40)]), 0xE8459A, shade: 0xB82F75)
        for (x, y, rgb) in [(90, -6, 0xFFD84A), (106, 14, 0x4FE0E8), (80, 30, 0x4FE0E8), (112, 36, 0xFFD84A), (97, -24, 0xFFFFFF)] as [(CGFloat, CGFloat, UInt32)] {
            fill(c, oval(x, y, 4, 4), rgb)
        }
        part(c, box(54, 42, 140, 56, r: 6), 0xFFD84A, shade: 0xD9A92A)
        part(c, oval(97, -44, 10, 10), 0xFFFFFF, shade: 0xD6D9E4)
    case .propeller:
        let dome = CGMutablePath()
        dome.move(to: pt(58, 46)); dome.addCurve(to: pt(97, 8), control1: pt(58, 22), control2: pt(76, 8))
        dome.addCurve(to: pt(136, 46), control1: pt(118, 8), control2: pt(136, 22)); dome.closeSubpath()
        c.saveGState(); c.addPath(dome); c.clip()
        for (x0, rgb) in [(0, 0x3DCB6C), (77, 0xF0483E), (97, 0xFFD23F), (117, 0x3D7BFF)] as [(CGFloat, UInt32)] { fill(c, box(x0, 0, 260, 60), rgb) }
        c.restoreGState()
        stroke(c, dome, ink, 3)
        part(c, box(52, 40, 142, 52, r: 5), 0x2B3A8C)
        part(c, box(94, -8, 100, 10), 0x5A6078)
        part(c, oval(68, -10, 28, 6), 0xF0483E, shade: 0xB8302A)
        part(c, oval(126, -10, 28, 6), 0x3D7BFF, shade: 0x2A58C8)
        part(c, oval(97, -10, 6, 6), 0xFFD23F)
    case .beret:
        part(c, oval(100, 38, 54, 16), 0xC22D45, shade: 0x861C2F)
        part(c, oval(97, 50, 40, 6), 0x861C2F)
        part(c, box(98, 16, 106, 25, r: 2), 0x5A1424)
    case .topHat:
        let line: UInt32 = 0x6E6A86   // lighter than ink, so a dark hat shows on the dark screen
        part(c, poly([pt(64, 46), pt(130, 46), pt(126, -34), pt(68, -34)]), 0x2A2836, shade: 0x15141C, line: line)
        fill(c, box(73, -28, 78, 22), 0x4A4760)
        part(c, box(65, 26, 129, 42), 0xD9384A, line: line)
        part(c, oval(97, 47, 62, 9), 0x2A2836, shade: 0x15141C, line: line)
    case .cowboy:
        let crown = CGMutablePath()
        crown.move(to: pt(66, 44)); crown.addLine(to: pt(70, 2))
        crown.addCurve(to: pt(97, 4), control1: pt(80, -10), control2: pt(90, -8))
        crown.addCurve(to: pt(124, 2), control1: pt(104, -8), control2: pt(114, -10))
        crown.addLine(to: pt(128, 44)); crown.closeSubpath()
        part(c, crown, 0xB9783E, shade: 0x8A552A)
        fill(c, box(67, 28, 127, 40), 0x6B3F1E)
        let brim = CGMutablePath()
        brim.move(to: pt(20, 26)); brim.addCurve(to: pt(97, 46), control1: pt(34, 46), control2: pt(70, 46))
        brim.addCurve(to: pt(174, 26), control1: pt(124, 46), control2: pt(160, 46))
        brim.addCurve(to: pt(97, 60), control1: pt(166, 52), control2: pt(130, 62))
        brim.addCurve(to: pt(20, 26), control1: pt(64, 62), control2: pt(28, 52)); brim.closeSubpath()
        part(c, brim, 0xB9783E, shade: 0x8A552A)
    case .chef:
        var puff = box(66, -6, 128, 42)
        for o in [oval(72, -8, 22, 22), oval(97, -18, 26, 26), oval(122, -8, 22, 22)] { puff = puff.union(o) }
        part(c, puff, 0xFAFAF7, shade: 0xD7DAE2)
        for x: CGFloat in [84, 110] { fill(c, box(x, 2, x + 3, 30), 0xD7DAE2) }
        part(c, box(66, 34, 128, 48), 0xC9CCD6)
    case .headphones:
        let band = CGMutablePath()
        band.move(to: pt(40, 64)); band.addCurve(to: pt(154, 64), control1: pt(40, -6), control2: pt(154, -6))
        stroke(c, band, ink, 14); stroke(c, band, 0xDADDE8, 8)
        part(c, box(26, 54, 50, 96, r: 9), 0xFF5A5F, shade: 0xC23A40)
        part(c, box(144, 54, 168, 96, r: 9), 0xFF5A5F, shade: 0xC23A40)
    case .crown:
        part(c, poly([pt(58, 46), pt(58, -2), pt(77, 22), pt(97, -12), pt(117, 22), pt(136, -2), pt(136, 46)]), 0xFFCF3A, shade: 0xC98A10)
        fill(c, oval(77, 34, 5, 5), 0xE8344E); fill(c, oval(97, 33, 6, 6), 0x3FA9F5); fill(c, oval(117, 34, 5, 5), 0xE8344E)
        for (x, y) in [(58, -4), (97, -14), (136, -4)] as [(CGFloat, CGFloat)] { part(c, oval(x, y, 5, 5), 0xFFE58A) }
    case .witch:
        part(c, oval(97, 48, 74, 10), 0x5B3591, shade: 0x3B2066)
        let cone = CGMutablePath()
        cone.move(to: pt(64, 46)); cone.addCurve(to: pt(110, -50), control1: pt(70, 8), control2: pt(92, -22))
        cone.addCurve(to: pt(156, -64), control1: pt(124, -66), control2: pt(144, -74))
        cone.addCurve(to: pt(130, 46), control1: pt(130, -30), control2: pt(130, 10)); cone.closeSubpath()
        part(c, cone, 0x5B3591, shade: 0x3B2066)
        part(c, box(65, 28, 130, 42), 0xFF8C1A)
        stroke(c, box(90, 25, 106, 45), 0xFFD84A, 4)
    case .pilgrim:
        let line: UInt32 = 0x6A6478
        part(c, poly([pt(64, 46), pt(130, 46), pt(124, -28), pt(70, -28)]), 0x2E2A36, shade: 0x1A171F, line: line)
        fill(c, box(75, -22, 80, 18), 0x4D4757)
        part(c, box(65, 20, 129, 42), 0x7A4A24, line: line)
        stroke(c, box(86, 19, 108, 43), 0xE8B84A, 5)
        part(c, oval(97, 47, 62, 9), 0x2E2A36, shade: 0x1A171F, line: line)
    case .santa:
        let cone = CGMutablePath()
        cone.move(to: pt(52, 46)); cone.addCurve(to: pt(152, -14), control1: pt(56, -6), control2: pt(110, -32))
        cone.addCurve(to: pt(142, 46), control1: pt(140, 6), control2: pt(138, 30)); cone.closeSubpath()
        part(c, cone, 0xE0303A, shade: 0xA81E26)
        part(c, box(44, 36, 150, 56, r: 10), 0xF7F7F7, shade: 0xD6D9E4)
        part(c, oval(156, -16, 11, 11), 0xF7F7F7, shade: 0xD6D9E4)
    }
}

private func drawWear(_ wear: BreakOutfit.Wear, _ c: CGContext) {
    switch wear {
    case .ghost:
        let p = CGMutablePath()
        p.move(to: pt(20, 182)); p.addLine(to: pt(22, 96))
        p.addCurve(to: pt(97, 18), control1: pt(22, 36), control2: pt(56, 16))
        p.addCurve(to: pt(172, 96), control1: pt(138, 16), control2: pt(172, 36))
        p.addLine(to: pt(174, 182))
        var x: CGFloat = 174
        for _ in 0..<5 { let next = x - 30.8; p.addQuadCurve(to: pt(next, 182), control: pt((x + next) / 2, 204)); x = next }
        p.closeSubpath()
        part(c, p, 0xF4F6FF, shade: 0xC9D0E8)
        fill(c, oval(76, 96, 9, 13), 0x14121C); fill(c, oval(116, 96, 9, 13), 0x14121C)
        fill(c, oval(96, 128, 6, 7), 0x14121C)
    case .shades:
        let p = CGMutablePath()
        p.addPath(box(52, 84, 146, 116, r: 14))
        p.addPath(oval(80, 100, 13, 9)); p.addPath(oval(113, 101, 13, 9))
        part(c, p, 0x2B2B3A, line: 0xC8C6E0, evenOdd: true)
        part(c, poly([pt(146, 92), pt(170, 80), pt(172, 94), pt(146, 104)]), 0x2B2B3A, line: 0xC8C6E0)
    case .laptop:
        part(c, box(58, 132, 136, 176, r: 4), 0xC9CED8, shade: 0x9DA3B0)
        fill(c, oval(97, 153, 5, 5), 0xFF8C1A)
        part(c, box(50, 174, 144, 182, r: 2), 0x8A90A0)
    }
}

private func drawProp(_ prop: BreakOutfit.Prop, _ c: CGContext) {
    switch prop {
    case .wand:
        let stick = CGMutablePath(); stick.move(to: pt(150, 172)); stick.addLine(to: pt(172, 120))
        stroke(c, stick, ink, 8); stroke(c, stick, 0x5A3A22, 4)
        let star = CGMutablePath()
        for i in 0..<10 {
            let r: CGFloat = i % 2 == 0 ? 15 : 6, a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let q = pt(175 + r * cos(a), 112 + r * sin(a))
            if i == 0 { star.move(to: q) } else { star.addLine(to: q) }
        }
        star.closeSubpath()
        part(c, star, 0xFFD84A, shade: 0xE0A82A)
        for (x, y) in [(196, 98), (160, 94), (194, 128)] as [(CGFloat, CGFloat)] {
            fill(c, box(x - 1, y - 4, x + 2, y + 5), 0xFFFFFF); fill(c, box(x - 4, y - 1, x + 5, y + 2), 0xFFFFFF)
        }
    case .wrench:
        let handle = CGMutablePath(); handle.move(to: pt(150, 174)); handle.addLine(to: pt(170, 130))
        stroke(c, handle, ink, 11); stroke(c, handle, 0xB8C0CC, 6)
        part(c, oval(174, 120, 13, 13), 0xB8C0CC, shade: 0x8C95A6)
        c.setBlendMode(.clear); c.fill(CGRect(x: 170, y: 102, width: 9, height: 16)); c.setBlendMode(.normal)
    case .phone:
        part(c, box(148, 128, 168, 164, r: 4), 0x24222E, line: 0xC8C6E0)
        fill(c, box(151, 132, 165, 158, r: 2), 0x6FA8FF)
    }
}

/// The outfit as one 272×328 bitmap over the 192×208 cell (40 px wider each side, 120 taller above), drawn in the
/// cell's top-down coordinates without antialiasing, so it scales with `.interpolation(.none)` just as the sprite does.
private func petExtras(_ outfit: BreakOutfit) -> CGImage? {
    guard let c = CGContext(data: nil, width: 272, height: 328, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.translateBy(x: 0, y: 328); c.scaleBy(x: 1, y: -1)
    c.translateBy(x: 40, y: 120)
    c.setShouldAntialias(false)
    if let wear = outfit.wear { drawWear(wear, c) }
    if let hat = outfit.hat { drawHat(hat, c) }
    if let prop = outfit.prop { drawProp(prop, c) }
    return c.makeImage()
}

@MainActor private var petCache: [BreakOutfit: CGImage] = [:]
@MainActor private var headCache: [ObjectIdentifier: CGPoint] = [:]

enum BreakPetHead {
    /// Where idle frame 0's head sits: the top of the cloud and its middle, in cell pixels.
    static let rest = CGPoint(x: 97.5, y: 30)

    /// How far a frame's head sits from `rest`: its topmost opaque row, and the middle of the cloud 16 rows below it.
    static func measure(_ frame: CGImage) -> CGPoint {
        let w = frame.width, h = frame.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .zero }
        c.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        func span(_ y: Int) -> (Int, Int)? {
            let xs = (0..<w).filter { px[(y * w + $0) * 4 + 3] > 128 }
            return xs.first.map { ($0, xs.last!) }
        }
        guard let top = (0..<h).first(where: { span($0) != nil }), let (a, b) = span(min(h - 1, top + 16)) else { return .zero }
        return CGPoint(x: Double(a + b) / 2 - rest.x, y: Double(top) - rest.y)
    }

    @MainActor static func offset(_ frame: CGImage) -> CGPoint {
        let key = ObjectIdentifier(frame)
        if let p = headCache[key] { return p }
        let p = measure(frame)
        headCache[key] = p
        return p
    }
}

/// An outfit over a Codex pet sprite `width` wide showing `frame`; it follows the head from frame to frame.
struct PetOutfit: View {
    let outfit: BreakOutfit
    let width: CGFloat
    let frame: CGImage

    var body: some View {
        let k = width / 192, head = BreakPetHead.offset(frame)
        Group {
            if let image = cached() {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .frame(width: 272 * k, height: 328 * k)
                    .offset(x: (head.x - 40) * k, y: (head.y - 120) * k)
            }
        }
        .frame(width: width, height: width * 208 / 192, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func cached() -> CGImage? {
        if let image = petCache[outfit] { return image }
        let image = petExtras(outfit)
        petCache[outfit] = image
        return image
    }
}
