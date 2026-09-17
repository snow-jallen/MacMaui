<#
.SYNOPSIS
    One-time setup for .github/workflows/release.yml: creates the Azure App Service that hosts
    MacMaui.ApiService, lets GitHub Actions deploy to it, and stores the resulting secrets and
    variables on the GitHub repository.

.DESCRIPTION
    Idempotent: safe to run again after a partial failure.

    Azure side (in the chosen subscription):
      - resource group, Linux App Service plan, .NET 10 web app
      - an Entra app registration with a federated credential trusting GitHub Actions
        (subject repo:<owner>/<repo>:environment:production), holding Website Contributor
        on the resource group. No client secret anywhere.
      - or, with -UsePublishProfile (for tenants where you cannot create app registrations),
        the web app's publish profile is stored as a GitHub secret instead.

    GitHub side (via gh, which must be logged in):
      variables AZURE_WEBAPP_NAME, AZURE_RESOURCE_GROUP, API_BASE_URL
      secrets   AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID   (OIDC)
             or AZURE_WEBAPP_PUBLISH_PROFILE                            (-UsePublishProfile)

    Prints API_BASE_URL at the end. Set the same value as an environment variable on the Xcode
    Cloud workflow so the iOS build talks to the same API.

.EXAMPLE
    ./scripts/azure-bootstrap.ps1
    ./scripts/azure-bootstrap.ps1 -AppName macmaui-api-jallen -Sku B1
    ./scripts/azure-bootstrap.ps1 -UsePublishProfile
#>
[CmdletBinding()]
param(
    # Subscription name or id. Defaults to the faculty subscription.
    [string]$Subscription = 'faculty_Jonathan_Allen',
    [string]$ResourceGroup = 'macmaui-rg',
    [string]$Location = 'westus2',
    # Globally unique; becomes <AppName>.azurewebsites.net (or a regional variant).
    [string]$AppName = 'macmaui-api',
    # F1 is free (60 CPU-minutes/day, cold starts). B1 is the cheapest always-warm tier.
    [string]$Sku = 'F1',
    # OpenObserve: one container holding logs, traces and metrics, reachable over OTLP.
    [string]$EnvironmentName = 'macmaui-env',
    [string]$OpenObserveName = 'macmaui-otel',
    [string]$OpenObserveTag = 'v0.20.3',
    [string]$OpenObserveEmail = 'admin@example.com',
    [int]$RetentionDays = 30,
    # owner/name. Defaults to the repository the current directory is a clone of.
    [string]$Repo,
    # GitHub environment the deploy job runs in; must match release.yml.
    [string]$Environment = 'production',
    [switch]$UsePublishProfile
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    # Always a string, never $null, so callers can .Trim() an empty query result.
    ($out -join "`n")
}

Write-Host "==> Azure subscription $Subscription"
# A name can match several subscriptions (a disabled twin is common); pick the enabled one.
$subId = (Invoke-Az account list --all --query "[?(name=='$Subscription' || id=='$Subscription') && state=='Enabled'].id | [0]" -o tsv).Trim()
if (-not $subId) { throw "No enabled subscription named or with id '$Subscription'. Run 'az login' or pass -Subscription." }
Invoke-Az account set --subscription $subId | Out-Null
$tenantId = (Invoke-Az account show --query tenantId -o tsv).Trim()

if (-not $Repo) {
    $Repo = (& gh repo view --json nameWithOwner -q .nameWithOwner).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $Repo) {
        throw 'Could not determine the GitHub repository. Push this folder to GitHub first (gh repo create --source . --push) or pass -Repo owner/name.'
    }
}
Write-Host "==> GitHub repository $Repo"

Write-Host "==> Resource group $ResourceGroup in $Location"
Invoke-Az group create --name $ResourceGroup --location $Location -o none

$planName = "$AppName-plan"
Write-Host "==> App Service plan $planName ($Sku, Linux)"
$planExists = (Invoke-Az appservice plan list -g $ResourceGroup --query "[?name=='$planName'] | length(@)" -o tsv).Trim()
if ($planExists -eq '0') {
    Invoke-Az appservice plan create -g $ResourceGroup -n $planName --is-linux --sku $Sku -o none
}

Write-Host "==> Web app $AppName (.NET 10)"
$appExists = (Invoke-Az webapp list -g $ResourceGroup --query "[?name=='$AppName'] | length(@)" -o tsv).Trim()
if ($appExists -eq '0') {
    Invoke-Az webapp create -g $ResourceGroup -p $planName -n $AppName --runtime 'DOTNETCORE:10.0' -o none
}
Invoke-Az webapp config set -g $ResourceGroup -n $AppName --http20-enabled true --min-tls-version 1.2 -o none
Invoke-Az webapp update -g $ResourceGroup -n $AppName --https-only true -o none
$hostName = (Invoke-Az webapp show -g $ResourceGroup -n $AppName --query defaultHostName -o tsv).Trim()
$apiBaseUrl = "https://$hostName"

