#!/bin/sh
#
# Run by the "Embed .NET MAUI app" build phase of XcodeCloud/MacMauiCloud.xcodeproj.
#
# The wrapper target compiles a one-line placeholder so Xcode has something to sign and
# archive. This phase runs after Xcode has laid out the placeholder bundle and before it
# code-signs, and replaces the bundle's contents with the .NET MAUI app that
# ci_scripts/ci_post_clone.sh built and staged in XcodeCloud/build. Xcode's own codesign
# step then signs the MAUI app with the identity and profile Xcode Cloud manages.
#
# Override MAUI_APP_BUNDLE to point at a different .app when building locally.

set -eu

MAUI_APP="${MAUI_APP_BUNDLE:-$SRCROOT/build/$PRODUCT_NAME.app}"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"

if [ ! -d "$MAUI_APP" ]; then
  echo "error: MAUI app bundle not found at $MAUI_APP" >&2
  echo "error: On Xcode Cloud, ci_scripts/ci_post_clone.sh builds it. Locally, run that script first (it needs the .NET SDK) or set MAUI_APP_BUNDLE." >&2
  exit 1
fi

echo "Embedding $MAUI_APP into $APP"

# Files Xcode already wrote and still needs (embedded.mobileprovision, PkgInfo) stay.
# The placeholder executable and any stale signature go.
rm -f "$APP/$EXECUTABLE_NAME"
rm -rf "$APP/_CodeSignature"
cp -R "$MAUI_APP/." "$APP/"
# The .NET build signed ad hoc. That signature is void once the bundle changes, and Xcode
# re-signs the whole bundle a few steps from now.
rm -rf "$APP/_CodeSignature"

if [ ! -f "$APP/$EXECUTABLE_NAME" ]; then
  echo "error: $MAUI_APP has no executable named '$EXECUTABLE_NAME'. PRODUCT_NAME in the wrapper target must equal the MAUI project's assembly name." >&2
  exit 1
fi

# Xcode signs nested code only when it embedded that code itself. Anything the .NET build
# placed in Frameworks/ has to be signed here, inside out, or the outer signature is rejected.
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ -d "$APP/Frameworks" ]; then
  find "$APP/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print | while IFS= read -r nested; do
    echo "Signing nested code: $nested"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags "$nested"
  done
fi

# Ship the .NET dSYM in the archive so crash logs symbolicate.
if [ -d "$MAUI_APP.dSYM" ] && [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ] && [ -n "${DWARF_DSYM_FILE_NAME:-}" ]; then
  rm -rf "$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME"
  cp -R "$MAUI_APP.dSYM" "$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME"
fi

PLIST="$APP/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "Embedded $BUNDLE_ID version $SHORT_VERSION ($BUILD_VERSION)"
