#!/bin/zsh
# Build Pulse.app into .build; `./package.sh --install` also puts it in /Applications.
# Signing is ad-hoc unless CODE_SIGN_IDENTITY is set (an untracked .env in this folder may set it).
set -euo pipefail
cd "$(dirname "$0")"
[[ -f .env ]] && source .env
INSTALL=0
ARGS=()
for a in "$@"; do [[ "$a" == "--install" ]] && INSTALL=1 || ARGS+=("$a"); done
set -- "${ARGS[@]}"

swift build -c release "$@"
BIN_DIR="$(swift build -c release "$@" --show-bin-path)"
STAGE="$(mktemp -d .build/package.XXXXXX)"
APP="$STAGE/Pulse.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>app.pulse</string>
    <key>CFBundleName</key><string>Pulse</string>
    <key>CFBundleExecutable</key><string>Pulse</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Live voice with the Codex pet uses your microphone.</string>
</dict></plist>
EOF

cp "$BIN_DIR/Pulse" "$APP/Contents/MacOS/Pulse"
cp -R "$BIN_DIR/Pulse_Pulse.bundle" "$APP/Contents/Resources/"
cp Sources/Pulse/Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign -f -s "${CODE_SIGN_IDENTITY:--}" --identifier app.pulse "$APP"
codesign --verify --strict "$APP"

# keep one previous build; the stage folder is gone once the bundle is in place
if [[ -e .build/Pulse.app ]]; then
    rm -rf .build/Pulse.app.previous
    mv .build/Pulse.app .build/Pulse.app.previous
fi
mv "$APP" .build/Pulse.app
rmdir "$STAGE"
echo "built: .build/Pulse.app"

if (( INSTALL )); then
    pkill -x Pulse 2>/dev/null || true
    # an installed copy is never deleted: it goes to the Trash
    if [[ -e /Applications/Pulse.app ]]; then
        mv /Applications/Pulse.app ~/.Trash/"Pulse $(date +%Y%m%d-%H%M%S).app"
    fi
    cp -R .build/Pulse.app /Applications/Pulse.app
    echo "installed: /Applications/Pulse.app"
else
    echo "add --install to put it in /Applications"
fi
