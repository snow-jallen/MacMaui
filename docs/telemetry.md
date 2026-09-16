# Telemetry in production

The Aspire dashboard only exists while `aspire start` is running on your machine. A deployed API
and an installed app have no dashboard to talk to, so the same OpenTelemetry signals go to
**Application Insights** instead.

Nothing in the app changed to make that work. The API and the client still create spans, logs and
metrics exactly as before; only the exporter differs, chosen at startup by whether a connection
string is present.

| Where the code runs | Exporter | Destination |
|---|---|---|
| `aspire start` on your machine | OTLP, endpoint injected by the AppHost | Aspire dashboard |
| API on Azure App Service | Azure Monitor | Application Insights |
| Installed Windows app, APK, TestFlight build | Azure Monitor | Application Insights |

The server reads `APPLICATIONINSIGHTS_CONNECTION_STRING` from its App Service settings. The client
has no settings to read, so the connection string is baked into the binary at build time, the same
mechanism as the API address. Neither is set when running under Aspire, so local development is
untouched and still uses the dashboard.

## Opening it

Azure portal, resource group `macmaui-rg`, resource **macmaui-insights**. Or:

```powershell
az monitor app-insights component show --app macmaui-insights -g macmaui-rg --query id -o tsv
```

## If you know the Aspire dashboard, you know this

| Aspire dashboard | Application Insights | What to expect |
|---|---|---|
| **Traces** | **Investigate > Transaction search**, then click a result for the end-to-end view | A request from the app to the API appears as one operation spanning both, exactly as in the dashboard |
| **Structured logs** | **Monitoring > Logs**, query the `traces` table | Your `ILogger` output, with scopes and structured properties preserved |
| **Metrics** | **Monitoring > Metrics**, metric namespace *azure.applicationinsights* | The custom counter and histogram from `Telemetry.cs` appear here |
| **Resources** graph | **Investigate > Application map** | API and client shown as nodes with call volumes and failure rates |
| Watching it live | **Investigate > Live metrics** | Sub-second view while you press the button, useful for demos |

The one habit to unlearn: the dashboard is instant, Application Insights is not. Telemetry is
batched client-side and indexed server-side, so allow **one to three minutes** before it appears.
Live metrics is the exception and is near real time.

## Queries worth keeping

Logs, traces and metrics all live in tables you query with KQL under **Monitoring > Logs**.

**Recent logs from everything**

```kusto
traces
| where timestamp > ago(30m)
| project timestamp, message, severityLevel, cloud_RoleName, operation_Id
| order by timestamp desc
```

`cloud_RoleName` is how you tell the API and the client apart.

**Follow one user action end to end**

```kusto
union traces, dependencies, requests, exceptions
| where operation_Id == "PASTE_AN_OPERATION_ID"
| project timestamp, itemType, name, message, duration, success
| order by timestamp asc
```

Grab an `operation_Id` from any row above. This is the query equivalent of clicking a trace in the
Aspire dashboard, showing the button press, the outgoing HTTP call and the API's handling together.

**The app's own counter**

```kusto
customMetrics
| where name == "macmaui.mobile.weather_requests"
| summarize requests = sum(valueSum) by tostring(customDimensions.outcome), bin(timestamp, 5m)
| render timechart
```

That is the counter from `MacMaui.ClientLogic/Telemetry.cs`, tagged with `outcome` of `success` or
`failure`.

**How long requests take, from the client's point of view**

```kusto
customMetrics
| where name == "macmaui.mobile.weather_request.duration"
| summarize avg = sum(valueSum) / sum(valueCount), p95 = percentile(valueMax, 95) by bin(timestamp, 5m)
| render timechart
```

**Which app versions are in the wild**

```kusto
union requests, customMetrics
| where timestamp > ago(7d)
| summarize count() by application_Version, cloud_RoleName
```

Useful for seeing whether people have taken the Velopack update.

**Failures only**

```kusto
exceptions
| where timestamp > ago(1d)
| project timestamp, cloud_RoleName, type, outerMessage, operation_Id
| order by timestamp desc
```

## Cost, and a caveat worth understanding

Azure Monitor includes 5 GB of ingestion per month at no charge, and this app produces a tiny
fraction of that. The bootstrap script also sets a **1 GB per day cap**, after which telemetry is
dropped until the next day rather than billed. Raise it with:

```powershell
az monitor app-insights component billing update --app macmaui-insights -g macmaui-rg --cap 5
```

The caveat: the client's connection string is inside the shipped app, and anyone who installs it
can read it. That is normal for client-side telemetry, the same as a website's JavaScript key, but
it does mean someone could send junk to your resource. The daily cap is what stops that becoming a
bill. If the resource ever fills up with data you did not send, create a new Application Insights
resource, run the bootstrap script again and publish a new build.

## When nothing shows up

1. **Wait three minutes.** Batching plus indexing genuinely takes that long.
2. **Check the server has its setting.**
   ```powershell
   az webapp config appsettings list -g macmaui-rg -n macmaui-api-jallen `
     --query "[?name=='APPLICATIONINSIGHTS_CONNECTION_STRING'].name" -o tsv
   ```
3. **Check the client build received one.** The connection string only reaches a build that was
   given `-p:ApplicationInsightsConnectionString=...`, which GitHub Actions passes from the
   `APPINSIGHTS_CONNECTION_STRING` secret. A build made by hand without it reports nothing, by
   design.
4. **Remember which build you are running.** A debug build started from Visual Studio has neither
   a connection string nor an Aspire endpoint, so it reports nowhere at all. Run it under
   `aspire start` for the dashboard, or install a release build for Application Insights.
