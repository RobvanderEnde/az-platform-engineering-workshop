targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
//  Parameters
// ─────────────────────────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Environment token embedded in every resource name (e.g. test, prod).')
@allowed(['test', 'prod', 'dev'])
param environmentName string = 'test'

@description('Short workload identifier used in resource names.')
@minLength(3)
@maxLength(20)
param workloadName string = 'hotelbooking'

@description('Resource ID of the existing spoke VNet.')
param spokeVnetResourceId string

@description('Resource ID of the hub VNet (for Private DNS zone links).')
param hubVnetResourceId string

@description('Address prefix for the Container Apps infrastructure subnet (min /23).')
param appsSubnetPrefix string = '10.10.2.0/23'

@description('Name of the existing private-endpoints subnet in the spoke VNet.')
param privateEndpointsSubnetName string = 'snet-private-endpoints'

@description('SKU for the Azure SQL Database.')
param sqlDatabaseSku object = {
  name: 'GP_S_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 1
}

@description('Auto-pause delay in minutes for the serverless SQL database (-1 to disable).')
param sqlAutoPauseDelay int = 60

@description('Resource ID of the shared container registry (from deploy-shared stage).')
param acrResourceId string

@description('Login server of the shared container registry (from deploy-shared stage).')
param acrLoginServer string

@description('Tags applied to all resources.')
param tags object = {
  workload: workloadName
  environment: environmentName
  managedBy: 'bicep'
}

// ─────────────────────────────────────────────────────────────────────────────
//  Variables — naming (CAF)
// ─────────────────────────────────────────────────────────────────────────────

var regionShort = location // used in names as-is (e.g. swedencentral)
var runtimeMiName = 'id-${workloadName}-${environmentName}-001'
var deployMiName = 'id-deploy-${workloadName}-${environmentName}-001'
var logAnalyticsName = 'log-${workloadName}-${environmentName}-001'
var appInsightsName = 'appi-${workloadName}-${environmentName}-001'
var caeName = 'cae-${workloadName}-${environmentName}-${regionShort}-001'
var backendAppName = 'ca-hotelapi-${environmentName}-001'
var frontendAppName = 'ca-hotelfrontend-${environmentName}-001'
var sqlServerName = 'sql-${workloadName}-${environmentName}-${uniqueString(resourceGroup().id)}'
var sqlDatabaseName = 'sqldb-${workloadName}-${environmentName}'
var sqlPeName = 'pep-sql-${workloadName}-${environmentName}-001'
#disable-next-line no-hardcoded-env-urls // Private DNS zone name is a fixed convention, not an environment URL
var sqlDnsZoneName = 'privatelink.database.windows.net'
var appsSubnetName = 'snet-apps'

// Parse VNet name from the spoke resource ID
var spokeVnetName = last(split(spokeVnetResourceId, '/'))

// ─────────────────────────────────────────────────────────────────────────────
//  Existing spoke VNet reference (same resource group as this deployment)
// ─────────────────────────────────────────────────────────────────────────────

resource spokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: spokeVnetName
}

resource privateEndpointsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: privateEndpointsSubnetName
  parent: spokeVnet
}

// ─────────────────────────────────────────────────────────────────────────────
//  Subnet for Container Apps (added to existing spoke VNet)
// ─────────────────────────────────────────────────────────────────────────────

