#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstraps GitHub Actions OIDC federation to Azure, one deploy identity per environment.
.DESCRIPTION
    For each environment this creates (or verifies) a user-assigned managed identity dedicated to
    GitHub Actions, its role assignments, one federated credential, the matching GitHub Environment
    and the four environment variables the workflows consume. No app registrations, no secrets.
    Every step is check-then-write, so a second run changes nothing.
.PARAMETER Owner
    GitHub owner. Inferred from the 'origin' remote when omitted.
.PARAMETER Repository
    GitHub repository name. Inferred from the 'origin' remote when omitted.
.PARAMETER Environment
    Environments to bootstrap. 'prod' gets required reviewers; others get no protection.
.PARAMETER ReviewerLogin
    GitHub user that must approve 'prod' deployments. Defaults to the signed-in gh user.
.PARAMETER Location
    Azure region for the identity resource group, the identities and any missing workload resource group.
.PARAMETER IdentityResourceGroupName
    Resource group that holds the deploy identities (kept apart from the workload resource groups).
.PARAMETER HubResourceGroupName
    Hub resource group; the deploy identities get Network Contributor on it.
#>
[CmdletBinding()]
param(
    [string]$Owner,
    [string]$Repository,
    [string[]]$Environment = @('test', 'prod'),
    [string]$ReviewerLogin,
    [string]$Workload = 'hotelbooking',
    [string]$Location = 'polandcentral',
    [string]$IdentityResourceGroupName = 'rg-hotelbooking-cicd',
    [string]$HubResourceGroupName = 'rg-platform'
)

$ErrorActionPreference = 'Stop'
$issuer = 'https://token.actions.githubusercontent.com'
$audience = 'api://AzureADTokenExchange'

function Invoke-Az {
    $output = & az @args --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)." }
    $output
}

function Invoke-Gh {
    $output = & gh @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed (exit $LASTEXITCODE)." }
    $output
}

function Write-Result {
    param([string]$Action, [string]$Message)
    $color = if ($Action -eq 'unchanged') { 'DarkGray' } else { 'Green' }
    Write-Host ('  [{0,-9}] {1}' -f $Action, $Message) -ForegroundColor $color
}

if (-not $Owner -or -not $Repository) {
    $originUrl = (& git remote get-url origin).Trim()
    if ($originUrl -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
        throw "Cannot infer owner/repository from origin '$originUrl'. Pass -Owner and -Repository."
    }
    if (-not $Owner) { $Owner = $Matches.owner }
    if (-not $Repository) { $Repository = $Matches.repo }
}
if (-not $ReviewerLogin) { $ReviewerLogin = (Invoke-Gh api user --jq .login).Trim() }

$account = Invoke-Az account show --output json | ConvertFrom-Json
$subscriptionId = $account.id
$tenantId = $account.tenantId
$subscriptionScope = "/subscriptions/$subscriptionId"
$hubScope = "$subscriptionScope/resourceGroups/$HubResourceGroupName"
$repoApi = "repos/$Owner/$Repository"

Write-Host "Repository   : $Owner/$Repository" -ForegroundColor Cyan
Write-Host "Subscription : $subscriptionId (tenant $tenantId)" -ForegroundColor Cyan

function Confirm-ResourceGroup {
    param([string]$Name, [hashtable]$Tags = @{})
    if ((Invoke-Az group exists --name $Name) -eq 'true') {
        Write-Result 'unchanged' "resource group $Name"
        return
    }
    $tagArgs = @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    Invoke-Az group create --name $Name --location $Location --tags @tagArgs --output none
    Write-Result 'created' "resource group $Name"
}

function Confirm-RoleAssignment {
    param([string]$PrincipalId, [string]$Role, [string]$Scope)
    $existing = Invoke-Az role assignment list --role $Role --scope $Scope --query "[?principalId=='$PrincipalId'] | length(@)" --output tsv
    if ([int]$existing -gt 0) {
        Write-Result 'unchanged' "$Role on $Scope"
        return
    }
    Invoke-Az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal `
        --role $Role --scope $Scope --output none
    Write-Result 'created' "$Role on $Scope"
}

function Confirm-FederatedCredential {
    param([string]$IdentityName, [string]$EnvironmentName)
    $subject = "repo:${Owner}/${Repository}:environment:${EnvironmentName}"
    $credentialName = "github-$EnvironmentName"
    $credentials = @(Invoke-Az identity federated-credential list --identity-name $IdentityName `
            --resource-group $IdentityResourceGroupName --output json | ConvertFrom-Json)

    $others = @($credentials | Where-Object { $_.name -ne $credentialName })
    if ($others.Count -gt 0) {
        Write-Warning "Identity $IdentityName has unexpected federated credentials: $($others.name -join ', ')"
    }

    $current = $credentials | Where-Object { $_.name -eq $credentialName }
    $common = @('--identity-name', $IdentityName, '--resource-group', $IdentityResourceGroupName, '--name', $credentialName,
        '--issuer', $issuer, '--subject', $subject, '--audiences', $audience, '--output', 'none')
    if (-not $current) {
        Invoke-Az identity federated-credential create @common
        Write-Result 'created' "federated credential $subject"
    }
    elseif ($current.subject -ne $subject -or $current.issuer -ne $issuer -or @($current.audiences) -notcontains $audience) {
        Invoke-Az identity federated-credential update @common
        Write-Result 'updated' "federated credential $subject"
    }
    else {
        Write-Result 'unchanged' "federated credential $subject"
    }
}

