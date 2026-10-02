import Foundation
import Carbon

@main
struct VoiceShortcutChecks {
    static func main() {
        var gesture = VoiceShortcutGesture()
        func check(_ result: Bool, _ message: String) {
            guard result else { fatalError(message) }
        }

        check(gesture.keyDown(at: 1, voiceActive: false, muted: true) == .start, "a fresh press starts voice even after mute")
        check(gesture.keyUp(at: 1.1) == nil, "a short starting tap leaves continuous voice on")
        check(gesture.keyDown(at: 2, voiceActive: true, muted: false) == nil, "pressing during a call leaves the microphone open until release")
        check(gesture.keyUp(at: 2.1) == .mute, "a short tap pauses the microphone and keeps the call open")

        check(gesture.keyDown(at: 3, voiceActive: false, muted: false) == .start, "a held shortcut starts a call")
        check(gesture.keyUp(at: 4) == .mute, "release mutes capture instead of ending playback, even while connecting")
        check(gesture.keyDown(at: 5, voiceActive: true, muted: true) == .unmute, "the next hold reuses the muted call")
        check(gesture.keyDown(at: 5.8, voiceActive: true, muted: false) == nil, "key repeat cannot reset the hold timer")
        check(gesture.keyUp(at: 6) == .mute, "release after a repeated key-down is still a hold")
        check(gesture.keyUp(at: 6.1) == nil, "a repeated release does nothing")

        check(gesture.keyDown(at: 7, voiceActive: true, muted: false) == nil, "holding during continuous voice keeps it live")
        check(gesture.keyUp(at: 8) == .mute, "holding during continuous voice becomes push-to-talk")
        check(gesture.keyDown(at: 9, voiceActive: true, muted: true) == .unmute, "a tap unmutes an existing call")
        check(gesture.keyUp(at: 9.5) == nil, "the half-second boundary is a tap and leaves voice on")

        _ = gesture.keyDown(at: 10, voiceActive: true, muted: false)
        check(gesture.cancel(), "ending a held call or rebinding cancels the gesture and asks capture to mute")
        check(gesture.keyUp(at: 11) == nil, "the old release cannot affect a replacement call")
        check(!gesture.cancel(), "cancelling an idle shortcut does not mute continuous voice")
        check(gesture.keyDown(at: 12, voiceActive: false, muted: true) == .start, "a new gesture works after cancellation")
        check(gesture.keyUp(at: 13) == .mute, "a new hold still mutes on release")
        check(HotKeyCombo.voiceDefault.keyCode == UInt32(kVK_Space)
              && HotKeyCombo.voiceDefault.carbonModifiers == UInt32(controlKey | optionKey), "the default is Control-Option-Space")
        let custom = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | optionKey), label: "⌘⌥V")
        let restored = try! JSONDecoder().decode(HotKeyCombo.self, from: JSONEncoder().encode(custom))
        check(restored == custom && restored != .voiceDefault, "a saved custom shortcut stays unchanged")
        print("Voice shortcut checks passed")
    }
}
