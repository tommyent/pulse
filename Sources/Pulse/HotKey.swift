import AppKit
import Carbon

/// A system-wide key combination. Carbon's hotkey API needs no Accessibility grant and reports
/// both press and release, which is what hold-to-talk needs.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var label: String

    static let voiceDefault = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | optionKey), label: "⌘⌥V")

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
        Self.installHandler()
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

    private static func installHandler() {
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                guard let key = HotKey.registry.object(forKey: NSNumber(value: hk.id)) else { return }
                if kind == UInt32(kEventHotKeyPressed) { key.onPress?() } else { key.onRelease?() }
            }
            return noErr
        }, types.count, &types, nil, &handler)
    }
}

/// Recorder field for Settings: click, press a combination, done. Escape cancels.
import SwiftUI

struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Press keys…" : combo.label) { recording ? stop() : start() }
                .frame(minWidth: 110)
            if combo != .voiceDefault, !recording {
                Button("Reset") { combo = .voiceDefault }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
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
