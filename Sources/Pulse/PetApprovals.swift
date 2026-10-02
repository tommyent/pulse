import AppKit
import CryptoKit
import os

private let log = Logger(subsystem: "app.pulse", category: "approvals")

struct PetApproval {
    /// `dismiss` decides nothing; for a consent request `deny` is a decision the server remembers.
    enum Decision: String { case deny, allow, always, dismiss }
    let id: AnyHashable
    let thread: String
    let title: String
    let detail: String
    let allowed: [String: Any]
    let denied: [String: Any]
    let cancelled: [String: Any]   // Stop, New conversation, Esc on a consent prompt
    let taskScope: Bool
    let consent: Bool   // an MCP tool's yes/no consent request, e.g. Browser Use site access
    let rememberKey: String?
    /// Multiple-choice questions from Codex (`item/tool/requestUserInput`); the chosen labels land in `picks`.
    struct Question { let id, header, text: String; let options: [(label: String, detail: String)] }
    final class Picks { var answers: [String: String] = [:] }
    var questions: [Question] = []
    /// Set when a helper the pet started is asking: it can use existing remembered approvals, never create one.
    var helper: String?
    var canRemember: Bool { rememberKey != nil && helper == nil }
    let picks = Picks()

    init?(id: AnyHashable, method: String, params p: [String: Any], item: [String: Any]?) {
        guard let thread = p["threadId"] as? String else { return nil }   // consent may arrive outside a turn
        self.id = id; self.thread = thread
        var details = [String]()
        var rule = p
        // Identity and display-only fields do not broaden the operation being remembered.
        for field in ["threadId", "turnId", "itemId", "startedAtMs", "approvalId", "reason", "commandActions", "availableDecisions", "proposedExecpolicyAmendment", "proposedNetworkPolicyAmendments"] { rule[field] = nil }
        rule["method"] = method
        rule["cwd"] = p["cwd"] ?? item?["cwd"]
        if let reason = p["reason"] as? String { details.append(reason) }
        if let cwd = (p["cwd"] ?? item?["cwd"]) as? String { details.append("Working folder: \(cwd)") }
        switch method {
        case "item/commandExecution/requestApproval":
            if let options = p["availableDecisions"] as? [Any], !options.contains(where: { $0 as? String == "accept" }) { return nil }
            if let network = p["networkApprovalContext"] as? [String: Any] {
                title = "Allow network access?"
                details.append("Network destination:\n" + Self.json(network))
            } else {
                guard let command = (p["command"] ?? item?["command"]) as? String, !command.isEmpty else { return nil }
                title = p["kind"] as? String == "writeStdin" ? "Allow terminal input?" : "Allow this command?"
                details.append(command)
                rule["command"] = command
            }
            if let permissions = p["additionalPermissions"] as? [String: Any] {
                details.append("Requested access:\n" + Self.json(permissions))
            }
            details.append("Allow once approves this request. Always allow remembers this exact command or network destination, working folder and requested access.")
            allowed = ["decision": "accept"]; denied = ["decision": "decline"]; cancelled = ["decision": "cancel"]
            taskScope = false; consent = false
        case "item/fileChange/requestApproval":
            guard let changes = item?["changes"] as? [[String: Any]], !changes.isEmpty else { return nil }
            title = "Allow these file changes?"
            details.append(Self.json(changes)) // Includes paths, operation kinds, moves and complete diffs.
            rule["changes"] = changes.map { $0.filter { $0.key != "diff" } }
            details.append("Allow once approves these changes. Always allow remembers these exact paths and operation types, including future edits with different content.")
            allowed = ["decision": "accept"]; denied = ["decision": "decline"]; cancelled = ["decision": "cancel"]
            taskScope = false; consent = false
        case "item/permissions/requestApproval":
            guard let permissions = p["permissions"] as? [String: Any], !permissions.isEmpty else { return nil }
            title = "Allow access for this task?"
            details.append("Requested access:\n" + Self.json(permissions))
            details.append("Allow for this task expires when the current Codex turn ends. Always allow also approves future requests for this same access, including the listed folders.")
            allowed = ["permissions": permissions.filter { !($0.value is NSNull) }, "scope": "turn"]
            denied = ["permissions": [String: Any](), "scope": "turn"]; cancelled = denied   // no separate cancel reply exists
            taskScope = true; consent = false
        case "mcpServer/elicitation/request":
            // Only plain yes/no consent. Forms, links, sign-ins, verification codes, device checks and
            // auto-review prechecks need the Codex app, so they are cancelled, never answered here.
            // The schema must be well formed and ask for nothing: accepting sends no content.
            let meta = p["_meta"] as? [String: Any] ?? [:]
            guard ["form", "openai/form", "openaiForm"].contains(p["mode"] as? String ?? ""),
                  let schema = p["requestedSchema"] as? [String: Any], schema["type"] as? String == "object",
                  (schema["properties"] as? [String: Any])?.isEmpty == true,
                  schema["required"] == nil || schema["required"] is NSNull || (schema["required"] as? [Any])?.isEmpty == true,
                  let message = p["message"] as? String, !message.isEmpty,
                  meta["codex_approval_kind"] as? String == "mcp_tool_call",
                  meta["codex_requires_user_input"] as? Bool != true,
                  meta["codex_strict_auto_review"] as? Bool != true else { return nil }
            title = message
            let source = (meta["connector_name"] ?? p["serverName"]) as? String ?? "A Codex tool"
            details.append("\(source): \((meta["tool_title"] ?? meta["tool_name"]) as? String ?? "tool request")")
            if let params = meta["tool_params"] { details.append("Request:\n" + Self.json(params)) }
            if meta["tool_name"] as? String == "access_browser_origin" {
                details.append("Allow or Deny applies to this site for the rest of this conversation. Not now decides nothing.")
            }
            allowed = ["action": "accept"]; denied = ["action": "decline"]; cancelled = ["action": "cancel"]
            taskScope = false; consent = true
        case "item/tool/requestUserInput":
            // Multiple choice only, all questions or none: a partial answer would silently drop some.
            // Secret questions never come through Pulse.
            let asked = p["questions"] as? [[String: Any]] ?? []
            let parsed = asked.compactMap(Self.question)
            guard !parsed.isEmpty, parsed.count == asked.count, Set(parsed.map(\.id)).count == parsed.count else { return nil }
            questions = parsed
            title = "Codex has a question"
            details.append(contentsOf: questions.map(\.text))
            allowed = [:]; denied = ["answers": [String: Any]()]; cancelled = denied   // answers come from `picks`
            taskScope = false; consent = false
        default: return nil
        }
        // Store only a digest, never shell commands or their potential secret arguments.
        // Consent and answers are never remembered by Pulse: the tool keeps its own decisions.
        if consent || !questions.isEmpty || p["kind"] as? String == "writeStdin" { rememberKey = nil }
        else if let data = try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]) {
            rememberKey = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else { rememberKey = nil }
        if rememberKey != nil { details.append("Remembered approvals persist across restarts. Reset them in Settings → Codex voice.") }
        detail = details.joined(separator: "\n\n")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "Unavailable" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A question Pulse can answer faithfully: not secret, no free-text "Other" (the chat note covers
    /// free text), with distinct, non-empty choices.
    private static func question(_ q: [String: Any]) -> Question? {
        guard let id = q["id"] as? String, !id.isEmpty, let text = q["question"] as? String, !text.isEmpty,
              q["isSecret"] as? Bool != true, q["isOther"] as? Bool != true,
              let options = q["options"] as? [[String: Any]] else { return nil }
        let choices = options.compactMap { o in (o["label"] as? String).flatMap { $0.isEmpty ? nil : ($0, o["description"] as? String ?? "") } }
        guard !choices.isEmpty, choices.count == options.count, Set(choices.map(\.0)).count == choices.count else { return nil }
        return Question(id: id, header: q["header"] as? String ?? "", text: text, options: choices)
    }

    func reply(_ decision: Decision) -> [String: Any] {
        switch decision {
        case .deny: denied
        case .dismiss: cancelled
        case .allow, .always: questions.isEmpty ? allowed : ["answers": picks.answers.mapValues { ["answers": [$0]] }]
        }
    }

    /// The chat line for a request Pulse cannot show, so a cancelled or unanswered request never looks like a hang.
    static func unshowableNote(method: String, params p: [String: Any]) -> String? {
        switch method {
        case "mcpServer/elicitation/request":
            let meta = p["_meta"] as? [String: Any] ?? [:]
            let source = (meta["connector_name"] ?? p["serverName"]) as? String ?? "A Codex tool"
            let ask = (p["message"] ?? p["title"]) as? String ?? "a request"
            return "\(source) asked for something Pulse can't show (“\(ask)”), so Pulse cancelled it without denying anything. To finish it, run the task in Codex CLI or the ChatGPT desktop app."
        case "item/tool/requestUserInput":
            let asked = p["questions"] as? [[String: Any]] ?? []
            if asked.contains(where: { $0["isSecret"] as? Bool == true }) {
                return "Codex asked for something secret, which Pulse never takes in chat or voice, so Codex continues without it. Don't type it here; run the task in a Codex client that supports secret entry."
            }
            let first = asked.first?["question"] as? String ?? "a question"
            let more = asked.count > 1 ? " and \(asked.count - 1) more" : ""
            return "Codex asked “\(first)”\(more), which Pulse can't show as choices, so Codex continues without an answer. Reply in this chat to answer."
        default: return nil
        }
    }

    @MainActor
    func show() -> Decision {
        if !questions.isEmpty { return ask() }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = helper.map { "A helper Codex started (\($0)) is asking for your permission. Helpers can't create remembered approvals." }
            ?? "Codex in Pulse is asking for your permission."
        // Esc picks the first button: a consent tool remembers Deny, so Esc there must decide nothing.
        let choices: [(String, Decision)] = consent
            ? [("Not now", .dismiss), ("Deny", .deny), ("Allow", .allow)]
            : [("Deny", .deny), (taskScope ? "Allow for this task" : "Allow once", .allow)] + (canRemember ? [("Always allow", .always)] : [])
        for (title, _) in choices { alert.addButton(withTitle: title) }
        alert.buttons[0].keyEquivalent = "\u{1b}"
        for button in alert.buttons.dropFirst() { button.keyEquivalent = "" } // Enter while typing must not approve an unexpected prompt.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = detail
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel("Requested action and access")
        scroll.documentView = text
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index].1 : choices[0].1   // abort: the first, safest choice
    }

    /// One alert per question: Skip (Esc) or an option. Enter picks nothing.
    @MainActor
    private func ask() -> Decision {
        for q in questions {
            let alert = NSAlert()
            alert.messageText = q.header.isEmpty ? title : q.header
            alert.informativeText = ([q.text] + q.options.filter { !$0.detail.isEmpty }.map { "\($0.label): \($0.detail)" }).joined(separator: "\n\n")
            alert.addButton(withTitle: "Skip").keyEquivalent = "\u{1b}"
            for option in q.options { alert.addButton(withTitle: option.label).keyEquivalent = "" }
            NSApp.activate(ignoringOtherApps: true)
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0 else { return .dismiss }   // withdrawn while open
            if index > 0, index <= q.options.count { picks.answers[q.id] = q.options[index - 1].label }
        }
        return picks.answers.isEmpty ? .dismiss : .allow
    }
}

