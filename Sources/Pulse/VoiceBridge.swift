import Foundation
import AppKit
import os

/// Codex's installed native voice helper owns WebRTC, microphone capture and playback.
/// Its private, same-build protocol uses length-prefixed JSON; audio never crosses this pipe.
@MainActor
final class VoiceBridge {
    static let shared = VoiceBridge()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var expected: String?
    private var deadline: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var offerWaiter: CheckedContinuation<String, Error>?
    private var generation = UUID()
    private var muted = false
    private var appliedMute: Bool?
    private var sentMute = false
    private var devicesOpen = false
    private var announcedReady = false
    private let log = Logger(subsystem: "app.pulse", category: "voice")
    /// Set when a voice start begins; cleared once audio is ready. See `mark`.
    var warmupStart: Date?

    /// Warm-up timing, one line per step: `/usr/bin/log show --last 10m --predicate 'process == "Pulse"'`
    /// (zsh's `log` builtin shadows the tool; the offline checks log under the same subsystem).
    /// Step names and elapsed time only; never SDP, transcripts or credentials.
    func mark(_ step: String) {
        guard let warmupStart else { return }
        log.notice("voice warm-up: \(step, privacy: .public) +\(Int(Date().timeIntervalSince(warmupStart) * 1000)) ms")
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VoiceBridge.shared.close() }
        }
    }

    func createOffer(muted: Bool) async throws -> String {
        close()
        self.muted = muted
        guard let codex = locateBinary("codex")?.resolvingSymlinksInPath() else {
            throw CodexAppServer.Failure.notInstalled
        }
        let root = codex.deletingLastPathComponent().deletingLastPathComponent()
        let voice = root.appendingPathComponent("codex-resources/voice")
        let binary = voice.appendingPathComponent("bin/codex-voice-host")
        guard FileManager.default.isExecutableFile(atPath: binary.path), binary.resolvingSymlinksInPath() == binary,
              let manifest = try? Data(contentsOf: voice.appendingPathComponent("manifest.json")),
              let info = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let commit = info["buildCommit"] as? String, !commit.isEmpty else {
            throw CodexAppServer.Failure.remote("Install a Codex CLI package with native voice support.")
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = binary
        child.currentDirectoryURL = root
        let allowed = Set(["HOME", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"])
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        for key in ["GST_PLUGIN_PATH", "GST_PLUGIN_PATH_1_0", "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_SYSTEM_PATH_1_0"] { environment[key] = "" }
        environment["GST_REGISTRY"] = "/dev/null"
        environment["GST_REGISTRY_UPDATE"] = "no"
        environment["GST_REGISTRY_FORK"] = "no"
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let run = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                if data.isEmpty { self.fail("Native voice helper closed.") }
                else { self.consume(data) }
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.fail("Native voice helper stopped.")
            }
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        do { try child.run() } catch { close(); throw error }
        return try await withCheckedThrowingContinuation { continuation in
            offerWaiter = continuation
            send(["type": "hello", "protocol": 1, "buildCommit": commit], expecting: "ready", seconds: 30)
        }
    }

    func accept(answer: String) {
        guard process != nil, expected == nil, !devicesOpen else { return }
        send(["type": "applyAnswer", "sdp": answer], expecting: "transportReady", seconds: 20)
    }

    func setMuted(_ value: Bool) {
        muted = value
        updateControls()
    }

    func close() {
        generation = UUID()
        deadline?.cancel(); deadline = nil
        poll?.cancel(); poll = nil
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil
        buffer = Data(); expected = nil
        devicesOpen = false; announcedReady = false; appliedMute = nil
        let waiter = offerWaiter; offerWaiter = nil
        waiter?.resume(throwing: CodexAppServer.Failure.remote("Voice stopped."))
    }

    private func fail(_ message: String) {
        mark("failed: \(message)")
        warmupStart = nil
        let waiter = offerWaiter; offerWaiter = nil
        close()
        waiter?.resume(throwing: CodexAppServer.Failure.remote(message))
        CodexAppServer.shared.onNotification?("thread/realtime/error", ["message": message])
    }

    private func send(_ message: [String: Any], expecting reply: String, seconds: UInt64 = 5) {
        guard expected == nil, let input else { fail("Native voice control sequence failed."); return }
        do {
            let payload = try JSONSerialization.data(withJSONObject: message)
            guard payload.count <= 128 * 1024 else { fail("Native voice message too large."); return }
            var length = UInt32(payload.count).bigEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(payload)
            expected = reply
            try input.write(contentsOf: frame)
            let run = generation
            deadline?.cancel()
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                guard let self, self.generation == run else { return }
                self.fail("Native voice timed out waiting for \(reply).")
            }
        } catch { fail("Could not send native voice controls.") }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= 128 * 1024 else { fail("Invalid native voice frame."); return }
            guard buffer.count >= length + 4 else { return }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(length + 4))
            guard let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let type = message["type"] as? String, type == expected else {
                fail("Unexpected native voice response."); return
            }
            deadline?.cancel(); deadline = nil; expected = nil
            if type != "audioState" { mark(type) }
            switch type {
            case "ready": send(["type": "initializeRuntime"], expecting: "runtimeReady", seconds: 30)
            case "runtimeReady": send(["type": "startTransport"], expecting: "offer", seconds: 20)
            case "offer":
                guard let sdp = message["sdp"] as? String, !sdp.isEmpty, sdp.utf8.count <= 64 * 1024 else {
                    fail("Invalid native voice offer."); return
                }
                let waiter = offerWaiter; offerWaiter = nil
                waiter?.resume(returning: sdp)
                let run = generation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.generation == run else { return }
                    self.fail("Native voice timed out waiting for the server answer.")
                }
            case "transportReady": send(["type": "openDevices"], expecting: "devicesOpened")
            case "devicesOpened": devicesOpen = true; updateControls()
            case "audioControlsApplied":
                appliedMute = sentMute
                updateControls()
                if expected == nil && !announcedReady {
                    announcedReady = true
                    mark("audio ready (voice live)")
                    warmupStart = nil
                    CodexAppServer.shared.onNotification?("pulse/voiceReady", [:])
                    startPolling()
                }
            case "audioState":
                let peak = (message["state"] as? [String: Any])?["speakerPeak"] as? Int ?? 0
                CodexAppServer.shared.onNotification?("pulse/voice", ["type": peak > 0 ? "output_audio_buffer.started" : "output_audio_buffer.stopped"])
                updateControls()
            default: fail("Unexpected native voice response."); return
            }
        }
    }

    private func updateControls() {
        guard devicesOpen, expected == nil, appliedMute != muted else { return }
        sentMute = muted
        send(["type": "setAudioControls", "controls": ["microphoneMuted": muted, "speakerSuppressed": false]], expecting: "audioControlsApplied")
    }

    private func startPolling() {
        let run = generation
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.generation == run else { return }
                if self.expected == nil { self.send(["type": "inspectAudio"], expecting: "audioState") }
            }
        }
    }
}
