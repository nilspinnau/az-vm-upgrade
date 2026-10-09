#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$SubscriptionId,
    [string]$ResourceGroup, [string]$Location, [string]$Size,
    [string]$TagName, [AllowEmptyString()][string]$TagValue, [string]$OutputDirectory = '.\out\inventory',
    [switch]$AdvisorCrossCheck,
    [ValidateSet('active','completed','postponed','dismissed','unknown')][string[]]$AdvisorState = @('active','completed','postponed','dismissed','unknown'),
    [string]$AdvisorStatePropertyPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
$parameters = @{ SubscriptionId=$SubscriptionId; ResourceGroup=$ResourceGroup; Location=$Location; Size=$Size
    AdvisorCrossCheck=$AdvisorCrossCheck; AdvisorState=$AdvisorState; AdvisorStatePropertyPath=$AdvisorStatePropertyPath }
if ($TagName) { $parameters.TagName = $TagName }
if ($PSBoundParameters.ContainsKey('TagValue')) { $parameters.TagValue = $TagValue }
$inventory = Get-VmInventory @parameters
Write-UpgradeJson $inventory (Join-Path $OutputDirectory 'inventory.json')
$inventory.vms | Select-Object id,name,subscriptionId,resourceGroup,location,size,controller,osType,
    @{n='lifecycleSeries';e={($_.lifecycle.series -join ';')}} |
    Export-Csv (Join-Path $OutputDirectory 'inventory.csv') -NoTypeInformation
$coverage = @('# Inventory scope coverage','','Resource Graph is eventually consistent; fresh ARM/guest checks are mandatory before execution.','')
foreach ($scope in $inventory.scopes) { $coverage += "- $($scope.subscriptionId): $($scope.status), $($scope.count) rows. $($scope.error)" }
if ($inventory.advisor) {
    $coverage += @('','## Advisor coverage gaps','',$inventory.advisor.limitations)
    foreach ($scope in $inventory.advisor.scopes) { $coverage += "- Advisor $($scope.subscriptionId): $($scope.status). $($scope.error)" }
    foreach ($scope in $inventory.advisor.metadataScopes) { $coverage += "- Advisor metadata $($scope.subscriptionId): $($scope.status). $($scope.error)" }
    foreach ($gap in $inventory.advisor.coverageGaps) { $coverage += "- $($gap.kind): $($gap.vmId). $($gap.detail)" }
    Write-UpgradeJson $inventory.advisor (Join-Path $OutputDirectory 'advisor-cross-check.json')
}
$coverage | Set-Content (Join-Path $OutputDirectory 'coverage.md')
if (-not $inventory.complete) { throw 'Inventory has denied/failed scopes. Partial evidence was saved; do not claim complete estate coverage.' }
$inventory