/// One native prompt at a time, shared by text, voice and their delegated agent requests.
@MainActor
final class PetApprovals {
    static let shared = PetApprovals()
    var present: (PetApproval) -> PetApproval.Decision = { $0.show() }
    var onPromptOpened: (PetApproval) -> Void = { _ in }
    var helperOf: (String) -> String? = { _ in nil }   // the asking thread's helper name; nil for the pet itself
    var defaults = UserDefaults.standard
    private let savedKey = "petRememberedApprovals"
    private var queue: [PetApproval] = []
    private var active: PetApproval?
    private var showing = false
    private var items: [String: [String: Any]] = [:]

    func receive(id: Any, method: String, params: [String: Any]) {
        let tool = (params["_meta"] as? [String: Any])?["tool_name"] as? String ?? "-"
        log.info("request \(String(describing: id), privacy: .public) \(method, privacy: .public) tool=\(tool, privacy: .public)")
        guard let id = id as? AnyHashable,
              var approval = PetApproval(id: id, method: method, params: params,
                                         item: items[key(params)]) else {
            switch method {
            case "mcpServer/elicitation/request":
                // The app-server records an error reply as the user's decline; cancel decides nothing.
                CodexAppServer.shared.respond(id: id, result: ["action": "cancel"])
            case "item/tool/requestUserInput":
                CodexAppServer.shared.respond(id: id, result: ["answers": [String: Any]()])
            default:
                CodexAppServer.shared.respond(id: id, error: "Pulse cannot review this request; no permission was granted.")
            }
            log.info("reply \(String(describing: id), privacy: .public) unshowable")
            if let note = PetApproval.unshowableNote(method: method, params: params) {
                CodexAppServer.shared.onNotification?("pulse/note", ["text": note])
            }
            return
        }
        approval.helper = helperOf(approval.thread)
        queue.append(approval)
        schedule()
    }

