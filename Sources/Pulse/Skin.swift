import SwiftUI

/// A skin as a file would hold it: its name and a set of values for each appearance. Classic is the look Pulse has
/// always had; Groove is a sculpted one (Fable's "Groove C · Inlay"). Pulse draws dark only for now, so `light` is
/// empty until Groove's light half (Fable's "White") is built; an appearance without its own half uses `dark`.
///
/// Plain Codable values with fixed key names, so a skin can come from a JSON file: colours are hex strings
/// ("#RRGGBB", "#RRGGBBAA", "p3:#RRGGBB" for Display P3), shadows are `[x, y, blur, "#RRGGBB", opacity]` as in Fable's
/// token files, sizes are numbers.
struct PulseSkinSet: Codable, Equatable {
    var name: String
    var dark: PulseSkin
    var light: PulseSkin?

    func half(_ scheme: ColorScheme) -> PulseSkin { scheme == .light ? light ?? dark : dark }

    static let classic = PulseSkinSet(name: "classic", dark: .classic)
    static let groove = PulseSkinSet(name: "groove", dark: .groove)
    static let builtIn = [classic, groove]

    /// The built-in skin a setting names; nil or an unknown name is Classic.
    static func named(_ name: String?) -> PulseSkinSet { builtIn.first { $0.name == name } ?? classic }
}

/// One appearance's half of a skin: what the views read from the environment. Views hold no colour or shadow of their own.
struct PulseSkin: Codable, Equatable {
    var accents: Accents
    var surface: SkinColor   // a flat panel (Classic's Solid)
    var track: SkinColor     // an empty ring's track (Classic)
    var ink: Ink
    var stale: Double        // opacity of a ring and number from an earlier refresh
    var groove: Groove?      // nil = flat: Classic's surface, tracks and text

    struct Accents: Codable, Equatable {
        var claude, codex, grok, antigravity: SkinColor
        var antigravity2: SkinColor   // an account's later pool of models (Antigravity's Claude and GPT)
        var battery: SkinColor?       // the battery ring at a normal charge; nil = the system's green. Low and critical stay system yellow and red
        var breakBar: SkinColor?      // the countdown ring for the default break colour; nil = the colour the break settings give
    }

    struct Ink: Codable, Equatable {
        var primary: SkinColor?   // nil = the system's primary label colour
        var secondary: SkinColor
        var alert: SkinColor? = nil   // near a limit, a critical battery; nil = the system's red
    }

    func accent(_ id: AccountID, pool: Int = 0) -> Color {
        guard pool == 0 else { return accents.antigravity2.color }
        return switch id {
        case .claude: accents.claude.color
        case .codex: accents.codex.color
        case .grok: accents.grok.color
        case .antigravity: accents.antigravity.color
        }
    }
    var battery: Color { accents.battery?.color ?? .green }
    var primary: Color { ink.primary?.color ?? .primary }
    var secondary: Color { ink.secondary.color }
    var alert: Color { ink.alert?.color ?? .red }

    /// What a window draws with: the named skin's half for Pulse's dark appearance, adjusted for Increase Contrast.
    static func named(_ name: String?, contrast: ColorSchemeContrast = .standard) -> PulseSkin {
        let half = PulseSkinSet.named(name).half(.dark)
        return contrast == .increased ? half.increasedContrast() : half
    }

    /// Increase Contrast: Classic's full colours instead of muted ones, white ink, and no shade over the rings' colour.
    func increasedContrast() -> PulseSkin {
        guard var g = groove else { return self }
        var skin = self
        g.wall = nil
        g.onFace = "#FFFFFF"
        skin.groove = g
        skin.accents = PulseSkin.classic.accents
        skin.ink = Ink(primary: "#FFFFFF", secondary: "#FFFFFF", alert: ink.alert)
        return skin
    }

    static let classic = PulseSkin(
        accents: Accents(claude: "p3:#FF6629", codex: "p3:#386BFF", grok: "p3:#FFB81A",
                         antigravity: "p3:#995CFF",   // not green: the battery's ring is
                         antigravity2: "p3:#59B8FF"),
        surface: "#121214",
        // Match the dark menu progress track with opaque ink, independent of glass and backdrop.
        track: "#252527",
        ink: Ink(primary: nil, secondary: "#E6E6E6"),
        stale: 0.5,
        groove: nil)

