#!/bin/sh
#
# Build, sign, and upload the iOS app to TestFlight from a Mac, with no GUI and no Xcode Cloud.
#
# This is the alternative to the Xcode Cloud route in XcodeCloud/README.md. It uses the same
# wrapper Xcode project, but instead of Apple's build service it runs on any Mac you can reach
# over SSH, authenticating to App Store Connect with an API key. Everything is scriptable, so
# it also works as a GitHub Actions step on a macOS runner or a self-hosted Mac.
#
# Required environment:
#   ASC_KEY_ID        App Store Connect API key id, e.g. 2X9R4HXF34
#   ASC_ISSUER_ID     the issuer id shown above the key list, a UUID
#   ASC_KEY_PATH      path to the downloaded AuthKey_<ASC_KEY_ID>.p8
#   TEAM_ID           the ten-character Apple Developer team id
# Optional:
#   API_BASE_URL      address of the deployed API, baked into the app
#   BUILD_NUMBER      CFBundleVersion; must be higher than any previous upload (default: epoch)
#   DISPLAY_VERSION   CFBundleShortVersionString (default: the csproj's value)
#   SKIP_UPLOAD       set to 1 to archive and export an .ipa without uploading
#
# Signing assets are created on demand: -allowProvisioningUpdates lets Xcode make the
# distribution certificate and provisioning profile through the API key, so nothing has to be
# exported from a keychain by hand.

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
XC_DIR="$REPO/XcodeCloud"
WORK="${WORK_DIR:-${TMPDIR:-/tmp}}/macmaui-ios"
ARCHIVE="$WORK/MacMaui.xcarchive"
EXPORT_DIR="$WORK/export"

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

for var in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH TEAM_ID; do
  eval "value=\${$var:-}"
  [ -n "$value" ] || fail "$var is not set. See the header of this script."
done
[ -f "$ASC_KEY_PATH" ] || fail "ASC_KEY_PATH does not exist: $ASC_KEY_PATH"

BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"
export CI_BUILD_NUMBER="$BUILD_NUMBER"
export API_BASE_URL="${API_BASE_URL:-}"
[ -n "${DISPLAY_VERSION:-}" ] && export CI_TAG="v$DISPLAY_VERSION"

# --- 1. Build the .NET MAUI app and stage it for the wrapper project. ------------------------
# Reuses the Xcode Cloud post-clone script so both routes build the app identically.
log "Building the .NET MAUI iOS app (build $BUILD_NUMBER)"
sh "$XC_DIR/ci_scripts/ci_post_clone.sh"

# --- 2. Archive through the wrapper project, creating signing assets as needed. --------------
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$WORK"

log "Archiving with Xcode (team $TEAM_ID)"
xcodebuild archive \
  -project "$XC_DIR/MacMauiCloud.xcodeproj" \
  -scheme MacMaui.Mobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic

APP="$ARCHIVE/Products/Applications/MacMaui.Mobile.app"
[ -d "$APP" ] || fail "the archive has no MacMaui.Mobile.app"
log "Archived $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist") \
version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist") \
($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"))"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3

# --- 3. Export, and upload to App Store Connect unless asked not to. -------------------------
# destination=upload hands the build straight to App Store Connect; TestFlight then distributes
# it to whichever internal group you configured there.
DESTINATION=upload
[ "${SKIP_UPLOAD:-0}" = "1" ] && DESTINATION=export

OPTIONS="$WORK/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

log "Exporting with destination=$DESTINATION"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

if [ "$DESTINATION" = upload ]; then
  log "Uploaded build $BUILD_NUMBER to App Store Connect."
  echo "TestFlight shows it under the app's TestFlight tab once processing finishes,"
  echo "usually within a few minutes."
else
  log "Exported without uploading:"
  ls -la "$EXPORT_DIR"
fi
