import SwiftUI

/// Which of Settings' two theme menus a theme belongs in: the light theme's, the dark theme's, or both ("any": it
/// draws the same in both modes).
enum ThemeSlot: String, Codable, CaseIterable {
    case light, dark, any
    func fits(_ mode: ColorScheme) -> Bool { self == .any || (self == .light) == (mode == .light) }
}

/// A theme as its file holds it, one look: the format it's written in, the name Settings shows, who made it and what it
/// is (optional), which menu it belongs in, and the look's own keys beside them in the same object. Nothing in it
/// refers to anything outside the file, so the file alone is the theme: it can be sent to someone or moved to another Mac.
///
/// Plain Codable values with fixed key names (`Themes.swift` reads and checks them): colours are strings (`SkinColor`:
/// hex, or exact components such as "p3:1,0.40,0.16"), shadows are `[x, y, blur, "#RRGGBB", opacity]` as in Fable's
/// token files, sizes are numbers.
struct PulseThemeFile: Codable, Equatable {
    static let currentFormat = 1

    var format = PulseThemeFile.currentFormat
    var name: String
    var author: String? = nil
    var description: String? = nil
    var appearance: ThemeSlot
    var look: PulseSkin

    /// The appearance Pulse's windows take with this theme: its own for a light or dark one; for "any", the one its
    /// surface reads as (Classic: dark, as Pulse always was).
    var scheme: ColorScheme {
        switch appearance {
        case .light: .light
        case .dark: .dark
        case .any: (look.groove?.slab ?? look.surface).luminance > 0.18 ? .light : .dark
        }
    }

    private enum Keys: String, CodingKey { case format, name, author, description, appearance }
    init(name: String, author: String? = nil, description: String? = nil, appearance: ThemeSlot, look: PulseSkin) {
        self.name = name; self.author = author; self.description = description; self.appearance = appearance; self.look = look
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        format = try c.decode(Int.self, forKey: .format)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        appearance = try c.decode(ThemeSlot.self, forKey: .appearance)
        look = try PulseSkin(from: decoder)   // the look's keys sit beside these in the same object
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(format, forKey: .format)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(appearance, forKey: .appearance)
        try look.encode(to: encoder)
    }

    static let classicGlass = PulseThemeFile(name: "Classic Glass", description: "Pulse's own look, on untinted dark Liquid Glass.",
                                             appearance: .any, look: .classicGlass)
    static let classicSolid = PulseThemeFile(name: "Classic Solid", description: "Pulse's own look, on an opaque dark surface.",
                                             appearance: .any, look: .classic)
    static let groove = PulseThemeFile(name: "Groove", description: "Each ring a channel pressed into a raised dark slab, the colour on its floor.",
                                       appearance: .dark, look: .groove)
    static let grooveWhite = PulseThemeFile(name: "Groove White", description: "Groove in white: white channels pressed into a white slab, the colours deepened to read on it.",
                                            appearance: .light, look: .grooveWhite)
    static let grooveBlack = PulseThemeFile(name: "Groove Black", description: "A white slab with each ring a black puck pressed into it, Groove's dark colours inside.",
                                            appearance: .light, look: .grooveBlack)
    /// Pulse's own themes, under the ids settings and theme files use; with the collection's picks, the built-ins (`builtIn`).
    static let pulseOwn: [(id: String, file: PulseThemeFile)] = [("classic-glass", classicGlass), ("classic-solid", classicSolid),
                                                                ("groove", groove), ("groove-white", grooveWhite), ("groove-black", grooveBlack)]
}

/// One appearance's half of a skin: what the views read from the environment. Views hold no colour or shadow of their own.
struct PulseSkin: Codable, Equatable {
    var accents: Accents
    var surface: SkinColor   // a flat panel (Classic's Solid)
    var track: SkinColor     // an empty ring's track (Classic)
    var ink: Ink
    var stale: Double        // opacity of a ring and number from an earlier refresh
    var glass: Bool? = nil   // a flat look's panels: untinted dark Liquid Glass instead of `surface` (Classic Glass)
    var groove: Groove?      // nil = flat: Classic's surface, tracks and text
    var liquid: Bool? = nil  // prototype: a flat look's panels are Apple's clear Liquid Glass with the content inside, no veil; `ink` and `accents` alone do the reading
    var halo: [SkinShadow]? = nil   // prototype, liquid only: soft shadows behind everything inside the glass (text, rings, icons), in points
    var liquidMaterial: LiquidMaterial? = nil   // prototype, liquid only: nil = clear
    var wash: SkinColor? = nil      // prototype, liquid only: a colour, alpha included, laid on the glass under the content
    var backdrop: String? = nil     // prototype, liquid only: "desktop", or a picture beside the theme file, drawn under the glass