    /// Groove C · Inlay, its dark half: the colour lies flat on the floor of a deep channel, part of it in the wall's shadow;
    /// muted colours (OKLCH chroma 58%, lightness 95%); text embossed, logos and icons raised. Light from the top left.
    static let groove = PulseSkin(
        accents: Accents(claude: "#CF7C5E", codex: "#4E6FC0", grok: "#DBB572", antigravity: "#896EC5",
                         antigravity2: "#79AAD2", battery: "#7DB57C", breakBar: "#9C92CF"),
        surface: "#202226",
        track: "#050506",
        ink: Ink(primary: "#E4E6EA", secondary: "#E6E6E6", alert: "#FF6B61"),
        stale: 0.56,
        groove: Groove())

    /// Groove's surfaces, wells and raised marks. Ring values are in ring units, where 100 is the ring's size.
    struct Groove: Codable, Equatable {
        // the slab: rail, cards, pill, popover and Settings
        var slab: SkinColor = "#202226", slabTop: SkinColor = "#2A2C31", slabBottom: SkinColor = "#181A1D"
        var grain = 0.07
        var raise: [SkinShadow] = [[7, 7, 10, "#FFFFFF", 0.04], [-9, -9, 13, "#000000", 0.3],
                                   [1.2, 1.2, 0.9, "#FFFFFF", 0.2], [-1.6, -1.6, 1.4, "#000000", 0.6]]
        /// Fable's slab throws 12, 16, 18 and 2, 3, 3. The panel leaves 12 pt around the rail and cards, and its window
        /// cuts off anything past that, so the far shadow is shortened to end inside it.
        var drop: [SkinShadow] = [[3, 4, 5, "#000000", 0.5], [2, 3, 3, "#000000", 0.45]]

        // the rings
        var outer = Track(radius: 46.5, channel: 16, tube: 12.5)
        var inner = Track(radius: 30.5, channel: 11, tube: 8)
        var hubSingle = 38.5, hubDouble = 25.0
        var floor: SkinColor = "#050506"
        var face: SkinColor = "#202226", faceTop: SkinColor = "#2B2D32", faceBottom: SkinColor = "#17191B"
        var pressLip: SkinShadow = [1.2, 1.2, 0.8, "#FFFFFF", 0.22]
        var pressInner: [SkinShadow] = [[3.6, 3.6, 2.2, "#000000", 1], [-1.8, -1.8, 1.1, "#FFFFFF", 0.28]]
        var tubeBleed: SkinShadow = [0, 0, 3.4, "accent", 0.4]   // the colour's own glow up the channel's far wall
        var tubeInner: SkinShadow = [-0.8, -0.8, 1.4, "#000000", 0.3]
        var wall: SkinShadow? = [4.4, 4.4, 3.2, "#000000", 0.8]   // the wall's shadow across the colour
        var dome: [SkinShadow] = [[1.2, 1.2, 1.2, "#FFFFFF", 0.2], [-1.6, -1.6, 2, "#000000", 0.5]]
        var bubbleDrop: SkinShadow = [1.4, 1.4, 1, "#000000", 0.8]
        var bubbleInner: [SkinShadow] = [[0.8, 0.8, 0.6, "#FFFFFF", 0.22], [-0.9, -0.9, 0.8, "#000000", 0.5]]
        var logoDrop: [SkinShadow] = [[1.6, 2, 1.4, "#000000", 0.85], [3.2, 4.2, 5, "#000000", 0.45]]
        var logoInner: [SkinShadow] = [[0.7, 0.7, 0.5, "#FFFFFF", 0.5], [-0.8, -0.8, 0.8, "#000000", 0.4]]

        // how text and icons stand off the slab
        var onFace: SkinColor = "#F5F5F7"   // marks on a ring's hub
        var type: [SkinShadow] = [[-0.035, -0.035, 0, "#FFFFFF", 0.85],   // in ems of the text's size
                                  [0.06, 0.09, 0.05, "#000000", 0.9], [0.14, 0.2, 0.3, "#000000", 0.55]]
        var glyph: [SkinShadow] = [[-0.5, -0.5, 0, "#FFFFFF", 0.5],   // in points
                                   [1, 1.5, 1, "#000000", 0.9], [2.5, 3.5, 5, "#000000", 0.5]]

        // a card's bars: a slot pressed into the slab, the fill raised inside it
        var barSlot = 10.0, barFill = 6.0, barRadius = 5.0
        var barFloor: SkinColor = "#0B0C0E"
        var barPress: [SkinShadow] = [[2.2, 2.4, 2.6, "#000000", 1], [-1, -1, 1, "#FFFFFF", 0.1]]
        var barLip: SkinShadow = [1, 1, 0.8, "#FFFFFF", 0.1]
        var fillInner: [SkinShadow] = [[1, 1, 1, "#FFFFFF", 0.3], [-1, -1, 1.4, "#000000", 0.4]]
        var fillDrop: SkinShadow = [1.2, 1.2, 1.6, "#000000", 0.85]
        var secondBarGround: SkinColor = "#252527"   // a later window's bar is its colour halfway to this

