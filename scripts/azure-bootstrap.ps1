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
    [string]$WorkspaceName = 'macmaui-logs',
    [string]$InsightsName = 'macmaui-insights',
    # GB per day of telemetry before ingestion stops until tomorrow. Azure Monitor includes
    # 5 GB per month free, so this is a guard rail rather than an expected cost.
    [int]$DailyCapGb = 1,
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

# --- Application Insights -------------------------------------------------------------------
# Where telemetry goes once the app is no longer running under the Aspire dashboard. Without
# this the OpenTelemetry spans, logs and metrics are produced and then dropped, because the
# service defaults only export when they are told an endpoint.
Write-Host "==> Log Analytics workspace $WorkspaceName"
$workspaceExists = (Invoke-Az monitor log-analytics workspace list -g $ResourceGroup --query "[?name=='$WorkspaceName'] | length(@)" -o tsv).Trim()
if ($workspaceExists -eq '0') {
    Invoke-Az monitor log-analytics workspace create -g $ResourceGroup -n $WorkspaceName -l $Location -o none
}
$workspaceId = (Invoke-Az monitor log-analytics workspace show -g $ResourceGroup -n $WorkspaceName --query id -o tsv).Trim()

Write-Host "==> Application Insights $InsightsName"
if (-not (& az extension show --name application-insights 2>$null)) {
    Invoke-Az extension add --name application-insights --yes -o none
}
$insightsExists = (Invoke-Az monitor app-insights component show -g $ResourceGroup --query "[?name=='$InsightsName'] | length(@)" -o tsv 2>$null)
if (-not $insightsExists -or $insightsExists.Trim() -eq '0') {
    Invoke-Az monitor app-insights component create `
        --app $InsightsName -g $ResourceGroup -l $Location `
        --workspace $workspaceId --application-type web -o none
}
$insightsConnection = (Invoke-Az monitor app-insights component show --app $InsightsName -g $ResourceGroup --query connectionString -o tsv).Trim()

# A daily cap so a runaway loop, or someone else using the ingestion key lifted out of the
# shipped client, cannot run up a bill. Telemetry past the cap is dropped until the next day.
Write-Host "==> Daily ingestion cap: $DailyCapGb GB"
try {
    Invoke-Az monitor app-insights component billing update --app $InsightsName -g $ResourceGroup --cap $DailyCapGb -o none
}
catch {
    Write-Warning "Could not set the daily cap; set it in the portal under Usage and estimated costs."
}

Write-Host "==> App Service setting APPLICATIONINSIGHTS_CONNECTION_STRING"
Invoke-Az webapp config appsettings set -g $ResourceGroup -n $AppName `
    --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$insightsConnection" -o none

Write-Host "==> GitHub variables"
& gh variable set AZURE_WEBAPP_NAME --repo $Repo --body $AppName
& gh variable set AZURE_RESOURCE_GROUP --repo $Repo --body $ResourceGroup
& gh variable set API_BASE_URL --repo $Repo --body $apiBaseUrl

# A secret rather than a variable so it is masked in build logs. It is not truly secret once
# the desktop and mobile builds embed it, but there is no reason to print it either.
Write-Host "==> GitHub secret APPINSIGHTS_CONNECTION_STRING"
$insightsConnection | & gh secret set APPINSIGHTS_CONNECTION_STRING --repo $Repo

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
Write-Host "  API_BASE_URL = $apiBaseUrl"
Write-Host "  Application Insights = $InsightsName (daily cap $DailyCapGb GB)"
Write-Host ''
Write-Host 'Next:'
Write-Host "  1. Xcode Cloud workflow > Environment: add API_BASE_URL = $apiBaseUrl"
Write-Host '  2. git tag v1.0.0 && git push --tags     (or run the Release workflow from the Actions tab)'
exit 0   # the optional `gh secret delete` above may have set a nonzero exit code
