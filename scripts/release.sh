#!/usr/bin/env bash
# Builds a release of Simmer: signed with Developer ID, notarized by Apple,
# packed in a DMG, signed for Sparkle updates, with an appcast and a
# Homebrew cask file. Nothing is published unless you pass --publish.
#
#   ./scripts/release.sh 0.1.0                   build everything locally
#   ./scripts/release.sh 0.1.0 --skip-notarize   local test, no Apple upload
#   ./scripts/release.sh 0.1.0 --publish         also create the GitHub release
#
# One-time setup for notarization (stores your login in the keychain):
#   xcrun notarytool store-credentials simmer-notary \
#     --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#
# GitHub Actions runs this same script (.github/workflows/release.yml). There,
# the logins come from environment variables instead of the keychain:
#   TEAM_ID, NOTARY_APPLE_ID, NOTARY_PASSWORD, SPARKLE_KEY_FILE
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh VERSION [--skip-notarize] [--publish]}"
shift
NOTARIZE=1
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    --publish) PUBLISH=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
if [[ $PUBLISH == 1 && $NOTARIZE == 0 ]]; then
  echo "error: never publish a build that Apple has not notarized." >&2
  exit 1
fi

REPO="barry-napier/simmer"
NOTARY_PROFILE="simmer-notary"
SPARKLE_ACCOUNT="com.barrynapier.simmer"
BUILD_NUMBER=$(git rev-list --count HEAD)
OUT="build/release/$VERSION"
APP="$OUT/export/Simmer.app"
DMG="$OUT/Simmer-$VERSION.dmg"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
step() { printf '\n==> %s\n' "$*"; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit your changes first, so the release matches a commit." >&2
  exit 1
fi
if [[ -z "${TEAM_ID:-}" ]]; then
  [[ -f Config/Local.xcconfig ]] || { echo "error: run scripts/build.sh once first." >&2; exit 1; }
  TEAM_ID=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig | tr -d ' ')
fi
# Notarization login: from the environment on GitHub, from the keychain on a Mac.
if [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "${NOTARY_PASSWORD:?NOTARY_PASSWORD is not set}" --team-id "$TEAM_ID")
else
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
if [[ $NOTARIZE == 1 ]] && ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
  echo "error: Apple's notary service did not accept the login. To save one on this Mac:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id $TEAM_ID" >&2
  exit 1
fi
# Sparkle signing key: a file on GitHub, the keychain on a Mac.
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  SPARKLE_KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
else
  SPARKLE_KEY=(--account "$SPARKLE_ACCOUNT")
fi

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving Simmer $VERSION (build $BUILD_NUMBER)"
command -v xcodegen >/dev/null && xcodegen generate --quiet
xcodebuild -project Simmer.xcodeproj -scheme Simmer -configuration Release \
  -derivedDataPath build/DerivedData -archivePath "$OUT/Simmer.xcarchive" \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet archive

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Simmer.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -quiet

step "Checking the signature"
codesign --verify --deep --strict --verbose=1 "$APP"
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$SIGN_INFO" \
  || { echo "error: not signed with Developer ID." >&2; exit 1; }
grep -qE "flags=.*runtime" <<<"$SIGN_INFO" \
  || { echo "error: the hardened runtime is off." >&2; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "error: release build still has the debugging entitlement." >&2; exit 1
fi

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing the app (this can take a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/Simmer.zip"
  xcrun notarytool submit "$OUT/Simmer.zip" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$APP"
fi

step "Making the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Simmer.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Simmer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing the DMG"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
  step "Checking that Gatekeeper accepts it"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  spctl --assess --type execute --verbose "$APP"
fi

step "Signing for Sparkle updates"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "${SPARKLE_KEY[@]}" "$DMG")
[[ "$SIGNATURE" == *edSignature* ]] || { echo "error: Sparkle signing failed: $SIGNATURE" >&2; exit 1; }
DMG_URL="https://github.com/$REPO/releases/download/v$VERSION/Simmer-$VERSION.dmg"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Simmer</title>
    <item>
      <title>Simmer $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$DMG_URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

step "Writing the Homebrew cask"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
cat > "$OUT/simmer.rb" <<RUBY
cask "simmer" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Simmer-#{version}.dmg"
  name "Simmer"
  desc "Volume control for each app on your Mac"
  homepage "https://github.com/$REPO"

  depends_on macos: ">= :sequoia"

  app "Simmer.app"

  zap trash: [
    "~/Library/Logs/Simmer",
    "~/Library/Preferences/com.barrynapier.simmer.plist",
  ]
end
RUBY

echo
echo "Done: $DMG"
echo "      $OUT/appcast.xml"
echo "      $OUT/simmer.rb  (submit to homebrew-cask once published)"

if [[ $PUBLISH == 1 ]]; then
  step "Publishing v$VERSION on GitHub"
  # The tag already exists when the release was started by pushing it.
  if ! git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
    git tag -a "v$VERSION" -m "Simmer $VERSION"
    git push origin "v$VERSION"
  fi
  # The same file under a name that never changes, for the website's Download
  # button: releases/latest/download/Simmer.dmg always serves the newest release.
  STABLE_DMG="$OUT/Simmer.dmg"
  cp "$DMG" "$STABLE_DMG"
  gh release create "v$VERSION" "$DMG" "$STABLE_DMG" "$OUT/appcast.xml" --repo "$REPO" \
    --title "Simmer $VERSION" --verify-tag --generate-notes \
    --notes "Download **Simmer-$VERSION.dmg**, open it, and drag Simmer to Applications. If you already have Simmer, it will offer this update by itself."
else
  echo
  echo "Not published. To publish: ./scripts/release.sh $VERSION --publish"
fi
