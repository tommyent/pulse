import Foundation

// Standalone Grok regression check: compiles the app's real adapter and runs it against the live
// xAI endpoints. Refreshes ~/.grok/auth.json in place if the CLI token is expired (same as the app).
// Run via scripts/grok-check.sh; exit 0 means the CLI billing path is healthy.

setvbuf(stdout, nil, _IONBF, 0)   // line-by-line progress even when piped

func check(_ ok: Bool, _ msg: String) {
    print(ok ? "PASS" : "FAIL", msg)
    if !ok { exit(1) }
}

// pure rules
check(GrokError.network("x").health == .providerError, "transport errors keep stale windows (providerError)")
check(GrokError.refreshFailed("invalid_grant").health == .needsAuth, "refresh rejection asks to reconnect")
let guest = [HTTPCookie(properties: [.domain: "grok.com", .path: "/", .name: "x-anonuserid", .value: "1"])!]
check(GrokAdapter.cookieHeader(from: guest) == nil, "guest cookies are not a signed-in session")
let signedIn = guest + [HTTPCookie(properties: [.domain: ".grok.com", .path: "/", .name: "sso", .value: "t"])!]
check(GrokAdapter.cookieHeader(from: signedIn)?.contains("sso=t") == true, "sso cookie marks a signed-in session")

let soon = Date.now.addingTimeInterval(3600)
check(!GrokCLIAuth.needsRefresh(expiresAt: soon, diskKey: "a", rejectedKey: nil), "fresh token, no rejection: reuse")
check(GrokCLIAuth.needsRefresh(expiresAt: soon, diskKey: "a", rejectedKey: "a"), "fresh but rejected, still on disk: refresh")
check(!GrokCLIAuth.needsRefresh(expiresAt: soon, diskKey: "b", rejectedKey: "a"), "rejected key already rotated on disk: try the new one first")
check(GrokCLIAuth.needsRefresh(expiresAt: Date.now.addingTimeInterval(30), diskKey: "a", rejectedKey: nil), "expiring within 60s: refresh")
check(GrokCLIAuth.needsRefresh(expiresAt: nil, diskKey: "a", rejectedKey: nil), "no expiry on disk: refresh")

let credits: [String: Any] = ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-09-11T16:21:11.647501+00:00"],
                              "isUnifiedBillingUser": true]
let cw = GrokAdapter.billingWindows(from: credits)
check(cw.first?.percentUsed == 0 && cw.first?.label == "Credits (weekly)" && cw.first?.resetsAt != nil,
      "credits schema: omitted creditUsagePercent parses as 0% weekly")
let legacy: [String: Any] = ["used": ["val": 25.0], "monthlyLimit": ["val": 100.0],
                             "billingPeriodStart": "2026-09-01T00:00:00+00:00", "billingPeriodEnd": "2026-10-01T00:00:00+00:00"]
let lw = GrokAdapter.billingWindows(from: legacy)
check(lw.first?.percentUsed == 25 && lw.first?.label == "Credits (monthly)", "legacy schema: used/monthlyLimit -> 25% monthly")
let zeroLimit: [String: Any] = ["used": ["val": 0.0], "monthlyLimit": ["val": 0.0]]
let zw = GrokAdapter.billingWindows(from: zeroLimit)
check(zw.count == 1 && zw[0].percentUsed == nil, "legacy zero limit: one window, no percent")
let protoZero: [String: Any] = ["used": [:], "monthlyLimit": ["val": "200"], "billingPeriodEnd": "2026-10-01T00:00:00+00:00"]
let pz = GrokAdapter.billingWindows(from: protoZero)
check(pz.count == 1 && pz[0].percentUsed == 0, "legacy: empty wrapper is protobuf zero, string int64 limit parses")

if CommandLine.arguments.contains("--offline") { exit(0) }

// live
Task {
    do {
        let e = try await GrokCLIAuth.shared.token()
        check((e.expiresAt ?? .distantPast) > .now, "CLI token usable, expires \(e.expiresAt!.formatted())")
    } catch { check(false, "CLI token: \(error)") }
    let snap = await GrokAdapter.fetch()
    print("health=\(snap.health) source=\(snap.source) detail=\(snap.detail ?? "-")")
    for w in snap.windows {
        print("  \(w.label): \(w.percentUsed.map { "\(Int($0))%" } ?? "-")  \(resetLabel(w.resetsAt))")
    }
    check(snap.health == .ok && snap.source == .cliStatus, "CLI billing path returns usage")
    exit(0)
}
dispatchMain()   // keeps the main actor free for the adapter's @MainActor cookie lookup
