using './main.bicep'

param environment = 'test'
param spokeAddressPrefix = '10.20.0.0/16'
param zoneRedundant = false
param linkHubVnetToPrivateDns = true
param minReplicas = 0
param maxReplicas = 3
param sqlSkuName = 'GP_S_Gen5_1'
param sqlSkuCapacity = 1
param sqlMinCapacity = '0.5'
param sqlAutoPauseDelay = 60
param sqlMaxSizeBytes = 2147483648
param sqlBackupRedundancy = 'Local'
param logRetentionDays = 30
param logDailyQuotaGb = 1
