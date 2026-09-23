import Foundation
import AppKit
import CoreAudio
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
    private var errorHandle: FileHandle?
    private let errorLog = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulse-voice.err")
    private var prewarmDevice: (AudioDeviceID, AudioDeviceIOProcID)?
    private var bluetoothInput = false
    private var devicesOpenedAt: Date?
    /// The helper dying moments after its devices open is the signature of an audio device changing
    /// under it. The chat reads this to retry the call once instead of showing an error.
    private(set) var lastFailureWasEarlyDeath = false
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
        lastFailureWasEarlyDeath = false
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
        // Both ends of a headset drop to the hands-free rate when the microphone is its own,
        // which is what a thin, crackly call sounds like. 24 kHz here means the call is on that
        // profile; a built-in input leaves the headset at its full 44.1/48 kHz for playback.
        mark("audio: input \(deviceRate(kAudioHardwarePropertyDefaultInputDevice)) Hz, output \(deviceRate(kAudioHardwarePropertyDefaultOutputDevice)) Hz")
        let run = generation
        await prewarmBluetoothInput()
        guard generation == run else { throw CodexAppServer.Failure.remote("Voice stopped.") }
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
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        errorHandle = try? FileHandle(forWritingTo: errorLog)
        child.standardError = errorHandle ?? FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                if data.isEmpty { self.fail("Native voice helper closed.") }
                else { self.consume(data) }
            }
        }
        child.terminationHandler = { [weak self, log] child in
            log.notice("voice helper exited: status \(child.terminationStatus, privacy: .public) reason \(child.terminationReason.rawValue, privacy: .public)")
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
        devicesOpenedAt = nil; bluetoothInput = false
        try? errorHandle?.close(); errorHandle = nil
        stopPrewarm()
        let waiter = offerWaiter; offerWaiter = nil
        waiter?.resume(throwing: CodexAppServer.Failure.remote("Voice stopped."))
    }

    private func fail(_ message: String) {
        var message = message
        lastFailureWasEarlyDeath = devicesOpenedAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        if bluetoothInput && devicesOpen {
            message += " A Bluetooth microphone can stop the call; switching Sound input to the built-in microphone works around it."
        }
        if warmupStart != nil { mark("failed: \(message)") }
        else { log.notice("voice failed: \(message, privacy: .public)") }
        if let line = helperStderrTail() {
            log.notice("voice helper stderr: \(line, privacy: .public)")
        }
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
            case "devicesOpened": devicesOpen = true; devicesOpenedAt = .now; updateControls()
            case "audioControlsApplied":
                appliedMute = sentMute
                updateControls()
                if expected == nil && !announcedReady {
                    announcedReady = true
                    mark("audio ready (voice live)")
                    warmupStart = nil
                    CodexAppServer.shared.onNotification?("pulse/voiceReady", [:])
                    stopPrewarm()          // the helper holds the microphone now
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
        // A mute is a state change, not speech: the helper ends the session on queue overflow, so
        // knowing when the microphone went quiet is what lines a mid-call death up with its cause.
        let state = muted ? "muted" : "unmuted"
        log.notice("voice: microphone \(state, privacy: .public)")
        send(["type": "setAudioControls", "controls": ["microphoneMuted": muted, "speakerSuppressed": false]], expecting: "audioControlsApplied")
    }

    /// The helper's own last line, read straight off its stderr file so a failure explains itself.
    /// Bounded at both ends: the last 4 KiB of the file, then the last 200 characters of one line.
    private func helperStderrTail() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: errorLog) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 4096 ? end - 4096 : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last else { return nil }
        return String(line.suffix(200))
    }

    // MARK: Bluetooth microphones

    /// Codex's helper treats an input sample-rate change as fatal, and a Bluetooth headset changes
    /// rate the moment its microphone opens (A2DP gives way to hands-free). Open the microphone
    /// here first and hold it until the helper has its own, so the helper only ever sees the
    /// settled hands-free rate. The headset keeps the call; nothing switches to the built-in mic.
    private func prewarmBluetoothInput() async {
        // Only the packaged app captures audio; the offline checks drive a fake helper.
        guard Bundle.main.bundleIdentifier != nil, let device = bluetoothInputDevice() else { return }
        bluetoothInput = true
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, { _, _, _, _, _ in }) == noErr,
              let proc else {
            log.notice("voice: could not hold the Bluetooth microphone")
            return
        }
        guard AudioDeviceStart(device, proc) == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            log.notice("voice: could not start the Bluetooth microphone")
            return
        }
        prewarmDevice = (device, proc)
        // ponytail: 100 ms x 20 is a guess at how long the profile switch takes; widen it if a
        // slower headset still trips the helper.
        var rate: Double = 0
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let current = sampleRate(device)
            if current != 0, current == rate { break }
            rate = current
        }
        mark("bluetooth microphone held at \(Int(rate)) Hz")
    }

    private func stopPrewarm() {
        guard let (device, proc) = prewarmDevice else { return }
        prewarmDevice = nil
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
    }

    /// The default input device, when it is a Bluetooth headset.
    private func bluetoothInputDevice() -> AudioDeviceID? {
        guard let device = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              let transport = audioProperty(device, kAudioDevicePropertyTransportType),
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return nil }
        return device
    }

    private func deviceRate(_ selector: AudioObjectPropertySelector) -> Int {
        guard let device = audioProperty(AudioObjectID(kAudioObjectSystemObject), selector) else { return 0 }
        return Int(sampleRate(device))
    }

    private func sampleRate(_ device: AudioDeviceID) -> Double {
        var address = audioAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0), size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// Device ids and transport types are both `UInt32`.
    private func audioProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = audioAddress(selector)
        var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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
