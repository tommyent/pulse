import AppKit
import Carbon

/// A tap toggles the microphone; a hold listens until release. A quick second tap, released as a tap, ends the call.
struct VoiceShortcutGesture {
    enum Action: Equatable { case start, unmute, mute, end }
    private var press: (time: TimeInterval, mutesOnTap: Bool, mayDouble: Bool, second: Bool)?
    private var lastTap: TimeInterval?   // a tap on a running call: a quick second tap ends the call
    static let doubleTap: TimeInterval = 0.4

    mutating func keyDown(at time: TimeInterval, voiceActive: Bool, muted: Bool) -> Action? {
        guard press == nil else { return nil }   // repeated key-down events are still one gesture
        // A quick second press is only a candidate: held, it's push-to-talk as usual, so its release decides.
        let second = voiceActive && lastTap.map { time - $0 <= Self.doubleTap } == true
        lastTap = nil
        press = (time, voiceActive && !muted, voiceActive, second)   // a tap that starts a call never counts toward ending it
        return !voiceActive ? .start : muted ? .unmute : nil
    }

    mutating func keyUp(at time: TimeInterval) -> Action? {
        guard let press else { return nil }
        self.press = nil
        if time - press.time > 0.5 { return .mute }
        if press.second { return .end }
        if press.mayDouble { lastTap = time }
        return press.mutesOnTap ? .mute : nil
    }

    /// An ended call or a rebound shortcut must not leave a release aimed at a different call.
    @discardableResult mutating func cancel() -> Bool {
        let wasPressed = press != nil
        press = nil
        lastTap = nil
        return wasPressed
    }
}

/// A system-wide key combination. Carbon's hotkey API needs no Accessibility grant and reports
/// both press and release, which is what hold-to-talk needs.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var label: String

    static let voiceDefault = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")

    init(keyCode: UInt32, carbonModifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.carbonModifiers = carbonModifiers; self.label = label
    }

    /// From a key event captured in the recorder field. Needs at least one of ⌘⌃⌥.
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods: UInt32 = 0, label = ""
        if f.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if f.contains(.option)  { mods |= UInt32(optionKey);  label += "⌥" }
        if f.contains(.shift)   { mods |= UInt32(shiftKey);   label += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey);     label += "⌘" }
        let names: [UInt16: String] = [UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
                                       UInt16(kVK_Escape): "⎋", UInt16(kVK_Delete): "⌫", UInt16(kVK_UpArrow): "↑",
                                       UInt16(kVK_DownArrow): "↓", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→"]
        let key = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        guard event.keyCode != UInt16(kVK_Escape) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods, label: label + key)
    }
}

/// One registered hotkey with press/release callbacks on the main thread.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static let registry = NSMapTable<NSNumber, HotKey>.strongToWeakObjects()
    private static var nextID: UInt32 = 1
    private let id: UInt32
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    init?(_ combo: HotKeyCombo) {
        guard Self.installHandler() else { return nil }
        id = Self.nextID; Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C5345 /* PLSE */), id: id)
        guard RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                  GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        Self.registry.setObject(self, forKey: NSNumber(value: id))
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.registry.removeObject(forKey: NSNumber(value: id))
    }

    private static func installHandler() -> Bool {
        guard handler == nil else { return true }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                guard let key = HotKey.registry.object(forKey: NSNumber(value: hk.id)) else { return }
                if kind == UInt32(kEventHotKeyPressed) { key.onPress?() } else { key.onRelease?() }
            }
            return noErr
        }, types.count, &types, nil, &handler) == noErr
    }
}

/// Recorder field for Settings: click, press a combination, done. Escape cancels.
import SwiftUI

struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Press keys…" : combo.label) { recording ? stop() : start() }
                .frame(minWidth: 110)
            if combo != .voiceDefault, !recording {
                Button("Reset") { combo = .voiceDefault }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { stop() } }   // disabled mid-recording: stop swallowing keys
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let c = HotKeyCombo(event: event) { combo = c }
            if event.keyCode == UInt16(kVK_Escape) || HotKeyCombo(event: event) != nil { stop() }
            return nil   // swallow while recording
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
