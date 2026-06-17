targetScope = 'resourceGroup'

@description('Azure region for the spoke resources.')
param location string = resourceGroup().location

@description('Name of the spoke virtual network.')
@minLength(2)
@maxLength(64)
param spokeVnetName string = 'vnet-workload-test-swedencentral-001'

@description('Address space for the spoke VNet (must not overlap with hub 192.168.100.0/24).')
param spokeVnetAddressPrefix string = '10.10.0.0/16'

@description('Address prefix for the private endpoints subnet.')
param privateEndpointsSubnetPrefix string = '10.10.1.0/24'

@description('Resource ID of the hub virtual network to peer with.')
param hubVnetResourceId string

@description('Tags applied to all resources.')
param tags object = {
  workload: 'hotelbooking'
  environment: 'test'
}

// Spoke VNet with a private-endpoints subnet and bidirectional peering to the hub
module spokeVnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'spoke-vnet-deployment'
  params: {
    name: spokeVnetName
    location: location
    addressPrefixes: [
      spokeVnetAddressPrefix
    ]
    subnets: [
      {
        name: 'snet-private-endpoints'
        addressPrefix: privateEndpointsSubnetPrefix
      }
    ]
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowForwardedTraffic: true
        allowVirtualNetworkAccess: true
        remotePeeringEnabled: true
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowVirtualNetworkAccess: true
      }
    ]
    tags: tags
  }
}

output spokeVnetId string = spokeVnet.outputs.resourceId
output spokeVnetName string = spokeVnet.outputs.name
