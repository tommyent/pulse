// Run: swiftc Sources/Pulse/Battery.swift Checks/BatteryChecks.swift -o /tmp/pulse-battery-check && /tmp/pulse-battery-check
import Foundation
import SwiftUI

@main
enum BatteryChecks {
    static func main() {
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

        // this Mac's own battery, if it has one
        if let r = BatteryMonitor.internalBattery() {
            assert((0...100).contains(r.percent) && (r.minutesLeft ?? 1) > 0)
            assert(!r.onAC || r.minutesLeft == nil)
        }
        print("battery checks passed")
    }
}
