# Build and test

## Build from source

Builds from source are development builds:

```sh
./package.sh --install     # builds .build/Pulse.app and puts it in /Applications
open /Applications/Pulse.app
```

Without `--install` the bundle stays in `.build`. An existing installed copy is moved to the Trash, never deleted, and `--install` won't replace a newer build unless you add `--force`. `./build.sh` makes a development executable instead.

Development builds are signed ad-hoc by default, so no certificate is needed, and they are not notarized. macOS ties microphone permission to the code signature, and an ad-hoc signature changes on every build, so if you rebuild often set `CODE_SIGN_IDENTITY` to a self-signed identity from Keychain Access. A `.env` file in the project folder is sourced by the scripts and ignored by git, so it is a good place for that.

`./scripts/release.sh` makes an official build from a clean checkout: it signs with a Developer ID Application identity (set `DEVELOPER_ID` if the keychain has more than one), the hardened runtime and the microphone entitlement, then notarizes and staples both the app and the DMG, using the `notarytool` keychain profile `notary` (or `NOTARY_PROFILE`). It stops with an error unless Apple accepts both submissions and Gatekeeper accepts the app and the DMG. It also needs the release notes in `docs/releases/<version>.md` and Sparkle's update-signing key in the login Keychain (Sparkle's `generate_keys --account io.github.tommyent.pulse`), whose public half must match `SUPublicEDKey` in `package.sh`; it signs the DMG with that key into Sparkle's `appcast.xml`. The DMG, its checksum, the appcast and a manifest land in `.build/release.*`. `./scripts/site.sh .build/release.<id>` then commits the appcast, the notes and the new version's download links to the local `gh-pages` branch, ready to push.

## Checks

```sh
./scripts/check.sh
```

Offline, no sign-ins or audio capture; needs Node.js 18 or later. Covers overlay geometry, reset labels, battery levels, alerts and the Pushover request, the battery card's readings and wording, the pet sprite sheet, credential writes, redirect and cache policy, the voice shortcut, each provider's usage reply, the Antigravity report and its version guard, which limit each part of a ring shows and what VoiceOver reads for it, Codex startup, timeouts and broken pipes, the native voice protocol and lifecycle, voice sounds, a denied microphone, Codex Stop, refused messages, the pet's consent and questions, conversation recovery and the work-model choice, the break schedule (due-based spacing, the countdown, pause, snooze, voice calls, locks and both time-away modes), restoring it after a restart, the break history, picking ideas, Rex's status and events, stale rings' numbers, the forecast line's pace, history and wording, that a stuck provider can't hold up a refresh, that settings saved by an older Pulse load unchanged, and that a value or file Pulse can't read is kept in a copy.

Live checks that use your accounts: `./scripts/grok-check.sh` may refresh Grok credentials, and `./scripts/codex-chat-check.sh` opens a temporary conversation with the app's settings, sends one prompt and negotiates a voice session. Provider endpoints and the experimental realtime protocol can change without notice.

`./scripts/approval-ui-check.sh` checks the native permission prompts in a logged-in session. It briefly opens example prompts that close themselves and takes focus while it runs; it starts no Codex process and uses no network, microphone, browser or settings. It isn't part of `check.sh`.

## Layout of the code

| File | Owns |
|---|---|
| `Adapters.swift` | usage fetch for Claude, Codex, Grok and Antigravity; credential reads and Grok token refresh |
| `CodexChat.swift` | Codex app-server client and pet session |
| `VoiceBridge.swift` | installed Codex native voice helper, audio controls and lifecycle |
| `PetApprovals.swift` | native approval, consent and question prompts, scoped replies and cancellation |
| `HotKey.swift` | global shortcut registration and the Settings recorder |
| `Views.swift` | rail, rings, usage cards, pet card, Settings |
| `Breaks.swift` | break settings, schedule, colours and picking ideas |
| `BreakController.swift` | the break clock, idle and lock detection, the overlay windows |
| `BreakViews.swift` | the countdown, the break screen, its agents and Settings → Breaks |
| `BreakIdeas.swift` | loads the idea list, `Resources/break-ideas.json` |
| `RexAgents.swift` | which agents Rex reports as working |
| `PulseApp.swift` | app entry, overlay panel, shortcut binding |
| `AppState.swift` | persisted settings, refresh loop, snapshots |
| `Models.swift` | account IDs, usage windows and which part of a ring each one takes, snapshots and their health, a limit's pace and forecast |
| `GrokLogin.swift` | Keychain storage, the embedded sign-in window and the hidden claude.ai session |
| `CodexPetSprite.swift` | the pet's sprite sheet |
| `DockGeometry.swift` | screen-edge docking and outside-click geometry |
