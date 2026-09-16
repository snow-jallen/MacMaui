#!/bin/sh
#
# Xcode Cloud custom build script. Runs after the repository is cloned, once per action.
#
# Xcode Cloud only knows how to archive an Xcode project, so this script does the .NET side
# of the work up front: it installs the .NET SDK and the MAUI iOS workload, builds the MAUI
# app bundle for a physical device, and stages it where the wrapper project's
# "Embed .NET MAUI app" build phase (../scripts/embed-maui-app.sh) expects to find it.
# Xcode then signs and archives that bundle exactly as it would a native app.
#
# Everything here runs without sudo. The SDK is installed into $HOME/.dotnet.
#
# Environment variables to set on the Xcode Cloud workflow (Environment section):
#   API_BASE_URL     Where the deployed API lives, e.g. https://macmaui-api.azurewebsites.net
#                    Optional: falls back to the committed XcodeCloud/api-base-url.txt.
#   APPINSIGHTS_CONNECTION_STRING
#                    Application Insights destination for the app's telemetry. Must be set here,
#                    marked secret, because the App Store Connect API cannot write Xcode Cloud
#                    environment variables and this repository is public, so unlike the API
#                    address it is not committed. Without it the iOS build reports nothing.
#   DOTNET_CHANNEL   .NET SDK channel to install (default 10.0)

set -eu

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
MAUI_PROJECT="$REPO/MacMaui.Mobile/MacMaui.Mobile.csproj"
PBXPROJ="$REPO/XcodeCloud/MacMauiCloud.xcodeproj/project.pbxproj"
OUT_DIR="$REPO/XcodeCloud/build"
TFM="net10.0-ios"
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"

log() { printf '\n==> %s\n' "$*"; }

# --- The wrapper target and the MAUI app must agree on the bundle identifier. ---------------
APP_ID="$(sed -n 's:.*<ApplicationId>\(.*\)</ApplicationId>.*:\1:p' "$MAUI_PROJECT" | head -n 1)"
if [ -z "$APP_ID" ]; then
  echo "error: could not read <ApplicationId> from $MAUI_PROJECT" >&2
  exit 1
fi
if ! grep -q "PRODUCT_BUNDLE_IDENTIFIER = $APP_ID;" "$PBXPROJ"; then
  echo "error: PRODUCT_BUNDLE_IDENTIFIER in $PBXPROJ does not match <ApplicationId> '$APP_ID' in $MAUI_PROJECT" >&2
  exit 1
fi

# --- Signing team. The project file ships without one; Xcode Cloud tells us which to use. --
if [ -n "${CI_TEAM_ID:-}" ]; then
  log "Setting DEVELOPMENT_TEAM = $CI_TEAM_ID in the wrapper project"
  sed -i '' "s/DEVELOPMENT_TEAM = \"\";/DEVELOPMENT_TEAM = $CI_TEAM_ID;/g" "$PBXPROJ"
fi

# --- Version numbers. CFBundleVersion must be unique per upload; the Xcode Cloud build ------
# --- number is. A tag such as v1.2.3 overrides the display version from the csproj. --------
BUILD_NUMBER="${CI_BUILD_NUMBER:-1}"
DISPLAY_VERSION="$(sed -n 's:.*<ApplicationDisplayVersion>\(.*\)</ApplicationDisplayVersion>.*:\1:p' "$MAUI_PROJECT" | head -n 1)"
case "${CI_TAG:-}" in
  v[0-9]*) DISPLAY_VERSION="${CI_TAG#v}" ;;
esac
log "Building $APP_ID version $DISPLAY_VERSION ($BUILD_NUMBER)"

# --- API address. See MacMaui.Mobile.csproj (ApiBaseUrl) and MauiProgram.cs. ------------------
# Read from the committed file rather than a workflow setting: the App Store Connect API cannot
# set Xcode Cloud environment variables, so keeping the address in the repository is the only way
# to configure a workflow entirely from a script. An environment variable still overrides it.
API_BASE_URL="${API_BASE_URL:-$(cat "$REPO/XcodeCloud/api-base-url.txt" 2>/dev/null | tr -d '[:space:]')}"
if [ -z "$API_BASE_URL" ]; then
  echo "warning: no API base URL (XcodeCloud/api-base-url.txt is missing or empty); the app will build but cannot reach the API." >&2
