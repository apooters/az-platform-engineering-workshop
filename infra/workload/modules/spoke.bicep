@description('Azure region for the workload spoke VNet.')
param location string

@description('Name of the workload spoke virtual network.')
param spokeVnetName string

@description('Non-overlapping address space for the workload spoke.')
param spokeAddressPrefix string

@description('Resource ID of the existing hub virtual network.')
param hubVnetId string

@description('Name of the remote (hub-side) peering back to this spoke.')
param remotePeeringName string

@description('Tags applied to the spoke VNet.')
param tags object

var privateEndpointSubnetName = 'snet-private-endpoints'
var containerAppsSubnetName = 'snet-container-apps'

module spokeVnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'spoke-virtual-network'
  params: {
    name: spokeVnetName
    location: location
    addressPrefixes: [
      spokeAddressPrefix
    ]
    subnets: [
      {
        name: privateEndpointSubnetName
        addressPrefix: cidrSubnet(spokeAddressPrefix, 24, 0)
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: containerAppsSubnetName
        addressPrefix: cidrSubnet(spokeAddressPrefix, 24, 1)
        delegation: 'Microsoft.App/environments'
      }
    ]
    peerings: [
      {
        name: 'peer-to-hub'
        remoteVirtualNetworkResourceId: hubVnetId
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: false
        allowGatewayTransit: false
        useRemoteGateways: false
        remotePeeringEnabled: true
        remotePeeringName: remotePeeringName
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: false
        remotePeeringAllowGatewayTransit: false
        remotePeeringUseRemoteGateways: false
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

output spokeVnetId string = spokeVnet.outputs.resourceId
output spokeVnetName string = spokeVnet.outputs.name
output privateEndpointSubnetId string = '${spokeVnet.outputs.resourceId}/subnets/${privateEndpointSubnetName}'
output containerAppsSubnetId string = '${spokeVnet.outputs.resourceId}/subnets/${containerAppsSubnetName}'
