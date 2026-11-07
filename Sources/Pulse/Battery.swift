import Foundation
import IOKit
import IOKit.ps
import SwiftUI

/// The internal battery right now.
struct BatteryReading: Equatable {
    var percent: Int
    var onAC: Bool
    var minutesLeft: Int?   // on battery only; nil while macOS is still estimating
    var simulated = false

    /// `defaults write io.github.tommyent.pulse simulatedBattery "8"`: on battery at 8%. "8 25" adds 25 minutes left, "8 ac" is plugged in.
    /// `defaults delete io.github.tommyent.pulse simulatedBattery` goes back to the real battery. Also works as `--args -simulatedBattery 8`.
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

/// Saved inside state.json. New fields must be optional: a key missing there makes all of these fall back to their defaults.
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

extension BatteryReading {
    /// The ring's tooltip and what VoiceOver reads for it.
    var summary: String {
        "\(percent)%" + (onAC ? ", plugged in" : minutesLeft.map { ", about \(batteryTimeLeft($0)) left" } ?? "")
            + (simulated ? " (simulated)" : "")
    }
}

/// The battery card's lines beyond the charge, from public sources only: the power-source API, the battery's
/// registry entry, and System Information's data for what System Settings calls Maximum Capacity.
struct BatteryDetails: Equatable {
    var charging = false
    var minutesToFull: Int?     // while charging, once macOS has an estimate
    var macWatts: Double?       // what the whole Mac draws, from the adapter or the battery
    var batteryWatts: Double?   // into the battery while charging, out of it (negative) on battery
    var adapterWatts: Int?
    var maxCapacity: Int?       // percent, System Settings' Maximum Capacity
    var condition: String?
    var cycles: Int?
    var lowPowerMode = false

    /// The power-source description, the battery's registry properties and the adapter's details, as macOS gives them.
    static func parse(source: [String: Any], registry: [String: Any], adapter: [String: Any]?) -> BatteryDetails {
        func number(_ any: Any?) -> Int64? { (any as? NSNumber)?.int64Value }   // amperage is signed
        var d = BatteryDetails()
        d.charging = source[kIOPSIsChargingKey] as? Bool ?? false
        d.minutesToFull = (source[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }   // -1 while estimating, 0 when full
        if let mV = number(registry["Voltage"]), let mA = number(registry["Amperage"]) {
            d.batteryWatts = Double(mV * mA) / 1_000_000
        }
        // SystemLoad is what the Mac uses while the adapter also charges the battery (seen on AC: adapter in = load + charging).
        // shortcut: on battery it falls back to the battery's own discharge; SystemLoad there wasn't seen, check it on a Mac on battery.
        if let load = number((registry["PowerTelemetryData"] as? [String: Any])?["SystemLoad"]), load > 0 {
            d.macWatts = Double(load) / 1000
        } else if let out = d.batteryWatts, out < 0 {
            d.macWatts = -out
        }
        d.adapterWatts = (adapter?[kIOPSPowerAdapterWattsKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
        d.cycles = number(registry["CycleCount"]).map(Int.init)
        return d
    }

    /// Maximum Capacity and condition from `system_profiler SPPowerDataType -json`. Its JSON says "Good" where System
    /// Settings and its own text output say "Normal" (seen 2026-11-07), so that one is translated.
    mutating func addHealth(profilerJSON data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let health = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first else { return }
        maxCapacity = (health["sppower_battery_health_maximum_capacity"] as? String)
            .flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        condition = (health["sppower_battery_health"] as? String).map { $0 == "Good" ? "Normal" : $0 }
        if cycles == nil { cycles = health["sppower_battery_cycle_count"] as? Int }
    }

    /// "100% · Charging, full in about 40 min", or "64% · On battery, about 3 hr left".
    func status(_ reading: BatteryReading) -> String {
        let state = if !reading.onAC {
            "On battery" + (reading.minutesLeft.map { ", about \(batteryTimeLeft($0)) left" } ?? "")
        } else if charging {
            "Charging" + (minutesToFull.map { ", full in about \(batteryTimeLeft($0))" } ?? "")
        } else {
            reading.percent >= 100 ? "Plugged in, fully charged" : "Plugged in, not charging"
        }
        return "\(reading.percent)% · \(state)" + (reading.simulated ? " (simulated)" : "")
    }

    /// "The Mac is using 14.7 W", then "Charging at 2.2 W from a 100 W adapter" while it charges.
    /// Charging takes a second line, which the card's width would otherwise break mid-phrase. Non-breaking spaces keep
    /// each number with its unit.
    var power: String? {
        guard let macWatts else { return nil }
        func watts(_ w: Double) -> String { "\(w.formatted(.number.precision(.fractionLength(1))))\u{00A0}W" }
        let adapter = adapterWatts.map { " from a \($0)\u{00A0}W adapter" } ?? ""
        let using = "The Mac is using \(watts(macWatts))"
        guard charging, let into = batteryWatts, into >= 0.1 else { return using + adapter }
        return using + "\nCharging at \(watts(into))" + adapter
    }

    /// "Maximum Capacity 95% · Normal".
    var health: String? {
        switch (maxCapacity, condition) {
        case let (capacity?, condition?): "Maximum Capacity \(capacity)% · \(condition)"
        case let (capacity?, nil): "Maximum Capacity \(capacity)%"
        case let (nil, condition?): "Condition: \(condition)"
        case (nil, nil): nil
        }
    }

    var cycleCount: String? { cycles.map { $0 == 1 ? "1 cycle" : "\($0) cycles" } }

    /// Everything but the health: IOKit calls only, quick enough for the main thread. nil on a Mac without a battery.
    static func read() -> BatteryDetails? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.lazy.compactMap({ IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
                .first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else { return nil }
        var registry: [String: Any] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                registry = props?.takeRetainedValue() as? [String: Any] ?? [:]
            }
        }
        var d = parse(source: source, registry: registry,
                      adapter: IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])
        d.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        return d
    }

    /// System Information's power data, about 60 ms; killed after 5 s so a stuck run can't hold the card's task.
    static func profilerJSON() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stop.cancel()
        return p.terminationStatus == 0 ? data : nil
    }
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
