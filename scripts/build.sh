#!/usr/bin/env bash
# Build Simmer, sign it with your stable Apple Development certificate,
# install it to /Applications and relaunch it.
#
# Always use this script for test builds. The app path and signature then
# never change, so macOS keeps the sound permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
APP_NAME="Simmer"
INSTALL_PATH="/Applications/${APP_NAME}.app"
DERIVED="build/DerivedData"
LOCAL_XCCONFIG="Config/Local.xcconfig"

# 1. Team ID for signing, taken from your Apple Development certificate.
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
  team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
  if [[ -z "${team:-}" ]]; then
    echo "error: no Apple Development certificate found in your keychain." >&2
    echo "       Copy Config/Local.xcconfig.example to $LOCAL_XCCONFIG and set your Team ID." >&2
    exit 1
  fi
  printf '// Local signing settings. Not committed.\nDEVELOPMENT_TEAM = %s\n' "$team" > "$LOCAL_XCCONFIG"
  echo "Created $LOCAL_XCCONFIG"
fi

# 2. Regenerate the Xcode project if XcodeGen is installed.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

# 3. Build.
echo "Building $APP_NAME ($CONFIG)..."
xcodebuild -project Simmer.xcodeproj -scheme Simmer -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=arm64" -quiet build
BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"

# 4. Refuse ad-hoc builds: they make macOS forget permissions.
codesign --verify --strict "$BUILT"
if codesign -dv "$BUILT" 2>&1 | grep -q "Signature=adhoc"; then
  echo "error: the build is ad-hoc signed. Check your signing certificate." >&2
  exit 1
fi

# 5. Quit the running copy, install, relaunch.
pkill -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
for _ in $(seq 1 50); do
  pgrep -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" >/dev/null || break
  sleep 0.1
done
rm -rf "$INSTALL_PATH"
ditto "$BUILT" "$INSTALL_PATH"
open "$INSTALL_PATH"
echo "Installed and launched $INSTALL_PATH"