# --- OpenObserve -----------------------------------------------------------------------------
# Where telemetry goes once the app is no longer running under the Aspire dashboard. Without a
# destination the OpenTelemetry spans, logs and metrics are produced and then dropped, because
# the service defaults only export when they are told an endpoint.
#
# One container, one UI for all three signals, and plain OTLP, so the apps need no vendor SDK:
# the exporter they already use for the Aspire dashboard is simply pointed somewhere else.
# No volume is mounted, and that is deliberate rather than an omission.
#
# OpenObserve keeps its metadata in SQLite, and SQLite cannot run on an Azure Files SMB share:
# the container starts, fails to take a write lock, and dies with
#   "attempt to write a readonly database"
#   "db init failed: pool timed out while waiting for an open connection"
# Container Apps offers only Azure Files, and its NFS flavour, which SQLite could use, needs a
# premium account reachable solely from a virtual network, so the environment would have to be
# rebuilt inside one.
#
# The consequence: telemetry lives on the replica's own disk and is lost if the container
# restarts. Fine for watching what an app is doing now, no good for looking at last week. See
# docs/telemetry.md for the options if that stops being acceptable.
Write-Host "==> Container Apps environment $EnvironmentName"
$envExists = (Invoke-Az containerapp env list -g $ResourceGroup --query "[?name=='$EnvironmentName'] | length(@)" -o tsv).Trim()
if ($envExists -eq '0') {
    Invoke-Az containerapp env create -g $ResourceGroup -n $EnvironmentName -l $Location -o none
}

# Generated once and then reused, so re-running this script does not lock the apps out of the
# backend they were built against.
# Not Invoke-Az: on a first run the container app does not exist yet and this is expected to
# fail, which Invoke-Az would turn into a thrown error.
$existingPassword = (& az containerapp secret show -g $ResourceGroup -n $OpenObserveName --secret-name root-password --query value -o tsv 2>$null)
if ($LASTEXITCODE -eq 0 -and $existingPassword) {
    $openObservePassword = ($existingPassword -join '').Trim()
}
else {
    $openObservePassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
}

Write-Host "==> OpenObserve container app $OpenObserveName"
$appExists2 = (Invoke-Az containerapp list -g $ResourceGroup --query "[?name=='$OpenObserveName'] | length(@)" -o tsv).Trim()
if ($appExists2 -eq '0') {
    Invoke-Az containerapp create -g $ResourceGroup -n $OpenObserveName --environment $EnvironmentName `
        --image "openobserve/openobserve:$OpenObserveTag" `
        --target-port 5080 --ingress external `
        --min-replicas 1 --max-replicas 1 `
        --cpu 0.5 --memory 1.0Gi `
        --secrets "root-password=$openObservePassword" `
        --env-vars "ZO_ROOT_USER_EMAIL=$OpenObserveEmail" "ZO_ROOT_USER_PASSWORD=secretref:root-password" `
                   "ZO_DATA_DIR=/data" "ZO_COMPACT_DATA_RETENTION_DAYS=$RetentionDays" `
        -o none

}

$openObserveHost = (Invoke-Az containerapp show -g $ResourceGroup -n $OpenObserveName --query "properties.configuration.ingress.fqdn" -o tsv).Trim()
$openObserveUrl = "https://$openObserveHost"
# The OTLP/HTTP exporter appends /v1/traces, /v1/metrics and /v1/logs to this base.
$otlpEndpoint = "$openObserveUrl/api/default"

# Compose the basic auth header here rather than in the apps. OTEL_EXPORTER_OTLP_HEADERS is a
# standard OpenTelemetry variable that every SDK reads on its own, so doing the base64 once at
# provisioning time means neither the API nor the client needs a line of code for authentication.
$otlpHeaders = "Authorization=Basic " + [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes("${OpenObserveEmail}:${openObservePassword}"))

Write-Host "==> App Service OTLP settings"
Invoke-Az webapp config appsettings set -g $ResourceGroup -n $AppName --settings `
    "OTEL_EXPORTER_OTLP_ENDPOINT=$otlpEndpoint" `
    "OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf" `
    "OTEL_EXPORTER_OTLP_HEADERS=$otlpHeaders" -o none

# The Application Insights setting would otherwise keep a second exporter alive alongside this one.
Invoke-Az webapp config appsettings delete -g $ResourceGroup -n $AppName `
    --setting-names APPLICATIONINSIGHTS_CONNECTION_STRING -o none 2>$null