    /// A backdrop picture's name: a file directly in the Themes folder, never a path.
    static func isBackdropFileName(_ name: String) -> Bool {
        name.count <= 80 && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && ["png", "jpg", "jpeg", "heic"].contains((name as NSString).pathExtension.lowercased())
    }

    /// What a liquid theme's panels are made of: Liquid Glass .clear or .regular, or the older blur with no bending.
    enum LiquidMaterial: String, Codable { case clear, regular, ultraThin }

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

    /// Increase Contrast: black or white ink, whichever stands further from the slab (and from the hub, for marks on
    /// it), no shade over the rings' colour, and Classic's full colours where the rings' floor is dark (on a light
    /// floor those would read worse than the theme's own, which are already deepened for it).
    func increasedContrast() -> PulseSkin {
        guard var g = groove else { return self }
        var skin = self
        func bw(on ground: SkinColor) -> SkinColor { ground.luminance > 0.18 ? "#000000" : "#FFFFFF" }
        g.wall = nil
        g.onFace = bw(on: g.face)
        g.bubbleInk = g.bubbleInk.map { _ in bw(on: g.bubble ?? g.face) }
        skin.groove = g
        if g.floor.luminance < 0.18 { skin.accents = PulseSkin.classic.accents }
        let text = bw(on: g.slab)
        skin.ink = Ink(primary: text, secondary: text, alert: ink.alert)
        return skin
    }

    static let classic = PulseSkin(
        // exact components (hex only for whole 255ths): Classic draws exactly as the code before skins does with these colours
        accents: Accents(claude: "p3:1,0.40,0.16", codex: "p3:0.08,0.32,1", grok: "p3:1,0.72,0.10",
                         antigravity: "p3:0.46,0.16,0.98",   // indigo, not green: the battery's ring is
                         antigravity2: "p3:0.20,0.80,0.95"),   // aqua: clear of Codex's blue and the battery's green
        surface: "#060608",
        // Opaque ink, independent of glass and backdrop. Lighter than the dark menu progress track (37) it once matched,
        // so an empty ring still shows on the near-black surface.
        track: "#303033",
        ink: Ink(primary: nil, secondary: "srgb:0.9,0.9,0.9"),
        stale: 0.5,
        groove: nil)

    /// Classic on untinted dark Liquid Glass.
    static let classicGlass: PulseSkin = { var s = classic; s.glass = true; return s }()

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

    /// Groove's light half, White (Fable's "1 · White"): white channels pressed into a white slab, the hubs and discs
    /// of the same material, and Pulse's colours deepened (same hue) until they read on the white floor.
    static let grooveWhite: PulseSkin = {
        var g = Groove.lightSlab()
        g.floor = "#D0D3DA"
        g.face = "#E3E5EA"; g.faceTop = "#F4F5F8"; g.faceBottom = "#D2D5DC"
        g.pressLip = [1.2, 1.2, 0.8, "#FFFFFF", 1]
        g.pressInner = [[3.4, 3.4, 2.6, "#3E4350", 0.8], [-1.8, -1.8, 1.2, "#FFFFFF", 1]]
        g.tubeBleed = [0, 0, 3.4, "accent", 0.22]
        g.tubeInner = [-0.8, -0.8, 1.4, "#000000", 0.2]
        g.wall = [4.4, 4.4, 3.2, "#1E222B", 0.62]
        g.dome = [[1.2, 1.2, 1.2, "#FFFFFF", 1], [-1.6, -1.6, 2, "#5E6472", 0.4]]
        g.bubbleDrop = [1.4, 1.4, 1.2, "#2A2F3A", 0.5]
        g.bubbleInner = [[0.8, 0.8, 0.6, "#FFFFFF", 1], [-0.9, -0.9, 0.8, "#5E6472", 0.35]]
        g.logoDrop = [[1.6, 2, 1.4, "#2A2F3A", 0.5], [3.2, 4.2, 5, "#2A2F3A", 0.22]]
        g.logoInner = [[0.7, 0.7, 0.5, "#FFFFFF", 0.55], [-0.8, -0.8, 0.8, "#000000", 0.3]]
        g.onFace = "#1A1B1E"
        g.bubble = "#EEF0F3"; g.bubbleInk = "#3C3F45"; g.discWell = "#C6C9D1"; g.discInk = "#2A2C31"
        // the card's bars follow the rings: a white slot
        g.barFloor = "#D0D3DA"
        g.barPress = [[2, 2.2, 2.6, "#3E4350", 0.75], [-1, -1, 1, "#FFFFFF", 1]]
        g.barLip = [1, 1, 0.8, "#FFFFFF", 0.95]
        g.fillInner = [[1, 1, 1, "#FFFFFF", 0.3], [-1, -1, 1.4, "#000000", 0.3]]
        g.fillDrop = [1.2, 1.2, 1.6, "#2A2F3A", 0.45]
        g.secondBarGround = "#D0D3DA"
        return PulseSkin(
            accents: Accents(claude: "#BF4711", codex: "#3A66E0", grok: "#986300", antigravity: "#8354D6",
                             antigravity2: "#2373AB", battery: "#247E29", breakBar: "#7462B8"),
            surface: "#E3E5EA", track: "#D0D3DA", ink: .light, stale: 0.65, groove: g)
    }()

