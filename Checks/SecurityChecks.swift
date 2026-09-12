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
        print("Security checks passed: private atomic auth writes, redirect/cache policy and shortcut release")
    }
}
