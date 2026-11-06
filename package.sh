#!/bin/zsh
# Build Pulse.app into .build; `./package.sh --install` also puts it in /Applications.
# Signing is ad-hoc unless CODE_SIGN_IDENTITY is set (an untracked .env in this folder may set it).
set -euo pipefail
cd "$(dirname "$0")"
[[ -f .env ]] && source .env
INSTALL=0
FORCE=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --install) INSTALL=1 ;;
        --force) FORCE=1 ;;   # with --install: allow replacing a newer installed build
        *) ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]}"

swift build -c release "$@"
BIN_DIR="$(swift build -c release "$@" --show-bin-path)"
STAGE="$(mktemp -d .build/package.XXXXXX)"
APP="$STAGE/Pulse.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>io.github.tommyent.pulse</string>
    <key>CFBundleName</key><string>Pulse</string>
    <key>CFBundleExecutable</key><string>Pulse</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.1</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Live voice with the Codex pet uses your microphone.</string>
    <key>SUFeedURL</key><string>https://tommyent.github.io/pulse/appcast.xml</string>
    <key>SUPublicEDKey</key><string>b+88Zfi9JKSrvlROjgKWtc55KNWhZp5Pa/XkLT+2EQ4=</string>
</dict></plist>
EOF

cp "$BIN_DIR/Pulse" "$APP/Contents/MacOS/Pulse"
cp -R "$BIN_DIR/Pulse_Pulse.bundle" "$APP/Contents/Resources/"
cp Sources/Pulse/Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sparkle with its symlinks and permissions; its XPC services are for sandboxed apps, so they stay out
rsync -a --exclude XPCServices "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
codesign -f -s "${CODE_SIGN_IDENTITY:--}" "$APP/Contents/Frameworks/Sparkle.framework"   # resealed without them

./scripts/stamp-sdk.sh "$APP/Contents/MacOS/Pulse"
codesign -f -s "${CODE_SIGN_IDENTITY:--}" "$APP"   # the identifier comes from Info.plist
codesign --verify --strict "$APP"

# Preserve previous builds for rollback; the stage folder is gone once the bundle is in place.
if [[ -e .build/Pulse.app ]]; then
    PREVIOUS="$(mktemp -d .build/previous.XXXXXX)"
    mv .build/Pulse.app "$PREVIOUS/Pulse.app"
fi
mv "$APP" .build/Pulse.app
rmdir "$STAGE"
echo "built: .build/Pulse.app"

if (( INSTALL )); then
    # A checkout on an older branch would otherwise silently drop whatever the installed build has since.
    if [[ -e /Applications/Pulse.app ]] && (( ! FORCE )); then
        INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Pulse.app/Contents/Info.plist)"
        BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' .build/Pulse.app/Contents/Info.plist)"
        if (( BUILT < INSTALLED )); then
            print -u2 -- "not installed: this is build $BUILT and /Applications has build $INSTALLED. Use --force to replace it anyway."
            exit 1
        fi
    fi
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
