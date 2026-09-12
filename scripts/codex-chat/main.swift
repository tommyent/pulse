// Live check of the pet's Codex path: app-server over stdio with the user's own Codex sign-in.
// 1. a text turn round-trips and streams an agent message
// 2. a subscription-backed realtime (voice) session negotiates: the app-server answers our SDP offer
// Runs against the real `codex` binary; needs a signed-in Codex CLI. No microphone involved.
import Foundation

func locateBinary(_ name: String) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [home.appending(path: ".local/bin/\(name)"), home.appending(path: ".\(name)/bin/\(name)"),
            URL(filePath: "/opt/homebrew/bin/\(name)"), URL(filePath: "/usr/local/bin/\(name)")]
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
    if !ok { failures += 1 }
}

let offer = """
v=0\r
o=- 4611731400430051336 2 IN IP4 127.0.0.1\r
s=-\r
t=0 0\r
a=group:BUNDLE 0 1\r
a=msid-semantic: WMS\r
m=audio 9 UDP/TLS/RTP/SAVPF 111\r
c=IN IP4 0.0.0.0\r
a=ice-ufrag:abcd\r
a=ice-pwd:abcdefghijklmnopqrstuvwx\r
a=fingerprint:sha-256 19:E2:1C:3B:4B:9F:81:E6:B8:5C:F4:A5:A8:D8:73:04:BB:05:2F:70:9F:04:A9:0E:05:E9:26:33:E8:70:88:A2\r
a=setup:actpass\r
a=mid:0\r
a=sendrecv\r
a=rtcp-mux\r
a=rtpmap:111 opus/48000/2\r
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
c=IN IP4 0.0.0.0\r
a=ice-ufrag:abcd\r
a=ice-pwd:abcdefghijklmnopqrstuvwx\r
a=fingerprint:sha-256 19:E2:1C:3B:4B:9F:81:E6:B8:5C:F4:A5:A8:D8:73:04:BB:05:2F:70:9F:04:A9:0E:05:E9:26:33:E8:70:88:A2\r
a=setup:actpass\r
a=mid:1\r
a=sctp-port:5000\r

"""

final class Collector: @unchecked Sendable {
    let lock = NSLock()
    var text = ""; var completed = false; var answer: String?; var rtError: String?
    func handle(_ m: String, _ p: [String: Any]) {
        lock.withLock {
            switch m {
            case "item/agentMessage/delta": text += (p["delta"] as? String) ?? ""
            case "turn/completed": completed = true
            case "thread/realtime/sdp": answer = p["sdp"] as? String
            case "thread/realtime/error": rtError = p["message"] as? String
            default: break
            }
        }
    }
}

let server = CodexAppServer.shared
let c = Collector()
server.onNotification = { c.handle($0, $1) }

let done = DispatchSemaphore(value: 0)
Task {
    do {
        try await server.start()
        check("app-server starts and initializes", true)
        let t = try await server.request("thread/start", ["cwd": NSHomeDirectory(), "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true])
        let tid = (t["thread"] as? [String: Any])?["id"] as? String
        check("thread/start returns a thread id", tid != nil)
        guard let tid else { done.signal(); return }
        _ = try await server.request("turn/start", ["threadId": tid, "input": [["type": "text", "text": "Reply with exactly the single word PONG and nothing else.", "text_elements": []]]])
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !c.lock.withLock({ c.completed }) { try await Task.sleep(for: .milliseconds(200)) }
        let text = c.lock.withLock { c.text }
        check("text turn completes", c.lock.withLock { c.completed })
        check("agent message streamed via deltas", text.uppercased().contains("PONG"), text.prefix(80).description)

        _ = try await server.request("thread/realtime/start", ["threadId": tid, "transport": ["type": "webrtc", "sdp": offer],
                                                                "version": "v3", "voice": "cove", "outputModality": "audio", "includeStartupContext": false])
        let rtDeadline = Date().addingTimeInterval(30)
        while Date() < rtDeadline, c.lock.withLock({ c.answer == nil && c.rtError == nil }) { try await Task.sleep(for: .milliseconds(200)) }
        let (answer, err) = c.lock.withLock { (c.answer, c.rtError) }
        check("realtime voice negotiates under the Codex subscription (SDP answer)", answer?.hasPrefix("v=0") == true, err ?? "")
        _ = try? await server.request("thread/realtime/stop", ["threadId": tid])
    } catch {
        check("codex path", false, error.localizedDescription)
    }
    server.stop()
    done.signal()
}
while done.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
