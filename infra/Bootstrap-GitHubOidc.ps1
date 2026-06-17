<#
.SYNOPSIS
    Bootstraps GitHub Actions OIDC federation for each environment.

.DESCRIPTION
    Idempotent script that provisions per-environment deploy identities (user-assigned
    managed identities) with federated credentials for GitHub Actions OIDC, assigns the
    required roles, creates GitHub Environments with variables, and adds a required-reviewer
    protection rule to prod.

    Re-running the script is a clean no-op.

.PARAMETER WorkloadName
    Short workload name used in resource group and identity naming (e.g. 'workload').

.PARAMETER Environments
    Array of environment names to provision. Defaults to 'test', 'prod'.

.PARAMETER HubResourceGroup
    Name of the hub resource group containing the hub VNet.

.PARAMETER HubVNetName
    Name of the hub virtual network.

.PARAMETER AcrResourceGroup
    Resource group containing the ACR. Defaults to the workload RG for the first environment.

.PARAMETER AcrName
    Name of the container registry. If not provided, looks up the single ACR in the workload RG.

.PARAMETER Location
    Azure region for the managed identities. Defaults to 'swedencentral'.

.PARAMETER RepoOwner
    GitHub repository owner. Inferred from 'gh repo view' if not provided.

.PARAMETER RepoName
    GitHub repository name. Inferred from 'gh repo view' if not provided.

.PARAMETER ProdReviewer
    GitHub username to add as required reviewer for the prod environment. Inferred from
    'gh api user' (the authenticated user) if not provided.

.EXAMPLE
    .\Bootstrap-GitHubOidc.ps1 -WorkloadName 'workload' -HubResourceGroup 'rg-platform' -HubVNetName 'vnet-hub'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorkloadName,

    [Parameter()]
    [string[]]$Environments = @('test', 'prod'),

    [Parameter(Mandatory)]
    [string]$HubResourceGroup,

    [Parameter(Mandatory)]
    [string]$HubVNetName,

    [Parameter()]
    [string]$AcrResourceGroup,

    [Parameter()]
    [string]$AcrName,

    [Parameter()]
    [string]$Location = 'swedencentral',

    [Parameter()]
    [string]$RepoOwner,

    [Parameter()]
    [string]$RepoName,

    [Parameter()]
    [string]$ProdReviewer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve subscription and tenant ──────────────────────────────────────────
$account = az account show --output json | ConvertFrom-Json
$subscriptionId = $account.id
$tenantId = $account.tenantId
Write-Host "Subscription : $subscriptionId"
Write-Host "Tenant       : $tenantId"

# ── Resolve repo owner/name from gh CLI ──────────────────────────────────────
if (-not $RepoOwner -or -not $RepoName) {
    $repoJson = gh repo view --json nameWithOwner | ConvertFrom-Json
    $parts = $repoJson.nameWithOwner -split '/'
    if (-not $RepoOwner) { $RepoOwner = $parts[0] }
    if (-not $RepoName) { $RepoName = $parts[1] }
}
Write-Host "Repository   : $RepoOwner/$RepoName"

# ── Resolve prod reviewer ───────────────────────────────────────────────────
if (-not $ProdReviewer) {
    $ghUser = gh api user --jq '.login' 2>$null
    if ($ghUser) {
        $ProdReviewer = $ghUser
    }
    else {
        Write-Warning 'Could not determine authenticated GitHub user for prod reviewer. Provide -ProdReviewer explicitly.'
    }
}

# ── Resolve hub RG resource ID (for Network Contributor scope) ───────────────
$hubRgId = "/subscriptions/$subscriptionId/resourceGroups/$HubResourceGroup"
Write-Host "Hub RG scope : $hubRgId"

# ── Resolve ACR ──────────────────────────────────────────────────────────────
if (-not $AcrName) {
    $firstRg = "rg-$WorkloadName-$($Environments[0])"
    if (-not $AcrResourceGroup) { $AcrResourceGroup = $firstRg }
    $acrList = @(az acr list --resource-group $AcrResourceGroup --query '[].name' -o json | ConvertFrom-Json)
    if ($acrList.Count -eq 0) {
        throw "No ACR found in resource group '$AcrResourceGroup'."
    }
    $AcrName = $acrList[0]
}
if (-not $AcrResourceGroup) {
    $AcrResourceGroup = "rg-$WorkloadName-$($Environments[0])"
}
$acrResourceId = az acr show --name $AcrName --resource-group $AcrResourceGroup --query id -o tsv
Write-Host "ACR          : $AcrName ($acrResourceId)"

