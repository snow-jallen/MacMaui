# Building the iOS app with Xcode Cloud

**Current state: working.** The product and the `TestFlight` workflow exist, and build 4
reached TestFlight on 2026-09-16. Pushing to `main` builds and distributes to the Internal
group. The setup steps below are kept for reference and for rebuilding this from scratch.

To change the workflow, edit `scripts/xcode-cloud-workflow.py` and run it; it rewrites the
workflow in place through the App Store Connect API. Do not hand-edit it in App Store Connect,
or the next run of the script will overwrite your change.

```bash
ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=/path/AuthKey_XXXXXXXXXX.p8 \
    python scripts/xcode-cloud-workflow.py --start-build
```

Xcode Cloud is the Mac. You develop on Windows, push to GitHub, and Apple's build machines
compile the .NET MAUI iOS app, sign it, and put it on TestFlight. No Mac, no certificate
export, no provisioning profile juggling.

## How it works

Xcode Cloud only knows how to archive an Xcode project, so this folder gives it one.

| Path | Role |
|---|---|
| `MacMauiCloud.xcodeproj` | A wrapper iOS app target named `MacMaui.Mobile` whose product name and bundle identifier mirror the MAUI project. Its only source is a one-line `main.c`. |
| `ci_scripts/ci_post_clone.sh` | Xcode Cloud runs this right after cloning. It installs the .NET SDK and the `maui-ios` workload, builds `MacMaui.Mobile` for `ios-arm64` in Release, and stages the resulting `.app` in `XcodeCloud/build/`. |
| `scripts/embed-maui-app.sh` | Run by the wrapper target's last build phase, after Xcode has laid out its placeholder bundle and before it code-signs. It replaces the placeholder's contents with the staged MAUI `.app`. |
| `ci_scripts/ci_post_xcodebuild.sh` | Diagnostics only: prints the version and signature of what was archived. |

So the archive Xcode Cloud signs and uploads *is* the MAUI app, with Xcode Cloud's own
managed signing. The .NET side signs ad hoc (`CodesignKey=-`), which the .NET iOS build
accepts without any certificate; Xcode then re-signs the whole bundle for real.

Two csproj details make the .NET build possible on a Mac that has only the iOS workload:
`-p:SingleTargetFramework=net10.0-ios` trims the target framework list to iOS (and picks
the `ios-arm64` runtime), and `-p:ApiBaseUrl=...` bakes the deployed API's address into the
app. Both are documented in `MacMaui.Mobile/MacMaui.Mobile.csproj`.

Version numbers come from Xcode Cloud: `CI_BUILD_NUMBER` becomes `CFBundleVersion`
(unique per upload, as TestFlight requires). The display version is the csproj's
`ApplicationDisplayVersion`, or the tag when the build was started by a tag like `v1.2.3`.

## One-time setup

You need an Apple Developer Program membership and the repository on GitHub.

1. **App Store Connect > Apps > + New App.** Platform iOS, bundle ID
   `edu.snow.macmaui.mobile` (register it under Identifiers first if it is not offered). This
   must equal `<ApplicationId>` in the csproj; the post-clone script refuses to build if the
   wrapper project disagrees.