else
  log "API base URL: $API_BASE_URL"
fi

# --- Telemetry destination. Not committed: see the header. -----------------------------------
APPINSIGHTS_CONNECTION_STRING="${APPINSIGHTS_CONNECTION_STRING:-}"
if [ -z "$APPINSIGHTS_CONNECTION_STRING" ]; then
  echo "warning: APPINSIGHTS_CONNECTION_STRING is not set on this workflow, so this build will" >&2
  echo "warning: send no telemetry. Add it under Environment in the Xcode Cloud workflow." >&2
else
  log "Telemetry: Application Insights configured"
fi

# --- .NET SDK -------------------------------------------------------------------------------
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

log "Installing the .NET SDK (channel $DOTNET_CHANNEL) into $DOTNET_ROOT"
INSTALLER="${TMPDIR:-/tmp}/dotnet-install.sh"
curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$INSTALLER"
sh "$INSTALLER" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_ROOT" --no-path
dotnet --version

log "Installing the .NET MAUI iOS workload"
dotnet workload install maui-ios

log "Xcode selected for this build"
xcode-select -p
xcodebuild -version

# Point the .NET iOS SDK at the Xcode that is actually selected. Without this it reads the path
# from ~/Library/Preferences/maui/Settings.plist, which on any Mac that has built MAUI before can
# name an Xcode that is no longer installed ("Could not find a valid Xcode app bundle at ..."),
# and on Xcode Cloud would ignore the Xcode version chosen in the workflow's Environment section.
MD_APPLE_SDK_ROOT="$(dirname "$(dirname "$(xcode-select -p)")")"
export MD_APPLE_SDK_ROOT
log "MD_APPLE_SDK_ROOT=$MD_APPLE_SDK_ROOT"

# --- Build the MAUI app bundle for a device. ------------------------------------------------
# SingleTargetFramework trims TargetFrameworks to iOS and selects the ios-arm64 runtime (see the
# csproj), so restore does not demand the Android and Mac Catalyst workloads. CodesignKey=- signs
# ad hoc, which the .NET iOS build accepts without a certificate or provisioning profile; Xcode
# replaces that signature with the real one.
log "dotnet build $MAUI_PROJECT ($TFM, Release, ios-arm64)"
dotnet build "$MAUI_PROJECT" \
  --configuration Release \
  --framework "$TFM" \
  -p:SingleTargetFramework="$TFM" \
  -p:ApiBaseUrl="$API_BASE_URL" \
  -p:ApplicationInsightsConnectionString="$APPINSIGHTS_CONNECTION_STRING" \
  -p:CodesignKey=- \
  -p:CodesignRequireProvisioningProfile=false \
  -p:ApplicationVersion="$BUILD_NUMBER" \
  -p:ApplicationDisplayVersion="$DISPLAY_VERSION"

BIN_DIR="$(dirname "$MAUI_PROJECT")/bin/Release/$TFM/ios-arm64"
APP_BUNDLE="$(find "$BIN_DIR" -maxdepth 1 -type d -name '*.app' | head -n 1)"
if [ -z "$APP_BUNDLE" ]; then
  echo "error: no .app bundle found under $BIN_DIR" >&2
  exit 1
fi

log "Staging $(basename "$APP_BUNDLE") in $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$APP_BUNDLE" "$OUT_DIR/"
if [ -d "$APP_BUNDLE.dSYM" ]; then
  cp -R "$APP_BUNDLE.dSYM" "$OUT_DIR/"
fi

STAGED="$OUT_DIR/$(basename "$APP_BUNDLE")"
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' \
  -c 'Print :CFBundleShortVersionString' \
  -c 'Print :CFBundleVersion' \
  "$STAGED/Info.plist"
log "Done. Xcode will embed $STAGED during the archive."
