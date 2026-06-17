targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
//  Parameters
// ─────────────────────────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short workload identifier used in resource names.')
@minLength(3)
@maxLength(20)
param workloadName string = 'hotelbooking'

@description('SKU for the Azure Container Registry.')
@allowed(['Basic', 'Standard', 'Premium'])
param acrSku string = 'Standard'

@description('Tags applied to all resources.')
param tags object = {
  workload: workloadName
  environment: 'shared'
}

// ─────────────────────────────────────────────────────────────────────────────
//  Variables — naming (CAF)
// ─────────────────────────────────────────────────────────────────────────────

var acrName = 'cr${workloadName}${uniqueString(resourceGroup().id)}'

// ─────────────────────────────────────────────────────────────────────────────
//  Container Registry (public, admin disabled, shared across envs)
// ─────────────────────────────────────────────────────────────────────────────

module acr 'br/public:avm/res/container-registry/registry:0.12.1' = {
  name: 'acr-deployment'
  params: {
    name: acrName
    location: location
    acrSku: acrSku
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    networkRuleSetDefaultAction: 'Allow'
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Outputs
// ─────────────────────────────────────────────────────────────────────────────

output acrResourceId string = acr.outputs.resourceId
output acrLoginServer string = acr.outputs.loginServer
output acrName string = acr.outputs.name
