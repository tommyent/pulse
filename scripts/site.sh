#!/bin/zsh
# Puts a finished release on the site: commits its appcast, its release notes and the page's download links for
# its version to the local gh-pages branch, in one commit. Pushing it is a separate step.
# Usage: scripts/site.sh .build/release.XXXXXX (the folder release.sh printed)
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { print -u2 -- "site: $1"; exit 1 }
REL="${1:?usage: scripts/site.sh .build/release.XXXXXX}"
VERSION="$(sed -n 's/^version: \([0-9.]*\) .*/\1/p' "$REL/manifest.txt")"
[[ -n "$VERSION" && -s "$REL/updates/appcast.xml" && -s "$REL/updates/Pulse-$VERSION.md" ]] \
    || fail "$REL is not a finished release"

SITE="$(mktemp -d .build/site.XXXXXX)"
git worktree add -q "$SITE" gh-pages   # refuses while gh-pages is checked out elsewhere
cp "$REL/updates/appcast.xml" "$SITE/appcast.xml"
mkdir -p "$SITE/notes"
cp "$REL/updates/Pulse-$VERSION.md" "$SITE/notes/"
# The page names the version only as vX.Y.Z (buttons, release-notes link) and Pulse-X.Y.Z (DMG and checksum file)
sed -E -i '' -e "s/v[0-9]+\.[0-9]+\.[0-9]+/v$VERSION/g" -e "s/Pulse-[0-9]+\.[0-9]+\.[0-9]+/Pulse-$VERSION/g" "$SITE/index.html"
STALE="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$SITE/index.html" | grep -vxF "$VERSION" || true)"
[[ -z "$STALE" ]] || fail "the page still names another version ($STALE); fix it in $SITE"
git -C "$SITE" add appcast.xml notes index.html
git -C "$SITE" commit -q -m "Pulse $VERSION: appcast, release notes and download links"
git worktree remove "$SITE"
git log -1 --stat gh-pages
