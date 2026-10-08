@description('Azure region for the workload resources.')
param location string

@description('Workload name token used in resource names.')
param workload string

@description('Environment token used in resource names.')
param environment string

@description('Region token used in resource names.')
param locationToken string

@description('Short region token for resources with tight name limits (container apps).')
param locationShortToken string

@description('Zero-padded instance token used in resource names.')
param instance string

@description('Resource ID of the spoke subnet that hosts private endpoints.')
param privateEndpointSubnetId string

@description('Resource ID of the delegated spoke subnet for the Container Apps environment.')
param containerAppsSubnetId string

@description('Resource ID of the spoke virtual network.')
param spokeVnetId string

@description('Resource ID of the hub virtual network.')
param hubVnetId string

@description('Image repository prefix on GHCR, without trailing slash (lowercase).')
param imageRepository string

@description('Image tag for both container images.')
param imageTag string

@description('SQL database SKU name.')
param sqlSkuName string

@description('SQL database vCore count.')
param sqlSkuCapacity int

@description('SQL serverless minimum vCores.')
param sqlMinCapacity string

@description('SQL serverless auto-pause delay in minutes.')
param sqlAutoPauseDelay int

@description('SQL database maximum size in bytes.')
param sqlMaxSizeBytes int

@description('Log Analytics retention in days.')
param logRetentionDays int

@description('Log Analytics daily ingestion cap in GB.')
param logDailyQuotaGb int

@description('Maximum replicas per container app.')
param maxReplicas int

@description('Minimum replicas per container app (0 enables scale-to-zero).')
param minReplicas int

@description('Zone redundancy for the Container Apps environment and the SQL database.')
param zoneRedundant bool

@description('Link the hub VNet to this environment\'s private DNS zone (a VNet can link to only one zone per zone name).')
param linkHubVnetToPrivateDns bool

@description('SQL backup storage redundancy (Local, Zone or Geo).')
param sqlBackupRedundancy string

@description('Tags applied to all resources.')
param tags object

var suffix = '${workload}-${environment}-${locationToken}-${instance}'
var appSuffix = '${environment}-${locationShortToken}-${instance}'
var databaseName = 'sqldb-${workload}-${environment}'
// SQL server names are globally unique; the subscription-derived token keeps the name stable across re-runs.
var sqlServerName = 'sql-${suffix}-${take(uniqueString(subscription().id), 5)}'
var sqlPrivateDnsZoneName = 'privatelink${az.environment().suffixes.sqlServerHostname}'
var apiPort = 8080
var spokeDnsLink = {
  name: 'vnl-${workload}-${environment}-spoke'
  virtualNetworkResourceId: spokeVnetId
  registrationEnabled: false
}
var hubDnsLink = {
  name: 'vnl-${workload}-${environment}-hub'
  virtualNetworkResourceId: hubVnetId
  registrationEnabled: false
}

module runtimeIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'runtime-identity'
  params: {
    name: 'id-hotelapi-${environment}-${locationToken}-${instance}'
    location: location
    tags: tags
    enableTelemetry: false
  }
}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-analytics'
  params: {
    name: 'log-${suffix}'
    location: location
    skuName: 'PerGB2018'
    dataRetention: logRetentionDays
    dailyQuotaGb: string(logDailyQuotaGb)
    tags: tags
    enableTelemetry: false
  }
}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'application-insights'
  params: {
    name: 'appi-${suffix}'
    location: location
    workspaceResourceId: logAnalytics.outputs.resourceId
    kind: 'web'
    applicationType: 'web'
    tags: tags
    enableTelemetry: false
  }
}

module sqlPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'private-dns-zone-sql'
  params: {
    name: sqlPrivateDnsZoneName
    virtualNetworkLinks: linkHubVnetToPrivateDns ? [
      spokeDnsLink
      hubDnsLink
    ] : [
      spokeDnsLink
    ]
    tags: tags
    enableTelemetry: false
  }
}

