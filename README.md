# Pulse

A macOS menu bar app with floating usage rings for Claude, Codex, Grok and Antigravity, plus a Codex pet you can chat with by text or live voice. Usage refreshes every 2 minutes.

Everything runs on your own subscription sign-ins. There are no API keys, no accounts with Pulse, and no backend of its own.

## Requirements

- **Run:** macOS 14 Sonoma or later. The glass styling needs macOS 26. Tested on Apple Silicon with macOS 27; Intel is untested.
- **Build:** Xcode 26 or later (the Command Line Tools alone lack the SwiftUI macro plugin) and Swift 6.2 or later. No third-party packages.
- **Codex:** a signed-in Codex CLI (`codex login`). Voice needs a CLI package containing `codex-voice-host` (tested with 0.155.0), microphone permission, and an account that supports the CLI's experimental realtime protocol.
- **Claude and Grok:** sign in through their CLIs, or use **Connect** in Pulse's Settings. Grok CLI support reads Grok Build's `~/.grok/auth.json`.
- **Antigravity:** the Antigravity CLI (`agy`) 1.1.11 or later (tested with 1.2.9), signed in by running `agy` once. The ring shows the Gemini or Claude and GPT pool nearer its limit; the card lists both pools' 5-hour and weekly limits.

Pulse looks for the Codex and `agy` executables in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, and for Codex also in `~/.codex/bin`. If yours lives elsewhere, link it into `~/.local/bin`; apps launched from Finder do not inherit your shell's PATH.

## Build and install

```sh
./package.sh --install     # builds .build/Pulse.app and puts it in /Applications
open /Applications/Pulse.app
```

Without `--install` the bundle stays in `.build`. An existing installed copy is moved to the Trash, never deleted. `./build.sh` makes a development executable instead.

Signing is ad-hoc by default, so no certificate is needed. macOS ties microphone permission to the code signature, and an ad-hoc signature changes on every build, so if you rebuild often set `CODE_SIGN_IDENTITY` to a self-signed identity from Keychain Access. A `.env` file in the project folder is sourced by the scripts and ignored by git, so it is a good place for that.

There are no binary releases; build from source.

## Use

Click the menu bar icon for Settings, where **Launch at login** starts Pulse when you log in. Drag the rings to any screen edge; top and bottom lay out horizontally. In the light appearance the rings and cards sit on Liquid Glass with a white wash; the dark appearance is opaque black. Turn off **Tint the glass** in Settings for plain Liquid Glass in either appearance, which follows the Liquid Glass slider in System Settings → Appearance. Click a ring for that account's windows and reset times.

Click the pet to chat. The waveform button below the expanded pet ring starts or ends voice without opening the pop-out. **Command-click the pet** to start voice, then Command-click again to end the session; another Command-click starts a new voice session. Command-click leaves the pop-out closed (or preserves the current card). The **ring around the pet** is gray when voice is off, yellow only while connecting, Codex blue while listening, and red when the microphone is paused. A white slashed-microphone badge and **Microphone paused · voice still on** in the card also show the paused state; replies can still play. The waveform buttons use the same colors, and Pulse plays the macOS Pluck sound when the microphone goes live and Pong when a live call ends. **⌃⌥Space** opens the pet and starts hands-free voice. Tap it to pause the microphone, and tap again to resume. Hold it to talk: when you let go, only the microphone pauses and the call stays open, so Codex can still answer aloud. The first press opens the call, so start speaking after the start sound; later presses reuse the open call. If an audio device changes while you're holding it, the call reconnects paused, so press again. The shortcut never ends a call: press Escape (which also closes the card), click the waveform button, or Command-click the pet. The shortcut is configurable in Settings, and one you set before is kept. Closing the card by clicking elsewhere does not end a call.

Audio capture and playback use the native voice helper from your installed Codex package. Pulse includes the Codex thread's startup context in voice sessions. The audio helper does not change the thread's file or tool permissions.

The pet starts in `~/Documents/codex-pet`. Ask it to work in another folder, such as `~/Projects` or `~/Downloads`, and approve the requested access in Pulse's permission dialog. The dialog shows the command, file changes, or requested paths. **Allow once** approves one action; **Allow for this task** grants the requested access until the current Codex turn ends. **Always allow** remembers matching requests across restarts: the exact command and working folder, the same requested access, or the same file paths and operation types. A broader or different request still asks. **Deny** grants nothing. Use **Settings → Codex voice → Reset remembered approvals** to ask again for future requests; existing task grants expire when the task ends.

Codex tools can also ask for consent, such as Browser Use asking to open a website. **Allow** and **Deny** are remembered by that tool, not by Pulse: Browser Use keeps site decisions for the rest of the conversation, so start a **New conversation** to be asked again. **Not now** (Esc) decides nothing. Multiple-choice questions from Codex appear as a dialog. Requests Pulse can't show faithfully, such as sign-ins, links, verification codes, secrets or free-text questions, are cancelled or left unanswered, never answered for you, and a note in the chat says what happened. During a call, a prompt also plays a sound and the voice tells you it's waiting; you answer in the window, never by voice.

