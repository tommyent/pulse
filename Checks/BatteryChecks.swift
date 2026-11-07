// Run: swiftc Sources/Pulse/Battery.swift Checks/BatteryChecks.swift -o /tmp/pulse-battery-check && /tmp/pulse-battery-check
import Foundation
import SwiftUI

@main
enum BatteryChecks {
    static func main() async {
        let s = BatterySettings()   // yellow at 20, red at 10
        assert(s.level(100) == .ok && s.level(21) == .ok)
        assert(s.level(20) == .low && s.level(11) == .low)
        assert(s.level(10) == .critical && s.level(0) == .critical)
        assert(BatteryLevel.ok.color == .green && BatteryLevel.low.color == .yellow && BatteryLevel.critical.color == .red)
        var moved = s; moved.lowPercent = 40; moved.criticalPercent = 25
        assert(moved.level(40) == .low && moved.level(41) == .ok && moved.level(25) == .critical)

        func on(_ p: Int) -> BatteryReading { BatteryReading(percent: p, onAC: false) }
        func ac(_ p: Int) -> BatteryReading { BatteryReading(percent: p, onAC: true) }
        var latch = BatteryAlertLatch()
        assert(latch.update(on(50), s) == nil)
        assert(latch.update(on(20), s) == .low)
        assert(latch.update(on(19), s) == nil && latch.update(on(15), s) == nil)   // once per level
        assert(latch.update(on(10), s) == .critical)
        assert(latch.update(on(9), s) == nil && latch.update(on(1), s) == nil)
        assert(latch.update(ac(9), s) == nil && latch.announced == .ok)             // plugging in rearms
        assert(latch.update(on(9), s) == .critical)                                 // unplugged still low: it says so again
        latch = BatteryAlertLatch()
        assert(latch.update(on(5), s) == .critical)                                 // woke far down: only the worse alert
        assert(latch.update(ac(5), s) == nil && latch.update(ac(50), s) == nil && latch.update(on(49), s) == nil)
        assert(latch.update(nil, s) == nil && latch.announced == .ok)              // battery gone

        assert(latch.update(on(15), s) == .low)
        var lower = s; lower.lowPercent = 10; lower.criticalPercent = 5
        assert(latch.update(on(15), lower) == nil && latch.announced == .ok)       // threshold moved under the charge
        assert(latch.update(on(10), lower) == .low)

        assert(BatteryReading.simulated("8") == BatteryReading(percent: 8, onAC: false, minutesLeft: nil, simulated: true))
        assert(BatteryReading.simulated("8 25")?.minutesLeft == 25)
        assert(BatteryReading.simulated("8 ac") == BatteryReading(percent: 8, onAC: true, minutesLeft: nil, simulated: true))
        assert(BatteryReading.simulated("8 25 ac")?.minutesLeft == nil)
        assert(BatteryReading.simulated("") == nil && BatteryReading.simulated("x") == nil && BatteryReading.simulated("101") == nil)

        assert(batteryTimeLeft(65).contains("1") && batteryTimeLeft(65).contains("5"))

        let keys = Pushover.keys(from: """
        # comment
        PUSHOVER_USER=u123
        export PUSHOVER_TOKEN="t 456"
        PUSHOVER_DEVICE='phone'
        """)
        assert(keys == ["PUSHOVER_USER": "u123", "PUSHOVER_TOKEN": "t 456", "PUSHOVER_DEVICE": "phone"], "\(keys.keys)")
        let req = Pushover.request(title: "Battery critical: 8%", message: "a+b & c=d", keys: keys)!
        assert(req.url?.absoluteString == "https://api.pushover.net/1/messages.json" && req.httpMethod == "POST")
        let body = String(decoding: req.httpBody!, as: UTF8.self)
        assert(body == "token=t%20456&user=u123&title=Battery%20critical%3A%208%25&message=a%2Bb%20%26%20c%3Dd&device=phone", body)
        assert(Pushover.request(title: "", message: "", keys: ["PUSHOVER_USER": "u"]) == nil)
        assert(Pushover.request(title: "", message: "", keys: ["PUSHOVER_USER": "u", "PUSHOVER_TOKEN": ""]) == nil)

        // The battery card. Charging on a 100 W adapter: the readings an Air gave on 2026-11-07.
        let source: [String: Any] = ["Type": "InternalBattery", "Is Charging": true, "Time to Full Charge": 40]
        let registry: [String: Any] = ["Voltage": 13192, "Amperage": 170, "CycleCount": 234,
                                       "PowerTelemetryData": ["SystemLoad": 14706, "SystemPowerIn": 16948, "BatteryPower": 2242]]
        var charging = BatteryDetails.parse(source: source, registry: registry, adapter: ["Watts": 100])
        assert(charging.charging && charging.minutesToFull == 40 && charging.adapterWatts == 100 && charging.cycles == 234)
        assert(abs(charging.macWatts! - 14.706) < 0.001 && abs(charging.batteryWatts! - 2.24264) < 0.001)
        assert(charging.power == "The Mac is using 14.7\u{00A0}W\nCharging at 2.2\u{00A0}W from a 100\u{00A0}W adapter", charging.power ?? "nil")
        assert(charging.status(ac(100)) == "100% · Charging, full in about \(batteryTimeLeft(40))")
        assert(charging.cycleCount == "234 cycles" && charging.health == nil)
        // System Information's JSON, trimmed to what the card reads
        let profiler = Data(#"{"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_charge_info":{"sppower_battery_state_of_charge":100},"sppower_battery_health_info":{"sppower_battery_cycle_count":234,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"95%"}},{"_name":"sppower_ac_charger_information"}]}"#.utf8)
        charging.addHealth(profilerJSON: profiler)
        assert(charging.maxCapacity == 95 && charging.condition == "Normal" && charging.health == "Maximum Capacity 95% · Normal")
        var worn = BatteryDetails()
        worn.addHealth(profilerJSON: Data(#"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_health":"Service Recommended","sppower_battery_cycle_count":1}}]}"#.utf8))
        assert(worn.health == "Condition: Service Recommended" && worn.cycleCount == "1 cycle")
        worn.addHealth(profilerJSON: Data("not json".utf8))   // unreadable output changes nothing
        assert(worn.condition == "Service Recommended")
        // still estimating (-1), then full (0): no time to full
        assert(BatteryDetails.parse(source: ["Is Charging": true, "Time to Full Charge": -1], registry: [:], adapter: nil).minutesToFull == nil)
        let full = BatteryDetails.parse(source: ["Is Charging": false, "Time to Full Charge": 0], registry: registry, adapter: ["Watts": 100])
        assert(full.minutesToFull == nil && full.status(ac(100)) == "100% · Plugged in, fully charged" && full.status(ac(80)) == "80% · Plugged in, not charging")
        assert(full.power == "The Mac is using 14.7\u{00A0}W from a 100\u{00A0}W adapter")
        // on battery, with no telemetry: the battery's own discharge is the Mac's draw, and no adapter
        let draining = BatteryDetails.parse(source: ["Is Charging": false], registry: ["Voltage": 12500, "Amperage": -640], adapter: nil)
        assert(abs(draining.macWatts! - 8.0) < 0.001 && draining.power == "The Mac is using 8.0\u{00A0}W", draining.power ?? "nil")
        assert(draining.status(BatteryReading(percent: 64, onAC: false, minutesLeft: 180)) == "64% · On battery, about \(batteryTimeLeft(180)) left")
        assert(draining.status(on(64)) == "64% · On battery" && BatteryDetails().power == nil)
        assert(BatteryReading.simulated("8")!.summary == "8% (simulated)" && ac(50).summary == "50%, plugged in")

        // this Mac's own battery, if it has one
        if let r = BatteryMonitor.internalBattery() {
            assert((0...100).contains(r.percent) && (r.minutesLeft ?? 1) > 0)
            assert(!r.onAC || r.minutesLeft == nil)
            let d = BatteryDetails.read()
            assert(d != nil && (d!.cycles ?? 0) > 0)
            var withHealth = d!
            if let json = await BatteryDetails.profilerJSON() { withHealth.addHealth(profilerJSON: json); assert(withHealth.maxCapacity != nil) }
        }
        print("battery checks passed")
    }
}
