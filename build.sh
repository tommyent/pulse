#!/bin/zsh
# Ad-hoc signing works on any Mac; optionally set CODE_SIGN_IDENTITY to your own identity.
set -euo pipefail
cd "$(dirname "$0")"
swift build "$@"
BIN_DIR="$(swift build "$@" --show-bin-path)"
codesign -f -s "${CODE_SIGN_IDENTITY:--}" --identifier app.pulse "$BIN_DIR/Pulse"
echo "signed: app.pulse"
