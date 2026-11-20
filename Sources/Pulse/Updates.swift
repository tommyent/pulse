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

/// What this build is: "Pulse 0.5.0 (10)" at the foot of Settings and in the standard About panel. Builds that aren't
/// releases carry their commit in Info.plist (`PulseCommit`, written by package.sh), shown after the build number,
/// so two test builds of one version can be told apart.
enum AboutPulse {
    static func build(_ info: [String: Any]) -> String {
        let build = info["CFBundleVersion"] as? String ?? "?"
        return (info["PulseCommit"] as? String).map { "\(build), \($0)" } ?? build
    }

    static func line(_ info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        guard let version = info["CFBundleShortVersionString"] as? String else { return "Pulse (development build)" }
        return "Pulse \(version) (\(build(info)))"
    }

    @MainActor static func show() {
        NSApp.activate()   // an accessory app: without this the panel can open behind the front app
        NSApp.orderFrontStandardAboutPanel(options: [.version: build(Bundle.main.infoDictionary ?? [:])])
    }
}
