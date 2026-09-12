import Foundation

// This binary supplies a fake CLI. It never launches the user's Codex or reads its credentials.
func locateBinary(_ name: String) -> URL? {
    ProcessInfo.processInfo.environment["PULSE_CHECK_CODEX"].map { URL(fileURLWithPath: $0) }
}

@main
enum CodexSessionChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env node
        const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
        require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
          const m = JSON.parse(line);
          if (m.method === 'initialize') send({ id: m.id, result: {} });
          if (m.method === 'thread/start') send({ id: m.id, result: { thread: { id: 'fixture-thread' } } });
          if (m.method === 'turn/start') {
            send({ id: m.id, result: { turn: { id: 'fixture-turn' } } });
            send({ method: 'turn/started', params: { threadId: 'fixture-thread', turn: { id: 'fixture-turn' } } });
            send({ method: 'item/started', params: { threadId: 'fixture-thread', item: { id: 'fixture-item', type: 'reasoning' } } });
          }
          if (m.method === 'turn/interrupt') {
            if (m.params.threadId !== 'fixture-thread' || m.params.turnId !== 'fixture-turn') {
              send({ id: m.id, error: { message: 'missing or incorrect turn identity' } });
            } else {
              send({ id: m.id, result: {} });
              send({ method: 'turn/completed', params: { threadId: 'fixture-thread' } });
            }
          }
        });
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        setenv("PULSE_CHECK_CODEX", cli.path, 1)
        let session = CodexPetSession()
        defer { CodexAppServer.shared.stop() }
        session.send("offline fixture")
        var deadline = Date().addingTimeInterval(10)
        while session.activity.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(!session.activity.isEmpty, "fake turn must start")
        assert(session.thinking)
        session.interrupt()
        deadline = Date().addingTimeInterval(10)
        while session.thinking && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(!session.thinking, "Stop must interrupt the active turn using its ID")
        assert(session.status == nil)
        print("Codex session check passed: text Stop supplies the active thread and turn IDs")

        // Load the real inline WebKit page and prove its origin passes the bridge's guard.
        // This posts a synthetic data event only; pulseStart/getUserMedia are never called.
        let bridge = VoiceBridge.shared
        var received = false
        CodexAppServer.shared.onNotification = { method, params in
            if method == "pulse/voice", params["type"] as? String == "offline-origin-check" { received = true }
        }
        deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? await bridge.webView.evaluateJavaScript("typeof pulseStart === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await bridge.webView.evaluateJavaScript("void webkit.messageHandlers.pulse.postMessage({kind:'event',type:'offline-origin-check'})")
        deadline = Date().addingTimeInterval(5)
        while !received && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        assert(received, "the real inline page must have the trusted voice origin")
        assert(!bridge.webView.configuration.websiteDataStore.isPersistent)
        print("WebKit check passed: trusted page origin and nonpersistent voice storage")
    }
}
