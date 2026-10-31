#!/bin/zsh
# Official build: Developer ID signature with the hardened runtime, then a notarized, stapled app inside a
# notarized, stapled DMG, its checksum and a manifest in .build/release.XXXXXX.
# Fails closed: it exits non-zero unless Apple accepts both submissions, both staples validate and Gatekeeper
# accepts the app and the DMG. Needs a "Developer ID Application" identity (DEVELOPER_ID picks one when there
# are several) and a notarytool keychain profile (NOTARY_PROFILE, default "notary").
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && source .env
PROFILE="${NOTARY_PROFILE:-notary}"
fail() { print -u2 -- "release: $1"; exit 1 }

git diff --quiet HEAD -- || fail "commit the tracked changes first: a release is built from a commit"
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    IDS=("${(@f)$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)"$/\1/p' | sort -u)}")
    (( ${#IDS} == 1 )) && [[ -n "${IDS[1]}" ]] || fail "set DEVELOPER_ID: expected one Developer ID Application identity"
    DEVELOPER_ID="${IDS[1]}"
fi
TEAM="${${DEVELOPER_ID##*\(}%\)}"

./package.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/Pulse.app/Contents/Info.plist)"
OUT="$(mktemp -d .build/release.XXXXXX)"
APP="$OUT/Pulse.app"
ditto .build/Pulse.app "$APP"

# Nested code would be signed here, inside-out, before the app; today the main executable is the only code.
for f in "$APP"/Contents/**/*(.ND); do
    [[ "$f" == "$APP/Contents/MacOS/Pulse" || "$(file -b "$f")" != Mach-O* ]] || fail "sign nested code first: $f"
done
codesign -f -s "$DEVELOPER_ID" --options runtime --timestamp --entitlements scripts/Pulse.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
INFO="$(codesign -dv "$APP" 2>&1)"
[[ "$INFO" == *"flags=0x10000(runtime)"* && "$INFO" == *"TeamIdentifier=$TEAM"* && "$INFO" == *Timestamp=* ]] \
    || fail "signature lacks the hardened runtime, Team ID $TEAM or a secure timestamp"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
[[ "$ENTITLEMENTS" == *com.apple.security.device.audio-input* && "$ENTITLEMENTS" != *get-task-allow* ]] \
    || fail "entitlements must hold audio-input and no get-task-allow"

NOTARY=()
notarize() {   # $1: the file to submit; returns only when Apple's answer is Accepted
    local name="${1:t}" id notary_status
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/$name.notary.json" || true
    id="$(plutil -extract id raw "$OUT/$name.notary.json")"
    notary_status="$(plutil -extract status raw "$OUT/$name.notary.json")"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/$name.notary-log.json" || true
    print -r -- "notarization of $name: $notary_status ($id)"
    [[ "$notary_status" == Accepted ]] || fail "notarization of $name: $notary_status, see $OUT/$name.notary-log.json"
    NOTARY+=("$name $id")
}
gatekeeper() {   # $@: spctl arguments; Gatekeeper must accept the item as notarized Developer ID
    local verdict
    verdict="$(spctl --assess -vvv "$@" 2>&1)" || fail "Gatekeeper rejected: $verdict"
    print -r -- "$verdict"
    [[ "$verdict" == *"source=Notarized Developer ID"* ]] || fail "not accepted as notarized: $verdict"
}

ditto -c -k --keepParent "$APP" "$OUT/Pulse.zip"
notarize "$OUT/Pulse.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
gatekeeper --type execute "$APP"

DMG="$OUT/Pulse-$VERSION.dmg"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Pulse.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Pulse $VERSION" -srcfolder "$OUT/dmg" -format UDZO -o "$DMG"
codesign -s "$DEVELOPER_ID" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
gatekeeper --type open --context context:primary-signature "$DMG"

(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
cat > "$OUT/manifest.txt" <<EOF
version: $VERSION ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))
commit: $(git rev-parse HEAD)
sha256: $(cut -d' ' -f1 "$DMG.sha256")  ${DMG:t}
identity: $DEVELOPER_ID
team: $TEAM
notary: ${(j:, :)NOTARY}
built on: macOS $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')SDK $(xcrun --sdk macosx --show-sdk-version), $(uname -m)
EOF
cat "$OUT/manifest.txt"
print "release: $OUT"
