#!/bin/zsh
# Offline checks only: no sign-ins, account requests, or microphone capture.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"   # shared across runs, rebuilt only when sources change
./Checks/SDKStampChecks.sh
swiftc Sources/Pulse/DockGeometry.swift Sources/Pulse/Models.swift Checks/OverlayChecks.swift -o "$OUT/overlay"
"$OUT/overlay"
swiftc Sources/Pulse/Models.swift Checks/RefreshChecks.swift -o "$OUT/refresh"
"$OUT/refresh"
swiftc Sources/Pulse/Models.swift Checks/LimitAlertChecks.swift -o "$OUT/limit"
"$OUT/limit"
swiftc Sources/Pulse/Models.swift Checks/ForecastChecks.swift -o "$OUT/forecast"
"$OUT/forecast" -AppleLocale en_US
TZ=Asia/Kolkata "$OUT/forecast" -AppleLocale en_GB   # a 24-hour clock, in a zone whose hours fall on UTC's half hours
swiftc Sources/Pulse/Battery.swift Checks/BatteryChecks.swift -o "$OUT/battery"
"$OUT/battery"
swiftc Sources/Pulse/CodexPetSprite.swift Checks/CodexPetChecks.swift -o "$OUT/pet"
"$OUT/pet"
swiftc Sources/Pulse/Breaks.swift Sources/Pulse/BreakTricks.swift Sources/Pulse/RexAgents.swift Checks/BreakChecks.swift -o "$OUT/break"
"$OUT/break"
swiftc Sources/Pulse/BreakHats.swift Sources/Pulse/BreakTricks.swift Sources/Pulse/CodexPetSprite.swift Checks/BreakHatChecks.swift -o "$OUT/hats"
"$OUT/hats"
swift package resolve   # the views link Sparkle
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
swiftc -F "$SPARKLE" -Xlinker -rpath -Xlinker "$SPARKLE" \
    $(find Sources/Pulse -name "*.swift" ! -name PulseApp.swift) Checks/SettingsStateChecks.swift -o "$OUT/state"
"$OUT/state"
swiftc Sources/Pulse/HotKey.swift Checks/VoiceShortcutChecks.swift -o "$OUT/voice-shortcut"
"$OUT/voice-shortcut"
swiftc Sources/Pulse/Models.swift Sources/Pulse/Adapters.swift Sources/Pulse/GrokLogin.swift Sources/Pulse/HotKey.swift Checks/SecurityChecks.swift -o "$OUT/security"
"$OUT/security"
swiftc Sources/Pulse/Models.swift Sources/Pulse/Adapters.swift Sources/Pulse/GrokLogin.swift Sources/Pulse/HotKey.swift Checks/PlanLabelChecks.swift -o "$OUT/plan-labels"
"$OUT/plan-labels"
swiftc Sources/Pulse/Models.swift Sources/Pulse/Adapters.swift Sources/Pulse/GrokLogin.swift Sources/Pulse/HotKey.swift Checks/SignInChecks.swift -o "$OUT/sign-in"
"$OUT/sign-in"
swiftc Sources/Pulse/Models.swift Sources/Pulse/Adapters.swift Sources/Pulse/GrokLogin.swift Sources/Pulse/HotKey.swift Checks/UsageParserChecks.swift -o "$OUT/usage-parsers"
"$OUT/usage-parsers"
./scripts/grok-check.sh --offline
swiftc Sources/Pulse/CodexChat.swift Sources/Pulse/VoiceBridge.swift Sources/Pulse/PetApprovals.swift Checks/CodexSessionChecks.swift -o "$OUT/codex-session"
"$OUT/codex-session"
