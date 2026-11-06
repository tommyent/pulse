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

enum PulsePalette {
    static let surface = Color(.sRGB, red: 0.07, green: 0.07, blue: 0.08, opacity: 1)
    // Match the dark menu progress track with opaque ink, independent of glass and backdrop.
    static let track = Color(.sRGB, red: 37.0 / 255, green: 37.0 / 255, blue: 39.0 / 255, opacity: 1)
    static let secondary = Color(.sRGB, red: 0.9, green: 0.9, blue: 0.9, opacity: 1)
    static let border = track
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
    let shape: S
    var polished = false   // the floating pieces; a whole screen or window stays flat

    var body: some View {
        switch appearance {
        case .glass:
            // Keep the foreground outside glass's adaptive foreground/vibrancy treatment.
            Color.clear.glassEffect(.regular, in: shape)
                // A fixed legibility veil keeps untinted glass dark over bright windows too.
                .overlay { shape.fill(.black.opacity(0.65)) }
                .environment(\.appearsActive, true)
        case .solid where polished:
            // A clear coat on deeper black: one soft light from the top left.
            ZStack {
                shape.fill(Color(white: 0.035))
                shape.fill(EllipticalGradient(stops: [.init(color: .white.opacity(0.19), location: 0),
                                                      .init(color: .white.opacity(0.06), location: 0.45),
                                                      .init(color: .clear, location: 1)],
                                              center: UnitPoint(x: 0.16, y: -0.08), startRadiusFraction: 0, endRadiusFraction: 0.85))
            }
        case .solid:
            shape.fill(PulsePalette.surface)
        }
    }
}

/// A 1 pt rim. On Solid it follows the surface's light, brightest at the top left.
private struct PulseRim<S: Shape>: View {
    @Environment(\.pulseAppearance) private var appearance
    let shape: S

    var body: some View {
        let lit = LinearGradient(colors: [.white.opacity(0.42), PulsePalette.track, Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
        // Clip the centered stroke to keep a 1 pt rim inside shapes with tails too.
        shape.stroke(appearance == .solid ? AnyShapeStyle(lit) : AnyShapeStyle(PulsePalette.border), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .clipShape(shape)
    }
}

private struct PulsePresentation: ViewModifier {
    @ObservedObject var state: AppState
    func body(content: Content) -> some View {
        content.preferredColorScheme(.dark)
            .background(PulseWindowBacking())
            .environment(\.pulseAppearance, state.persisted.appearance)
            .environment(\.appearsActive, true)
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
        background { PulseSurface(shape: shape, polished: true) }
            .overlay {
                if bordered {
                    PulseRim(shape: shape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
    func pulsePresentation(_ state: AppState) -> some View { modifier(PulsePresentation(state: state)) }
}
