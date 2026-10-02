import AppKit

// Only the approval UI is real. No Codex process, browser, microphone or saved permissions.
@MainActor
final class CodexAppServer {
    static let shared = CodexAppServer()
    var onNotification: ((String, [String: Any]) -> Void)?
    var replies: [(Int, [String: Any])] = []
    func respond(id: Any, result: [String: Any]) { replies.append((id as! Int, result)) }
    func respond(id: Any, error: String) { fatalError("Unexpected error: \(error)") }
}

@main
enum ApprovalPresentationChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let approvals = PetApprovals.shared
        var shown: [Int] = []
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        approvals.onPromptOpened = { shown.append($0.id.base as! Int) }
        let params: [String: Any] = [
            "threadId": "ui-check", "mode": "form", "message": "Pulse approval timing check",
            "requestedSchema": ["type": "object", "properties": [String: Any]()],
            "_meta": ["codex_approval_kind": "mcp_tool_call", "connector_name": "Isolated preview",
                      "tool_title": "No browser or microphone. This prompt closes itself."]
        ]

        // A native run-loop timer still runs if the presenting code blocks GCD. It makes a regression
        // fail with a message instead of leaving a real modal window hanging on the screen.
        let began = ProcessInfo.processInfo.systemUptime
        let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.systemUptime - began > 3 {
                    check(false, "Presentation blocked main-thread work")
                    app.abortModal()
                }
                if ProcessInfo.processInfo.systemUptime - began > 6 { exit(1) }
            }
        }
        RunLoop.main.add(watchdog, forMode: .default)
        RunLoop.main.add(watchdog, forMode: .modalPanel)

        approvals.receive(id: 1, method: "mcpServer/elicitation/request", params: params)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            check(shown == [1] && app.modalWindow != nil, "MainActor task must run while the first prompt is open")
            var releaseRan = false
            DispatchQueue.main.async {   // the same delivery path as HotKey.onRelease
                releaseRan = true
                check(app.modalWindow != nil, "Key-release callback must run before the prompt closes")
            }
            try? await Task.sleep(for: .milliseconds(50))
            check(releaseRan, "The prompt must not hold the hotkey callback")
            approvals.receive(id: 2, method: "mcpServer/elicitation/request", params: params)
            try? await Task.sleep(for: .milliseconds(100))
            check(shown == [1], "A queued request must not nest another prompt")

            approvals.observe("serverRequest/resolved", ["requestId": 1])
            try? await Task.sleep(for: .milliseconds(150))
            check(shown == [1, 2] && app.modalWindow != nil, "A withdrawn prompt must close and let the next one open")
            check(CodexAppServer.shared.replies.isEmpty, "A withdrawn request must receive no late answer")
            approvals.cancelAll()
            try? await Task.sleep(for: .milliseconds(100))
            let replies = CodexAppServer.shared.replies
            check(app.modalWindow == nil, "Stop must close the active prompt")
            check(replies.count == 1 && replies[0].0 == 2 && replies[0].1["action"] as? String == "cancel",
                  "Stop must cancel the remaining request exactly once, without denying it")
            watchdog.invalidate()
            if failures.isEmpty {
                print("Approval presentation checks passed: main-thread voice controls, serial prompts, withdrawal and Stop")
            } else {
                for failure in failures { print("FAIL: \(failure)") }
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
