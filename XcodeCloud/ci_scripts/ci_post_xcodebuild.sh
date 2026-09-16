#!/bin/sh
#
# Xcode Cloud custom build script. Runs after xcodebuild, even when it failed.
# Purely diagnostic: prints what was archived so the build log shows which MAUI version
# and build number went to TestFlight.

set -u

echo "xcodebuild action: ${CI_XCODEBUILD_ACTION:-unknown}, exit code: ${CI_XCODEBUILD_EXIT_CODE:-unknown}"

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ] || [ "${CI_XCODEBUILD_EXIT_CODE:-1}" != "0" ]; then
  exit 0
fi

for signed in "${CI_APP_STORE_SIGNED_APP_PATH:-}" "${CI_AD_HOC_SIGNED_APP_PATH:-}" "${CI_DEVELOPMENT_SIGNED_APP_PATH:-}"; do
  if [ -n "$signed" ] && [ -d "$signed" ]; then
    echo "Signed app: $signed"
    ls -la "$signed"
  fi
done

if [ -n "${CI_ARCHIVE_PATH:-}" ]; then
  APP="$(find "$CI_ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"
  if [ -n "$APP" ]; then
    echo "Archived bundle: $APP"
    /usr/libexec/PlistBuddy \
      -c 'Print :CFBundleIdentifier' \
      -c 'Print :CFBundleShortVersionString' \
      -c 'Print :CFBundleVersion' \
      "$APP/Info.plist"
    codesign --verify --deep --strict --verbose=2 "$APP" || echo "warning: codesign verification reported a problem"
  fi
fi
