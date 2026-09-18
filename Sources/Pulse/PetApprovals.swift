import AppKit
import CryptoKit

struct PetApproval {
    enum Decision: String { case deny, allow, always }
    let id: AnyHashable
    let thread: String
    let turn: String
    let title: String
    let detail: String
    let allowed: [String: Any]
    let denied: [String: Any]
    let taskScope: Bool
    let rememberKey: String?

    init?(id: AnyHashable, method: String, params p: [String: Any], item: [String: Any]?) {
        guard let thread = p["threadId"] as? String, let turn = p["turnId"] as? String else { return nil }
        self.id = id; self.thread = thread; self.turn = turn
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
            allowed = ["decision": "accept"]; denied = ["decision": "decline"]; taskScope = false
        case "item/fileChange/requestApproval":
            guard let changes = item?["changes"] as? [[String: Any]], !changes.isEmpty else { return nil }
            title = "Allow these file changes?"
            details.append(Self.json(changes)) // Includes paths, operation kinds, moves and complete diffs.
            rule["changes"] = changes.map { $0.filter { $0.key != "diff" } }
            details.append("Allow once approves these changes. Always allow remembers these exact paths and operation types, including future edits with different content.")
            allowed = ["decision": "accept"]; denied = ["decision": "decline"]; taskScope = false
        case "item/permissions/requestApproval":
            guard let permissions = p["permissions"] as? [String: Any], !permissions.isEmpty else { return nil }
            title = "Allow access for this task?"
            details.append("Requested access:\n" + Self.json(permissions))
            details.append("Allow for this task expires when the current Codex turn ends. Always allow also approves future requests for this same access, including the listed folders.")
            allowed = ["permissions": permissions.filter { !($0.value is NSNull) }, "scope": "turn"]
            denied = ["permissions": [String: Any](), "scope": "turn"]; taskScope = true
        default: return nil
        }
        // Store only a digest, never shell commands or their potential secret arguments.
        if p["kind"] as? String == "writeStdin" { rememberKey = nil }
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

    @MainActor
    func show() -> Decision {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Codex in Pulse is asking for your permission."
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: taskScope ? "Allow for this task" : "Allow once")
        if rememberKey != nil { alert.addButton(withTitle: "Always allow") }
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalent = "" // Enter while typing must not approve an unexpected prompt.
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
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .allow
        case .alertThirdButtonReturn: return .always
        default: return .deny
        }
    }
}

/// One native prompt at a time, shared by text, voice and their delegated agent requests.
@MainActor
final class PetApprovals {
    static let shared = PetApprovals()
    var present: (PetApproval) -> PetApproval.Decision = { $0.show() }
    var defaults = UserDefaults.standard
    private let savedKey = "petRememberedApprovals"
    private var queue: [PetApproval] = []
    private var active: PetApproval?
    private var showing = false
    private var items: [String: [String: Any]] = [:]

    func receive(id: Any, method: String, params: [String: Any]) {
        guard let id = id as? AnyHashable,
              let approval = PetApproval(id: id, method: method, params: params,
                                         item: items[key(params)]) else {
            CodexAppServer.shared.respond(id: id, error: "Pulse cannot review this request; no permission was granted.")
            return
        }
        queue.append(approval)
        DispatchQueue.main.async { self.showNext() }
    }

    private func showNext() {
        guard !showing, !queue.isEmpty else { return }
        showing = true
        let request = queue.removeFirst()
        active = request
        let decision: PetApproval.Decision = isRemembered(request) ? .allow : present(request)
        // A completed turn, cancellation or disconnected server invalidates an open prompt.
        if active?.id == request.id {
            if decision == .always { remember(request) }
            CodexAppServer.shared.respond(id: request.id.base, result: decision == .deny ? request.denied : request.allowed)
            active = nil
        }
        showing = false
        if !queue.isEmpty { DispatchQueue.main.async { self.showNext() } }
    }

    func isRemembered(_ request: PetApproval) -> Bool {
        guard let key = request.rememberKey else { return false }
        return defaults.stringArray(forKey: savedKey)?.contains(key) == true
    }

    func remember(_ request: PetApproval) {
        guard let key = request.rememberKey else { return }
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
        if reply {
            for request in removed { CodexAppServer.shared.respond(id: request.id.base, result: request.denied) }
        }
    }

    private func key(_ p: [String: Any]) -> String {
        "\(p["threadId"] as? String ?? "")/\(p["itemId"] as? String ?? "")"
    }
}