// No AVM module for standalone subnet creation on an existing VNet — raw resource
resource appsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  name: appsSubnetName
  parent: spokeVnet
  properties: {
    addressPrefix: appsSubnetPrefix
    delegations: [
      {
        name: 'Microsoft.App.environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Identity — Runtime (user-assigned)
// ─────────────────────────────────────────────────────────────────────────────

module runtimeMi 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'runtime-mi-deployment'
  params: {
    name: runtimeMiName
    location: location
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Identity — Deploy / CI (user-assigned)
// ─────────────────────────────────────────────────────────────────────────────

module deployMi 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'deploy-mi-deployment'
  params: {
    name: deployMiName
    location: location
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  ACR Role Assignment — AcrPull for runtime MI on the shared registry
// ─────────────────────────────────────────────────────────────────────────────

var acrResourceGroupName = split(acrResourceId, '/')[4]

module acrPullRoleAssignment '../shared/acr-role-assignment.bicep' = {
  name: 'acr-pull-role-assignment'
  scope: resourceGroup(acrResourceGroupName)
  params: {
    acrResourceId: acrResourceId
    principalId: runtimeMi.outputs.principalId
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Observability — Log Analytics (public endpoint)
// ─────────────────────────────────────────────────────────────────────────────

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.1' = {
  name: 'log-analytics-deployment'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Observability — Application Insights (public endpoint)
// ─────────────────────────────────────────────────────────────────────────────

module appInsights 'br/public:avm/res/insights/component:0.7.2' = {
  name: 'app-insights-deployment'
  params: {
    name: appInsightsName
    location: location
    workspaceResourceId: logAnalytics.outputs.resourceId
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Private DNS Zone — Azure SQL
// ─────────────────────────────────────────────────────────────────────────────

module sqlDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'sql-dns-zone-deployment'
  params: {
    name: sqlDnsZoneName
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: spokeVnetResourceId
        registrationEnabled: false
      }
      {
        virtualNetworkResourceId: hubVnetResourceId
        registrationEnabled: false
      }
    ]
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Azure SQL Server + Database (serverless, Entra-only, private endpoint)
// ─────────────────────────────────────────────────────────────────────────────

module sqlServer 'br/public:avm/res/sql/server:0.21.4' = {
  name: 'sql-server-deployment'
  params: {
    name: sqlServerName
    location: location
    administrators: {
      azureADOnlyAuthentication: true
      login: runtimeMiName
      principalType: 'Application'
      sid: runtimeMi.outputs.principalId
    }
    managedIdentities: {
      userAssignedResourceIds: [
        runtimeMi.outputs.resourceId
      ]
    }
    primaryUserAssignedIdentityResourceId: runtimeMi.outputs.resourceId
    publicNetworkAccess: 'Disabled'
    databases: [
      {
        name: sqlDatabaseName
        availabilityZone: -1
        sku: sqlDatabaseSku
        autoPauseDelay: sqlAutoPauseDelay
        minCapacity: '0.5'
        maxSizeBytes: 2147483648 // 2 GB
        requestedBackupStorageRedundancy: 'Local'
      }
    ]
    privateEndpoints: [
      {
        name: sqlPeName
        subnetResourceId: privateEndpointsSubnet.id
        service: 'sqlServer'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: sqlDnsZone.outputs.resourceId
            }
          ]
        }
      }
    ]
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container Apps Environment (Consumption, VNet-integrated)
// ─────────────────────────────────────────────────────────────────────────────

module containerAppsEnv 'br/public:avm/res/app/managed-environment:0.13.3' = {
  name: 'cae-deployment'
  params: {
    name: caeName
    location: location
    internal: false
    infrastructureSubnetResourceId: appsSubnet.id
    zoneRedundant: false
    publicNetworkAccess: 'Enabled'
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    }
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container App — Backend API (internal ingress)
// ─────────────────────────────────────────────────────────────────────────────

// Passwordless SQL connection string built from resource outputs
var sqlConnectionString = 'Server=tcp:${sqlServer.outputs.fullyQualifiedDomainName},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;'

module backendApp 'br/public:avm/res/app/container-app:0.22.1' = {
  name: 'backend-app-deployment'
  params: {
    name: backendAppName
    location: location
    environmentResourceId: containerAppsEnv.outputs.resourceId
    ingressExternal: false
    ingressTargetPort: 8080
    ingressTransport: 'http'
    managedIdentities: {
      userAssignedResourceIds: [
        runtimeMi.outputs.resourceId
      ]
    }
    registries: [
      {
        server: acrLoginServer
        identity: runtimeMi.outputs.resourceId
      }
    ]
    scaleSettings: {
      minReplicas: 0
      maxReplicas: 3
      rules: [
        {
          name: 'http-scale'
          http: {
            metadata: {
              concurrentRequests: '20'
            }
          }
        }
      ]
    }
    containers: [
      {
        name: 'hotelapi'
        // Placeholder image — replaced with ACR image after container build
        image: 'mcr.microsoft.com/k8se/quickstart:latest'
        resources: {
          cpu: json('0.5')
          memory: '1Gi'
        }
        env: [
          {
            name: 'ConnectionStrings__HotelDb'
            value: sqlConnectionString
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: runtimeMi.outputs.clientId
          }
        ]
      }
    ]
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container App — Frontend SPA + nginx (external ingress)
// ─────────────────────────────────────────────────────────────────────────────

module frontendApp 'br/public:avm/res/app/container-app:0.22.1' = {
  name: 'frontend-app-deployment'
  params: {
    name: frontendAppName
    location: location
    environmentResourceId: containerAppsEnv.outputs.resourceId
    ingressExternal: true
    ingressTargetPort: 80
    ingressTransport: 'http'
    managedIdentities: {
      userAssignedResourceIds: [
        runtimeMi.outputs.resourceId
      ]
    }
    registries: [
      {
        server: acrLoginServer
        identity: runtimeMi.outputs.resourceId
      }
    ]
    scaleSettings: {
      minReplicas: 0
      maxReplicas: 3
      rules: [
        {
          name: 'http-scale'
          http: {
            metadata: {
              concurrentRequests: '20'
            }
          }
        }
      ]
    }
    containers: [
      {
        name: 'hotelfrontend'
        // Placeholder image — replaced with ACR image after container build
        image: 'mcr.microsoft.com/k8se/quickstart:latest'
        resources: {
          cpu: json('0.5')
          memory: '1Gi'
        }
        env: [
          {
            name: 'BACKEND_FQDN'
            value: backendApp.outputs.fqdn
          }
        ]
      }
    ]
    tags: tags
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Outputs
// ─────────────────────────────────────────────────────────────────────────────

output runtimeMiResourceId string = runtimeMi.outputs.resourceId
output runtimeMiClientId string = runtimeMi.outputs.clientId
output runtimeMiPrincipalId string = runtimeMi.outputs.principalId
output deployMiResourceId string = deployMi.outputs.resourceId
output deployMiClientId string = deployMi.outputs.clientId
output acrLoginServer string = acrLoginServer
output acrResourceId string = acrResourceId
output sqlServerFqdn string = sqlServer.outputs.fullyQualifiedDomainName
output containerAppsEnvironmentId string = containerAppsEnv.outputs.resourceId
output backendAppName string = backendApp.outputs.name
output backendFqdn string = backendApp.outputs.fqdn
output frontendAppName string = frontendApp.outputs.name
output frontendFqdn string = frontendApp.outputs.fqdn
output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
output appInsightsConnectionString string = appInsights.outputs.connectionString
