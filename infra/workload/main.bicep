targetScope = 'subscription'

@description('Azure region for the workload.')
param location string = 'polandcentral'

@description('Workload name token.')
@minLength(2)
@maxLength(20)
param workload string = 'hotelbooking'

@description('Environment token (set by the parameter file).')
@minLength(2)
@maxLength(8)
param environment string

@description('Region token used in resource names.')
param locationToken string = 'polandcentral'

@description('Short region token for resources with tight name limits (container apps).')
param locationShortToken string = 'plc'

@description('Zero-padded instance token.')
param instance string = '001'

@description('Non-overlapping address space for the workload spoke.')
param spokeAddressPrefix string

@description('Name of the existing hub resource group.')
param hubResourceGroupName string = 'rg-platform'

@description('Name of the existing hub virtual network.')
param hubVnetName string = 'vnet-hub'

@description('Image repository prefix on GHCR (lowercase, no trailing slash).')
param imageRepository string = 'ghcr.io/azureholic/az-platform-engineering-workshop'

@description('Image tag for both container images.')
param imageTag string = 'latest'

@description('SQL database SKU name (serverless).')
param sqlSkuName string

@description('SQL database vCore count.')
param sqlSkuCapacity int

@description('SQL serverless minimum vCores.')
param sqlMinCapacity string

@description('SQL serverless auto-pause delay in minutes (-1 disables auto-pause).')
param sqlAutoPauseDelay int

@description('SQL database maximum size in bytes.')
param sqlMaxSizeBytes int

@description('SQL backup storage redundancy (Local, Zone or Geo).')
param sqlBackupRedundancy string

@description('Log Analytics retention in days.')
param logRetentionDays int

@description('Log Analytics daily ingestion cap in GB.')
param logDailyQuotaGb int

@description('Minimum replicas per container app (0 enables scale-to-zero).')
param minReplicas int

@description('Maximum replicas per container app.')
param maxReplicas int

@description('Zone redundancy for the Container Apps environment and the SQL database.')
param zoneRedundant bool

@description('Link the hub VNet to this environment\'s private DNS zone (a VNet can link to only one zone per zone name).')
param linkHubVnetToPrivateDns bool

@description('Tags applied to all resources.')
param tags object = {
  workload: workload
  environment: environment
}

var resourceGroupName = 'rg-${workload}-${environment}'
var spokeVnetName = 'vnet-${workload}-${environment}-${locationToken}-001'
var hubVnetId = resourceId(subscription().subscriptionId, hubResourceGroupName, 'Microsoft.Network/virtualNetworks', hubVnetName)

resource workloadResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module spoke './modules/spoke.bicep' = {
  name: 'workload-spoke'
  scope: workloadResourceGroup
  params: {
    location: location
    spokeVnetName: spokeVnetName
    spokeAddressPrefix: spokeAddressPrefix
    hubVnetId: hubVnetId
    remotePeeringName: 'peer-to-${workload}-${environment}'
    tags: tags
  }
}

module workloadResources './modules/workload.bicep' = {
  name: 'workload-resources'
  scope: workloadResourceGroup
  params: {
    location: location
    workload: workload
    environment: environment
    locationToken: locationToken
    locationShortToken: locationShortToken
    instance: instance
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    containerAppsSubnetId: spoke.outputs.containerAppsSubnetId
    spokeVnetId: spoke.outputs.spokeVnetId
    hubVnetId: hubVnetId
    imageRepository: imageRepository
    imageTag: imageTag
    sqlSkuName: sqlSkuName
    sqlSkuCapacity: sqlSkuCapacity
    sqlMinCapacity: sqlMinCapacity
    sqlAutoPauseDelay: sqlAutoPauseDelay
    sqlMaxSizeBytes: sqlMaxSizeBytes
    sqlBackupRedundancy: sqlBackupRedundancy
    logRetentionDays: logRetentionDays
    logDailyQuotaGb: logDailyQuotaGb
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    zoneRedundant: zoneRedundant
    linkHubVnetToPrivateDns: linkHubVnetToPrivateDns
    tags: tags
  }
}

output workloadResourceGroupName string = workloadResourceGroup.name
output spokeVnetId string = spoke.outputs.spokeVnetId
output frontendFqdn string = workloadResources.outputs.frontendFqdn
output backendInternalFqdn string = workloadResources.outputs.backendInternalFqdn
output sqlServerFqdn string = workloadResources.outputs.sqlServerFqdn
