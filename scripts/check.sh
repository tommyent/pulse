#!/bin/zsh
# Offline checks only: no sign-ins, account requests, or microphone capture.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
export CLANG_MODULE_CACHE_PATH="$OUT/module-cache"
swiftc Sources/Pulse/DockGeometry.swift Checks/OverlayChecks.swift -o "$OUT/overlay"
"$OUT/overlay"
swiftc Sources/Pulse/CodexPetSprite.swift Checks/CodexPetChecks.swift -o "$OUT/pet"
"$OUT/pet"
swiftc Sources/Pulse/Models.swift Sources/Pulse/Adapters.swift Sources/Pulse/GrokLogin.swift Sources/Pulse/HotKey.swift Checks/SecurityChecks.swift -o "$OUT/security"
"$OUT/security"
./scripts/grok-check.sh --offline
swiftc Sources/Pulse/CodexChat.swift Sources/Pulse/VoiceBridge.swift Sources/Pulse/PetApprovals.swift Checks/CodexSessionChecks.swift -o "$OUT/codex-session"
"$OUT/codex-session"