        struct Track: Codable, Equatable { var radius, channel, tube: Double }

        var bubbleFace: Color { face.color.mix(with: .white, by: 0.09) }
        var discFloor: Color { floor.color.mix(with: .white, by: 0.16) }
    }
}

/// A colour as a hex string: "#RRGGBB" or "#RRGGBBAA" in sRGB, or "p3:#RRGGBB" in Display P3.
struct SkinColor: Codable, Equatable, ExpressibleByStringLiteral {
    let hex: String
    let color: Color

    init(_ hex: String) throws {
        let p3 = hex.hasPrefix("p3:")
        let digits = (p3 ? String(hex.dropFirst(3)) : hex).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6 || digits.count == 8, let v = UInt64(digits, radix: 16) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a hex colour: \(hex)"))
        }
        let rgba = digits.count == 6 ? v << 8 | 0xFF : v
        func part(_ shift: UInt64) -> Double { Double(rgba >> shift & 0xFF) / 255 }
        self.hex = hex
        color = Color(p3 ? .displayP3 : .sRGB, red: part(24), green: part(16), blue: part(8), opacity: part(0))
    }
    init(stringLiteral hex: String) { try! self.init(hex) }   // built-in skins only
    init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(hex) }
    static func == (a: Self, b: Self) -> Bool { a.hex == b.hex }
}

/// One shadow, `[x, y, blur, colour, opacity]`: an offset, a CSS blur (twice SwiftUI's radius), a hex colour or
/// "accent" (the ring's own colour), and its opacity.
struct SkinShadow: Codable, Equatable, ExpressibleByArrayLiteral {
    var x: CGFloat, y: CGFloat, blur: CGFloat
    var colour: String { didSet { parsed = Self.parse(colour) } }
    var opacity: Double
    private var parsed: Color?

    private static func parse(_ colour: String) -> Color? { colour == "accent" ? nil : (try? SkinColor(colour))?.color }

    init(arrayLiteral parts: SkinShadowPart...) {
        guard parts.count == 5, case let .number(x) = parts[0], case let .number(y) = parts[1], case let .number(blur) = parts[2],
              case let .text(colour) = parts[3], case let .number(opacity) = parts[4] else { fatalError("a shadow is [x, y, blur, colour, opacity]") }
        self.x = x; self.y = y; self.blur = blur; self.colour = colour; self.opacity = opacity
        parsed = Self.parse(colour)
    }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(CGFloat.self); y = try c.decode(CGFloat.self); blur = try c.decode(CGFloat.self)
        colour = try c.decode(String.self); opacity = try c.decode(Double.self)
        if colour != "accent" { _ = try SkinColor(colour) }
        parsed = Self.parse(colour)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(blur); try c.encode(colour); try c.encode(opacity)
    }

    /// The colour at its opacity; `accent` stands in for "accent".
    func color(accent: Color = .clear) -> Color {
        (parsed ?? accent).opacity(opacity)
    }
    var drop: ShadowStyle { .drop(color: color(), radius: blur / 2, x: x, y: y) }
    var inner: ShadowStyle { .inner(color: color(), radius: blur / 2, x: x, y: y) }
}

enum SkinShadowPart: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case number(CGFloat), text(String)
    init(floatLiteral v: Double) { self = .number(v) }
    init(integerLiteral v: Int) { self = .number(CGFloat(v)) }
    init(stringLiteral v: String) { self = .text(v) }
}

private struct PulseSkinKey: EnvironmentKey { static let defaultValue = PulseSkin.classic }
extension EnvironmentValues {
    var pulseSkin: PulseSkin {
        get { self[PulseSkinKey.self] }
        set { self[PulseSkinKey.self] = newValue }
    }
}

extension ShapeStyle {
    /// The style with inner shadows over it and drop shadows under it.
    func skinShadows(inner: [SkinShadow] = [], drop: [SkinShadow] = []) -> AnyShapeStyle {
        var style = AnyShapeStyle(self)
        for s in inner { style = AnyShapeStyle(style.shadow(s.inner)) }
        for s in drop { style = AnyShapeStyle(style.shadow(s.drop)) }
        return style
    }
}

// MARK: - the slab

/// Groove's raised slab: lit from the top left, a fine grain, no outline.
struct GrooveSlab<S: Shape>: View {
    let groove: PulseSkin.Groove
    let shape: S
    var floats = true   // false where the window already has its own shadow (the menu bar popover, Settings)

