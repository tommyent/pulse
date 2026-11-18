#!/bin/zsh
# Classic draws byte for byte as it did before skins: ClassicRender.swift's fixture, rendered with the sources at
# BASE (the last commit before skins) and with today's, must give identical RGBA bytes at 1x and 2x.
# Usage: Checks/ClassicRenderChecks.sh [base-revision]. Needs the repository's history.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=${1:-f7e5f5c}
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
git cat-file -e "$BASE^{commit}" || { echo "Classic render check: $BASE is not in this checkout's history"; exit 1; }
mkdir -p "$OUT/base" "$OUT/head-out" "$OUT/base-out"
git archive "$BASE" Sources | tar -x -C "$OUT/base"
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
build() {   # sources folder, output binary
    swiftc -F "$SPARKLE" -Xlinker -rpath -Xlinker "$SPARKLE" \
        $(find "$1" -name "*.swift" ! -name PulseApp.swift) Checks/ClassicRender.swift -o "$2"
}
build "$OUT/base/Sources/Pulse" "$OUT/base-render"
build Sources/Pulse "$OUT/head-render"
"$OUT/base-render" "$PWD/Sources/Pulse" "$OUT/base-out" >/dev/null
"$OUT/head-render" "$PWD/Sources/Pulse" "$OUT/head-out" >/dev/null
for scale in 1x 2x; do
    cmp -s "$OUT/base-out/classic-$scale.rgba" "$OUT/head-out/classic-$scale.rgba" \
        || { echo "Classic render check FAILED at $scale: pixels differ from $BASE"; exit 1; }
done
echo "Classic render check passed: identical bytes to $BASE at 1x and 2x"
