#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
# Prefer the stable SDK when a macOS update temporarily leaves the newest
# Command Line Tools compiler and SDK on different minor builds.
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
echo "Building NotchFlow..."
swift build -c release

STAGING="$(mktemp -d /tmp/notchflow-install.XXXXXX)"
APP="$STAGING/NotchFlow.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchFlow "$APP/Contents/MacOS/NotchFlow"
cp Info.plist "$APP/Contents/Info.plist"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-NotchFlow Local}"
if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
    echo "Missing the stable NotchFlow Local signing identity in the login Keychain."
    echo "Refusing to fall back to ad-hoc signing because that would invalidate Accessibility access."
    exit 1
fi
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP"
echo "Stopping the previous version..."
pkill -x NotchFlow || true
for attempt in {1..30}; do
    if ! pgrep -x NotchFlow >/dev/null; then break; fi
    sleep 0.1
done
if pgrep -x NotchFlow >/dev/null; then
    echo "Please quit NotchFlow before installing."
    exit 1
fi
echo "Installing to /Applications..."
if [[ -d "/Applications/NotchFlow.app" ]]; then
    mv "/Applications/NotchFlow.app" "$STAGING/NotchFlow-previous.app"
fi
ditto "$APP" "/Applications/NotchFlow.app"
open "/Applications/NotchFlow.app"
echo "Previous version (if any) is preserved in $STAGING."
echo "Done. NotchFlow is running from Applications."
