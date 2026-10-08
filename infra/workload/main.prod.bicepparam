using './main.bicep'

param environment = 'prod'
param spokeAddressPrefix = '10.21.0.0/16'
param zoneRedundant = true
param linkHubVnetToPrivateDns = false
param minReplicas = 3
param maxReplicas = 6
param sqlSkuName = 'GP_S_Gen5_2'
param sqlSkuCapacity = 2
param sqlMinCapacity = '1'
param sqlAutoPauseDelay = -1
param sqlMaxSizeBytes = 34359738368
param sqlBackupRedundancy = 'Zone'
param logRetentionDays = 90
param logDailyQuotaGb = 5
