targetScope = 'resourceGroup'

@description('Resource ID of the container registry to assign the role on.')
param acrResourceId string

@description('Principal ID of the managed identity to grant AcrPull.')
param principalId string

var acrName = last(split(acrResourceId, '/'))

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrResourceId, principalId, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
