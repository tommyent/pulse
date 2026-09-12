import AppKit
import WebKit

enum Keychain {
    static let service = "app.pulse.auth"

    /// Update in place, add if absent: a failed write never destroys the existing item.
    @discardableResult
    static func save(_ account: String, _ value: String) -> Bool {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let data = [kSecValueData: Data(value.utf8)] as [CFString: Any]
        let st = SecItemUpdate(q as CFDictionary, data as CFDictionary)
        if st == errSecItemNotFound {
            return SecItemAdd(q.merging(data) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return st == errSecSuccess
    }

    /// Pure lookup. Keychain ACLs are per-executable, so always run the /Applications build.
    static func read(_ account: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Embedded provider sign-in window. Polls `check` until the session is valid, then closes.
@MainActor
final class WebLogin: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var current: WebLogin?
    private let window: NSWindow
    private let web: WKWebView
    private var popup: NSWindow?
    private var timer: Timer?
    private var checking = false
    private let check: (WKWebView) async -> Bool
    private let onDone: () -> Void

    /// Connect/Reconnect: an expired-but-refreshable CLI session is renewed silently; the web
    /// sign-in window opens only when there is no recoverable CLI auth.
    static func presentGrok(onDone: @escaping () -> Void) {
        Task { @MainActor in
            do { _ = try await GrokAdapter.fetchCLI(); onDone() }          // renewed and billing accepts it
            catch let e as GrokError where e.health == .needsAuth { presentGrokWeb(onDone: onDone) }
            catch { onDone() }                                              // transient: let refreshAll re-poll
        }
    }

    /// Drop the web session only: saved cookie header + grok.com data in the shared WK store (claude.ai untouched).
    static func disconnectGrok() async {
        Keychain.delete("grok-cookies")
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("grok.com") })
    }

    private static func presentGrokWeb(onDone: @escaping () -> Void) {
        present(title: "Connect Grok", url: "https://grok.com", onDone: onDone) { web in
            let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
            // guests get grok.com cookies too; only a signed-in session (sso cookie + real quota) counts
            guard let header = GrokAdapter.cookieHeader(from: cookies),
                  await GrokAdapter.validate(cookieHeader: header) else { return false }
            return Keychain.save("grok-cookies", header)   // a failed save must not report "connected"
        }
    }

    static func presentClaude(onDone: @escaping () -> Void) {
        present(title: "Connect Claude", url: "https://claude.ai/login", onDone: onDone) { _ in
            // login shares the default WKWebsiteDataStore with the hidden fetcher
            await ClaudeWeb.shared.fetchUsage() != nil
        }
    }

    private static func present(title: String, url: String,
                                onDone: @escaping () -> Void,
                                check: @escaping (WKWebView) async -> Bool) {
        // a stale window for another provider (or a dead load) must not be reused as-is
        if let cur = current, cur.window.title != title { cur.window.close() }   // windowWillClose clears current
        let login = current ?? WebLogin(title: title, url: url, check: check, onDone: onDone)
        current = login
        login.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(title: String, url: String,
                 check: @escaping (WKWebView) async -> Bool, onDone: @escaping () -> Void) {
        self.check = check
        self.onDone = onDone
        web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.customUserAgent = safariUA   // default WKWebView UA gets a blank page from claude.ai
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false   // we hold a strong ref; default true double-releases on close
        window.contentView = web
        window.center()
        super.init()
        window.delegate = self
        web.navigationDelegate = self
        web.uiDelegate = self   // OAuth (e.g. Google) opens popups; without a UI delegate they're dropped
        web.load(URLRequest(url: URL(string: url)!))
        // SPA logins don't reliably fire didFinish — poll while the window is open
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in Self.current?.runCheck() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { runCheck() }

    /// window.open() from the login page: host the popup in its own window, sharing the
    /// given configuration so the OAuth opener/postMessage relationship stays intact.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let pw = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        pw.customUserAgent = safariUA
        pw.uiDelegate = self
        let w = NSWindow(contentRect: pw.frame, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Sign in"
        w.contentView = pw
        w.center()
        w.makeKeyAndOrderFront(nil)
        popup?.close()
        popup = w
        return pw
    }

    func webViewDidClose(_ webView: WKWebView) {   // script called window.close()
        if webView !== web { popup?.close(); popup = nil }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        popup?.close()
        Self.current = nil
    }

    private func runCheck() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            let ok = await check(web)
            // the window may have been closed or replaced by a newer login while we awaited
            guard ok, Self.current === self, window.isVisible else { return }
            window.close()
            onDone()
        }
    }
}

/// Hidden WKWebView that stays signed into claude.ai and fetches usage as a real browser
/// (claude.ai sits behind a Cloudflare challenge, so plain URLSession + cookies won't pass).
@MainActor
final class ClaudeWeb: NSObject, WKNavigationDelegate {
    static let shared = ClaudeWeb()
    private var web: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Never>?

    /// Returns (rate-limit tier, usage payload) or nil when not signed in / unreachable.
    func fetchUsage() async -> (tier: String?, usage: [String: Any])? {
        let web = await ensureLoaded()
        let js = """
        const orgs = await fetch('/api/organizations',{headers:{accept:'application/json'}}).then(r=>r.ok?r.json():null);
        if (!orgs || !orgs.length) { return null; }
        const org = orgs.find(o=>(o.capabilities||[]).includes('chat')) || orgs[0];
        const u = await fetch('/api/organizations/'+org.uuid+'/usage',{headers:{accept:'application/json'}}).then(r=>r.ok?r.json():null);
        if (!u) { return null; }
        return JSON.stringify({tier: org.rate_limit_tier || null, usage: u});
        """
        guard let result = try? await web.callAsyncJavaScript(js, contentWorld: .defaultClient),
              let str = result as? String,
              let obj = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any],
              let usage = obj["usage"] as? [String: Any]
        else { return nil }
        return (obj["tier"] as? String, usage)
    }

    /// Disconnect: drop the claude.ai web session (cookies, storage) and the hidden webview.
    func clearSession() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("claude.ai") })
        web = nil
    }

    private func ensureLoaded() async -> WKWebView {
        if let web, web.url?.host?.hasSuffix("claude.ai") == true { return web }
        let web = self.web ?? WKWebView(frame: .zero)
        web.customUserAgent = safariUA
        self.web = web
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "https://claude.ai/robots.txt")!))
        await withCheckedContinuation { cont in
            loadContinuation = cont
            Task { @MainActor in   // don't hang the poll loop if the load stalls
                try? await Task.sleep(for: .seconds(15))
                self.loadContinuation?.resume()
                self.loadContinuation = nil
            }
        }
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}
