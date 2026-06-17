#requires -Version 7.0
<#
.SYNOPSIS
    Builds container images in ACR and rolls them out to Container Apps.

.DESCRIPTION
    - Reads ACR login server and container app names from the deployment outputs
      (or accepts them as parameters).
    - Runs `az acr build` for backend and frontend (server-side build — no local Docker).
    - Updates each container app to the new image.
    - Prints the public frontend URL.

.PARAMETER ResourceGroupName
    Workload resource group. Default: rg-workload-test

.PARAMETER DeploymentName
    Name of the Bicep deployment to read outputs from. If not set, uses the latest deployment.

.PARAMETER AcrLoginServer
    Override: ACR login server (e.g. crhotelbooking....azurecr.io).

.PARAMETER BackendAppName
    Override: backend container app name.

.PARAMETER FrontendAppName
    Override: frontend container app name.

.PARAMETER ImageTag
    Image tag. Defaults to short git SHA.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-workload-test',
    [string]$DeploymentName,
    [string]$AcrLoginServer,
    [string]$BackendAppName,
    [string]$FrontendAppName,
    [string]$ImageTag
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Resolve image tag ────────────────────────────────────────────────────────
if (-not $ImageTag) {
    $ImageTag = git -C $repoRoot rev-parse --short HEAD 2>$null
    if (-not $ImageTag) { $ImageTag = Get-Date -Format 'yyyyMMddHHmmss' }
}
Write-Host "Image tag: $ImageTag" -ForegroundColor Cyan

# ── Resolve deployment outputs ───────────────────────────────────────────────
if (-not $AcrLoginServer -or -not $BackendAppName -or -not $FrontendAppName) {
    Write-Host "Reading deployment outputs from '$ResourceGroupName'..." -ForegroundColor Cyan

    if (-not $DeploymentName) {
        $DeploymentName = az deployment group list `
            --resource-group $ResourceGroupName `
            --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name" `
            -o tsv
        if (-not $DeploymentName) {
            Write-Error "No successful deployment found in '$ResourceGroupName'. Specify -DeploymentName or provide all override parameters."
        }
        Write-Host "  Using deployment: $DeploymentName" -ForegroundColor Gray
    }

    $outputs = az deployment group show `
        --resource-group $ResourceGroupName `
        --name $DeploymentName `
        --query 'properties.outputs' -o json | ConvertFrom-Json

    if (-not $AcrLoginServer) { $AcrLoginServer = $outputs.acrLoginServer.value }
    if (-not $BackendAppName) { $BackendAppName = $outputs.backendAppName.value }
    if (-not $FrontendAppName) { $FrontendAppName = $outputs.frontendAppName.value }
}

Write-Host "ACR:      $AcrLoginServer" -ForegroundColor Gray
Write-Host "Backend:  $BackendAppName" -ForegroundColor Gray
Write-Host "Frontend: $FrontendAppName" -ForegroundColor Gray

# ── ACR login (Entra-based, no admin user) ───────────────────────────────────
Write-Host "`nLogging into ACR..." -ForegroundColor Cyan
az acr login --name $AcrLoginServer

# ── Build backend image ──────────────────────────────────────────────────────
$backendRepo = 'hotelbooking/backend'
$backendContext = Join-Path $repoRoot 'workload-app' 'backend' 'HotelBooking.Api'
$backendDockerfile = Join-Path $backendContext 'Dockerfile'

Write-Host "`nBuilding backend image ($backendRepo`:$ImageTag)..." -ForegroundColor Cyan
az acr build `
    --registry $AcrLoginServer `
    --image "${backendRepo}:${ImageTag}" `
    --image "${backendRepo}:latest" `
    --file $backendDockerfile `
    $backendContext

# ── Build frontend image ─────────────────────────────────────────────────────
$frontendRepo = 'hotelbooking/frontend'
$frontendContext = Join-Path $repoRoot 'workload-app' 'frontend'
$frontendDockerfile = Join-Path $frontendContext 'Dockerfile'

Write-Host "`nBuilding frontend image ($frontendRepo`:$ImageTag)..." -ForegroundColor Cyan
az acr build `
    --registry $AcrLoginServer `
    --image "${frontendRepo}:${ImageTag}" `
    --image "${frontendRepo}:latest" `
    --file $frontendDockerfile `
    $frontendContext

# ── Roll out backend ─────────────────────────────────────────────────────────
$backendImage = "${AcrLoginServer}/${backendRepo}:${ImageTag}"
Write-Host "`nUpdating backend container app ($BackendAppName) with $backendImage..." -ForegroundColor Cyan
az containerapp update `
    --resource-group $ResourceGroupName `
    --name $BackendAppName `
    --image $backendImage `
    -o table

# ── Roll out frontend ────────────────────────────────────────────────────────
$frontendImage = "${AcrLoginServer}/${frontendRepo}:${ImageTag}"
Write-Host "`nUpdating frontend container app ($FrontendAppName) with $frontendImage..." -ForegroundColor Cyan
az containerapp update `
    --resource-group $ResourceGroupName `
    --name $FrontendAppName `
    --image $frontendImage `
    -o table

# ── Print frontend URL ───────────────────────────────────────────────────────
$frontendFqdn = az containerapp show `
    --resource-group $ResourceGroupName `
    --name $FrontendAppName `
    --query 'properties.configuration.ingress.fqdn' -o tsv

Write-Host "`n=== Deployment complete ===" -ForegroundColor Green
Write-Host "Frontend URL: https://$frontendFqdn" -ForegroundColor Green
