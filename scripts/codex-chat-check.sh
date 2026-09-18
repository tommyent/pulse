#!/bin/zsh
# Compile the pet's Codex client standalone and run it live against the signed-in Codex CLI.
# Fresh output dir each run: overwriting the same binary inode trips macOS's stale-signature SIGKILL.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/codex-chat-check"
swiftc -O -o "$OUT" Sources/Pulse/CodexChat.swift Sources/Pulse/VoiceBridge.swift Sources/Pulse/PetApprovals.swift scripts/codex-chat/main.swift
codesign -s - "$OUT" 2>/dev/null || true
exec "$OUT"
