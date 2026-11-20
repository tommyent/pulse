import SwiftUI

enum PulseAppearance: String, Codable {
    case glass, solid
}

extension PulseSkin {
    /// How a flat look's panels are drawn: Glass or Solid.
    var material: PulseAppearance { glass == true ? .glass : .solid }
}

private struct PulseAppearanceKey: EnvironmentKey { static let defaultValue = PulseAppearance.solid }
extension EnvironmentValues {
    var pulseAppearance: PulseAppearance {
        get { self[PulseAppearanceKey.self] }
        set { self[PulseAppearanceKey.self] = newValue }
    }
}

/// Resolve at the text, inside the panel's wallpaper-adjusted environment.
struct PulsePrimary: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved { environment.pulseSkin.primary.resolve(in: environment) }
}
extension ShapeStyle where Self == PulsePrimary {
    static var pulsePrimary: PulsePrimary { PulsePrimary() }
}

/// Captions in the theme's own secondary ink: Classic's grey in Classic, as before, and a dark grey on a light theme's
/// slab, where Classic's grey would be near-white on white. The break screen keeps Classic's grey: it's always dark.
struct PulseSecondary: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved { environment.pulseSkin.secondary.resolve(in: environment) }
}
extension ShapeStyle where Self == PulseSecondary {
    static var pulseSecondary: PulseSecondary { PulseSecondary() }
}

/// Classic's colours, for the views that don't change with the skin (Groove's secondary ink is the same).
enum PulsePalette {
    static let surface = PulseSkin.classic.surface.color
    static let track = PulseSkin.classic.track.color
    static let secondary = PulseSkin.classic.secondary
}

struct RingTrack: View {
    @Environment(\.pulseSkin) private var skin
    let lineWidth: CGFloat

    var body: some View {
        Circle().stroke(skin.track.color, lineWidth: lineWidth)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PulseSurface<S: Shape>: View {
    @Environment(\.pulseAppearance) private var appearance
    @Environment(\.pulseSkin) private var skin
    let shape: S
    var floats = true   // Groove: the slab throws its own shadow; false where the window already has one

    var body: some View {
        if let groove = skin.groove {
            GrooveSlab(groove: groove, shape: shape, floats: floats)
        } else if skin.liquid == true {
            Color.clear.liquidPanel(skin, in: shape)   // prototype: Settings' background; panels put their content inside (SurfaceModifier)
        } else {
            classic
        }
    }

    @ViewBuilder private var classic: some View {
        switch appearance {
        case .glass:
            // Keep the foreground outside glass's adaptive foreground/vibrancy treatment.
            Color.clear.glassEffect(.regular, in: shape)
                // A fixed legibility veil keeps untinted glass dark over bright windows too. A veil, because a tint in
                // the glass only shows while its window is key. Much darker and the rings' tracks disappear into it.
                .overlay { shape.fill(.black.opacity(0.65)) }
                .environment(\.appearsActive, true)
        case .solid:
            shape.fill(skin.surface.color)
        }
    }
}

/// A gloss: one tight highlight from the top left that dies out partway down. It goes over the content, because under
/// it the surface would brighten towards the rings' fixed track shade and hide empty rings; over it, both rise together.
private struct PulseLight<S: Shape>: View {
    let shape: S

    var body: some View {
        shape.fill(EllipticalGradient(stops: [.init(color: .white.opacity(0.36), location: 0),
                                              .init(color: .white.opacity(0.08), location: 0.26),
                                              .init(color: .clear, location: 0.6)],
                                      center: UnitPoint(x: 0.16, y: -0.08), startRadiusFraction: 0, endRadiusFraction: 0.85))
    }
}

/// A 1 pt rim that follows the light, brightest at the top left.
private struct PulseRim<S: Shape>: View {
    let shape: S

    var body: some View {
        // Clip the centered stroke to keep a 1 pt rim inside shapes with tails too.
        shape.stroke(LinearGradient(colors: [.white.opacity(0.42), PulsePalette.track, Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing),
                     style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .clipShape(shape)
    }
}

private struct PulsePresentation: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        let choice = state.persisted.themeChoice
        let scheme = themes.scheme(choice)
        content.preferredColorScheme(scheme)
            .background(PulseWindowBacking(scheme: scheme))
            .modifier(PanelLook(theme: themes.current(choice), slot: themes.mode(choice), saved: state.persisted))
    }
}

/// Shared by the live panels and the look being edited in Settings.
struct PanelLook: ViewModifier {
    let theme: PulseTheme
    let slot: ColorScheme
    let saved: AppState.Persisted
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let glass = saved.glass(for: theme, slot: slot)
        var look = theme.file.look
        if contrast == .increased { look = look.increasedContrast() }
        if glass != nil { look.groove = nil }
        return content
            .environment(\.pulseAppearance, look.material)
            .environment(\.pulseSkin, look)
            .environment(\.glassSetting, glass)
            .environment(\.appearsActive, true)
    }
}

/// The overlay's hosting presentation follows the theme too, so default text and AppKit-backed colours agree.
struct ThemeScheme: ViewModifier {
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View { content.preferredColorScheme(themes.scheme(themes.choice)) }
}

/// Settings' window background: the theme's surface, in the theme's appearance.
struct SettingsBackground: View {
    @ObservedObject var state: AppState
    @ObservedObject private var themes = ThemeStore.shared
    var body: some View {
        let choice = state.persisted.themeChoice, look = themes.skin(choice)
        PulseSurface(shape: Rectangle(), floats: false)
            .environment(\.pulseAppearance, look.material)
            .environment(\.pulseSkin, look)
            .environment(\.appearsActive, true)
            .preferredColorScheme(themes.scheme(choice))
    }
}

extension View {
    /// Prototype, a liquid theme's panel: the content with the theme's halo behind it and its wash under it, inside the
    /// system's glass (by default .clear: the most transparent, the strongest lensing at its edges; .regular frosts it
    /// grey), which draws its own edge and light and adapts to what's behind; or on the older blur, which doesn't bend.
    /// The halo is live shadows, not flattened like Groove's: a bitmap would lose the AppKit controls inside (the card's bars).
    /// A backdrop, if the theme has one, lies behind the glass inside the panel, so the glass bends that known picture
    /// instead of whatever is on the desktop.
    @MainActor func liquidPanel<S: Shape>(_ skin: PulseSkin, in shape: S) -> some View {
        let lit = (skin.halo ?? []).reduce(AnyView(self)) { view, s in AnyView(view.shadow(color: s.color(), radius: s.blur / 2, x: s.x, y: s.y)) }
            .background(skin.wash?.color ?? .clear, in: shape)
        return Group {
            switch skin.liquidMaterial ?? .clear {
            case .clear: lit.glassEffect(.clear, in: shape)
            case .regular: lit.glassEffect(.regular, in: shape)
            case .ultraThin: lit.background(.ultraThinMaterial, in: shape)
            }
        }
        .background {
            if let picture = ThemeBackdrop.picture(skin.backdrop) {
                Color.clear
                    .overlay { Image(decorative: picture.image, scale: 1).resizable().scaledToFill().blur(radius: picture.blur, opaque: true) }
                    .clipShape(shape)
            }
        }
    }
}

extension View {
    /// Prototype: the break screen and its countdown keep no backdrop until the owner has seen them plain (desk-lead, 2026-11-19).
    func withoutBackdrop() -> some View { transformEnvironment(\.pulseSkin) { $0.backdrop = nil } }
}

/// Prototype: a liquid theme's `backdrop`, "desktop": the Mac's desktop picture, blurred. Read once per picture,
/// downsampled, and kept; a picture that can't be read draws nothing.
@MainActor enum ThemeBackdrop {
    private static var cache: [String: CGImage] = [:]

