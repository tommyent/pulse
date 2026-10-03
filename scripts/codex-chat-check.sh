#!/bin/zsh
# Compile the pet's Codex client standalone and run it live against the signed-in Codex CLI.
# Fresh output dir each run: overwriting the same binary inode trips macOS's stale-signature SIGKILL.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
OUT="$DIR/codex-chat-check"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc -O -o "$OUT" Sources/Pulse/CodexChat.swift Sources/Pulse/VoiceBridge.swift Sources/Pulse/PetApprovals.swift scripts/codex-chat/main.swift
codesign -s - "$OUT" 2>/dev/null || true
"$OUT"
