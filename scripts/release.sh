#!/bin/zsh
# Official build: Developer ID signature with the hardened runtime, then a notarized, stapled app inside a
# notarized, stapled DMG, its checksum, Sparkle's appcast and a manifest in .build/release.XXXXXX.
# Fails closed: it exits non-zero unless Apple accepts both submissions, both staples validate and Gatekeeper
# accepts the app and the DMG. Needs a "Developer ID Application" identity (DEVELOPER_ID picks one when there
# are several), a notarytool keychain profile (NOTARY_PROFILE, default "notary"), Sparkle's EdDSA key in the
# login Keychain and the release notes in docs/releases/<version>.md.
# scripts/site.sh then puts the appcast, the notes and the version on the gh-pages branch.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && source .env
PROFILE="${NOTARY_PROFILE:-notary}"
KEY_ACCOUNT=io.github.tommyent.pulse   # Sparkle's EdDSA key in the login Keychain, kept apart from other apps' keys
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
fail() { print -u2 -- "release: $1"; exit 1 }

git diff --quiet HEAD -- || fail "commit the tracked changes first: a release is built from a commit"
# Untracked files count too: SwiftPM compiles everything in Sources/Pulse, and the manifest would name a commit without them.
[[ -z "$(git status --porcelain -- Sources Package.swift Package.resolved package.sh scripts)" ]] || fail "commit or remove the untracked build files first: a release is built from a commit"
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    IDS=("${(@f)$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)"$/\1/p' | sort -u)}")
    (( ${#IDS} == 1 )) && [[ -n "${IDS[1]}" ]] || fail "set DEVELOPER_ID: expected one Developer ID Application identity"
    DEVELOPER_ID="${IDS[1]}"
fi
TEAM="${${DEVELOPER_ID##*\(}%\)}"

./scripts/check.sh
./package.sh --only-use-versions-from-resolved-file
PLIST=.build/Pulse.app/Contents/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NOTES="docs/releases/$VERSION.md"
[[ -s "$NOTES" ]] || fail "write the release notes first: $NOTES"
# An update signed with any other key would be refused by every installed copy
[[ "$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p)" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" ]] \
    || fail "SUPublicEDKey in package.sh is not the public half of the Keychain's $KEY_ACCOUNT key"
OUT="$(mktemp -d .build/release.XXXXXX)"
APP="$OUT/Pulse.app"
ditto .build/Pulse.app "$APP"

# Nested code first, inside-out and without --deep, as Sparkle's documentation signs it; then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
    codesign -f -s "$DEVELOPER_ID" --options runtime --timestamp "$code"
done
codesign -f -s "$DEVELOPER_ID" --options runtime --timestamp --entitlements scripts/Pulse.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
for f in "$APP" "$APP"/Contents/**/*(.ND); do   # every piece of code, so nothing unsigned by us slips in
    [[ "$f" == "$APP" || "$(file -b "$f")" == Mach-O* ]] || continue
    INFO="$(codesign -dv "$f" 2>&1)"
    [[ "$INFO" == *"flags=0x10000(runtime)"* && "$INFO" == *"TeamIdentifier=$TEAM"* && "$INFO" == *Timestamp=* ]] \
        || fail "$f: signature lacks the hardened runtime, Team ID $TEAM or a secure timestamp"
done
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

# Sparkle's feed, one item: the stapled DMG's EdDSA signature, the download on GitHub Releases, notes on the site
mkdir "$OUT/updates"
cp "$DMG" "$OUT/updates/"
cp "$NOTES" "$OUT/updates/Pulse-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/tommyent/pulse/releases/download/v$VERSION/" \
    --release-notes-url-prefix "https://tommyent.github.io/pulse/notes/" \
    --link "https://tommyent.github.io/pulse/" "$OUT/updates"
APPCAST="$(<"$OUT/updates/appcast.xml")"
for want in "<sparkle:version>$BUILD</sparkle:version>" "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" \
    "url=\"https://github.com/tommyent/pulse/releases/download/v$VERSION/Pulse-$VERSION.dmg\"" \
    "length=\"$(stat -f %z "$DMG")\"" "sparkle:edSignature=" \
    "<sparkle:releaseNotesLink>https://tommyent.github.io/pulse/notes/Pulse-$VERSION.md</sparkle:releaseNotesLink>"; do
    [[ "$APPCAST" == *"$want"* ]] || fail "appcast lacks $want"
done

cat > "$OUT/manifest.txt" <<EOF
version: $VERSION ($BUILD)
commit: $(git rev-parse HEAD)
sha256: $(cut -d' ' -f1 "$DMG.sha256")  ${DMG:t}
identity: $DEVELOPER_ID
team: $TEAM
notary: ${(j:, :)NOTARY}
appcast: $OUT/updates/appcast.xml (EdDSA key: $KEY_ACCOUNT)
built on: macOS $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')SDK $(xcrun --sdk macosx --show-sdk-version), $(uname -m)
EOF
cat "$OUT/manifest.txt"
print "release: $OUT"
