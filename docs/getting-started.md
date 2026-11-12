# Install and setup

## Requirements

- **Tested:** macOS 26.5.1 on Apple silicon. Intel is untested.
- **Build:** Xcode 26 or later (the Command Line Tools alone lack the SwiftUI macro plugin) and Swift 6.2 or later. Sparkle, for in-app updates, is the only third-party package; SwiftPM fetches it.
- **Codex:** a signed-in Codex CLI (`codex login`). Voice needs a CLI package containing `codex-voice-host` (tested with 0.160.0), microphone permission, and an account that supports the CLI's experimental realtime protocol.
- **Claude and Grok:** sign in through their CLIs, or use **Connect**, which shows on the account's card, in the menu bar popover and in **Settings → Accounts** while the CLI isn't signed in. Grok CLI support reads Grok Build's `~/.grok/auth.json`.
- **Antigravity:** the Antigravity CLI (`agy`) 1.1.11 or later (tested with 1.5.2), signed in by running `agy` once. The Gemini pool and the Claude and GPT pool each have a ring, and **Settings → Accounts** has a switch for the second; each ring's card lists that pool's limits.

Pulse looks for the Codex and `agy` executables in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, and for Codex also in `~/.codex/bin`. If yours lives elsewhere, link it into `~/.local/bin`; apps launched from Finder do not inherit your shell's PATH.

## Install

Download `Pulse-<version>.dmg` from [Releases](https://github.com/tommyent/pulse/releases), open it and drag Pulse to Applications. These official builds are signed with the project's Developer ID, use the hardened runtime and are notarized by Apple. They are built for Apple silicon. To check a download against the release's checksum file, run `shasum -a 256 -c Pulse-<version>.dmg.sha256` in the folder that holds both.

From 0.3.0 Pulse updates itself with [Sparkle](https://sparkle-project.org). On its second launch it asks whether to check for updates automatically; **Check for Updates…** in the menu bar popover checks at any time. Each update is signed, and Sparkle checks that signature against a key built into Pulse before installing it. Pulse 0.2.0 has no updater, so if you have it, download 0.3.0 once from Releases and replace it in Applications; later versions arrive in the app.

[Build from source and checks](development.md)