    var body: some View {
        let fill = LinearGradient(stops: [.init(color: groove.slabTop.color, location: 0), .init(color: groove.slab.color, location: 0.45),
                                          .init(color: groove.slabBottom.color, location: 1)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        shape.fill(fill.skinShadows(inner: groove.raise, drop: floats ? groove.drop : []))
            .overlay { shape.fill(ImagePaint(image: Grain.image, scale: 0.5)).opacity(groove.grain) }
    }
}

/// White specks of random strength, made once and tiled.
private enum Grain {
    static let image: Image = {
        let side = 128
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0 ..< side * side {
            let a = UInt8.random(in: 0 ... 255, using: &rng) > 160 ? UInt8.random(in: 0 ... 255, using: &rng) : 0
            bytes[i * 4 ..< i * 4 + 4] = [a, a, a, a]   // premultiplied white
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return Image(decorative: cg, scale: 1)
    }()
}

// MARK: - text and icons

extension View {
    /// Groove's embossed text: a lit edge above and two shadows below, in ems of `size`. Nothing in Classic.
    func embossed(_ skin: PulseSkin, size: CGFloat) -> some View {
        modifier(SkinShadows(shadows: skin.groove?.type ?? [], scale: size))
    }

    /// Groove's raised icons and logos: a lit edge and two cast shadows, in points. Nothing in Classic.
    func raised(_ skin: PulseSkin) -> some View {
        modifier(SkinShadows(shadows: skin.groove?.glyph ?? [], scale: 1))
    }
}

private struct SkinShadows: ViewModifier {
    let shadows: [SkinShadow]
    let scale: CGFloat

    func body(content: Content) -> some View {
        shadows.reduce(AnyView(content)) { view, s in
            AnyView(view.shadow(color: s.color(), radius: s.blur * scale / 2, x: s.x * scale, y: s.y * scale))
        }
    }
}

// MARK: - the rings

/// A Groove ring drawn once per change into one layer: the channels pressed into the slab, each account's colour lying on
/// its floor under the wall's shadow, the hub, the cap disc, and the logo or symbol standing on the hub.
struct GrooveRing<Mark: View>: View, Animatable {
    let groove: PulseSkin.Groove
    let size: CGFloat
    var colour: Color? = nil
    var outer: Double? = nil     // 0 to 100 of the outer channel in colour; nil = empty
    var inner: Double? = nil     // the inner channel's, when it has one
    var twoTracks = false
    var hub = true
    var disc: Double? = nil      // the cap disc's level, 0 to 1; nil = none
    var raiseMark = true         // the mark stands on the hub; false = drawn flat (the pet's sprite isn't one)
    @ViewBuilder var mark: Mark

    /// The outer colour follows an animation as a trimmed stroke does (the break's countdown drains smoothly).
    var animatableData: Double {
        get { outer ?? 0 }
        set { if outer != nil { outer = newValue } }
    }

    var body: some View {
        // 20% of room around the ring: the channel reaches past the ring's frame, as Classic's stroke does
        Canvas { ctx, box in
            let u = size / 100
            let c = CGPoint(x: box.width / 2, y: box.height / 2)
            func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r * u, y: c.y - r * u, width: 2 * r * u, height: 2 * r * u)) }
            func band(_ t: PulseSkin.Groove.Track) -> Path { circle(t.radius).strokedPath(StrokeStyle(lineWidth: t.channel * u)) }

            let tracks = [(groove.outer, outer)] + (twoTracks ? [(groove.inner, inner)] : [])
            for (track, fill) in tracks {
                let channel = band(track)
                ctx.drawShadow(channel, groove.pressLip, u)
                ctx.fill(channel, with: .color(groove.floor.color))
                for s in groove.pressInner { ctx.innerShadow(channel, s, u) }
                if let fill, fill > 0, let colour {
                    var lit = ctx
                    lit.clip(to: channel)
                    let arc = circle(track.radius).trimmedPath(from: 0, to: min(fill, 100) / 100)
                        .applying(CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(.init(rotationAngle: -.pi / 2))
                            .concatenating(.init(translationX: c.x, y: c.y)))
                    let tube = arc.strokedPath(StrokeStyle(lineWidth: track.tube * u, lineCap: .round))
                    var glow = lit
                    let bleed = groove.tubeBleed
                    glow.addFilter(.shadow(color: bleed.color(accent: colour), radius: bleed.blur * u / 2, x: bleed.x * u, y: bleed.y * u, options: .shadowOnly))
                    glow.fill(tube, with: .color(colour))
                    lit.fill(tube, with: .color(colour))
                    lit.innerShadow(tube, groove.tubeInner, u)
                }
                if let wall = groove.wall { ctx.innerShadow(channel, wall, u) }
            }

            if hub {
                let dome = circle(twoTracks ? groove.hubDouble : groove.hubSingle)
                ctx.fill(dome, with: .radialGradient(Gradient(stops: [.init(color: groove.faceTop.color, location: 0),
                                                                      .init(color: groove.face.color, location: 0.6),
                                                                      .init(color: groove.faceBottom.color, location: 1)]),
                                                     center: CGPoint(x: c.x - 12 * u, y: c.y - 16 * u), startRadius: 0, endRadius: 46 * u))
                for s in groove.dome { ctx.innerShadow(dome, s, u) }
            }
            if let disc {
                let rd = (twoTracks ? groove.hubDouble : groove.hubSingle) - 2.5
                let well = circle(rd)
                ctx.drawShadow(well, groove.pressLip, u)
                ctx.fill(well, with: .color(groove.discFloor))
                var level = ctx
                level.clip(to: well)
                let h = 2 * rd * u * max(0, min(disc, 1))
                level.fill(Path(CGRect(x: c.x - rd * u, y: c.y + rd * u - h, width: 2 * rd * u, height: h)),
                           with: .linearGradient(Gradient(colors: [.white.opacity(0.42), .white.opacity(0.2)]),
                                                 startPoint: CGPoint(x: c.x, y: c.y - rd * u), endPoint: CGPoint(x: c.x, y: c.y + rd * u)))
                for s in groove.pressInner { ctx.innerShadow(well, s, u) }
            }

            if let symbol = ctx.resolveSymbol(id: 0) {
                if raiseMark {
                    for s in groove.logoDrop {
                        var shade = ctx
                        shade.addFilter(.shadow(color: s.color(), radius: s.blur * u / 2, x: s.x * u, y: s.y * u, options: .shadowOnly))
                        shade.draw(symbol, at: c)
                    }
                }
                ctx.draw(symbol, at: c)
                if raiseMark {
                    ctx.drawLayer { layer in
                        layer.clipToLayer { $0.draw(symbol, at: c) }
                        for s in groove.logoInner {
                            var edge = layer
                            edge.addFilter(.shadow(color: s.color(), radius: s.blur * u / 2, x: s.x * u, y: s.y * u, options: [.invertsAlpha, .shadowOnly]))
                            edge.draw(symbol, at: c)
                        }
                    }
                }
            }
        } symbols: {
            mark.tag(0)
        }
        .frame(width: size * 1.2, height: size * 1.2)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension GraphicsContext {
    /// A drop shadow of `path` alone, scaled from ring units.
    func drawShadow(_ path: Path, _ s: SkinShadow, _ u: CGFloat) {
        var c = self
        c.addFilter(.shadow(color: s.color(), radius: s.blur * u / 2, x: s.x * u, y: s.y * u, options: .shadowOnly))
        c.fill(path, with: .color(.black))
    }

    /// An inner shadow inside `path`: the shadow of everything outside it, kept to its inside.
    func innerShadow(_ path: Path, _ s: SkinShadow, _ u: CGFloat) {
        var c = self
        c.clip(to: path)
        c.addFilter(.shadow(color: s.color(), radius: s.blur * u / 2, x: s.x * u, y: s.y * u, options: [.invertsAlpha, .shadowOnly]))
        c.fill(path, with: .color(.black))
    }
}

/// A Groove disc standing on the slab: the agents ring's bubbles and the rings' badges.
struct GrooveBubble: View {
    let groove: PulseSkin.Groove
    var fill: Color

    var body: some View {
        Circle().fill(fill.skinShadows(inner: groove.bubbleInner, drop: [groove.bubbleDrop]))
    }
}

// MARK: - bars

/// A card's bar in Groove: a slot pressed into the slab, the window's colour raised inside it.
struct GrooveBar: View {
    let groove: PulseSkin.Groove
    let value: Double   // 0 to 100
    let colour: Color

    var body: some View {
        let inset = (groove.barSlot - groove.barFill) / 2
        let slot = RoundedRectangle(cornerRadius: groove.barRadius)
        slot.fill(groove.barFloor.color.skinShadows(inner: groove.barPress, drop: [groove.barLip]))
            .frame(height: groove.barSlot)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: groove.barRadius - 2)
                        .fill(colour.skinShadows(inner: groove.fillInner, drop: [groove.fillDrop]))
                        .frame(width: max(groove.barFill, geo.size.width * max(0, min(value, 100)) / 100))
                }
                .padding(inset)
            }
    }
}