The pet keeps one conversation across restarts. Opening it shows the recent messages, and **Load earlier messages** goes further back. It shows typed messages, requests Codex acted on and its replies; the rest of a voice call isn't shown. Each result of a voice request appears once, without its progress notes, marked **Work result**, or **After the call** if it finished after you hung up. During a call, Pulse forwards completed work results to the voice, as Codex's own CLI does, and only for your latest request in that call; questions and long answers get a pointer to the pet chat instead. **New conversation** starts over and stops any helpers still running. The card's header shows the model Codex works with, its reasoning effort, the folder and when the conversation began. Click it to choose another work model or effort for this conversation and new ones; the voice is a separate realtime model and doesn't change. After an update from a version that didn't keep conversations, the pet reopens its most recent one once; sites a tool blocked in that conversation stay blocked there. Pulse runs its own Codex app-server, so don't continue the pet's conversation in another Codex app at the same time.

For bigger requests, such as building something, research or multi-step changes, the pet can hand the work to a Codex helper (one of Codex's own sub-agents) and tell you it has started, so you can keep talking while the helper works. A card line shows while a helper is working. When it finishes, Pulse asks the pet for a short report: it appears in the chat as **Helper result**, and during the call that asked for the work the voice tells you once. A report waits while you're asking something else. The card's Stop button stops the pet's work and its helpers. Ending a call, pausing the microphone or closing the card leaves helpers working, and their results stay in the chat. A helper can use approvals you've already remembered but can't create new ones. With a model that has helpers, when you pick an effort above medium in the card's header, the pet talks at medium so it answers quickly and helpers work at your pick; a new helper effort applies from the next conversation or Pulse restart, as does switching to a model that can't run the helpers' current effort (the header shows what's pending). Helpers need a model whose sub-agent tool supports them; Pulse gives the pet this instruction only in its own conversations, never in the folder's `AGENTS.md`.

## Privacy

- Pulse reads the current user's own CLI credentials: Claude Code's Keychain item (through Apple's `security` tool, so it never prompts) or `~/.claude/.credentials.json`, `~/.codex/auth.json`, and `~/.grok/auth.json`. Grok's file is refreshed in place with an atomic, owner-only write.
- Web sign-ins made through **Connect** live in macOS WebKit storage; Grok's saved cookie header uses the Keychain service `app.pulse.auth`. Preferences and usage snapshots live in `~/Library/Application Support/Pulse`. The voice helper's error output goes to `pulse-voice.err` in your temporary folder, for diagnosing failed calls.
- Antigravity usage comes from the CLI's own report: Pulse runs `agy -p /usage --output-format json` in a private temporary folder on each refresh and never reads the Google sign-in. The report is a local command, so it sends no prompt and uses no quota; agy writes its usual log file for each run. Before each run Pulse sends one empty HEAD request to `oauth2.googleapis.com` and skips agy when it gets no answer, because agy opens a browser sign-in when its token refresh hits a network error. If agy reports a sign-out or stalls, Pulse stops running it until you click **Refresh**.
- Usage requests go straight to each provider over HTTPS. Authenticated responses are not cached to disk and redirects are refused, so a token is never forwarded off-host.
- Pet chat and audio go through Codex and OpenAI under your Codex account, which may retain threads. The pet thread starts in `~/Documents/codex-pet` with workspace-write sandboxing and user-reviewed, on-request approvals. Pulse creates the folder and seeds an `AGENTS.md` there when it launches; existing files have only Pulse's original sentences updated, preserving your own instructions. The instructions require permission before working outside the inbox, and let the pet send, pay, book or contact someone only when you explicitly ask for that specific action, with the permission prompts as the check; the sandbox enforces write restrictions, while normal read access follows Codex's workspace-write policy. Supported approval, consent and question requests from the pet and its delegated agents are shown for review. Requests Pulse can't show are cancelled or left unanswered with a note in the chat, so they are never recorded as your refusal; other unknown requests are rejected. Your own Codex configuration and tools apply.

## Checks

```sh
./scripts/check.sh
```

Offline, no sign-ins or audio capture; needs Node.js 18 or later. Covers overlay geometry, reset labels, the pet sprite sheet, credential writes, redirect and cache policy, the voice shortcut, Grok parsing, the Antigravity report and its version guard, Codex startup, timeouts and broken pipes, the native voice protocol and lifecycle, voice sounds, Codex Stop, the pet's consent and questions, conversation recovery and the work-model choice.

Live checks that use your accounts: `./scripts/grok-check.sh` may refresh Grok credentials, and `./scripts/codex-chat-check.sh` sends one prompt and negotiates a voice session. Provider endpoints and the experimental realtime protocol can change without notice.

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
| `PulseApp.swift` | app entry, overlay panel, shortcut binding |
| `AppState.swift` | persisted settings, refresh loop, snapshots |

## License

MIT. See `LICENSE`.
