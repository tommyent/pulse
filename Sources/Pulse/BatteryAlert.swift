import AppKit
import Combine
import SwiftUI
import SystemConfiguration
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "app.pulse", category: "battery")

/// Low and critical battery alerts: Pulse's own panel and sound, never Notification Center, where they get lost.
@MainActor
final class BatteryAlerts {
    private let state: AppState
    private var latch = BatteryAlertLatch()
    private var panel: NSPanel?
    private var sound: NSSound?
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        BatteryMonitor.shared.$reading
            .combineLatest(state.$persisted.map(\.battery).removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] reading, settings in self?.update(reading, settings) }
            .store(in: &cancellables)
    }

    private func update(_ reading: BatteryReading?, _ settings: BatterySettings) {
        if reading?.onAC != false || !settings.alerts { close() }   // plugged in: the alert has done its job
        guard let level = latch.update(reading, settings), settings.alerts, let reading else { return }
        show(level, reading, settings)
    }

    private func show(_ level: BatteryLevel, _ reading: BatteryReading, _ settings: BatterySettings) {
        close()
        let critical = level == .critical
        log.notice("alert: \(critical ? "critical" : "low", privacy: .public) at \(reading.percent)%\(reading.simulated ? " (simulated)" : "", privacy: .public)")
        let title = Self.title(level, reading)
        panel = AlertPanel.show(BatteryAlertView(level: level) { [weak self] in self?.close() }, announcing: title, state: state)

        sound = BatterySounds.sound(critical ? settings.criticalSound : settings.lowSound)
        sound?.loops = critical ? settings.criticalLoops : settings.lowLoops
        sound?.play()

        if critical, settings.pushover, Pushover.configured {
            let message = "\(SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Your Mac") is at \(reading.percent)%"
                + (reading.minutesLeft.map { " with about \(batteryTimeLeft($0)) left" } ?? "") + ". Plug it in."
            Task { if let error = await Self.push(title: title, message: message) { log.error("pushover: \(error, privacy: .public)") } }
        }
    }

    private func close() {
        sound?.stop()
        sound = nil
        panel?.close()   // orderOut alone would keep it in the app's window list
        panel = nil
    }

    static func title(_ level: BatteryLevel, _ reading: BatteryReading) -> String {
        "Battery \(level == .critical ? "critical" : "low"): \(reading.percent)%"
    }

    /// nil when Pushover took it; otherwise why not. Never includes the keys.
    static func push(title: String, message: String) async -> String? {
        guard let text = try? String(contentsOf: Pushover.envFile, encoding: .utf8),
              let req = Pushover.request(title: title, message: message, keys: Pushover.keys(from: text))
        else { return "No PUSHOVER_USER and PUSHOVER_TOKEN in ~/.config/pushover.env" }
        guard let (data, resp) = try? await ProviderHTTP.session.data(for: req), let http = resp as? HTTPURLResponse
        else { return "Couldn't reach Pushover" }
        if http.statusCode == 200 { return nil }
        let errors = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["errors"] as? [String]
        return "Pushover said \(errors?.joined(separator: "; ") ?? "HTTP \(http.statusCode)")"
    }
}

/// macOS's alert sounds, ~/Library/Sounds, and files imported into Pulse's own folder.
enum BatterySounds {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pulse/Sounds")
    private static let folders = [folder, FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds"),
                                  URL(filePath: "/System/Library/Sounds")]

    /// By name, imported ones first, so an import named like a system sound replaces it.
    static func all() -> [(name: String, url: URL)] {
        var seen = Set<String>()
        return folders.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
                .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
        }
        .filter { seen.insert($0.name).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A sound that went missing falls back to the default, so a critical alert is never silent by accident.
    static func sound(_ name: String?) -> NSSound? {
        guard let name else { return nil }
        let sounds = all()
        let url = sounds.first { $0.name == name }?.url ?? sounds.first { $0.name == BatterySettings().criticalSound }?.url
        return url.flatMap { NSSound(contentsOf: $0, byReference: true) }
    }

    /// Copies the chosen files in; returns the ones macOS can't play.
    static func importFiles(_ urls: [URL]) -> [String] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rejected: [String] = []
        for url in urls {
            let target = folder.appending(path: url.lastPathComponent)
            if url.standardizedFileURL == target.standardizedFileURL { continue }   // already in the folder
            guard NSSound(contentsOf: url, byReference: true) != nil else { rejected.append(url.lastPathComponent); continue }
            try? FileManager.default.removeItem(at: target)   // re-importing a name replaces the old copy
            if (try? FileManager.default.copyItem(at: url, to: target)) == nil { rejected.append(url.lastPathComponent) }
        }
        return rejected
    }

    private static var preview: NSSound?
    /// Plays once; a second press stops it.
    static func togglePreview(_ name: String?) {
        if preview?.isPlaying == true { preview?.stop(); preview = nil; return }
        preview = sound(name)
        preview?.play()
    }
}

struct BatteryAlertView: View {
    @ObservedObject private var battery = BatteryMonitor.shared
    let level: BatteryLevel
    let dismiss: () -> Void

    var body: some View {
        let reading = battery.reading
        AlertCard(help: "Closes this alert and stops its sound. It also closes when the Mac is plugged in.", dismiss: dismiss) {
            Image(systemName: level == .critical ? "battery.0percent" : "battery.25percent")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(level.color)
                .accessibilityHidden(true)
            Text(level == .critical ? "Battery critical" : "Battery low")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text(reading.map { "\($0.percent)%" } ?? "—")
                .font(.system(size: 44, weight: .bold).monospacedDigit())
                .foregroundStyle(level == .critical ? Color.red : Color.primary)
            Text((reading?.minutesLeft.map { "About \(batteryTimeLeft($0)) left. " } ?? "")
                 + "Plug in your Mac before it goes to sleep.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