function Confirm-GitHubEnvironment {
    param([string]$EnvironmentName)
    $wantsReviewers = $EnvironmentName -eq 'prod'
    $reviewerId = if ($wantsReviewers) { [int](Invoke-Gh api "users/$ReviewerLogin" --jq .id) }

    $current = $null
    $existing = & gh api "$repoApi/environments/$EnvironmentName" 2>$null
    if ($LASTEXITCODE -eq 0) { $current = $existing | ConvertFrom-Json }

    $currentReviewerIds = @()
    if ($current) {
        $rule = $current.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }
        if ($rule) { $currentReviewerIds = @($rule.reviewers | ForEach-Object { $_.reviewer.id }) }
    }
    $upToDate = $current -and $(if ($wantsReviewers) {
            ($currentReviewerIds -contains $reviewerId) -and $current.deployment_branch_policy.custom_branch_policies
        } else { $currentReviewerIds.Count -eq 0 })
    if (-not $upToDate) {
        $body = if ($wantsReviewers) {
            @{
                reviewers              = @(@{ type = 'User'; id = $reviewerId })
                deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
            }
        } else { @{} }
        $body | ConvertTo-Json -Depth 5 | & gh api --method PUT "$repoApi/environments/$EnvironmentName" --input - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not configure GitHub environment '$EnvironmentName' (exit $LASTEXITCODE)." }
        Write-Result $(if ($current) { 'updated' } else { 'created' }) "GitHub environment $EnvironmentName$(if ($wantsReviewers) { " (reviewer $ReviewerLogin)" })"
    }
    else {
        Write-Result 'unchanged' "GitHub environment $EnvironmentName"
    }

    if ($wantsReviewers) {
        $policiesApi = "$repoApi/environments/$EnvironmentName/deployment-branch-policies"
        $policies = Invoke-Gh api $policiesApi --jq '[.branch_policies[].name] | join(",")'
        if (@($policies -split ',') -contains 'main') {
            Write-Result 'unchanged' "$EnvironmentName deployment branch policy main"
        }
        else {
            @{ name = 'main'; type = 'branch' } | ConvertTo-Json | & gh api --method POST $policiesApi --input - | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not add branch policy 'main' to '$EnvironmentName'." }
            Write-Result 'created' "$EnvironmentName deployment branch policy main"
        }
    }
}

function Confirm-GitHubVariable {
    param([string]$EnvironmentName, [string]$Name, [string]$Value)
    $variablesApi = "$repoApi/environments/$EnvironmentName/variables"
    $existing = & gh api "$variablesApi/$Name" 2>$null
    $body = @{ name = $Name; value = $Value } | ConvertTo-Json
    if ($LASTEXITCODE -ne 0) {
        $body | & gh api --method POST $variablesApi --input - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not create variable $Name." }
        Write-Result 'created' "$EnvironmentName variable $Name"
    }
    elseif (($existing | ConvertFrom-Json).value -ne $Value) {
        $body | & gh api --method PATCH "$variablesApi/$Name" --input - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not update variable $Name." }
        Write-Result 'updated' "$EnvironmentName variable $Name"
    }
    else {
        Write-Result 'unchanged' "$EnvironmentName variable $Name"
    }
}

Write-Host "`n== Identity resource group" -ForegroundColor Cyan
Confirm-ResourceGroup -Name $IdentityResourceGroupName -Tags @{ workload = $Workload; purpose = 'cicd' }

foreach ($environmentName in $Environment) {
    $identityName = "id-$Workload-cicd-$environmentName-$Location-001"
    $workloadResourceGroup = "rg-$Workload-$environmentName"
    $workloadScope = "$subscriptionScope/resourceGroups/$workloadResourceGroup"

    Write-Host "`n== Environment: $environmentName" -ForegroundColor Cyan
    Confirm-ResourceGroup -Name $workloadResourceGroup -Tags @{ workload = $Workload; environment = $environmentName }

    $identity = & az identity show --name $identityName --resource-group $IdentityResourceGroupName --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $identity) {
        $identity = Invoke-Az identity create --name $identityName --resource-group $IdentityResourceGroupName `
            --location $Location --tags workload=$Workload environment=$environmentName purpose=cicd --output json
        Write-Result 'created' "managed identity $identityName"
    }
    else {
        Write-Result 'unchanged' "managed identity $identityName"
    }
    $identity = $identity | ConvertFrom-Json

    Confirm-RoleAssignment -PrincipalId $identity.principalId -Role 'Contributor' -Scope $workloadScope
    Confirm-RoleAssignment -PrincipalId $identity.principalId -Role 'Network Contributor' -Scope $hubScope
    Confirm-FederatedCredential -IdentityName $identityName -EnvironmentName $environmentName
    Confirm-GitHubEnvironment -EnvironmentName $environmentName

    $variables = [ordered]@{
        AZURE_CLIENT_ID       = $identity.clientId
        AZURE_TENANT_ID       = $tenantId
        AZURE_SUBSCRIPTION_ID = $subscriptionId
        AZURE_RESOURCE_GROUP  = $workloadResourceGroup
    }
    foreach ($variable in $variables.GetEnumerator()) {
        Confirm-GitHubVariable -EnvironmentName $environmentName -Name $variable.Key -Value $variable.Value
    }
}

Write-Host "`nDone." -ForegroundColor Green
