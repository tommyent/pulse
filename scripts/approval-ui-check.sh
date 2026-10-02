#!/bin/zsh
# Run explicitly in a logged-in macOS GUI session. Briefly opens self-closing example prompts.
# No Codex process, network, microphone, browser or settings writes.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
export CLANG_MODULE_CACHE_PATH="$OUT/module-cache"
swiftc Sources/Pulse/PetApprovals.swift Checks/ApprovalPresentationChecks.swift -o "$OUT/approval-ui"
"$OUT/approval-ui"
