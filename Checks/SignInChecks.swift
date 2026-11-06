// Run through scripts/check.sh. Offline: a fixture auth file and a stubbed session, no real account or request.
import AppKit

/// Answers every request with `status`, and counts them so a path that must not reach the network can say so.
private final class StubUsage: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests = 0
    static let body = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_after_seconds":100}}}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
enum SignInChecks {
    static let claudeMessage = "Sign in to Claude Code, or use Connect"
    static let codexMessage = "Run `codex login` in Terminal"
    static let codexMissing = "Install Codex CLI"

    static func snapshot(_ id: AccountID, _ health: Health, detail: String? = nil) -> AccountSnapshot {
        AccountSnapshot(id: id, displayName: id.displayName, planLabel: "", health: health, windows: [],
                        fetchedAt: .now, source: .cliStatus, detail: detail)
    }

    static func main() async throws {
        // Signed out: each account says what really works, and only those Pulse can sign in itself get a button
        let signedOut = snapshot(.claude, .needsAuth)
        assert(signedOut.healthMessage == claudeMessage, "Claude: \(signedOut.healthMessage ?? "nil")")
        assert(signedOut.connectTitle == "Connect Claude…")
        assert(snapshot(.codex, .needsAuth).healthMessage == codexMessage)
        assert(snapshot(.codex, .needsAuth).connectTitle == nil, "Codex signs in only through its CLI")
        assert(snapshot(.antigravity, .needsAuth, detail: "Run agy once").connectTitle == nil)
        let grok = snapshot(.grok, .needsAuth, detail: GrokError.noCLIAuth.description)
        assert(grok.healthMessage == GrokError.noCLIAuth.description, "an adapter's own reason wins")
        assert(grok.connectTitle == "Connect Grok…")

        // Connect is for signing in: not when signed in, nor when a failure says nothing about the sign-in
        for id in AccountID.allCases {
            for health in [Health.ok, .stale, .providerError, .missingClient] {
                assert(snapshot(id, health).connectTitle == nil, "\(id) \(health) offers Connect")
            }
        }
        assert(snapshot(.claude, .providerError, detail: "claude.ai didn't load").healthMessage == "claude.ai didn't load")

        // A snapshot saved by an older build has no detail and must not bring the old dead end back
        let saved = Data(#"{"id":"codex","displayName":"Codex","planLabel":"OpenAI","health":"needsAuth","windows":[],"fetchedAt":0,"source":"officialProtocol"}"#.utf8)
        let old = try JSONDecoder().decode(AccountSnapshot.self, from: saved)
        assert(old.healthMessage == codexMessage)

        // Before the first fetch nothing is known: no account asks for a sign-in or offers one
        for id in AccountID.allCases {
            let checking = AccountSnapshot.checking(id)
            assert(checking.healthMessage == "Checking \(id.displayName)…", "\(id): \(checking.healthMessage ?? "nil")")
            assert(checking.connectTitle == nil && checking.health != .needsAuth)
        }

        try await codexStates()

        // One line in the narrower of the card (320 pt) and the popover (300 pt less 14 pt either side): .caption is this font
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        for message in [claudeMessage, codexMessage, codexMissing, "Checking Antigravity…"] {
            let width = (message as NSString).size(withAttributes: [.font: font]).width
            assert(width <= 272, "\(message) is \(width) pt wide")
        }
        print("Sign-in checks passed: every signed-out card says what to do, and Connect appears only where Pulse can sign in")
    }

    /// `CodexAdapter.fetch` end to end for each sign-in state.
    static func codexStates() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubUsage.self]
        let session = URLSession(configuration: config)
        let absent = dir.appendingPathComponent("absent.json")
        let signedIn = dir.appendingPathComponent("signed-in.json")
        try Data(#"{"tokens":{"access_token":"test-only","account_id":"test-only"}}"#.utf8).write(to: signedIn)
        let unusable = dir.appendingPathComponent("unusable.json")
        try Data(#"{"OPENAI_API_KEY":"test-only","tokens":null}"#.utf8).write(to: unusable)

        func fetch(_ file: URL, cliFound: Bool, status: Int = 200) async -> AccountSnapshot {
            StubUsage.status = status
            return await CodexAdapter.fetch(authFile: file, cliFound: cliFound, session: session)
        }

        // No sign-in on disk: nothing to ask the network
        StubUsage.requests = 0
        let notInstalled = await fetch(absent, cliFound: false)
        assert(notInstalled.health == .missingClient && notInstalled.healthMessage == codexMissing, "\(notInstalled.health)")
        let installed = await fetch(absent, cliFound: true)
        assert(installed.health == .needsAuth && installed.healthMessage == codexMessage, "\(installed.health)")
        // An unusable file means Codex has run here, so the CLI may only be off Pulse's search path
        for cliFound in [true, false] {
            let snap = await fetch(unusable, cliFound: cliFound)
            assert(snap.health == .needsAuth && snap.healthMessage == codexMessage, "unusable, CLI \(cliFound): \(snap.health)")
        }
        assert(StubUsage.requests == 0, "\(StubUsage.requests) requests without a token")

        // A sign-in with no CLI on the search path keeps working
        for cliFound in [true, false] {
            let snap = await fetch(signedIn, cliFound: cliFound)
            assert(snap.health == .ok && snap.planLabel == "ChatGPT Plus" && snap.windows.count == 1 && snap.healthMessage == nil,
                   "signed in, CLI \(cliFound): \(snap.health)")
        }
        assert(StubUsage.requests == 2)

        // A rejected token says to sign in again, CLI found or not; other failures say nothing about the sign-in
        for status in [401, 403] {
            for cliFound in [true, false] {
                let snap = await fetch(signedIn, cliFound: cliFound, status: status)
                assert(snap.health == .needsAuth && snap.healthMessage == codexMessage, "\(status), CLI \(cliFound): \(snap.health)")
            }
        }
        let serverError = await fetch(signedIn, cliFound: true, status: 500)
        assert(serverError.health == .providerError && serverError.connectTitle == nil)
    }
}
