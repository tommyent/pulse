#!/bin/zsh
# SPM stamps its deployment target as the SDK; record the SDK actually used before signing.
set -euo pipefail
SDK="$(xcrun --show-sdk-version)"
xcrun vtool -set-build-version macos 26.0 "$SDK" -replace -output "$1" "$1"
BUILD="$(xcrun vtool -show-build "$1")"
if ! print -r -- "$BUILD" | awk -v sdk="$SDK" '
    $1 == "sdk" { count++; if ($2 != sdk) bad = 1 }
    $1 == "minos" && $2 != "26.0" { bad = 1 }
    END { exit bad || !count }
'; then
    print -u2 -- "Incorrect build version: expected macOS 26.0 and SDK $SDK"
    exit 1
fi
print -r -- "$BUILD"