    /// Groove Black's light half (Fable's "2 · Black"): the white slab, and each ring a black puck pressed into it,
    /// inside which everything is exactly Groove's dark half, colours too.
    static let grooveBlack: PulseSkin = {
        var g = Groove.lightSlab()
        g.porthole = Groove.Porthole(radius: 57.5, lip: [1.3, 1.3, 0.8, "#FFFFFF", 0.95],
                                     inner: [[2.4, 2.4, 2, "#000000", 0.85], [-1.2, -1.2, 0.9, "#FFFFFF", 0.1]])
        // the bars: a black slot with a white lip on the white slab
        g.barFloor = "#17181B"
        g.barPress = [[2.2, 2.4, 2.6, "#000000", 1], [-1, -1, 1, "#FFFFFF", 0.14]]
        g.barLip = [1, 1, 0.8, "#FFFFFF", 0.95]
        return PulseSkin(accents: PulseSkin.groove.accents, surface: "#E3E5EA", track: "#050506", ink: .light, stale: 0.65, groove: g)
    }()

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

        // optional, for a light slab
        var porthole: Porthole? = nil     // a dark puck each ring sits in, pressed into the slab
        var bubble: SkinColor? = nil      // the agents' discs; nil = the hub's face lifted 9% toward white
        var bubbleInk: SkinColor? = nil   // "+3" on a disc; nil = light grey
        var discWell: SkinColor? = nil    // the cap disc's well; nil = the floor lifted 16% toward white
        var discInk: SkinColor? = nil     // the cap disc's level; nil = white

        struct Track: Codable, Equatable { var radius, channel, tube: Double }
        struct Porthole: Codable, Equatable {
            var radius: Double       // in ring units, as the channels
            var lip: SkinShadow      // the light caught by the slab's edge below it
            var inner: [SkinShadow]  // the puck's own shading
        }

        var bubbleFace: Color { bubble?.color ?? face.color.mix(with: .white, by: 0.09) }
        var discFloor: Color { discWell?.color ?? floor.color.mix(with: .white, by: 0.16) }

        /// Groove's rings as in dark, on Fable's white slab: its gradient, grain, light and shadows, embossed text
        /// and raised icons. The slab's drop shadow is shortened as dark's is, to end inside the panel's 12 pt.
        static func lightSlab() -> Groove {
            var g = Groove()
            g.slab = "#E3E5EA"; g.slabTop = "#F2F3F6"; g.slabBottom = "#D5D8DE"
            g.grain = 0.05
            g.raise = [[7, 7, 10, "#FFFFFF", 0.5], [-9, -9, 13, "#5E6472", 0.22],
                       [1.2, 1.2, 0.9, "#FFFFFF", 0.95], [-1.6, -1.6, 1.6, "#5E6472", 0.5]]
            g.drop = [[3, 4, 5, "#20242E", 0.38], [2, 3, 3, "#20242E", 0.3]]
            g.type = [[-0.05, -0.05, 0.02, "#FFFFFF", 1], [0.06, 0.09, 0.06, "#2A2F3A", 0.5], [0.14, 0.2, 0.3, "#2A2F3A", 0.28]]
            g.glyph = [[-0.7, -0.7, 0.3, "#FFFFFF", 1], [1, 1.5, 1.2, "#2A2F3A", 0.5], [2.5, 3.5, 5, "#2A2F3A", 0.25]]
            return g
        }
    }
}

extension PulseSkin.Ink {
    /// Fable's ink for a light slab. The alert red is Fable's #BF2318 darkened (same hue) to #B12116, which reads at
    /// 4.75:1 on the slab's darker end, where #BF2318 gave 4.24.
    static let light = PulseSkin.Ink(primary: "#1A1B1E", secondary: "#3C3F45", alert: "#B12116")
}

