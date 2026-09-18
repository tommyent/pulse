# Pulse

A macOS menu bar app with floating usage rings for Claude, Codex and Grok, plus a Codex pet you can chat with by text or live voice. Usage refreshes every 10 minutes.

Everything runs on your own subscription sign-ins. There are no API keys, no accounts with Pulse, and no backend of its own.

## Requirements

- **Run:** macOS 14 Sonoma or later. The glass styling needs macOS 26. Tested on Apple Silicon with macOS 27; Intel is untested.
- **Build:** Xcode 26 or later (the Command Line Tools alone lack the SwiftUI macro plugin) and Swift 6.2 or later. No third-party packages.
- **Codex:** a signed-in Codex CLI (`codex login`). Voice needs a CLI package containing `codex-voice-host` (tested with 0.155.0), microphone permission, and an account that supports the CLI's experimental realtime protocol.
- **Claude and Grok:** sign in through their CLIs, or use **Connect** in Pulse's Settings. Grok CLI support reads Grok Build's `~/.grok/auth.json`.

Pulse looks for the Codex executable in `~/.local/bin`, `~/.codex/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. If yours lives elsewhere, link it into `~/.local/bin`; apps launched from Finder do not inherit your shell's PATH.

## Build and install

```sh
./package.sh --install     # builds .build/Pulse.app and puts it in /Applications
open /Applications/Pulse.app
```

Without `--install` the bundle stays in `.build`. An existing installed copy is moved to the Trash, never deleted. `./build.sh` makes a development executable instead.

Signing is ad-hoc by default, so no certificate is needed. macOS ties microphone permission to the code signature, and an ad-hoc signature changes on every build, so if you rebuild often set `CODE_SIGN_IDENTITY` to a self-signed identity from Keychain Access. A `.env` file in the project folder is sourced by the scripts and ignored by git, so it is a good place for that.

There are no binary releases; build from source.

## Use

Click the menu bar icon for Settings. Drag the rings to any screen edge; top and bottom lay out horizontally. Click a ring for that account's windows and reset times.

Click the pet to chat. The waveform button below the expanded pet ring starts or ends voice without opening the pop-out. **Command-click the pet** to start voice, then Command-click again to end the session; another Command-click starts a new voice session. Command-click leaves the pop-out closed (or preserves the current card). The **ring around the pet** is gray when voice is off or muted, yellow while warming up, and Codex blue when the microphone is ready. **⌘⌥V** opens the pet and starts a voice call; press it again to end the call, hold it for push-to-talk, and press Escape to end the call and close the card. The shortcut is configurable in Settings. Closing the card by clicking elsewhere does not end a call.

Audio capture and playback use the native voice helper from your installed Codex package. Pulse includes the Codex thread's startup context in voice sessions. The audio helper does not change the thread's file or tool permissions.

The pet starts in `~/Documents/codex-pet`. Ask it to work in another folder, such as `~/Projects` or `~/Downloads`, and approve the requested access in Pulse's permission dialog. The dialog shows the command, file changes, or requested paths. **Allow once** approves one action; **Allow for this task** grants the requested access until the current Codex turn ends. **Always allow** remembers matching requests across restarts: the exact command and working folder, the same requested access, or the same file paths and operation types. A broader or different request still asks. **Deny** grants nothing. Use **Settings → Codex voice → Reset remembered approvals** to ask again for future requests; existing task grants expire when the task ends.

## Privacy

- Pulse reads the current user's own CLI credentials: Claude Code's Keychain item (through Apple's `security` tool, so it never prompts) or `~/.claude/.credentials.json`, `~/.codex/auth.json`, and `~/.grok/auth.json`. Grok's file is refreshed in place with an atomic, owner-only write.
- Web sign-ins made through **Connect** live in macOS WebKit storage; Grok's saved cookie header uses the Keychain service `app.pulse.auth`. Preferences and usage snapshots live in `~/Library/Application Support/Pulse`.
- Usage requests go straight to each provider over HTTPS. Authenticated responses are not cached to disk and redirects are refused, so a token is never forwarded off-host.
- Pet chat and audio go through Codex and OpenAI under your Codex account, which may retain threads. The pet thread starts in `~/Documents/codex-pet` with workspace-write sandboxing and user-reviewed, on-request approvals. Pulse creates the folder and seeds an `AGENTS.md` there on first open; existing files have only the original inbox-only restrictions updated, preserving other instructions. The instructions require permission before working outside the inbox; the sandbox enforces write restrictions, while normal read access follows Codex's workspace-write policy. Supported approval requests from the pet and its delegated agents are shown for review; unsupported requests are rejected. Your own Codex configuration and tools apply.

## Checks

```sh
./scripts/check.sh
```

Offline, no sign-ins or audio capture; needs Node.js 18 or later. Covers overlay geometry, the pet sprite sheet, credential writes, redirect and cache policy, the voice shortcut, Grok parsing, the native voice protocol and lifecycle, and Codex Stop.

Live checks that use your accounts: `./scripts/grok-check.sh` may refresh Grok credentials, and `./scripts/codex-chat-check.sh` sends one prompt and negotiates a voice session. Provider endpoints and the experimental realtime protocol can change without notice.

## Layout of the code

| File | Owns |
|---|---|
| `Adapters.swift` | usage fetch for Claude, Codex and Grok; credential reads and Grok token refresh |
| `CodexChat.swift` | Codex app-server client and pet session |
| `VoiceBridge.swift` | installed Codex native voice helper, audio controls and lifecycle |
| `PetApprovals.swift` | native approval prompts, scoped replies and cancellation |
| `HotKey.swift` | global shortcut registration and the Settings recorder |
| `Views.swift` | rail, rings, usage cards, pet card, Settings |
| `PulseApp.swift` | app entry, overlay panel, shortcut binding |
| `AppState.swift` | persisted settings, refresh loop, snapshots |

## License

MIT. See `LICENSE`.
