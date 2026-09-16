# MacMaui

An [Aspire](https://aspire.dev) solution with a .NET MAUI client wired for OpenTelemetry,
generated from the `publicotel-maui` template, plus a release pipeline that ships the API to
Azure and the app to iOS, Android, and Windows from a Windows development machine. No Mac.

## What is here

| Path | Purpose |
|---|---|
| `MacMaui.AppHost` | Aspire AppHost for local development: API, Blazor web, MAUI Windows and Android targets, dev tunnels. |
| `MacMaui.ApiService` | Minimal API serving `/weatherforecast`. This is what gets deployed to Azure. |
| `MacMaui.Web` | Blazor frontend (local development only). |
| `MacMaui.Mobile` | .NET MAUI app. One **Get Weather** button. |
| `MacMaui.ClientLogic`, `MacMaui.ClientTests` | UI-agnostic client code and its tests. |
| `MacMaui.ServiceDefaults`, `MacMaui.MauiServiceDefaults` | Aspire defaults for the servers and for MAUI. |
| `MacMaui.Tests` | Integration tests against the AppHost. |
| `XcodeCloud/` | Wrapper Xcode project and scripts so Xcode Cloud builds, signs, and TestFlights the iOS app. See [XcodeCloud/README.md](XcodeCloud/README.md). |
| `.github/workflows/release.yml` | Deploys the API to Azure App Service, builds the APK and the Windows app against it, publishes a GitHub release. |
| `scripts/azure-bootstrap.ps1` | One-time Azure and GitHub setup for that workflow. |
| `scripts/run-android.ps1` | Local Android launch helper from the template. |

## Local development

```bash
aspire start
```

Start the `mobile-windows` resource from the dashboard and press **Get Weather**. For Android,
use the resource's **Run on Android** command. Inside Aspire the app finds the API through
the environment variables the AppHost injects.

## How the released apps find the API

Aspire is not there when someone installs the APK. Release builds bake the address in:

```
dotnet publish ... -p:ApiBaseUrl=https://macmaui-api.azurewebsites.net
```

The csproj turns that property into an assembly metadata attribute, and `MauiProgram.cs`
registers it as the service discovery entry for `apiservice` before the Aspire defaults run.
The rest of the app is unchanged: it still calls `https+http://apiservice`, and inside Aspire
the injected environment still wins. All three platform builds receive the same value, the
`API_BASE_URL` repository variable (GitHub Actions) or workflow environment variable
(Xcode Cloud).

## Release pipeline

Current deployment: the API runs at <https://macmaui-api-jallen.azurewebsites.net> (resource
group `macmaui-rg`, faculty subscription), and releases are at
<https://github.com/snow-jallen/MacMaui/releases>.

```
git tag v1.2.3 && git push --tags
        │
        ├── GitHub Actions (release.yml)
        │     ├── deploy-api  → Azure App Service       (.NET 10, Linux)
        │     ├── android     → MacMaui.Mobile-1.2.3-android.apk
        │     ├── windows     → MacMaui.Mobile-1.2.3-windows-x64.zip
        │     └── release     → GitHub release with both files + SHA256SUMS
        │
        └── Xcode Cloud (XcodeCloud/)   [triggered by any push to main]
              └── archive     → TestFlight
```

The iOS side is driven by `scripts/xcode-cloud-workflow.py`, which creates or rewrites the
Xcode Cloud workflow through the App Store Connect API and can start a build. Only the initial
product registration needed Xcode; everything since is scripted.

Versions: the display version is the tag without its `v`; the build number is the GitHub run
number (Android `versionCode`, Windows file version) or the Xcode Cloud build number (iOS
`CFBundleVersion`). Running the workflow by hand without a tag produces `0.0.<run number>`
and creates that tag.

### One-time setup

1. **Put the repository on GitHub.**
   ```powershell
   git add -A
   git commit -m "MacMaui: Aspire + MAUI with Xcode Cloud and Azure release pipeline"
   gh repo create snow-jallen/MacMaui --private --source . --push
   ```
2. **Create the Azure resources and wire GitHub to them.** Uses the faculty subscription by
   default; pass `-Subscription` to choose another.
   ```powershell
   ./scripts/azure-bootstrap.ps1
   ```
   This creates a resource group, a free (F1) Linux App Service plan, and a .NET 10 web app;
   registers an Entra application that GitHub Actions can sign into with OIDC (no stored
   secret) and gives it Website Contributor on the resource group; and stores the
   `AZURE_*` secrets plus the `AZURE_WEBAPP_NAME`, `AZURE_RESOURCE_GROUP`, and `API_BASE_URL`
   variables on the repository. If your tenant will not let you create app registrations,
   run it with `-UsePublishProfile` instead. Pass `-Sku B1` for an always-warm tier.
3. **Set up Xcode Cloud** as described in [XcodeCloud/README.md](XcodeCloud/README.md),
   giving its workflow the `API_BASE_URL` the bootstrap script printed.
4. **Optional: a release keystore for Android.** Without one the APK carries the default
   debug signature, which installs fine but cannot be updated later by a Play Store build.
   To sign properly, add the secrets `ANDROID_KEYSTORE_BASE64` (the keystore file, base64),
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`.

### Cutting a release

```powershell
git tag v1.0.0
git push --tags
```

Or open **Actions > Release > Run workflow** and type a version.

## Notes

- The Windows download is a zip of a self-contained, unpackaged app: extract it and run
  `MacMaui.Mobile.exe`. MAUI Windows apps are folders, not single executables.
- Free-tier App Service sleeps after 20 idle minutes; the first request afterwards takes
  20 to 60 seconds. The workflow's smoke test retries for that reason.
- The API has no authentication. It serves random weather to anyone who asks.
- `dotnet publish` should be scoped to a single project, never the solution, because the
  MAUI project cannot publish for every platform from one machine.
