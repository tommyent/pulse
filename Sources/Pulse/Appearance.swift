import SwiftUI

enum PulseAppearance: String, Codable {
    case glass, solid
}

private struct PulseAppearanceKey: EnvironmentKey { static let defaultValue = PulseAppearance.solid }
extension EnvironmentValues {
    var pulseAppearance: PulseAppearance {
        get { self[PulseAppearanceKey.self] }
        set { self[PulseAppearanceKey.self] = newValue }
    }
}

/// Classic's colours, for the views that don't change with the skin (Groove's secondary ink is the same).
enum PulsePalette {
    static let surface = PulseSkin.classic.surface.color
    static let track = PulseSkin.classic.track.color
    static let secondary = PulseSkin.classic.secondary
}

struct RingTrack: View {
    let lineWidth: CGFloat

    var body: some View {
        Circle().stroke(PulsePalette.track, lineWidth: lineWidth)
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
            shape.fill(PulsePalette.surface)
        }
    }
}

/// A clear coat: one soft light from the top left. It goes over the content, because under it the surface
/// would brighten past the rings' fixed track shade and hide empty rings; over it, both rise together.
private struct PulseLight<S: Shape>: View {
    let shape: S

    var body: some View {
        shape.fill(EllipticalGradient(stops: [.init(color: .white.opacity(0.17), location: 0),
                                              .init(color: .white.opacity(0.05), location: 0.45),
                                              .init(color: .clear, location: 1)],
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
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.preferredColorScheme(.dark)
            .background(PulseWindowBacking())
            .environment(\.pulseAppearance, state.persisted.appearance)
            .environment(\.pulseSkin, PulseSkin.named(state.persisted.skin, contrast: contrast))
            .environment(\.appearsActive, true)
    }
}

private struct SurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.pulseSkin) private var skin
    let shape: S
    let bordered: Bool   // false: the window supplies its own rim and shadow (the menu bar popover)

    func body(content: Content) -> some View {
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

// Native scenes otherwise keep an opaque window backing underneath the chosen surface.
private struct PulseWindowBacking: NSViewRepresentable {
    final class BackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearBacking()
        }
        func clearBacking() {
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }
    func makeNSView(context: Context) -> BackingView { BackingView() }
    func updateNSView(_ view: BackingView, context: Context) { view.clearBacking() }
}

extension View {
    func pulseSurface<S: Shape>(in shape: S, bordered: Bool = true) -> some View {
        modifier(SurfaceModifier(shape: shape, bordered: bordered))
    }
    func pulsePresentation(_ state: AppState) -> some View { modifier(PulsePresentation(state: state)) }
}
