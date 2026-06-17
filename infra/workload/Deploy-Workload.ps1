#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the HotelBooking workload infrastructure into the spoke resource group.

.DESCRIPTION
    Runs preflight checks (what-if + permission validation), then deploys
    infra/workload/main.bicep into the workload resource group.
    Requires az CLI logged in with the correct subscription selected.

.PARAMETER ResourceGroupName
    Workload resource group. Default: rg-workload-test

.PARAMETER Location
    Azure region. Default: swedencentral

.PARAMETER HubResourceGroupName
    Hub resource group name. Default: rg-platform

.PARAMETER HubVnetName
    Hub VNet name. Default: vnet-hub

.PARAMETER SpokeVnetName
    Spoke VNet name. Default: vnet-workload-test-swedencentral-001

.PARAMETER SkipWhatIf
    Skip the what-if preflight (useful after a successful first run).

.PARAMETER DeploymentName
    Override the auto-generated deployment name.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-workload-test',
    [string]$Location = 'swedencentral',
    [string]$HubResourceGroupName = 'rg-platform',
    [string]$HubVnetName = 'vnet-hub',
    [string]$SpokeVnetName = 'vnet-workload-test-swedencentral-001',
    [switch]$SkipWhatIf,
    [string]$DeploymentName = "workload-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptRoot 'main.bicep'

Write-Host "`n=== Workload Deployment ===" -ForegroundColor Cyan
Write-Host "Using subscription:" -ForegroundColor Cyan
az account show --query '{name:name, id:id}' -o table

# ── Resolve resource IDs ──────────────────────────────────────────────────

Write-Host "`nResolving hub VNet resource ID..." -ForegroundColor Cyan
$hubVnetId = az network vnet show `
    --resource-group $HubResourceGroupName `
    --name $HubVnetName `
    --query 'id' -o tsv
if (-not $hubVnetId) {
    Write-Error "Hub VNet '$HubVnetName' not found in '$HubResourceGroupName'."
}
Write-Host "  Hub VNet:  $hubVnetId" -ForegroundColor Gray

Write-Host "Resolving spoke VNet resource ID..." -ForegroundColor Cyan
$spokeVnetId = az network vnet show `
    --resource-group $ResourceGroupName `
    --name $SpokeVnetName `
    --query 'id' -o tsv
if (-not $spokeVnetId) {
    Write-Error "Spoke VNet '$SpokeVnetName' not found in '$ResourceGroupName'."
}
Write-Host "  Spoke VNet: $spokeVnetId" -ForegroundColor Gray

# ── Permission check ──────────────────────────────────────────────────────

Write-Host "`nChecking RBAC permissions on '$ResourceGroupName'..." -ForegroundColor Cyan
$callerObjectId = az ad signed-in-user show --query 'id' -o tsv 2>$null
if (-not $callerObjectId) {
    # Might be a service principal
    $callerObjectId = az account show --query 'user.name' -o tsv
    Write-Host "  Running as: $callerObjectId (service principal)" -ForegroundColor Gray
} else {
    Write-Host "  Caller object ID: $callerObjectId" -ForegroundColor Gray
}

$roles = az role assignment list `
    --assignee $callerObjectId `
    --resource-group $ResourceGroupName `
    --query "[].roleDefinitionName" -o tsv 2>$null

if ($roles) {
    Write-Host "  Roles on RG: $($roles -join ', ')" -ForegroundColor Gray
} else {
    Write-Host "  WARNING: Could not enumerate roles. Ensure you have Contributor or Owner." -ForegroundColor Yellow
}

# ── What-If preflight ────────────────────────────────────────────────────

if (-not $SkipWhatIf) {
    Write-Host "`nRunning what-if analysis..." -ForegroundColor Cyan
    az deployment group what-if `
        --resource-group $ResourceGroupName `
        --name "$DeploymentName-whatif" `
        --template-file $templateFile `
        --parameters `
            spokeVnetResourceId=$spokeVnetId `
            hubVnetResourceId=$hubVnetId `
        --result-format FullResourcePayloads `
        --no-pretty-print

    Write-Host "`nReview the what-if output above." -ForegroundColor Yellow
    $proceed = Read-Host "Proceed with deployment? (y/N)"
    if ($proceed -ne 'y') {
        Write-Host "Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ── Deploy ───────────────────────────────────────────────────────────────

Write-Host "`nDeploying workload infrastructure ($DeploymentName)..." -ForegroundColor Cyan
az deployment group create `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --template-file $templateFile `
    --parameters `
        spokeVnetResourceId=$spokeVnetId `
        hubVnetResourceId=$hubVnetId `
    --output table

Write-Host "`nDone." -ForegroundColor Green
