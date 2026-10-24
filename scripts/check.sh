#!/bin/zsh
# Offline checks only: no sign-ins, account requests, or microphone capture.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"   # shared across runs, rebuilt only when sources change
swiftc Sources/Pulse/DockGeometry.swift Sources/Pulse/Models.swift Checks/OverlayChecks.swift -o "$OUT/overlay"
"$OUT/overlay"
swiftc Sources/Pulse/Models.swift Checks/LimitAlertChecks.swift -o "$OUT/limit"
"$OUT/limit"
swiftc Sources/Pulse/Battery.swift Checks/BatteryChecks.swift -o "$OUT/battery"
"$OUT/battery"
swiftc Sources/Pulse/CodexPetSprite.swift Checks/CodexPetChecks.swift -o "$OUT/pet"
"$OUT/pet"
swiftc Sources/Pulse/Breaks.swift Sources/Pulse/RexAgents.swift Checks/BreakChecks.swift -o "$OUT/break"
"$OUT/break"
swiftc $(find Sources/Pulse -name "*.swift" ! -name PulseApp.swift) Checks/SettingsStateChecks.swift -o "$OUT/state"
"$OUT/state"
swiftc Sources/Pulse/HotKey.swift Checks/VoiceShortcutChecks.swift -o "$OUT/voice-shortcut"
"$OUT/voice-shortcut"
swiftc Sources/Pulse/Models.swift Sources/Pulse/Adapters.swift Sources/Pulse/GrokLogin.swift Sources/Pulse/HotKey.swift Checks/SecurityChecks.swift -o "$OUT/security"
"$OUT/security"
./scripts/grok-check.sh --offline
swiftc Sources/Pulse/CodexChat.swift Sources/Pulse/VoiceBridge.swift Sources/Pulse/PetApprovals.swift Checks/CodexSessionChecks.swift -o "$OUT/codex-session"
"$OUT/codex-session"