/// A colour as a string: hex ("#RRGGBB", "#RRGGBBAA"), or exact components from 0 to 1 ("r,g,b" or "r,g,b,a"). Either
/// may follow "srgb:" (the default) or "p3:" (Display P3): "p3:#FF6629", "srgb:0.07,0.07,0.08". Components keep values
/// that 8-bit hex would round.
struct SkinColor: Codable, Equatable, ExpressibleByStringLiteral {
    let hex: String   // the string as written, hex or not
    let color: Color
    let components: [Double]   // red, green, blue and alpha, 0 to 1, in the colour's own space
    let luminance: Double      // WCAG relative luminance, for the contrast floor; alpha left out

    init(_ text: String) throws {
        func refuse() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "not a colour: \(text)")) }
        let p3 = text.hasPrefix("p3:")
        let body = p3 ? String(text.dropFirst(3)) : text.hasPrefix("srgb:") ? String(text.dropFirst(5)) : text
        let parts: [Double]
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit), let v = UInt64(digits, radix: 16) else { throw refuse() }
            let rgba = digits.count == 6 ? v << 8 | 0xFF : v
            parts = [24, 16, 8, 0].map { Double(rgba >> $0 & 0xFF) / 255 }
        } else {
            let numbers = body.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 3 || numbers.count == 4, numbers.allSatisfy({ $0.map { (0 ... 1).contains($0) } == true }) else { throw refuse() }
            parts = numbers.map { $0! } + (numbers.count == 3 ? [1] : [])
        }
        hex = text
        components = parts
        color = Color(p3 ? .displayP3 : .sRGB, red: parts[0], green: parts[1], blue: parts[2], opacity: parts[3])
        // both spaces share sRGB's transfer curve; Y from each space's own primaries
        let linear = parts.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let y = p3 ? [0.2290, 0.6917, 0.0793] : [0.2126, 0.7152, 0.0722]
        luminance = zip(linear, y).map(*).reduce(0, +)
    }
    init(stringLiteral hex: String) { try! self.init(hex) }   // built-in skins only
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do { try self.init(text) } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "\"\(text)\" is not a colour (\"#RRGGBB\", \"#RRGGBBAA\" or \"r,g,b\" from 0 to 1)"))
        }
    }
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
        guard c.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "a shadow is exactly [x, y, blur, colour, opacity]")
        }
        if colour != "accent", (try? SkinColor(colour)) == nil {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "\"\(colour)\" is not a colour (\"#RRGGBB\", \"#RRGGBBAA\" or \"accent\")"))
        }
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
            .flattened(margin: 12)
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
        if shadows.isEmpty {
            content
        } else {
            shadows.reduce(AnyView(content)) { view, s in
                AnyView(view.shadow(color: s.color(), radius: s.blur * scale / 2, x: s.x * scale, y: s.y * scale))
            }
            .flattened(margin: 8)
        }
    }
}

extension View {
    /// Drawn once into a bitmap, `margin` points bigger than the view on every side for its shadows, and redrawn only
    /// when the view itself changes. Live shadows are blurred again each time anything else in the window moves.
    func flattened(margin: CGFloat) -> some View {
        padding(margin).drawingGroup().padding(-margin)
    }
}

// MARK: - the rings

/// A Groove ring: the channels pressed into the slab, each account's colour lying on its floor under the wall's shadow,
/// the hub, the cap disc, and the logo or symbol standing on the hub. Three layers: what never moves under the colour,
/// the colour, and what never moves over it. An animated value (the countdown draining, a refresh) redraws only the
/// colour; the blurs of the channel, the wall, the hub and the logo are drawn once per change of the ring itself.
struct GrooveRing<Mark: View>: View {
    let groove: PulseSkin.Groove
    let size: CGFloat
    var colour: Color? = nil
    var outer: Double? = nil     // 0 to 100 of the outer channel in colour; nil = empty
    var inner: Double? = nil     // the inner channel's, when it has one
    var twoTracks = false
    var hub = true
    var disc: Double? = nil      // the cap disc's level, 0 to 1; nil = none
    var raiseMark = true         // the mark stands on the hub; false = drawn flat
    @ViewBuilder var mark: Mark

