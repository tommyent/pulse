#!/bin/zsh
# Compile the app's Grok adapter standalone (no SwiftPM, no macros needed) and run it live.
# Fresh output dir each run: overwriting the same binary inode trips macOS's stale-signature SIGKILL.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/grok-check"
swiftc -O -o "$OUT" Sources/Pulse/Models.swift Sources/Pulse/Adapters.swift Sources/Pulse/GrokLogin.swift scripts/grok-check/main.swift
codesign -s - "$OUT" 2>/dev/null || true
exec "$OUT" "$@"
