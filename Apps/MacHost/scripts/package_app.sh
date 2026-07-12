#!/bin/sh
set -eu

CONFIGURATION="${1:-debug}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT/build/Remote Agent.app"
CONTENTS="$APP/Contents"

swift build --package-path "$ROOT" -c "$CONFIGURATION"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/$CONFIGURATION/RemoteAgent" "$CONTENTS/MacOS/RemoteAgent"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon/RemoteAgent.icns" "$CONTENTS/Resources/RemoteAgent.icns"
cp "$ROOT/Resources/crash-watchdog.sh" "$CONTENTS/Resources/crash-watchdog.sh"
chmod 755 "$CONTENTS/Resources/crash-watchdog.sh"
codesign --force --sign - "$APP"
echo "$APP"
