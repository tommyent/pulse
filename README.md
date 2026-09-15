# Pulse

A macOS menu bar app with floating usage rings for Claude, Codex and Grok, plus a Codex pet you can chat with by text or live voice. Usage refreshes every 10 minutes.

Everything runs on your own subscription sign-ins. There are no API keys, no accounts with Pulse, and no backend of its own.

## Requirements

- **Run:** macOS 14 Sonoma or later. The glass styling needs macOS 26. Tested on Apple Silicon with macOS 27; Intel is untested.
- **Build:** Xcode 26 or later (the Command Line Tools alone lack the SwiftUI macro plugin) and Swift 6.2 or later. No third-party packages.
- **Codex:** a signed-in Codex CLI (`codex login`). Voice also needs microphone permission and an account that supports the CLI's experimental realtime protocol.
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

Click the pet to chat. **⌘⌥V** opens the pet and starts a voice call; press it again to end the call, hold it for push-to-talk, and press Escape to end the call and close the card. The shortcut is configurable in Settings. Closing the card by clicking elsewhere does not end a call.

## Privacy

- Pulse reads the current user's own CLI credentials: Claude Code's Keychain item (through Apple's `security` tool, so it never prompts) or `~/.claude/.credentials.json`, `~/.codex/auth.json`, and `~/.grok/auth.json`. Grok's file is refreshed in place with an atomic, owner-only write.
- Web sign-ins made through **Connect** live in macOS WebKit storage; Grok's saved cookie header uses the Keychain service `app.pulse.auth`. Preferences and usage snapshots live in `~/Library/Application Support/Pulse`.
- Usage requests go straight to each provider over HTTPS. Authenticated responses are not cached to disk and redirects are refused, so a token is never forwarded off-host.
- Pet chat and audio go through Codex and OpenAI under your Codex account, which may retain threads. The pet thread runs in `~/Documents/codex-pet` with workspace-write sandboxing, so Codex can read and write files in that folder without asking. Pulse creates the folder and seeds an `AGENTS.md` there on first open; edit it to change the pet's rules. The pet declines every approval request, so anything outside that folder is refused. Your own Codex configuration and tools apply.

## Checks

```sh
./scripts/check.sh
```

Offline, no sign-ins or audio capture; needs Node.js 18 or later. Covers overlay geometry, the pet sprite sheet, credential writes, redirect and cache policy, the voice shortcut, Grok parsing, the voice page, and Codex Stop.

Live checks that use your accounts: `./scripts/grok-check.sh` may refresh Grok credentials, and `./scripts/codex-chat-check.sh` sends one prompt and negotiates a voice session. Provider endpoints and the experimental realtime protocol can change without notice.

## Layout of the code

| File | Owns |
|---|---|
| `Adapters.swift` | usage fetch for Claude, Codex and Grok; credential reads and Grok token refresh |
| `CodexChat.swift` | Codex app-server client, pet session, and the WebKit voice bridge |
| `HotKey.swift` | global shortcut registration and the Settings recorder |
| `Views.swift` | rail, rings, usage cards, pet card, Settings |
| `PulseApp.swift` | app entry, overlay panel, shortcut binding |
| `AppState.swift` | persisted settings, refresh loop, snapshots |

## License

MIT. See `LICENSE`.
