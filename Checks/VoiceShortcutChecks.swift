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
        // A double-tap ends a call that was already on, live or paused; a starting tap, a slow tap or a hold never counts.
        var ends = VoiceShortcutGesture()
        check(ends.keyDown(at: 20, voiceActive: true, muted: false) == nil && ends.keyUp(at: 20.1) == .mute, "the first tap pauses as usual")
        check(ends.keyDown(at: 20.3, voiceActive: true, muted: true) == .unmute, "a quick second press opens the microphone, as any press")
        check(ends.keyUp(at: 20.4) == .end, "and released as a tap, it ends the call")
        check(ends.keyDown(at: 21, voiceActive: true, muted: true) == .unmute && ends.keyUp(at: 21.1) == nil, "on a paused call the first tap resumes")
        check(ends.keyDown(at: 21.4, voiceActive: true, muted: false) == nil && ends.keyUp(at: 21.5) == .end, "and a quick second tap ends it")
        check(ends.keyDown(at: 30, voiceActive: true, muted: false) == nil && ends.keyUp(at: 30.1) == .mute, "a tap pauses")
        check(ends.keyDown(at: 30.2, voiceActive: true, muted: true) == .unmute, "a quick second press held to talk opens the microphone")
        check(ends.keyUp(at: 31.2) == .mute, "and its release is push-to-talk, not the end of the call")
        check(ends.keyDown(at: 22, voiceActive: false, muted: false) == .start && ends.keyUp(at: 22.1) == nil, "a tap starts a call")
        check(ends.keyDown(at: 22.3, voiceActive: true, muted: false) == nil, "and never counts toward ending it")
        check(ends.keyUp(at: 22.4) == .mute, "so the next tap only pauses")
        check(ends.keyDown(at: 23, voiceActive: true, muted: true) == .unmute, "a slow second tap is just a tap")
        _ = ends.keyUp(at: 23.1)
        _ = ends.keyDown(at: 24, voiceActive: true, muted: false)
        check(ends.keyUp(at: 25) == .mute, "a hold")
        check(ends.keyDown(at: 25.2, voiceActive: true, muted: true) == .unmute, "a tap right after a hold doesn't end the call")
        _ = ends.keyUp(at: 25.3)
        check(ends.cancel() == false && ends.keyDown(at: 25.5, voiceActive: true, muted: false) == nil && ends.keyUp(at: 25.6) == .mute,
              "an ended call forgets the last tap")
        check(HotKeyCombo.voiceDefault.keyCode == UInt32(kVK_Space)
              && HotKeyCombo.voiceDefault.carbonModifiers == UInt32(controlKey | optionKey), "the default is Control-Option-Space")
        let custom = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | optionKey), label: "⌘⌥V")
        let restored = try! JSONDecoder().decode(HotKeyCombo.self, from: JSONEncoder().encode(custom))
        check(restored == custom && restored != .voiceDefault, "a saved custom shortcut stays unchanged")
        print("Voice shortcut checks passed")
    }
}
