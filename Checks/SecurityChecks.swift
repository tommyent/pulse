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
        func report(_ gemini: Double, _ thirdParty: Double, argon: Double? = nil) -> [String: Any] {
            let cap = argon.map { """
            ,{"name":"Gemini 4 Argon","buckets":[
              {"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","window":"weekly","remaining_fraction":\($0),"reset_time":"2026-09-26T00:44:58Z"}]}
            """ } ?? ""
            let json = """
            {"conversation_id":"","status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
             {"name":"Gemini Models","buckets":[
              {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":\(gemini),"reset_time":"2026-09-25T11:01:14Z"},
              {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-09-24T00:46:21Z"}]},
             {"name":"Claude and GPT models","buckets":[
              {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-09-30T19:46:21Z"},
              {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":\(thirdParty),"reset_time":"2026-09-24T00:46:21Z"}]}\(cap)]}}}
            """
            return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        }
        let ag = AntigravityAdapter.windows(from: report(0.75, 1))
        assert(ag.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"], "\(ag.map(\.id))")
        assert(ag[1].label == "Gemini · weekly" && ag[1].percentUsed == 25 && ag[1].resetsAt != nil)
        assert(ag[2].label == "Claude and GPT · 5-hour" && ag[2].percentUsed == 0)
        for used in 1...99 {   // agy's fractions are 32-bit floats written as doubles: whole percents must not show one too few
            let fraction = Double(Float(100 - used) / 100)
            let shown = AntigravityAdapter.windows(from: report(fraction, 1)).first { $0.id == "gemini-weekly" }?.percentUsed
            assert(shown.map { Int($0) } == used, "\(used)% used read as \(shown ?? -1)")
        }
        let fuller = AntigravityAdapter.windows(from: report(1, 0.5))
        assert(fuller.first?.id == "gemini-5h" && fuller.map(\.pool) == ["Gemini", "Gemini", "Claude and GPT", "Claude and GPT"],
               "a fuller pool doesn't take the other's place: \(fuller.map(\.id))")
        let capped = AntigravityAdapter.windows(from: report(0.97, 1, argon: 0))
        assert(capped.map(\.id) == ["gemini-5h", "gemini-weekly", "weekly_model_gemini-argon-wtu-weekly", "3p-5h", "3p-weekly"],
               "a model cap joins its own pool: \(capped.map(\.id))")
        assert(capped[2].label == "Gemini 4 Argon · weekly" && capped[2].percentUsed == 100 && capped[2].pool == "Gemini")
        assert(capped.pools[0].outerArc?.id == "gemini-5h" && capped.pools[0].disc?.id == capped[2].id, "a full cap never leads")
        assert(capped.pools[1].disc == nil)
        var failed = report(0.5, 0.5); failed["status"] = "ERROR"
        assert(AntigravityAdapter.windows(from: failed).isEmpty)
        let prompted: [String: Any] = ["status": "SUCCESS", "response": "Here is your usage…", "num_turns": 1]
        assert(AntigravityAdapter.windows(from: prompted).isEmpty, "a model answer is not a usage report")
        assert(AntigravityAdapter.signedOut(Data("Select login method:".utf8)))
        assert(!AntigravityAdapter.signedOut(Data("dial tcp: i/o timeout".utf8)))
        // agy opens a browser sign-in when it can't auth, so a stall or sign-out holds polling back; offline does not.
        func agSnap(_ health: Health, _ detail: String?) -> AccountSnapshot {
            AccountSnapshot(id: .antigravity, displayName: "Antigravity", planLabel: "", health: health, windows: [],
                            fetchedAt: .now, source: .cliStatus, detail: detail)
        }
        // A Refresh clicked while agy runs gets its own pass, even if that run comes back stalled or signed out; a
        // second failure pauses again. Without a click, a failure pauses.
        let m0 = Date(timeIntervalSince1970: 1_000_000)   // agy's activity marker, a date that means nothing by itself
        var pause = AgyPause()
        pause.passStarted(marker: m0); pause.update(with: agSnap(.providerError, AntigravityAdapter.stalled), marker: m0)
        assert(pause.paused, "a stall pauses polling")
        pause.manualRefresh(whileRefreshing: false)
        assert(!pause.paused, "a Refresh lifts the pause")
        pause.passStarted(marker: m0); pause.manualRefresh(whileRefreshing: true); pause.update(with: agSnap(.needsAuth, nil), marker: m0)
        assert(!pause.paused, "a Refresh clicked during the run isn't consumed by that run's failure")
        pause.passStarted(marker: m0); pause.update(with: agSnap(.needsAuth, nil), marker: m0)
        assert(pause.paused, "the Refresh's own pass may pause again")
        pause.passStarted(marker: m0); pause.update(with: agSnap(.ok, nil), marker: m0)
        assert(pause.paused == false, "a good report never pauses")
        // A stall lifts when agy's activity marker changes after the stalled run ended; without that it gets a single
        // run half an hour on (monotonic), then waits. A sign-out waits for a Refresh whatever agy does.
        let t0 = ContinuousClock.now, stall = agSnap(.providerError, AntigravityAdapter.stalled)
        func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }
        var seen = AgyPause()
        seen.passStarted(now: t0, marker: m0); seen.update(with: stall, now: t0, marker: m0)
        seen.passStarted(now: at(120), marker: m0)
        assert(seen.paused, "the marker as it was when the stall ended (Pulse's own run) is no evidence")
        seen.passStarted(now: at(240), marker: m0 + 200)
        assert(!seen.paused, "agy's own session after the stall resumes polling")
        // Sol's probe: one marker dated ahead of the wall clock used to lift every later stall.
        var ahead = AgyPause()
        let future = m0 + 86_400 * 30
        ahead.passStarted(now: t0, marker: future); ahead.update(with: stall, now: t0, marker: future)
        for pass in 1...3 {
            ahead.passStarted(now: at(pass * 120), marker: future)
            assert(ahead.paused, "an unchanged marker never lifts a stall, however far ahead of the clock (pass \(pass))")
        }
        ahead.passStarted(now: at(480), marker: m0 - 86_400)
        assert(!ahead.paused, "a marker that changes to an earlier date (the clock set back) is still a change")
        ahead.update(with: stall, now: at(540), marker: m0 - 86_400)
        ahead.passStarted(now: at(660), marker: m0 - 86_400)
        assert(ahead.paused, "that change counts once: the next stall needs another")
        var quiet = AgyPause()
        quiet.passStarted(now: t0, marker: nil); quiet.update(with: stall, now: t0, marker: nil)
        quiet.passStarted(now: at(29 * 60), marker: nil)
        assert(quiet.paused, "no evidence: still paused before half an hour")
        quiet.passStarted(now: at(30 * 60), marker: nil)
        assert(!quiet.paused, "no evidence: one run half an hour on")
        quiet.update(with: stall, now: at(31 * 60), marker: nil)
        quiet.passStarted(now: at(86_400), marker: nil)
        assert(quiet.paused, "a stall with no evidence stays paused after its one extra run")
        quiet.passStarted(now: at(86_400), marker: m0)
        assert(quiet.paused, "a first successful read after failed ones is only the baseline")
        quiet.passStarted(now: at(86_520), marker: m0 + 1)
        assert(!quiet.paused, "a second read that differs from it is activity")
        // Sol's round-3 probe: with the budget spent, a nil read at the pass and the known one at the result used to
        // admit every poll.
        var churn = AgyPause()
        churn.passStarted(now: t0, marker: m0); churn.update(with: stall, now: t0, marker: m0)
        churn.passStarted(now: at(1800), marker: m0); assert(!churn.paused)
        churn.update(with: stall, now: at(1800), marker: m0)
        for pass in 1...5 {
            churn.passStarted(now: at(1800 + pass * 120), marker: nil)
            assert(churn.paused, "a failed marker read is never activity (pass \(pass))")
            churn.update(with: stall, now: at(1800 + pass * 120), marker: m0)
        }
        churn.passStarted(now: at(3000), marker: m0)
        assert(churn.paused, "nor is the known value read again after it")
        var out = AgyPause()
        out.passStarted(now: t0, marker: m0); out.update(with: agSnap(.needsAuth, nil), now: t0, marker: m0)
        out.passStarted(now: at(86_400), marker: m0 + 60)
        assert(out.paused, "a sign-out stays paused until Refresh, whatever agy does")
        out.manualRefresh(whileRefreshing: false)
        assert(!out.paused, "a Refresh lifts a sign-out")
        // The poll loop as AppState runs it: a pass every 2 minutes, agy run only when not paused, its nth run's result
        // landing a second later. Returns the minutes agy ran.
        let netTimeout = agSnap(.providerError, AntigravityAdapter.networkTimeout)
        let skipped = agSnap(.providerError, AntigravityAdapter.offline), good0 = agSnap(.ok, nil)
        func poll(_ p: inout AgyPause, from: Int = 0, to: Int = 24 * 60, marker: (Int) -> Date? = { _ in m0 },
                  results: (Int) -> AccountSnapshot) -> [Int] {
            var ran: [Int] = []
            for minute in stride(from: from, through: to, by: 2) {
                p.passStarted(now: at(minute * 60), marker: marker(minute))
                guard !p.paused else { continue }
                p.update(with: results(ran.count), now: at(minute * 60 + 1), marker: marker(minute))
                ran.append(minute)
            }
            return ran
        }
        var outage = AgyPause()
        assert(poll(&outage) { _ in netTimeout } == [0, 16, 48, 110],
               "network timeouts: runs 15, 30 and 60 minutes after each, then none for the rest of the day")
        var stuck = AgyPause()
        assert(poll(&stuck) { _ in stall } == [0, 32], "stalls: one run half an hour on, then none")
        var mixed = AgyPause()
        assert(poll(&mixed) { [stall, stall, netTimeout][min($0, 2)] } == [0, 32],
               "a stall's timed run spends the budget a later network timeout would have used")
        var alternating = AgyPause()   // Sol's probe: stall, timed run, network timeout, stall
        assert(poll(&alternating) { [stall, netTimeout, stall][min($0, 2)] } == [0, 32, 64],
               "a network timeout doesn't give back the run a stall used: one more, then none")
        var spotty = AgyPause()
        assert(poll(&spotty, to: 60) { [netTimeout, skipped, skipped, netTimeout][min($0, 3)] } == [0, 16, 18, 20, 52],
               "an offline skip never ran agy, so it spends nothing")
        var back = AgyPause()
        let busy = poll(&back, marker: { $0 < 600 ? m0 : m0 + 1 }) { $0 < 4 ? netTimeout : good0 }
        assert(busy == Array([0, 16, 48, 110, 600]) + Array(stride(from: 602, through: 24 * 60, by: 2)),
               "with the budget spent, the owner's own agy use runs it, and a good report puts polling back (\(busy.prefix(8)))")
        // One rule for every fetch: anything but a report, a sign-out or a fetch that never reached a usage run is a
        // failure, so an unknown reason holds agy back too.
        func outcome(_ health: Health, _ detail: String?) -> AgyPause.Outcome { AntigravityAdapter.outcome(of: agSnap(health, detail)) }
        assert(outcome(.providerError, AntigravityAdapter.noUsage) == .failed && outcome(.providerError, "a reason added later") == .failed
               && outcome(.providerError, AccountSnapshot.noAnswer(.antigravity).detail) == .failed && outcome(.providerError, nil) == .failed)
        assert(outcome(.providerError, AntigravityAdapter.networkError) == .network && outcome(.providerError, AntigravityAdapter.networkTimeout) == .network)
        assert(outcome(.providerError, AntigravityAdapter.offline) == .noAttempt && outcome(.providerError, AntigravityAdapter.tooOld) == .noAttempt
               && outcome(.missingClient, nil) == .noAttempt && outcome(.stale, nil) == .failed)
        assert(outcome(.needsAuth, AntigravityAdapter.signIn) == .signedOut && outcome(.ok, nil) == .report)
        var empty = AgyPause()   // Sol's probe: "returned no usage" used to leave the gate open every poll
        assert(poll(&empty) { _ in agSnap(.providerError, AntigravityAdapter.noUsage) } == [0, 32],
               "a run that exits with no usage is a failure like a stall: one run half an hour on, then none")
        var flaky = AgyPause()
        assert(poll(&flaky) { _ in agSnap(.providerError, AntigravityAdapter.networkError) } == [0, 16, 48, 110],
               "a quick network error spends the same budget as a network timeout")
        var lost = AgyPause()
        assert(poll(&lost) { _ in .noAnswer(.antigravity) } == [0, 32], "a fetch that never answered is taken for a stall")
        var clicked = AgyPause()
        _ = poll(&clicked, to: 300) { _ in netTimeout }
        clicked.manualRefresh(whileRefreshing: false)
        assert(poll(&clicked, from: 302, to: 340) { _ in netTimeout } == [302, 318], "a Refresh gives the budget back")
        // A killed run's cause, from its output and log. agy logs two not-signed-in lines at every start, working runs
        // too, so those are taken out; any other sign of a sign-in wins over network errors.
        func killed(log: String, out: String = "", survived: Bool = false, complete: Bool = true) -> AntigravityAdapter.Cause {
            AntigravityAdapter.cause(of: .init(out: Data(out.utf8), log: Data(log.utf8), killed: true, survived: survived,
                                               logComplete: complete))
        }
        let everyStart = """
            W1118 12:00:14.477407 52 cache.go:157] Cache(loadCodeAssistResponse): Singleflight refresh failed: error getting token source: You are not logged into Antigravity.
            I1118 11:51:22.380860 225 quota_manager.go:36] doRefreshQuota: skipped (not logged in)

            """
        let dns = everyStart + "W1117 16:52:25.926553 112832 cache.go:157] Post \"https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels\": dial tcp: lookup daily-cloudcode-pa.googleapis.com: i/o timeout\n"
        assert(killed(log: dns) == .network, "a network error in a whole log is a network hang")
        assert(killed(log: "Get \"https://aicode.googleapis.com/v1alpha:fetchConfig\": context deadline exceeded") == .network)
        assert(killed(log: everyStart) == .stalled, "agy's every-start lines alone are neither a sign-out nor the network")
        assert(killed(log: dns + "Opening browser to authenticate with Google...\nWaiting for authentication (timeout 60s)...\n") == .signedOut,
               "a real sign-in wait is a sign-out even with network errors")
        assert(killed(log: dns + "Please visit the following URL to authorize the application:\n") == .signedOut)
        assert(killed(log: "authentication required\ndial tcp: i/o timeout\n") == .signedOut, "Sol's mixed auth and network log")
        assert(killed(log: dns, out: "Please sign in to continue") == .signedOut, "a sign-in in the output counts too")
        assert(killed(log: "") == .stalled && killed(log: "", out: "dial tcp: i/o timeout") == .stalled, "no log is a stall")
        assert(killed(log: dns, survived: true) == .stalled, "a run that outlived SIGKILL is a stall")
        assert(killed(log: dns, complete: false) == .stalled, "a log not read whole is never taken for the network")
        let longLog = dir.appendingPathComponent("long.log")
        try Data(("Opening browser to authenticate with Google...\n" + String(repeating: "x", count: 5_000) + "\ndial tcp: i/o timeout\n").utf8).write(to: longLog)
        let (headAndTail, whole) = AntigravityAdapter.readLog(longLog, limit: 1_000)
        assert(!whole && headAndTail.count == 1_000 && killed(log: String(decoding: headAndTail, as: UTF8.self), complete: whole) == .signedOut,
               "past the limit, the log's start and end are both read: an early sign-in line isn't lost")
        try Data((String(repeating: "x", count: 2_000) + "Opening browser to authenticate...\n" + String(repeating: "x", count: 2_000) + "\ndial tcp: i/o timeout\n").utf8).write(to: longLog)
        let (middleLost, _) = AntigravityAdapter.readLog(longLog, limit: 1_000)
        assert(killed(log: String(decoding: middleLost, as: UTF8.self), complete: false) == .stalled,
               "a sign-in line lost in the middle still never makes it the network")
        // A run past its timeout is killed and hands back its own agy.log; one that finishes hands back no log. `run`
        // returns only once the stand-in and everything it started are gone, whatever they do with SIGTERM.
        func agyRun(_ script: String, timeout: Duration = .seconds(1), cancelAfter: TimeInterval? = nil) -> AntigravityAdapter.Run? {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: AntigravityAdapter.Run?
            let task = Task.detached {
                result = await AntigravityAdapter.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], timeout: timeout)
                done.signal()
            }
            if let cancelAfter { Thread.sleep(forTimeInterval: cancelAfter); task.cancel() }
            done.wait()
            return result
        }
        func pids(_ run: AntigravityAdapter.Run?) -> [pid_t] {
            String(decoding: run?.out ?? Data(), as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
        }
        func gone(_ pid: pid_t) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }
        let hung = agyRun("echo 'dial tcp: lookup example.com: i/o timeout' > agy.log; exec sleep 30")
        assert(hung?.killed == true && hung?.survived == false && hung.map(AntigravityAdapter.cause) == .network,
               "a killed run's log is read before its folder goes")
        let sols = dir.appendingPathComponent("sol-fixture")   // Sol's probe: an early sign-in line, 70 KB, then the network
        try Data(("Opening browser to authenticate with Google...\n" + String(repeating: "x", count: 70_000) + "\ndial tcp: i/o timeout\n").utf8).write(to: sols)
        let early = agyRun("cat '\(sols.path)' > agy.log; exec sleep 30")
        assert(early?.killed == true && early?.logComplete == true && early.map(AntigravityAdapter.cause) == .signedOut,
               "the real kill path keeps an early sign-in line: a sign-out, not the network")
        let quick = agyRun("echo 'dial tcp: i/o timeout' > agy.log; echo ok")
        assert(quick?.killed == false && quick.map { String(decoding: $0.out, as: UTF8.self) } == "ok\n"
               && quick.map(AntigravityAdapter.cause) == .network, "a run that exits by itself hands back its log too")
        // Sol's round-3 probe: agy says it's waiting for a sign-in and exits 1 at once. That is a sign-out, read from
        // stderr and the log, whereas the old exit-path check saw nothing and the gate stayed open every poll.
        let quickSignIn = agyRun("""
            printf '%s\\n' 'Opening browser to authenticate with Google...' > agy.log
            printf '%s\\n' 'Waiting for authentication (timeout 60s)...' >&2
            exit 1
            """)
        assert(quickSignIn?.killed == false && quickSignIn?.log.isEmpty == false && quickSignIn.map(AntigravityAdapter.cause) == .signedOut,
               "a quick sign-in exit is a sign-out")
        let exitedOffline = agyRun("echo 'dial tcp: lookup example.com: no such host' > agy.log; exit 1")
        assert(exitedOffline.map(AntigravityAdapter.cause) == .network, "a quick exit on a network error is the network")
        assert(agyRun("exec sleep 30")?.log.isEmpty == true, "a killed run without a log hands back none")
        let late = dir.appendingPathComponent("outlived-pulse")
        let stubborn = agyRun("""
            trap '' TERM; echo $$; (sleep 30; echo late > '\(late.path)') & echo $!
            echo 'dial tcp: i/o timeout' > agy.log; sleep 30; echo late > '\(late.path)'
            """)
        assert(stubborn?.killed == true && stubborn?.survived == false && pids(stubborn).count == 2,
               "a child that ignores SIGTERM is killed (\(String(describing: stubborn)))")
        assert(pids(stubborn).allSatisfy(gone), "run returns only after the child and its descendant are gone")
        Thread.sleep(forTimeInterval: 0.5)
        assert(!fm.fileExists(atPath: late.path), "nothing in agy's group outlives its run")
        // Sol's round-3 case: agy dies at SIGTERM while a descendant that ignores it holds the group. agy stays unreaped
        // until the group's SIGKILL, so that signal can only reach this group, and the descendant gets it.
        let orphan = dir.appendingPathComponent("outlived-its-leader")
        let leaderFirst = agyRun("""
            (trap '' TERM; sleep 30; echo late > '\(orphan.path)') & echo $!
            echo 'dial tcp: i/o timeout' > agy.log; exec sleep 30
            """)
        assert(leaderFirst?.killed == true && leaderFirst?.survived == false && pids(leaderFirst).count == 1
               && pids(leaderFirst).allSatisfy(gone), "a descendant left holding the group after agy exits still gets SIGKILL")
        Thread.sleep(forTimeInterval: 0.5)
        assert(!fm.fileExists(atPath: orphan.path))
        let flushed = agyRun("trap 'echo \"dial tcp: i/o timeout\" >> agy.log; exit 0' TERM; echo starting > agy.log; sleep 30 & wait")
        assert(flushed?.killed == true && String(decoding: flushed?.log ?? Data(), as: UTF8.self).contains("dial tcp"),
               "a line agy writes as SIGTERM lands is in the log Pulse reads")
        let started = ContinuousClock.now
        let cancelled = agyRun("echo $$; exec sleep 30", timeout: .seconds(30), cancelAfter: 0.3)
        assert(cancelled?.killed == true && ContinuousClock.now - started < .seconds(5) && pids(cancelled).allSatisfy(gone),
               "a cancelled fetch still ends agy and waits for it")
        // A failure after a good report keeps the windows, shown stale with the failure's own reason.
        var good = agSnap(.ok, nil); good.windows = [UsageWindow(id: "weekly_all", label: "Weekly", percentUsed: 40, resetsAt: nil)]
        let stalled = agSnap(.providerError, AntigravityAdapter.stalled).staleKeeping(good)
        assert(stalled.health == .stale && stalled.windows.count == 1 && stalled.healthMessage?.contains("click Refresh") == true,
               "a stall after a good report still says what to do (got \(stalled.healthMessage ?? "nil"))")
        assert(good.staleKeeping(good).healthMessage?.hasPrefix("Stale — last updated") == true, "no reason, no suffix")
        // A relaunch: AppState saves the gate's own hold in state.json and restores it at launch, round-tripped here
        // through JSON as it is on disk. The card's snapshot plays no part, so an offline skip can't rewrite it.
        func relaunched(_ before: AgyPause, marker: Date? = m0) throws -> AgyPause {
            let saved = try JSONDecoder().decode(AgyPause.Hold?.self, from: JSONEncoder().encode(before.hold))
            return AgyPause(restoring: saved, now: t0, marker: marker)
        }
        var stalledOnce = AgyPause(); stalledOnce.update(with: stall, now: t0, marker: m0)
        var afterStall = try relaunched(stalledOnce)
        assert(afterStall.paused, "a stall still holds agy back after a relaunch")
        afterStall.passStarted(now: at(120), marker: m0)
        assert(afterStall.paused)
        afterStall.passStarted(now: at(30 * 60), marker: m0)
        assert(!afterStall.paused, "and it gets its one timed run, counted from the launch")
        var spentAll = AgyPause()
        _ = poll(&spentAll) { _ in stall }
        var afterSpent = try relaunched(spentAll)
        afterSpent.passStarted(now: at(86_400), marker: m0)
        assert(afterSpent.paused, "a budget spent before the quit stays spent after it")
        var signedOutOnce = AgyPause(); signedOutOnce.update(with: agSnap(.needsAuth, AntigravityAdapter.signIn), now: t0, marker: m0)
        var afterSignOut = try relaunched(signedOutOnce)
        afterSignOut.passStarted(now: at(86_400), marker: m0 + 1)
        assert(afterSignOut.paused, "a saved sign-out waits for a Refresh after a relaunch")
        var afterGood = try relaunched(AgyPause())
        afterGood.passStarted(now: at(1), marker: m0)
        assert(!afterGood.paused && AgyPause().hold == nil, "with nothing held, agy runs at launch")
        // Sol's round-3 probe: a network failure's timed run ends at the offline skip twice, which rewrites the card's
        // reason; the hold is untouched, so the relaunch still waits.
        var skippedTwice = AgyPause()
        skippedTwice.update(with: netTimeout, now: t0, marker: m0)
        skippedTwice.passStarted(now: at(960), marker: m0); assert(!skippedTwice.paused)
        skippedTwice.update(with: skipped, now: at(960), marker: m0)
        skippedTwice.passStarted(now: at(960), marker: m0)
        skippedTwice.update(with: skipped, now: at(960), marker: m0)
        assert(skippedTwice.hold == AgyPause.Hold(network: true, spent: 0))
        var afterOutage = try relaunched(skippedTwice)
        afterOutage.passStarted(now: at(14 * 60), marker: m0)
        assert(afterOutage.paused, "after offline skips, a relaunch still waits the network failure's 15 minutes")
        // Nothing starts for a fetch already cancelled, or when its isolation can't be set up.
        let neverRan = dir.appendingPathComponent("never-ran")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var preCancelled: AntigravityAdapter.Run? = AntigravityAdapter.Run()
        Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            preCancelled = await AntigravityAdapter.run(URL(fileURLWithPath: "/bin/sh"),
                                                        ["-c", "echo ran > '\(neverRan.path)'; exec sleep 30"], timeout: .seconds(30))
            done.signal()
        }
        done.wait()
        Thread.sleep(forTimeInterval: 0.3)
        assert(preCancelled == nil && !fm.fileExists(atPath: neverRan.path), "a cancelled fetch never spawns agy")
        let nowhere = dir.appendingPathComponent("no-such-folder")
        for (out, cwd) in [(nowhere.appendingPathComponent("out"), dir), (dir.appendingPathComponent("out"), nowhere)] {
            let pid = AntigravityAdapter.spawnInOwnGroup(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo ran > '\(neverRan.path)'"],
                                                         in: cwd, out: out, err: dir.appendingPathComponent("err"))
            Thread.sleep(forTimeInterval: 0.3)
            assert(pid == nil && !fm.fileExists(atPath: neverRan.path), "a spawn whose output or folder can't be set up starts nothing")
        }
        // A run that came back `survived` leaves its group in the registry: no agy starts until that group is gone.
        // (Nothing here can outlive SIGKILL, so a live group stands in for one.)
        let lingering = AntigravityAdapter.spawnInOwnGroup(URL(fileURLWithPath: "/bin/sh"), ["-c", "exec sleep 30"], in: dir,
                                                           out: dir.appendingPathComponent("out2"), err: dir.appendingPathComponent("err2"))!
        AntigravityAdapter.survivors.withLock { _ = $0.insert(lingering) }
        assert(agyRun("echo ok") == nil, "no run starts while a survivor's group is still there")
        kill(-lingering, SIGKILL)
        Thread.sleep(forTimeInterval: 0.3)
        assert(agyRun("echo ok").map { String(decoding: $0.out, as: UTF8.self) } == "ok\n"
               && AntigravityAdapter.survivors.withLock { $0.isEmpty }, "once it's gone, runs start again")
        let netStale = agSnap(.providerError, AntigravityAdapter.networkTimeout).staleKeeping(good)
        assert(netStale.health == .stale && netStale.windows.count == 1 && netStale.healthMessage?.contains("(network)") == true,
               "a network timeout keeps the last windows, stale, with its reason (got \(netStale.healthMessage ?? "nil"))")
        print("Security checks passed: private atomic auth writes, redirect/cache policy, shortcut release and the agy usage guard")
    }
}
