import Foundation
import IOKit.ps
import SwiftUI

/// The internal battery right now.
struct BatteryReading: Equatable {
    var percent: Int
    var onAC: Bool
    var minutesLeft: Int?   // on battery only; nil while macOS is still estimating
    var simulated = false

    /// `defaults write app.pulse simulatedBattery "8"`: on battery at 8%. "8 25" adds 25 minutes left, "8 ac" is plugged in.
    /// `defaults delete app.pulse simulatedBattery` goes back to the real battery. Also works as `--args -simulatedBattery 8`.
    static func simulated(_ spec: String) -> BatteryReading? {
        let parts = spec.split(separator: " ")
        guard let first = parts.first, let percent = Int(first), (0...100).contains(percent) else { return nil }
        let onAC = parts.contains("ac")
        return BatteryReading(percent: percent, onAC: onAC,
                              minutesLeft: onAC ? nil : parts.dropFirst().lazy.compactMap { Int($0) }.first,
                              simulated: true)
    }
}

enum BatteryLevel: Int, Comparable {
    case ok, low, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var color: Color {
        switch self {
        case .ok: .green
        case .low: .yellow
        case .critical: .red
        }
    }
}

/// Saved inside state.json. New fields must be optional: a key missing there fails the whole file's decode.
struct BatterySettings: Codable, Equatable {
    var showInRail = true
    var alerts = true
    var lowPercent = 20        // yellow at or below
    var criticalPercent = 10   // red at or below
    var lowSound: String? = "Glass"   // nil = silent
    var lowLoops = false
    var criticalSound: String? = "Sosumi"
    var criticalLoops = true
    var pushover = true   // only when ~/.config/pushover.env has the keys

    func level(_ percent: Int) -> BatteryLevel {
        percent <= criticalPercent ? .critical : percent <= lowPercent ? .low : .ok
    }
}

/// Each level alerts once per discharge, on the way down. Plugging in rearms both; so does charge climbing back
/// above a level (a threshold moved under it).
struct BatteryAlertLatch {
    private(set) var announced = BatteryLevel.ok

    mutating func update(_ reading: BatteryReading?, _ settings: BatterySettings) -> BatteryLevel? {
        guard let reading, !reading.onAC else { announced = .ok; return nil }
        let level = settings.level(reading.percent)
        defer { announced = level }
        return level > announced ? level : nil
    }
}

extension UserDefaults {
    @objc dynamic var simulatedBattery: String? { string(forKey: "simulatedBattery") }
}

@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    @Published private(set) var reading: BatteryReading?
    private var simulation: NSKeyValueObservation?

    private init() {
        // macOS calls back on the main run loop for every change: percent, plugging in or out, a new estimate
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        // KVO here also sees `defaults write` from another process
        simulation = UserDefaults.standard.observe(\.simulatedBattery) { _, _ in
            Task { @MainActor in BatteryMonitor.shared.refresh() }
        }
        refresh()
    }

    func refresh() {
        let next = UserDefaults.standard.simulatedBattery.flatMap(BatteryReading.simulated) ?? Self.internalBattery()
        if next != reading { reading = next }
    }

    /// nil on a Mac without a battery.
    nonisolated static func internalBattery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = d[kIOPSTimeToEmptyKey] as? Int
            return BatteryReading(percent: min(100, current * 100 / max), onAC: onAC,
                                  minutesLeft: onAC ? nil : minutes.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }
}

/// "1 hr, 5 min" left.
func batteryTimeLeft(_ minutes: Int) -> String {
    Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

/// Pushover's message API, with the keys from `~/.config/pushover.env` (PUSHOVER_USER, PUSHOVER_TOKEN, optional
/// PUSHOVER_DEVICE). The keys are read when needed and never stored or logged.
enum Pushover {
    static let envFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/pushover.env")

    /// KEY=value lines as a shell sources them: `export`, quotes and comments allowed.
    static func keys(from text: String) -> [String: String] {
        var keys: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            keys[line[..<eq].trimmingCharacters(in: .whitespaces)] = value
        }
        return keys
    }

    static func request(title: String, message: String, keys: [String: String]) -> URLRequest? {
        guard let token = keys["PUSHOVER_TOKEN"], let user = keys["PUSHOVER_USER"], !token.isEmpty, !user.isEmpty else { return nil }
        var fields = [("token", token), ("user", user), ("title", title), ("message", message)]
        if let device = keys["PUSHOVER_DEVICE"], !device.isEmpty { fields.append(("device", device)) }
        // form encoding: everything but unreserved ASCII is escaped, "+" and "&" included
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var req = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved)!)" }
            .joined(separator: "&").utf8)
        return req
    }

    static var configured: Bool {
        request(title: "", message: "", keys: keys(from: (try? String(contentsOf: envFile, encoding: .utf8)) ?? "")) != nil
    }
}
