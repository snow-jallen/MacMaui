# Telemetry in production

The Aspire dashboard only exists while `aspire start` is running on your machine. A deployed API
and an installed app have no dashboard to talk to, so the same telemetry goes to a small
**OpenObserve** container instead: one service holding logs, traces and metrics, with one UI.

Nothing vendor-specific is involved. Both the API and the app already export over OTLP, which is
how they feed the Aspire dashboard. In production they are simply pointed somewhere else.

| Where the code runs | Endpoint comes from | Destination |
|---|---|---|
| `aspire start` on your machine | the AppHost | Aspire dashboard |
| API on Azure App Service | app settings | OpenObserve |
| Installed Windows app, APK, TestFlight build | baked in at build time | OpenObserve |

## Signing in

<https://macmaui-otel.lemonmeadow-1e3ee09b.westus2.azurecontainerapps.io>

The user is `admin@example.com`. The password was printed by `scripts/azure-bootstrap.ps1`, and you
can read it back at any time:

```powershell
az containerapp secret show -g macmaui-rg -n macmaui-otel --secret-name root-password --query value -o tsv
```

Everything lands in the **default** organisation and the **default** stream.

## If you know the Aspire dashboard, you know this

| Aspire dashboard | OpenObserve |
|---|---|
| **Structured logs** | **Logs**, stream `default` |
| **Traces** | **Traces**, click any trace for the span tree |
| **Metrics** | **Metrics**, pick the instrument by name |
| **Resources** | Filter any view by `service_name` |

The layout is deliberately similar: pick a stream, pick a time range, filter, click a row. The one
difference worth knowing is that a trace and its logs are separate views rather than one pane, and
you join them with `trace_id`.

Allow a minute or so. The exporters batch, and a short app session may not flush before it closes.

## Queries worth keeping

OpenObserve's query bar takes SQL over the stream you have selected.

**Everything logged, newest first**

```sql
SELECT _timestamp, service_name, severity_text, body
FROM default
ORDER BY _timestamp DESC
```

**Only the mobile app, not the API**

```sql
SELECT _timestamp, severity_text, body
FROM default
WHERE service_name = 'MacMaui.Mobile'
ORDER BY _timestamp DESC
```

**One press of Get Weather, end to end.** In **Traces**, search for the `GetWeather` operation and
open it. The span tree shows the button press, the outgoing HTTP call and the API's handling of it,
with `weather.days_requested` on each. To pull the logs belonging to the same trace, copy its id
into the Logs view:

```sql
SELECT _timestamp, service_name, body
FROM default
WHERE trace_id = 'PASTE_TRACE_ID'
ORDER BY _timestamp
```

**How often each day count is asked for.** In **Metrics**, select
`macmaui_mobile_weather_requests` and group by `days` and `outcome`. Both tags are recorded on
every press including failures, so a failed request never loses the day count.

**Whether asking for more days costs the user anything.** Select
`macmaui_mobile_weather_request_duration` and group by `days`. With the server-side cache warm it
largely should not, and this is the chart that shows it.

**Which app versions are in the wild**

```sql
SELECT service_version, COUNT(*) AS n
FROM default
GROUP BY service_version
ORDER BY n DESC
```

Useful for seeing whether people have taken the Velopack update.

## Cost, retention, and the one real limitation

Roughly 10 dollars a month: a single Container Apps replica that has to stay warm to receive
telemetry.

**Telemetry does not survive a container restart.** It lives on the replica's own disk, so a
platform restart, an image update or a configuration change starts the history over. Within a
session it is complete; across weeks it is not.

That is not an oversight, it is a wall. OpenObserve keeps its metadata in SQLite, and SQLite
cannot run on an Azure Files SMB share: mounting one makes the container die at startup with
*"attempt to write a readonly database"*. Container Apps offers only Azure Files, and its NFS
flavour, which SQLite would tolerate, requires a premium account reachable solely from a virtual
network, meaning the whole environment has to be rebuilt inside one.

If durable history becomes necessary, the honest options are:

| Option | Cost | Effort |
|---|---|---|
| Live with it: fine for demos and live debugging | ~$10/month | none, this is today |
| Rebuild the environment in a VNet with a premium NFS share | ~$26/month | moderate, new networking |
| Run OpenObserve on a small VM with a managed disk | ~$20/month | moderate, a VM to maintain |
| Grafana Cloud free tier, nothing to host | $0 | small, but three sub-systems to learn |

`ZO_COMPACT_DATA_RETENTION_DAYS` is set to 30 days and is the ceiling rather than the
expectation, since a restart will usually come first.

## A caveat worth understanding

The apps carry the OTLP endpoint and the basic auth header inside the binary, so anyone who
installs one can read them and could post telemetry to your instance. That is the price of
client-side telemetry and is no different from the key a website's JavaScript ships.

If it is ever abused, rotate it:

```powershell
az containerapp secret set -g macmaui-rg -n macmaui-otel --secrets root-password=<new>
./scripts/azure-bootstrap.ps1 -AppName macmaui-api-jallen
git commit --allow-empty -m "Rebuild clients with the rotated telemetry credentials" && git push
```

The script picks up the new password, updates the API's settings and the GitHub secrets, and the
next release rebuilds the clients against it.

## When nothing shows up

1. **Wait a minute.** The exporters batch before sending.
2. **Check the server has its settings.**
   ```powershell
   az webapp config appsettings list -g macmaui-rg -n macmaui-api-jallen `
     --query "[?starts_with(name,'OTEL_')].name" -o tsv
   ```
3. **Check the client build received them.** A build only reports if it was given
   `-p:OtlpEndpoint=...`, which GitHub Actions passes from the `OTLP_ENDPOINT` and `OTLP_HEADERS`
   secrets. For iOS the same two values must be set by hand under **Environment** on the Xcode
   Cloud workflow, because the App Store Connect API cannot write them and this repository is
   public so they cannot be committed. The post-clone script warns when they are missing.
4. **Remember which build you are running.** A debug build started from Visual Studio has no
   endpoint at all, by design. Run it under `aspire start` for the dashboard, or install a release
   build to report here.
5. **Check the container is up.**
   ```powershell
   az containerapp replica list -g macmaui-rg -n macmaui-otel -o table
   ```