Write-Host "==> GitHub variables"
& gh variable set AZURE_WEBAPP_NAME --repo $Repo --body $AppName
& gh variable set AZURE_RESOURCE_GROUP --repo $Repo --body $ResourceGroup
& gh variable set API_BASE_URL --repo $Repo --body $apiBaseUrl

# Secrets rather than variables so they are masked in build logs. They are not truly secret once
# the desktop and mobile builds embed them, but there is no reason to print them either.
Write-Host "==> GitHub secrets for the telemetry backend"
$otlpEndpoint | & gh secret set OTLP_ENDPOINT --repo $Repo
$otlpHeaders | & gh secret set OTLP_HEADERS --repo $Repo

if ($UsePublishProfile) {
    Write-Host "==> Publish profile -> secret AZURE_WEBAPP_PUBLISH_PROFILE"
    $profile = Invoke-Az webapp deployment list-publishing-profiles -g $ResourceGroup -n $AppName --xml
    ($profile -join "`n") | & gh secret set AZURE_WEBAPP_PUBLISH_PROFILE --repo $Repo
    & gh secret delete AZURE_CLIENT_ID --repo $Repo 2>$null
}
else {
    $regName = "$AppName-github"
    Write-Host "==> App registration $regName for GitHub OIDC"
    $appId = (Invoke-Az ad app list --display-name $regName --query '[0].appId' -o tsv).Trim()
    if (-not $appId) {
        $appId = (Invoke-Az ad app create --display-name $regName --query appId -o tsv).Trim()
    }
    $spId = (Invoke-Az ad sp list --filter "appId eq '$appId'" --query '[0].id' -o tsv).Trim()
    if (-not $spId) {
        $spId = (Invoke-Az ad sp create --id $appId --query id -o tsv).Trim()
    }

    Write-Host "==> Website Contributor on $ResourceGroup"
    Invoke-Az role assignment create `
        --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
        --role 'Website Contributor' `
        --scope "/subscriptions/$subId/resourceGroups/$ResourceGroup" -o none

    # GitHub's OIDC subject comes in two spellings depending on the repository's token settings:
    # repo:owner/name:environment:X and repo:owner@<ownerId>/name@<repoId>:environment:X.
    # Entra matches the subject literally, so register both.
    $owner, $name = $Repo -split '/'
    $ownerId, $repoId = (& gh api "repos/$Repo" --jq '"\(.owner.id) \(.id)"').Trim() -split ' '
    if ($LASTEXITCODE -ne 0 -or -not $repoId) { throw "gh api repos/$Repo failed" }
    $credentials = @(
        @{ name = "github-$Environment";     subject = "repo:${Repo}:environment:$Environment" }
        @{ name = "github-$Environment-ids"; subject = "repo:${owner}@${ownerId}/${name}@${repoId}:environment:$Environment" }
    )
    foreach ($credential in $credentials) {
        Write-Host "==> Federated credential for $($credential.subject)"
        $existing = (Invoke-Az ad app federated-credential list --id $appId --query "[?subject=='$($credential.subject)'] | length(@)" -o tsv).Trim()
        if ($existing -ne '0') { continue }
        $paramsFile = Join-Path ([IO.Path]::GetTempPath()) "macmaui-fic-$([guid]::NewGuid()).json"
        @{
            name      = $credential.name
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = $credential.subject
            audiences = @('api://AzureADTokenExchange')
        } | ConvertTo-Json | Set-Content -Path $paramsFile -Encoding utf8
        try {
            Invoke-Az ad app federated-credential create --id $appId --parameters "@$paramsFile" -o none
        }
        finally {
            Remove-Item $paramsFile -ErrorAction SilentlyContinue
        }
    }

    Write-Host "==> GitHub secrets for OIDC login"
    & gh secret set AZURE_CLIENT_ID --repo $Repo --body $appId
    & gh secret set AZURE_TENANT_ID --repo $Repo --body $tenantId
    & gh secret set AZURE_SUBSCRIPTION_ID --repo $Repo --body $subId
    & gh secret delete AZURE_WEBAPP_PUBLISH_PROFILE --repo $Repo 2>$null
}

Write-Host ''
Write-Host 'Done.'
Write-Host "  API_BASE_URL  = $apiBaseUrl"
Write-Host "  Telemetry UI  = $openObserveUrl"
Write-Host "  OTLP endpoint = $otlpEndpoint"
Write-Host "  Sign in as    $OpenObserveEmail"
Write-Host "  Password      $openObservePassword"
Write-Host ''
Write-Host 'Next:'
Write-Host "  1. Xcode Cloud workflow > Environment, add both, the second marked secret:"
Write-Host "       OTLP_ENDPOINT = $otlpEndpoint"
Write-Host "       OTLP_HEADERS  = $otlpHeaders"
Write-Host '  2. git push origin main    (every push deploys)'
exit 0   # the optional `gh secret delete` above may have set a nonzero exit code
