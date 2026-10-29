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
    // Opaque sRGB ink, independent of semantic vibrancy and the desktop beneath the glass.
    static let track = Color(.sRGB, red: 0.8, green: 0.8, blue: 0.8, opacity: 1)
    static let secondary = Color(.sRGB, red: 0.9, green: 0.9, blue: 0.9, opacity: 1)
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
    func pulseSurface<S: Shape>(in shape: S) -> some View { background { PulseSurface(shape: shape) } }
    func pulsePresentation(_ state: AppState) -> some View { modifier(PulsePresentation(state: state)) }
}