2. **Connect the repository from Xcode, once.** Apple requires the *first* workflow to be
   created in Xcode; App Store Connect only shows documentation links until then. Any Mac
   with Xcode 26 will do for this half hour (a lab Mac, a colleague's, or an hourly cloud Mac):
   sign in to your Apple ID under Xcode > Settings > Accounts, clone the repo, open
   `XcodeCloud/MacMauiCloud.xcodeproj`, and choose **Integrate > Create Workflow** (the
   Xcode Cloud commands live in the Integrate menu, not under Product). Follow the assistant;
   it asks you to grant Xcode Cloud access to the GitHub repository in a browser. Afterwards,
   `scripts/xcode-cloud-workflow.py` configures the workflow properly through the App Store
   Connect API, and App Store Connect's Xcode Cloud tab can edit it too.
3. **Configure the workflow.** Accept whatever the Xcode assistant proposes, then run
   `scripts/xcode-cloud-workflow.py`, which adopts that workflow and sets everything below
   through the API. Pinning the Xcode version is not optional: the assistant defaults to
   "Latest Release", and a build on a newer Xcode than the .NET iOS workload expects fails with
   *"This version of .NET for iOS requires Xcode 26.6. The current version of Xcode is 27.0."*

   For reference, the settings the script applies, should you ever set them by hand:
   - *Start conditions:* branch changes on `main`.
   - *Environment:* **Xcode 26.6**, macOS "Latest Release". The two must be a compatible pair,
     which is why the script picks the macOS version from the Xcode version's own list.
     There is no `API_BASE_URL` variable to set: the API address comes from the committed
     `XcodeCloud/api-base-url.txt`, because the App Store Connect API cannot write Xcode Cloud
     environment variables.
   - *Actions:* one **Archive** action, scheme `MacMaui.Mobile`, platform iOS, with
     `buildDistributionAudience` set to `INTERNAL_ONLY`, which is what sends it to TestFlight.
   - Assign the build to an internal tester group once; the script can do this too.
4. Push. The first build takes roughly 15 to 25 minutes, most of it installing the .NET SDK
   and workload and AOT-compiling the app. Later builds are similar; Xcode Cloud does not
   persist tool installs between builds.

The scripts must stay executable and LF-terminated. `.gitattributes` handles line endings;
the executable bit is set with `git update-index --chmod=+x XcodeCloud/ci_scripts/*.sh
XcodeCloud/scripts/*.sh` and is already recorded in this repository.

## Reading a build log

In the post-clone step, look for:

```
==> Building edu.snow.macmaui.mobile version 1.0 (42)
==> API base URL: https://...
==> Installing the .NET SDK (channel 10.0) into /Users/local/.dotnet
==> Installing the .NET MAUI iOS workload
==> dotnet build .../MacMaui.Mobile.csproj (net10.0-ios, Release, ios-arm64)
==> Staging MacMaui.Mobile.app in .../XcodeCloud/build
```

In the archive step, the phase **Embed .NET MAUI app** prints
`Embedded edu.snow.macmaui.mobile version 1.0 (42)`. The post-xcodebuild step then prints the
archived bundle's identifiers and runs `codesign --verify --deep --strict`.

## Troubleshooting

**`error: PRODUCT_BUNDLE_IDENTIFIER ... does not match <ApplicationId>`.** You changed the
bundle ID in one place. Update both `MacMaui.Mobile.csproj` and
`MacMauiCloud.xcodeproj/project.pbxproj` (two occurrences).

**The .NET build complains about the Xcode version.** Change the Xcode version in the
workflow's Environment section to the one the workload wants. The message names it.

**`warning: API_BASE_URL is not set`.** The app builds but its Get Weather button fails.
Add the variable to the workflow environment (step 3 above).

**Xcode Cloud does not list the scheme.** The scheme is shared under
`MacMauiCloud.xcodeproj/xcshareddata/xcschemes/`; make sure that folder is committed.

**Nested code signing errors.** The embed script signs anything the .NET build placed in
`Frameworks/`. A default MAUI app has nothing there. If you add a NuGet binding that ships a
framework and see `code object is not signed at all`, check the *Embed .NET MAUI app*
phase output for `Signing nested code:` lines.

**`sudo` in a script.** Not available on Xcode Cloud, and not needed: the SDK installs into
`$HOME/.dotnet`.

## Using the wrapper on a Mac

The same project archives locally in Xcode. Build the MAUI app first:

```sh
CI_BUILD_NUMBER=1 API_BASE_URL=https://... sh XcodeCloud/ci_scripts/ci_post_clone.sh
```

then open `XcodeCloud/MacMauiCloud.xcodeproj`, set your team under Signing, and
Product > Archive. Set `MAUI_APP_BUNDLE` in the scheme's environment to embed an `.app`
staged somewhere else.