module sqlServer 'br/public:avm/res/sql/server:0.22.1' = {
  name: 'sql-server'
  params: {
    name: sqlServerName
    location: location
    administrators: {
      azureADOnlyAuthentication: true
      login: runtimeIdentity.outputs.name
      principalType: 'Application'
      sid: runtimeIdentity.outputs.principalId
      tenantId: tenant().tenantId
    }
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    databases: [
      {
        name: databaseName
        availabilityZone: -1
        zoneRedundant: zoneRedundant
        sku: {
          name: sqlSkuName
          tier: 'GeneralPurpose'
          family: 'Gen5'
          capacity: sqlSkuCapacity
        }
        minCapacity: sqlMinCapacity
        autoPauseDelay: sqlAutoPauseDelay
        maxSizeBytes: sqlMaxSizeBytes
        requestedBackupStorageRedundancy: sqlBackupRedundancy
      }
    ]
    privateEndpoints: [
      {
        name: 'pep-sql-${suffix}'
        subnetResourceId: privateEndpointSubnetId
        service: 'sqlServer'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: sqlPrivateDnsZone.outputs.resourceId
            }
          ]
        }
        tags: tags
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'container-apps-environment'
  params: {
    name: 'cae-${suffix}'
    location: location
    zoneRedundant: zoneRedundant
    infrastructureSubnetResourceId: containerAppsSubnetId
    internal: false
    publicNetworkAccess: 'Enabled'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    diagnosticSettings: [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalytics.outputs.resourceId
        logCategoriesAndGroups: [
          { category: 'ContainerAppConsoleLogs' }
          { category: 'ContainerAppSystemLogs' }
        ]
        metricCategories: []
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module backendApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'container-app-backend'
  params: {
    name: 'ca-hotelapi-${appSuffix}'
    location: location
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    workloadProfileName: 'Consumption'
    managedIdentities: {
      userAssignedResourceIds: [
        runtimeIdentity.outputs.resourceId
      ]
    }
    ingressExternal: false
    ingressTargetPort: apiPort
    ingressAllowInsecure: false
    containers: [
      {
        name: 'backend'
        image: '${imageRepository}/backend:${imageTag}'
        resources: {
          cpu: json('0.5')
          memory: '1Gi'
        }
        env: [
          {
            name: 'ConnectionStrings__HotelDb'
            value: 'Server=tcp:${sqlServer.outputs.fullyQualifiedDomainName},1433;Database=${databaseName};Authentication=Active Directory Default;User Id=${runtimeIdentity.outputs.clientId};Encrypt=True;Connect Timeout=60;'
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: runtimeIdentity.outputs.clientId
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
        ]
        probes: [
          {
            type: 'Liveness'
            tcpSocket: {
              port: apiPort
            }
          }
          {
            type: 'Startup'
            tcpSocket: {
              port: apiPort
            }
            periodSeconds: 10
            failureThreshold: 24
          }
        ]
      }
    ]
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http-concurrency'
          http: {
            metadata: {
              concurrentRequests: '30'
            }
          }
        }
      ]
    }
    tags: tags
    enableTelemetry: false
  }
}

module frontendApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'container-app-frontend'
  params: {
    name: 'ca-hotelweb-${appSuffix}'
    location: location
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    workloadProfileName: 'Consumption'
    ingressExternal: true
    ingressTargetPort: apiPort
    ingressAllowInsecure: false
    containers: [
      {
        name: 'frontend'
        image: '${imageRepository}/frontend:${imageTag}'
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
        env: [
          {
            name: 'BACKEND_URL'
            value: 'https://${backendApp.outputs.fqdn}'
          }
        ]
        probes: [
          {
            type: 'Liveness'
            httpGet: {
              path: '/'
              port: apiPort
            }
          }
          {
            type: 'Readiness'
            httpGet: {
              path: '/'
              port: apiPort
            }
          }
        ]
      }
    ]
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http-concurrency'
          http: {
            metadata: {
              concurrentRequests: '100'
            }
          }
        }
      ]
    }
    tags: tags
    enableTelemetry: false
  }
}

output frontendFqdn string = frontendApp.outputs.fqdn
output backendInternalFqdn string = backendApp.outputs.fqdn
output sqlServerFqdn string = sqlServer.outputs.fullyQualifiedDomainName
output runtimeIdentityClientId string = runtimeIdentity.outputs.clientId