# ── Per-environment loop ─────────────────────────────────────────────────────
foreach ($env in $Environments) {
    Write-Host "`n════════════════════════════════════════════════════════════════"
    Write-Host "  Environment: $env"
    Write-Host "════════════════════════════════════════════════════════════════"

    $resourceGroup = "rg-$WorkloadName-$env"
    $identityName = "id-github-$WorkloadName-$env-$Location-001"
    $rgId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"

    # ── 1. Create the deploy managed identity (if missing) ───────────────────
    Write-Host "`n[1/6] Managed identity: $identityName"
    $existingIdentity = az identity show `
        --resource-group $resourceGroup `
        --name $identityName `
        --output json 2>$null | ConvertFrom-Json

    if ($existingIdentity) {
        Write-Host "      Already exists."
    }
    else {
        Write-Host "      Creating..."
        $existingIdentity = az identity create `
            --resource-group $resourceGroup `
            --name $identityName `
            --location $Location `
            --output json | ConvertFrom-Json
    }

    $principalId = $existingIdentity.principalId
    $clientId = $existingIdentity.clientId
    Write-Host "      Principal ID : $principalId"
    Write-Host "      Client ID    : $clientId"

    # ── 2. Assign roles (idempotent — re-run returns 200) ────────────────────
    Write-Host "`n[2/6] Role assignments"

    $roleAssignments = @(
        @{ Role = 'Owner';                Scope = $rgId;          Description = "Owner on $resourceGroup" }
        @{ Role = 'Network Contributor';  Scope = $hubRgId;       Description = "Network Contributor on $HubResourceGroup" }
        @{ Role = 'AcrPush';              Scope = $acrResourceId; Description = "AcrPush on $AcrName" }
    )

    foreach ($ra in $roleAssignments) {
        Write-Host "      $($ra.Description)..."
        az role assignment create `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --role $ra.Role `
            --scope $ra.Scope `
            --output none 2>&1 | Out-Null
    }
    Write-Host "      Done."

    # ── 3. Federated credential ──────────────────────────────────────────────
    Write-Host "`n[3/6] Federated credential"
    $credentialName = "github-actions-$env"
    $subject = "repo:${RepoOwner}/${RepoName}:environment:${env}"
    Write-Host "      Subject: $subject"

    $existingCred = az identity federated-credential show `
        --identity-name $identityName `
        --resource-group $resourceGroup `
        --name $credentialName `
        --output json 2>$null | ConvertFrom-Json

    if ($existingCred) {
        Write-Host "      Already exists — updating to ensure subject is correct..."
        az identity federated-credential update `
            --identity-name $identityName `
            --resource-group $resourceGroup `
            --name $credentialName `
            --issuer 'https://token.actions.githubusercontent.com' `
            --subject $subject `
            --audiences 'api://AzureADTokenExchange' `
            --output none
    }
    else {
        Write-Host "      Creating..."
        az identity federated-credential create `
            --identity-name $identityName `
            --resource-group $resourceGroup `
            --name $credentialName `
            --issuer 'https://token.actions.githubusercontent.com' `
            --subject $subject `
            --audiences 'api://AzureADTokenExchange' `
            --output none
    }
    Write-Host "      Done."

    # ── 4. GitHub Environment ────────────────────────────────────────────────
    Write-Host "`n[4/6] GitHub Environment: $env"
    gh api --method PUT "repos/$RepoOwner/$RepoName/environments/$env" --silent 2>$null
    Write-Host "      Created / confirmed."

    # ── 5. Prod reviewer protection ──────────────────────────────────────────
    Write-Host "`n[5/6] Environment protection"
    if ($env -eq 'prod' -and $ProdReviewer) {
        $reviewerUserId = gh api "users/$ProdReviewer" --jq '.id' 2>$null
        if ($reviewerUserId) {
            $protectionBody = @{
                reviewers = @(
                    @{
                        type = 'User'
                        id   = [int]$reviewerUserId
                    }
                )
            } | ConvertTo-Json -Depth 5 -Compress

            $protectionBody | gh api --method PUT `
                "repos/$RepoOwner/$RepoName/environments/$env" `
                --input - --silent 2>$null
            Write-Host "      Required reviewer: $ProdReviewer"
        }
        else {
            Write-Warning "Could not resolve GitHub user ID for '$ProdReviewer'. Skipping reviewer protection."
        }
    }
    else {
        Write-Host "      No protection required for '$env'."
    }

    # ── 6. Environment variables ─────────────────────────────────────────────
    Write-Host "`n[6/6] Environment variables"
    $envVars = @{
        AZURE_CLIENT_ID       = $clientId
        AZURE_TENANT_ID       = $tenantId
        AZURE_SUBSCRIPTION_ID = $subscriptionId
        AZURE_RESOURCE_GROUP  = $resourceGroup
    }

    foreach ($kv in $envVars.GetEnumerator()) {
        gh variable set $kv.Key --env $env --body $kv.Value 2>$null
        Write-Host "      $($kv.Key) = $($kv.Value)"
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "  Bootstrap complete. Verifying..."
Write-Host "════════════════════════════════════════════════════════════════"

foreach ($env in $Environments) {
    $resourceGroup = "rg-$WorkloadName-$env"
    $identityName = "id-github-$WorkloadName-$env-$Location-001"

    Write-Host "`n── $env ─────────────────────────────────────────────────────"

    Write-Host "  Federated credentials:"
    az identity federated-credential list `
        --identity-name $identityName `
        --resource-group $resourceGroup `
        --query '[].{name:name, subject:subject}' `
        --output table

    Write-Host "  GitHub Environment variables:"
    gh variable list --env $env

    if ($env -eq 'prod') {
        Write-Host "  Environment protection rules:"
        gh api "repos/$RepoOwner/$RepoName/environments/$env" --jq '.protection_rules'
    }
}

Write-Host "`nDone. Both environments are wired for OIDC federation."
