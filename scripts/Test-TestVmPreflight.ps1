#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SourceSize, [Parameter(Mandatory)][string]$TargetSize,
    [Parameter(Mandatory)][string]$ImageUrn, [string]$Zone,
    [Parameter(Mandatory)][decimal]$EstimatedHourlyCost,
    [Parameter(Mandatory)][decimal]$BudgetLimit, [int]$MaximumHours = 8,
    [string]$OutputPath = '.\out\test-preflight.json'
)
$ErrorActionPreference = 'Stop'
if ($EstimatedHourlyCost -le 0 -or $MaximumHours -le 0 -or $EstimatedHourlyCost * $MaximumHours -gt $BudgetLimit) { throw 'Positive cost estimate and sufficient approved budget are required.' }
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
$result = & (Get-Module AzVmUpgrade) {
    param($SubscriptionId,$Location,$SourceSize,$TargetSize,$ImageUrn,$Zone,$EstimatedHourlyCost,$BudgetLimit,$MaximumHours)
    $account = Invoke-UpgradeAz @('account','show','--subscription',$SubscriptionId)
    if ($account.id -ne $SubscriptionId -or $account.environmentName -ne 'AzureCloud') { throw 'Unexpected subscription/cloud context.' }
    $skus = Invoke-UpgradeAz @('vm','list-skus','--subscription',$SubscriptionId,'--location',$Location,'--resource-type','virtualMachines','--all')
    $usage = Invoke-UpgradeAz @('vm','list-usage','--subscription',$SubscriptionId,'--location',$Location)
    $image = Invoke-UpgradeAz @('vm','image','show','--subscription',$SubscriptionId,'--location',$Location,'--urn',$ImageUrn)
    if ($ImageUrn -match ':latest$' -or $image.hyperVGeneration -ne 'V2') { throw 'Select and pin an available Generation 2 image version, not latest.' }
    $selected = @()
    foreach ($size in @($SourceSize,$TargetSize | Sort-Object -Unique)) {
        $sku = @($skus | Where-Object name -CEQ $size)
        if ($sku.Count -ne 1) { throw "SKU $size is not uniquely advertised." }
        if (@($sku[0].restrictions).Count) { throw "SKU $size has restrictions; review exact zone/subscription restrictions before a lab deployment." }
        if ($Zone -and @($sku[0].locationInfo | Where-Object { $_.location -ieq $Location -and $Zone -in $_.zones }).Count -ne 1) { throw "SKU $size is not advertised in exact zone $Zone." }
        $cores = Get-SkuCapability $sku[0] 'vCPUs'
        if (-not $cores) { throw "Missing quota core count for $size." }
        foreach ($quota in @(@('cores',[int]$cores),@($sku[0].family,[int]$cores),@('virtualMachines',1))) {
            $record = @($usage | Where-Object { $_.name.value -ieq $quota[0] })
            if ($record.Count -ne 1 -or ($record[0].currentValue + $quota[1]) -gt $record[0].limit) { throw "Insufficient or unknown quota $($quota[0]) for $size." }
        }
        $selected += $sku[0]
    }
    @{
        observedAt = [DateTimeOffset]::UtcNow.ToString('o'); tenantId = $account.tenantId
        subscriptionId = $SubscriptionId; location = $Location; zone = $Zone
        skus = $selected; image = @{ urn = $ImageUrn; generation = $image.hyperVGeneration; plan = $image.plan }
        estimatedHourlyCost = $EstimatedHourlyCost; maximumHours = $MaximumHours; budgetLimit = $BudgetLimit
        allocationRisk = 'Unknown: quota and SKU availability are not capacity guarantees.'
        deploymentApproved = $false; cleanupApproved = $false
    }
} $SubscriptionId $Location $SourceSize $TargetSize $ImageUrn $Zone $EstimatedHourlyCost $BudgetLimit $MaximumHours
Write-UpgradeJson $result $OutputPath
$result
