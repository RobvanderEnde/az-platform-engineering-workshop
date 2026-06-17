#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the workload spoke VNet and peers it to the hub.

.DESCRIPTION
    Creates (or updates) the workload resource group, then deploys spoke.bicep
    which provisions the spoke VNet with a private-endpoints subnet and
    bidirectional peering to the hub VNet in rg-platform.
    Run from PowerShell 7+ with az CLI logged in and the correct subscription selected.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-workload-test',
    [string]$Location = 'swedencentral',
    [string]$HubResourceGroupName = 'rg-platform',
    [string]$HubVnetName = 'vnet-hub',
    [string]$DeploymentName = "spoke-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptRoot 'spoke.bicep'

Write-Host "Using subscription:" -ForegroundColor Cyan
az account show --query '{name:name, id:id}' -o table

# Resolve hub VNet resource ID
Write-Host "Resolving hub VNet resource ID..." -ForegroundColor Cyan
$hubVnetId = az network vnet show `
    --resource-group $HubResourceGroupName `
    --name $HubVnetName `
    --query 'id' -o tsv

if (-not $hubVnetId) {
    Write-Error "Hub VNet '$HubVnetName' not found in resource group '$HubResourceGroupName'. Deploy the hub first (mock-alz/Deploy-Hub.ps1)."
}
Write-Host "Hub VNet ID: $hubVnetId" -ForegroundColor Gray

# Ensure workload resource group exists
Write-Host "Ensuring resource group '$ResourceGroupName' exists in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

# Deploy spoke VNet with peering
Write-Host "Deploying spoke VNet ($DeploymentName)..." -ForegroundColor Cyan
az deployment group create `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --template-file $templateFile `
    --parameters hubVnetResourceId=$hubVnetId `
    --output table

Write-Host "Done." -ForegroundColor Green
