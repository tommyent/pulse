import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "app.pulse", category: "alerts")

/// Pulse's own alerts: a panel in the middle of the screen, never Notification Center, where alerts get lost.
@MainActor
enum AlertPanel {
    /// Above other windows on every Space, shown without taking the keyboard, so typing can't dismiss it.
    static func show<Content: View>(_ content: Content, announcing title: String, state: AppState) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar   // above the rings and other apps' floating windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hosting = OverlayHostingView(rootView: content
            .environment(\.glassTint, state.glassTint)
            .environment(\.showsRemaining, state.showsRemaining))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: screen.midX - panel.frame.width / 2, y: screen.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return panel
    }
}

/// The card every alert uses: its content, then Dismiss, which ignores clicks for its first second because the
/// panel can appear under a click meant for something else.
struct AlertCard<Content: View>: View {
    var help: String
    let dismiss: () -> Void
    @ViewBuilder var content: Content
    @State private var armed = false

    var body: some View {
        VStack(spacing: 10) {
            content
            Button("Dismiss", action: dismiss)
                .controlSize(.large)
                .disabled(!armed)
                .padding(.top, 6)
                .help(help)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 320)
        .glassCard(in: RoundedRectangle(cornerRadius: 26))
        .padding(12)   // room for the dark card's shadow
        .task {
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
    }
}

/// Usage windows that just crossed 98%, gathered in one alert that stays until it's dismissed.
@MainActor
final class LimitAlert {
    static let shared = LimitAlert()
    private var entries: [AccountSnapshot] = []   // each holding only its windows that crossed
    private var panel: NSPanel?

    func show(_ snap: AccountSnapshot, crossed: [UsageWindow], state: AppState) {
        let earlier = entries.first { $0.id == snap.id }?.windows ?? []
        var entry = snap
        entry.windows = earlier.filter { w in !crossed.contains { $0.id == w.id } } + crossed
        entries.removeAll { $0.id == snap.id }
        entries.append(entry)
        log.notice("limit alert: \(snap.id.rawValue, privacy: .public) \(crossed.map(\.id).joined(separator: ","), privacy: .public)")
        let open = panel != nil
        panel?.close()   // an open alert is redrawn with the new numbers, centred for its new size, without another beep
        panel = AlertPanel.show(LimitAlertView(entries: entries) { [weak self] in self?.dismiss() },
                                announcing: entries.map { Self.title($0) + ". " + Self.lines($0, remaining: state.showsRemaining) }
                                    .joined(separator: " "),
                                state: state)
        if !open { NSSound.beep() }   // the alert sound chosen in System Settings → Sound
    }

    private func dismiss() {
        panel?.close()
        panel = nil
        entries = []
    }

    static func title(_ snap: AccountSnapshot) -> String {
        snap.windows.contains { ($0.percentUsed ?? 0) >= 100 } ? "\(snap.displayName) hit a limit" : "\(snap.displayName) is near a limit"
    }

    static func lines(_ snap: AccountSnapshot, remaining: Bool) -> String {
        snap.windows.map { w in
            let p = w.percentUsed ?? 0
            let reset = resetLabel(w.resetsAt)
            return (remaining ? "\(w.label) has \(100 - Int(p))% left." : "\(w.label) is at \(Int(p))%.") + (reset.isEmpty ? "" : " \(reset).")
        }.joined(separator: "\n")
    }
}

struct LimitAlertView: View {
    @Environment(\.showsRemaining) private var remaining
    let entries: [AccountSnapshot]
    let dismiss: () -> Void

    var body: some View {
        AlertCard(help: "Closes this alert.", dismiss: dismiss) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, snap in
                if i > 0 { Divider().padding(.vertical, 6) }
                BrandIcon(account: snap.id, size: 40)
                    .accessibilityHidden(true)
                Text(LimitAlert.title(snap))
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.primary)
                if let top = snap.windows.compactMap(\.percentUsed).max() {
                    Text(remaining ? "\(100 - Int(top))% left" : "\(Int(top))%")
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.red)
                }
                Text(LimitAlert.lines(snap, remaining: remaining))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
