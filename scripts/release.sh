#!/bin/zsh
# Builds a signed, notarized Super Gloss DMG in dist/, and the same app zipped: the zip is
# what the app's updater downloads, so attach both to the GitHub release, under these names
# and tag (the updater finds the zip by them, without GitHub's API):
#   gh release create v<version> dist/SuperGloss-<version>.dmg dist/SuperGloss-<version>.zip
#
# Signing uses the first "Developer ID Application" identity in your keychain
# (override with SIGN_IDENTITY). Notarization uses either
#   NOTARY_PROFILE=<name>                       (from `xcrun notarytool store-credentials`)
# or
#   APPLE_ID=<email> NOTARY_PASSWORD_FILE=<file> (app-specific password, read from a file)
# Set SKIP_NOTARIZE=1 to stop after signing.
set -euo pipefail
cd "${0:A:h}/.."
root=$PWD

identity=${SIGN_IDENTITY:-"Developer ID Application"}
team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/')
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/SuperGloss/Info.plist)
app="$root/app/build/DerivedData/Build/Products/Release/Super Gloss.app"
dist="$root/dist"
dmg="$dist/SuperGloss-$version.dmg"
zip="$dist/SuperGloss-$version.zip"

echo "==> Building $version"
./build.sh Release

echo "==> Signing with $identity ($team)"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"

echo "==> Packaging $dmg"
mkdir -p "$dist"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "Super Gloss" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"

# The same signed app; notarizing the disk image covers it too (same code).
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
  echo "Signed (not notarized): $dmg, $zip"
  exit 0
fi

echo "==> Notarizing"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
else
  : "${APPLE_ID:?set APPLE_ID and NOTARY_PASSWORD_FILE, or NOTARY_PROFILE}"
  : "${NOTARY_PASSWORD_FILE:?set NOTARY_PASSWORD_FILE}"
  xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" --team-id "$team" \
    --password "$(cat "$NOTARY_PASSWORD_FILE")" --wait
fi
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

shasum -a 256 "$dmg" "$zip"
echo "Released: $dmg, $zip"