    var body: some View {
        let geometry = RingGeometry(groove: groove, size: size, twoTracks: twoTracks)
        ZStack {
            Canvas { ctx, box in
                let g = geometry.at(box)
                if let porthole = groove.porthole {
                    let puck = g.circle(porthole.radius), u = g.u, c = g.centre
                    ctx.drawShadow(puck, porthole.lip, u)
                    ctx.fill(puck, with: .linearGradient(Gradient(stops: [.init(color: groove.faceTop.color, location: 0),
                                                                          .init(color: groove.face.color, location: 0.5),
                                                                          .init(color: groove.faceBottom.color, location: 1)]),
                                                         startPoint: CGPoint(x: c.x - 42 * u, y: c.y - 42 * u),
                                                         endPoint: CGPoint(x: c.x + 42 * u, y: c.y + 42 * u)))
                    for s in porthole.inner { ctx.innerShadow(puck, s, u) }
                }
                for channel in g.channels {
                    ctx.drawShadow(channel, groove.pressLip, g.u)
                    ctx.fill(channel, with: .color(groove.floor.color))
                    for s in groove.pressInner { ctx.innerShadow(channel, s, g.u) }
                }
            }
            if let colour {
                GrooveColour(geometry: geometry, colour: colour, outer: outer ?? 0, inner: inner ?? 0)
            }
            Canvas { ctx, box in
                let g = geometry.at(box)
                if let wall = groove.wall { for channel in g.channels { ctx.innerShadow(channel, wall, g.u) } }
                let u = g.u, c = g.centre
                if hub {
                    let dome = g.circle(twoTracks ? groove.hubDouble : groove.hubSingle)
                    ctx.fill(dome, with: .radialGradient(Gradient(stops: [.init(color: groove.faceTop.color, location: 0),
                                                                          .init(color: groove.face.color, location: 0.6),
                                                                          .init(color: groove.faceBottom.color, location: 1)]),
                                                         center: CGPoint(x: c.x - 12 * u, y: c.y - 16 * u), startRadius: 0, endRadius: 46 * u))
                    for s in groove.dome { ctx.innerShadow(dome, s, u) }
                }
                if let disc {
                    let discInk = groove.discInk?.color ?? .white
                    let rd = (twoTracks ? groove.hubDouble : groove.hubSingle) - 2.5
                    let well = g.circle(rd)
                    ctx.drawShadow(well, groove.pressLip, u)
                    ctx.fill(well, with: .color(groove.discFloor))
                    var level = ctx
                    level.clip(to: well)
                    let h = 2 * rd * u * max(0, min(disc, 1))
                    level.fill(Path(CGRect(x: c.x - rd * u, y: c.y + rd * u - h, width: 2 * rd * u, height: h)),
                               with: .linearGradient(Gradient(colors: [discInk.opacity(0.42), discInk.opacity(0.2)]),
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
        }
        // 20% of room around the ring: the channel reaches past the ring's frame, as Classic's stroke does
        .frame(width: size * 1.2, height: size * 1.2)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where a ring's channels lie, in a box 1.2 times the ring's size.
private struct RingGeometry {
    let groove: PulseSkin.Groove
    let size: CGFloat
    let twoTracks: Bool

    struct Placed {
        let u: CGFloat   // a ring unit
        let centre: CGPoint
        let tracks: [PulseSkin.Groove.Track]
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: centre.x - r * u, y: centre.y - r * u, width: 2 * r * u, height: 2 * r * u))
        }
        func channel(_ t: PulseSkin.Groove.Track) -> Path { circle(t.radius).strokedPath(StrokeStyle(lineWidth: t.channel * u)) }
        var channels: [Path] { tracks.map(channel) }
    }

    func at(_ box: CGSize) -> Placed {
        Placed(u: size / 100, centre: CGPoint(x: box.width / 2, y: box.height / 2),
               tracks: [groove.outer] + (twoTracks ? [groove.inner] : []))
    }
}

/// The colour on the channels' floors, the only layer an animated value redraws.
private struct GrooveColour: View, Animatable {
    let geometry: RingGeometry
    let colour: Color
    var outer: Double
    var inner: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(outer, inner) }
        set { outer = newValue.first; inner = newValue.second }
    }

    var body: some View {
        Canvas { ctx, box in
            let g = geometry.at(box), u = g.u, c = g.centre, groove = geometry.groove
            for (track, fill) in zip(g.tracks, [outer, inner]) where fill > 0 {
                var lit = ctx
                lit.clip(to: g.channel(track))
                let arc = g.circle(track.radius).trimmedPath(from: 0, to: min(fill, 100) / 100)
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
        }
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
            .flattened(margin: 3)
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
                    // nothing at 0, as Classic's bar; any use at all shows at least a dot
                    if value > 0 {
                        RoundedRectangle(cornerRadius: max(0, groove.barRadius - 2))
                            .fill(colour.skinShadows(inner: groove.fillInner, drop: [groove.fillDrop]))
                            .frame(width: max(groove.barFill, geo.size.width * min(value, 100) / 100))
                    }
                }
                .padding(inset)
            }
            .flattened(margin: 4)
    }
}
