// Run: swiftc Sources/Pulse/Models.swift Checks/RefreshChecks.swift -o /tmp/pulse-refresh-check && /tmp/pulse-refresh-check
import Foundation

/// Stands in for the providers: counts each start, and holds a provider's fetches until released, ignoring cancellation
/// as one blocked on a `security` prompt does.
private final class Providers: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<AccountID> = []
    private var cancellable: Set<AccountID> = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var counts: [AccountID: Int] = [:]

    func hold(_ id: AccountID) { lock.withLock { _ = held.insert(id) } }
    func holdUntilCancelled(_ id: AccountID) { lock.withLock { _ = cancellable.insert(id) } }
    func starts(_ id: AccountID) -> Int { lock.withLock { counts[id] ?? 0 } }
    func release() {
        let released = lock.withLock { defer { held = []; waiting = [] }; return waiting }
        released.forEach { $0.resume() }
    }

    @Sendable func fetch(_ id: AccountID) async -> AccountSnapshot {
        let (number, isHeld, isCancellable) = lock.withLock {
            counts[id, default: 0] += 1
            return (counts[id] ?? 0, held.contains(id), cancellable.contains(id))
        }
        if isHeld { await withCheckedContinuation { c in lock.withLock { waiting.append(c) } } }
        if isCancellable { try? await Task.sleep(for: .seconds(3600)); lock.withLock { _ = cancellable.remove(id) } }
        return AccountSnapshot(id: id, displayName: id.displayName, planLabel: "", health: .ok, windows: [],
                               fetchedAt: .now, source: .mock, detail: "answer \(number)")
    }
}

@main
enum RefreshChecks {
    @MainActor static func main() async {
        let providers = Providers()
        let fetches = ProviderFetches(limit: .milliseconds(300), fetch: providers.fetch)

        /// One pass of AppState.refreshAll: every account, in a task group that waits for all of them.
        func pass(_ ids: [AccountID]) async -> (answers: [AccountID: AccountSnapshot], seconds: TimeInterval) {
            let start = Date()
            let answers = await withTaskGroup(of: AccountSnapshot?.self) { group in
                for id in ids { group.addTask { await fetches.answer(id) } }
                var out: [AccountID: AccountSnapshot] = [:]
                for await case let snap? in group { out[snap.id] = snap }
                return out
            }
            return (answers, Date().timeIntervalSince(start))
        }

        let quick = await pass([.claude, .codex])
        assert(quick.answers[.claude]?.health == .ok && quick.answers[.codex]?.health == .ok, "answers pass through")
        assert(quick.seconds < 0.25, "a pass doesn't wait out the limit when everyone answered: \(quick.seconds)")

        // A stuck provider: the pass still ends, at the limit, with a failure for it and the others' real answers.
        providers.hold(.claude)
        let stuck = await pass([.claude, .codex])
        assert(stuck.seconds >= 0.25 && stuck.seconds < 2, "the pass ends at the limit: \(stuck.seconds)")
        assert(stuck.answers[.claude]?.health == .providerError && stuck.answers[.claude]?.detail == "Claude didn't answer")
        assert(stuck.answers[.codex]?.health == .ok, "the others still update")

        // Still stuck: it isn't started again, and the others keep updating without waiting.
        let starts = providers.starts(.claude)
        let again = await pass([.claude, .codex])
        assert(providers.starts(.claude) == starts, "a stuck fetch isn't started a second time")
        assert(again.answers[.claude] == nil && again.answers[.codex]?.health == .ok)
        assert(again.seconds < 0.25, "skipping it costs the pass nothing: \(again.seconds)")

        // Released: its late answer goes nowhere, and the next pass fetches it again.
        providers.release()
        try? await Task.sleep(for: .milliseconds(50))
        let freed = await pass([.claude])
        assert(providers.starts(.claude) == starts + 1, "fetched again once the stuck one ended")
        assert(freed.answers[.claude]?.health == .ok && freed.answers[.claude]?.detail == "answer \(starts + 1)", "the new answer, not the late one")

        // A hang that honours cancellation, like a request: it's cancelled at the limit, so nothing stays stuck.
        providers.holdUntilCancelled(.grok)
        let hung = await pass([.grok])
        assert(hung.answers[.grok]?.health == .providerError)
        try? await Task.sleep(for: .milliseconds(50))
        let after = await pass([.grok])
        assert(after.answers[.grok]?.health == .ok, "a cancelled fetch doesn't block the next one")
        await sharedWaitChecks()
        print("Refresh checks passed: a stuck provider ends at its limit, isn't restarted while stuck, and never holds up the others; waiters share one load")
    }

    /// ClaudeWeb's page load: a Connect window's check and a poll can both need it.
    @MainActor static func sharedWaitChecks() async {
        final class Log { var starts = 0, woken = 0 }
        let log = Log(), wait = SharedWait()
        func waiter(limit: Duration = .seconds(30)) -> Task<Void, Never> {
            Task { @MainActor in
                await wait.join(limit: limit) { log.starts += 1 }
                log.woken += 1
            }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(30)) }

        // Two callers, one attempt: neither is woken early, and `finish` wakes both.
        let a = waiter(), b = waiter()
        await settle()
        assert(log.starts == 1 && log.woken == 0, "the second caller joins the first's load")
        wait.finish()
        _ = await (a.value, b.value)
        assert(log.woken == 2, "a finished load wakes everyone waiting on it")
        wait.finish()   // a late or second finish, with nobody waiting
        assert(log.woken == 2)

        // The limit wakes them if the load never finishes.
        let c = waiter(limit: .milliseconds(100)), d = waiter(limit: .seconds(30))
        await settle()
        _ = await (c.value, d.value)
        assert(log.starts == 2 && log.woken == 4, "the attempt's limit wakes all its waiters")

        // An earlier attempt's limit doesn't wake a later attempt's waiter.
        let e = waiter(limit: .milliseconds(100))
        await settle()
        wait.finish()
        await e.value
        let f = waiter(limit: .seconds(30))
        try? await Task.sleep(for: .milliseconds(200))
        assert(log.starts == 4 && log.woken == 5, "the first attempt's limit passed without touching the second")
        wait.finish()
        await f.value
        assert(log.woken == 6)
    }
}
