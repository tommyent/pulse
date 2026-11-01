import AppKit
import Sparkle
import SwiftUI

/// Sparkle's standard updater: the feed and the public key are in Info.plist, and Sparkle asks on the second launch
/// whether to check automatically. Pulse has no Dock icon, so a scheduled update alert would open behind other
/// windows; while one is up Pulse joins the Dock with a badge (Sparkle's gentle reminders for background apps).
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private(set) lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                                    userDriverDelegate: self)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        if !state.userInitiated { NSApp.dockTile.badgeLabel = "1" }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.dockTile.badgeLabel = ""
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Disabled while Sparkle can't start a check (one is already running).
struct CheckForUpdatesButton: View {
    @State private var canCheck = false

    var body: some View {
        Button("Check for Updates…") { Updates.shared.controller.checkForUpdates(nil) }
            .disabled(!canCheck)
            .onReceive(Updates.shared.controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