    /// Enter the modal from a run-loop callout: a GCD block would hold the serial main queue,
    /// delaying microphone mute, voice cues and withdrawn requests until the user answers.
    /// Default mode keeps the next prompt outside the current modal's nested event loop.
    private func schedule() {
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { self.showNext() } }
    }

    private func showNext() {
        guard !showing, !queue.isEmpty else { return }
        showing = true
        let request = queue.removeFirst()
        active = request
        let remembered = isRemembered(request)
        if !remembered { onPromptOpened(request) }
        let decision: PetApproval.Decision = remembered ? .allow : present(request)
        // A completed turn, cancellation or disconnected server invalidates an open prompt.
        if active?.id == request.id {
            if decision == .always { remember(request) }   // a helper's .always is only Allow once
            CodexAppServer.shared.respond(id: request.id.base, result: request.reply(decision))
            log.info("reply \(String(describing: request.id.base), privacy: .public) \(decision.rawValue, privacy: .public)")
            active = nil
        }
        showing = false
        if !queue.isEmpty { schedule() }
    }

    func isRemembered(_ request: PetApproval) -> Bool {
        guard let key = request.rememberKey else { return false }
        return defaults.stringArray(forKey: savedKey)?.contains(key) == true
    }

    func remember(_ request: PetApproval) {
        guard request.canRemember, let key = request.rememberKey else { return }
        var keys = Set(defaults.stringArray(forKey: savedKey) ?? [])
        keys.insert(key)
        defaults.set(Array(keys), forKey: savedKey)
    }

    func resetRemembered() { defaults.removeObject(forKey: savedKey) }

    func observe(_ method: String, _ p: [String: Any]) {
        if method == "item/started", let item = p["item"] as? [String: Any], let id = item["id"] as? String {
            var identity = p; identity["itemId"] = id
            items[key(identity)] = item
        } else if method == "item/completed", let item = p["item"] as? [String: Any], let id = item["id"] as? String {
            var identity = p; identity["itemId"] = id
            items[key(identity)] = nil
        } else if method == "serverRequest/resolved", let id = p["requestId"] as? AnyHashable {
            cancel(where: { $0.id == id }, reply: false)
        } else if method == "turn/completed", let thread = p["threadId"] as? String {
            cancel(where: { $0.thread == thread }, reply: false)
        }
    }

    func cancelAll(reply: Bool = true) {
        cancel(where: { _ in true }, reply: reply)
        items = [:]
    }

    private func cancel(where matches: (PetApproval) -> Bool, reply: Bool) {
        var removed = queue.filter(matches)
        queue.removeAll(where: matches)
        if let request = active, matches(request) {
            removed.append(request)
            active = nil
            NSApp?.abortModal()
        }
        if reply {   // Stop or New conversation: nobody decided, so nothing may be remembered as a denial
            for request in removed {
                CodexAppServer.shared.respond(id: request.id.base, result: request.cancelled)
                log.info("reply \(String(describing: request.id.base), privacy: .public) cancel (stopped)")
            }
        }
    }

    private func key(_ p: [String: Any]) -> String {
        "\(p["threadId"] as? String ?? "")/\(p["itemId"] as? String ?? "")"
    }
}