    static func picture(_ name: String?) -> (image: CGImage, blur: CGFloat)? {
        guard name == "desktop", let url = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }) else { return nil }
        let blur: CGFloat = 28
        if let image = cache[url.path] { return (image, blur) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
        else { return nil }
        cache[url.path] = image   // shortcut: a desktop picture replaced under the same name shows after a relaunch
        return (image, blur)
    }
}

private struct SurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.pulseSkin) private var skin
    @Environment(\.glassSetting) private var glass
    let shape: S
    var rail: Bool
    let bordered: Bool   // false: the window supplies its own rim and shadow (the menu bar popover)

    func body(content: Content) -> some View {
        if let glass {
            content.modifier(LevelPanel(setting: glass, shape: shape, crop: rail ? glass.railCrop : WallpaperCrop()))
        } else if skin.liquid == true {
            content.liquidPanel(skin, in: shape)
        } else {
            painted(content)
        }
    }

    private func painted(_ content: Content) -> some View {
        content
            .background { PulseSurface(shape: shape, floats: bordered) }
            .overlay {
                // Groove's slab carries its own light and edges: no gloss, no outline
                if skin.groove == nil {
                    ZStack {
                        PulseLight(shape: shape)
                        if bordered { PulseRim(shape: shape) }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

// Native scenes otherwise keep an opaque window backing underneath the chosen surface. The backing also gives its
// window the theme's appearance, so AppKit's own colours and controls in Pulse's themed windows follow the theme,
// while the application, and every other window, keeps Pulse's dark.
private struct PulseWindowBacking: NSViewRepresentable {
    let scheme: ColorScheme

    final class BackingView: NSView {
        var scheme = ColorScheme.dark
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearBacking()
        }
        func clearBacking() {
            window?.isOpaque = false
            window?.backgroundColor = .clear
            let name: NSAppearance.Name = scheme == .light ? .aqua : .darkAqua
            if window?.appearance?.name != name { window?.appearance = NSAppearance(named: name) }
        }
    }
    func makeNSView(context: Context) -> BackingView { let view = BackingView(); view.scheme = scheme; return view }
    func updateNSView(_ view: BackingView, context: Context) { view.scheme = scheme; view.clearBacking() }
}

extension View {
    func pulseSurface<S: Shape>(in shape: S, bordered: Bool = true, rail: Bool = false) -> some View {
        modifier(SurfaceModifier(shape: shape, rail: rail, bordered: bordered))
    }
    func pulsePresentation(_ state: AppState) -> some View { modifier(PulsePresentation(state: state)) }
}
