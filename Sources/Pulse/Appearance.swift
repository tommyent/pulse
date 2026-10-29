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
    static let border = LinearGradient(stops: [
        .init(color: .white.opacity(0.3), location: 0),
        .init(color: .white.opacity(0.12), location: 0.1),
        .init(color: .white.opacity(0.12), location: 0.9),
        .init(color: .white.opacity(0.3), location: 1)
    ], startPoint: .top, endPoint: .bottom)
}

struct PulseSurface<S: Shape>: View {
    @Environment(\.pulseAppearance) private var appearance
    let shape: S

    var body: some View {
        switch appearance {
        case .glass:
            // Keep the foreground outside glass's adaptive foreground/vibrancy treatment.
            Color.clear.glassEffect(.regular, in: shape)
                // A fixed legibility veil keeps untinted glass dark over bright windows too.
                .overlay { shape.fill(.black.opacity(0.65)) }
                .environment(\.appearsActive, true)
        case .solid:
            shape.fill(PulsePalette.surface)
        }
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
        background { PulseSurface(shape: shape) }
            .overlay {
                if bordered {
                    // Clip the centered stroke to keep a 1 pt rim inside shapes with tails too.
                    shape.stroke(PulsePalette.border, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                        .clipShape(shape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
    func pulsePresentation(_ state: AppState) -> some View { modifier(PulsePresentation(state: state)) }
}
