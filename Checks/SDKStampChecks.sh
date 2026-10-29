#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
check_stamp() (
    local observed_sdk="$1" observed_min="$2"
    xcrun() {
        if [[ "$1" == --show-sdk-version ]]; then print 27.0
        elif [[ "$2" == -show-build ]]; then
            print "    minos $observed_min"
            print "      sdk $observed_sdk"
        elif [[ "$2" != -set-build-version || "$3" != macos || "$4" != 26.0 || "$5" != 27.0 ]]; then
            return 1
        fi
    }
    set -- /tmp/fixture-Pulse
    source scripts/stamp-sdk.sh
)
check_stamp 27.0 26.0 > /dev/null
if check_stamp 26.0 26.0 > /dev/null 2>&1; then print -u2 'Accepted a stale SDK'; exit 1; fi
if check_stamp 27.0 14.0 > /dev/null 2>&1; then print -u2 'Accepted an old deployment target'; exit 1; fi
if check_stamp '' 26.0 > /dev/null 2>&1; then print -u2 'Accepted a missing SDK'; exit 1; fi
print 'SDK stamp checks passed: current SDK and macOS 26 required'
