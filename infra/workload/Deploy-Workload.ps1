#Requires -Version 7.0
<#
.SYNOPSIS
    Preflights and deploys the workload infrastructure (infra/workload/main.bicep) for one environment.
.DESCRIPTION
    Runs a Bicep build, a permission check and a what-if before every deployment.
    Environment differences come only from main.<environment>.bicepparam.
    The deployment itself only starts after preflight succeeds (and, unless -Force is set, after confirmation).
    Re-running with the same parameters is idempotent.
.PARAMETER Location
    Azure region for the deployment metadata and the workload.
.PARAMETER Environment
    Target environment; selects main.<environment>.bicepparam.
.PARAMETER ImageTag
    Tag of the public GHCR backend/frontend images.
.PARAMETER ParameterOverrides
    Extra Bicep parameters as a hashtable (for example @{ maxReplicas = 2 }).
.PARAMETER WhatIfOnly
    Run preflight only; do not deploy.
.PARAMETER Force
    Skip the confirmation prompt after what-if.
#>
[CmdletBinding()]
param(
    [string]$Location = 'polandcentral',
    [ValidateSet('test', 'prod')]
    [string]$Environment = 'test',
    [string]$ImageTag = 'latest',
    [string]$HubResourceGroupName = 'rg-platform',
    [hashtable]$ParameterOverrides = @{},
    [switch]$WhatIfOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$templateFile = Join-Path $PSScriptRoot 'main.bicep'
$parameterFile = Join-Path $PSScriptRoot "main.$Environment.bicepparam"
$deploymentName = "workload-$Environment"
$resourceGroupName = "rg-hotelbooking-$Environment"

$parameters = @{
    location             = $Location
    imageTag             = $ImageTag
    hubResourceGroupName = $HubResourceGroupName
} + $ParameterOverrides
$parameterArgs = @($parameterFile) + @($parameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })

function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)." }
    $output
}

Write-Host '== Preflight 1/3: Bicep build and lint' -ForegroundColor Cyan
Invoke-Az bicep build --file $templateFile --stdout | Out-Null

Write-Host '== Preflight 2/3: permission check' -ForegroundColor Cyan
$account = Invoke-Az account show --output json | ConvertFrom-Json
$assignee = if ($account.user.type -eq 'servicePrincipal') {
    $account.user.name
}
else {
    (Invoke-Az ad signed-in-user show --query id --output tsv)
}
$subscriptionScope = "/subscriptions/$($account.id)"
$roles = Invoke-Az role assignment list --assignee $assignee --include-inherited --include-groups `
    --query '[].{role:roleDefinitionName,scope:scope}' --output json | ConvertFrom-Json

$hubScope = "$subscriptionScope/resourceGroups/$HubResourceGroupName"
$subscriptionWideScopes = @('/', $subscriptionScope)
$hasDeployRights = $roles | Where-Object { $_.role -in @('Owner', 'Contributor') -and $_.scope -in $subscriptionWideScopes }
if (-not $hasDeployRights) {
    throw "Principal '$assignee' needs Owner or Contributor on $subscriptionScope to create '$resourceGroupName' and the workload resources. Grant it with 'az role assignment create' and retry."
}
$hubRights = $roles | Where-Object {
    $_.role -in @('Owner', 'Contributor', 'Network Contributor') -and $_.scope -in ($subscriptionWideScopes + $hubScope)
}
if (-not $hubRights) {
    throw "Principal '$assignee' needs Network Contributor (or higher) on hub resource group '$HubResourceGroupName' to write the hub-side peering and the hub DNS link."
}
Write-Host "Principal '$assignee' has the required roles."

Write-Host '== Preflight 3/3: what-if' -ForegroundColor Cyan
Invoke-Az deployment sub what-if `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters $parameterArgs `
    --validation-level Provider

if ($WhatIfOnly) {
    Write-Host 'WhatIfOnly set; skipping deployment.' -ForegroundColor Yellow
    return
}

if (-not $Force -and -not $PSCmdlet.ShouldContinue("Deploy '$deploymentName' to subscription $($account.id)?", 'Confirm deployment')) {
    Write-Host 'Deployment cancelled.' -ForegroundColor Yellow
    return
}

Write-Host '== Deploying' -ForegroundColor Cyan
Invoke-Az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters $parameterArgs `
    --query properties.outputs `
    --output json
