import AppKit
import Carbon

@main
enum SecurityChecks {
    static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        let sentinel = dir.appendingPathComponent("unrelated")
        try Data("unchanged".utf8).write(to: sentinel)
        try fm.createSymbolicLink(at: file.appendingPathExtension("pulse-tmp"), withDestinationURL: sentinel)
        try Data("old".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let saved = ["account": ["key": "test-only"], "other": ["key": "preserved"]]
        try GrokCLIAuth.save(saved, to: file)
        let readBack = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: [String: String]]
        assert(readBack == saved)
        let mode = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        let untouched = try String(contentsOf: sentinel, encoding: .utf8)
        let files = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        assert(mode == 0o600)
        assert(untouched == "unchanged")
        assert(files == ["auth.json", "auth.json.pulse-tmp", "unrelated"])
        let blocked = dir.appendingPathComponent("directory")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: false)
        do {
            try GrokCLIAuth.save(saved, to: blocked)
            assertionFailure("replacing a directory must fail")
        } catch {}
        let afterFailure = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: [String: String]]
        assert(afterFailure == saved)

        let session = ProviderHTTP.session
        assert(session.configuration.urlCache?.diskCapacity ?? 0 == 0)
        assert(!session.configuration.httpShouldSetCookies)
        let url = URL(string: "https://example.com")!
        let task = session.dataTask(with: url) // never resumed: this check is offline
        var redirectCalled = false
        ProviderHTTP.delegate.urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: url)) { redirected in
                assert(redirected == nil)
                redirectCalled = true
            }
        assert(redirectCalled)
        task.cancel()

        // Dropping the owner must unregister the old voice shortcut, even before a new one is bound.
        let combo = HotKeyCombo(keyCode: UInt32(kVK_F20), carbonModifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), label: "test")
        weak var released: HotKey?
        autoreleasepool {
            let key = HotKey(combo)
            assert(key != nil, "test shortcut could not register")
            released = key
        }
        assert(released == nil, "registry must not retain obsolete voice shortcuts")
        let replacement = HotKey(combo)
        assert(replacement != nil, "old shortcut must be unregistered")

        // Antigravity: `/usage` only reaches agy versions that treat it as a local command, never a prompt.
        for (v, ok) in [("1.2.9\n", true), ("1.1.11", true), ("agy 2.0.0", true), ("1.1.10", false), ("0.9.99", false), ("", false)] {
            assert(AntigravityAdapter.supportsUsageReport(v) == ok, "agy version \(v)")
        }
        func report(_ gemini: Double, _ thirdParty: Double) -> [String: Any] {
            let json = """
            {"conversation_id":"","status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
             {"name":"Gemini Models","buckets":[
              {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":\(gemini),"reset_time":"2026-09-25T11:01:14Z"},
              {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-09-24T00:46:21Z"}]},
             {"name":"Claude and GPT models","buckets":[
              {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-09-30T19:46:21Z"},
              {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":\(thirdParty),"reset_time":"2026-09-24T00:46:21Z"}]}]}}}
            """
            return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        }
        let ag = AntigravityAdapter.windows(from: report(0.75, 1))
        assert(ag.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"], "\(ag.map(\.id))")
        assert(ag[1].label == "Gemini · weekly" && ag[1].percentUsed == 25 && ag[1].resetsAt != nil)
        assert(ag[2].label == "Claude and GPT · 5-hour" && ag[2].percentUsed == 0)
        assert(AntigravityAdapter.windows(from: report(1, 0.5)).first?.id == "3p-5h", "the pool nearest its limit leads")
        var failed = report(0.5, 0.5); failed["status"] = "ERROR"
        assert(AntigravityAdapter.windows(from: failed).isEmpty)
        let prompted: [String: Any] = ["status": "SUCCESS", "response": "Here is your usage…", "num_turns": 1]
        assert(AntigravityAdapter.windows(from: prompted).isEmpty, "a model answer is not a usage report")
        assert(AntigravityAdapter.signedOut(Data("Select login method:".utf8)))
        assert(!AntigravityAdapter.signedOut(Data("dial tcp: i/o timeout".utf8)))
        print("Security checks passed: private atomic auth writes, redirect/cache policy, shortcut release and the agy usage guard")
    }
}
