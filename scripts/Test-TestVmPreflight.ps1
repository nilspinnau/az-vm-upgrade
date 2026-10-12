#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SourceSize, [Parameter(Mandatory)][string]$TargetSize,
    [Parameter(Mandatory)][string]$ImageUrn, [string]$Zone,
    [Parameter(Mandatory)][decimal]$EstimatedHourlyCost,
    [Parameter(Mandatory)][decimal]$BudgetLimit, [int]$MaximumHours = 8,
    [Parameter(Mandatory)][decimal]$MonthlyBudgetLimit,
    [decimal]$CostSafetyReserve = 25, [bool]$EncryptionAtHost = $true,
    [string]$OutputPath = '.\out\test-preflight.json'
)
$ErrorActionPreference = 'Stop'
if ($EstimatedHourlyCost -le 0 -or $MaximumHours -le 0 -or $EstimatedHourlyCost * $MaximumHours -gt $BudgetLimit) { throw 'Positive cost estimate and sufficient approved budget are required.' }
if ($MonthlyBudgetLimit -le 0 -or $CostSafetyReserve -lt 0) { throw 'Positive monthly ceiling and nonnegative telemetry safety reserve required.' }
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
$result = & (Get-Module AzVmUpgrade) {
    param($SubscriptionId,$Location,$SourceSize,$TargetSize,$ImageUrn,$Zone,$EstimatedHourlyCost,$BudgetLimit,$MaximumHours,$MonthlyBudgetLimit,$CostSafetyReserve,$EncryptionAtHost)
    $account = Invoke-UpgradeAz @('account','show','--subscription',$SubscriptionId)
    if ($account.id -ne $SubscriptionId -or $account.environmentName -ne 'AzureCloud') { throw 'Unexpected subscription/cloud context.' }
    $cost = Get-LabMonthToDateCost $SubscriptionId
    if ($cost.properties.nextLink -or @($cost.properties.rows).Count -ne 1) { throw 'Missing or ambiguous month-to-date cost/headroom.' }
    $columns = @($cost.properties.columns.name)
    $amountIndex = [array]::IndexOf($columns,'PreTaxCost')
    $currencyIndex = [array]::IndexOf($columns,'Currency')
    if ($amountIndex -lt 0 -or $currencyIndex -lt 0 -or $cost.properties.rows[0][$currencyIndex] -cne 'USD') {
        throw 'Expected a USD actual-cost total; do not infer currency conversion or free resources.'
    }
    $amount = $cost.properties.rows[0][$amountIndex]
    if ($null -eq $amount -or $amount -is [string] -or [decimal]$amount -lt 0) { throw 'Invalid actual cost total.' }
    $headroom = $MonthlyBudgetLimit - [decimal]$amount - $CostSafetyReserve
    if ($BudgetLimit -gt $headroom) { throw 'Lab budget exceeds conservative reported monthly headroom; cost telemetry is delayed.' }
    $featureState = $null
    if ($EncryptionAtHost) {
        $feature = Invoke-UpgradeAz @('feature','show','--subscription',$SubscriptionId,'--namespace','Microsoft.Compute','--name','EncryptionAtHost')
        $featureState = Get-Field $feature 'properties.state'
        if ($featureState -ne 'Registered') { throw 'EncryptionAtHost feature is not Registered. Obtain separate registration approval; never disable encryption to proceed.' }
    }
    foreach ($namespace in @('Microsoft.Compute','Microsoft.Network')) {
        $provider = Invoke-UpgradeAz @('provider','show','--subscription',$SubscriptionId,'--namespace',$namespace)
        if ($provider.registrationState -ne 'Registered') { throw "$namespace provider is not Registered; explicit registration approval is required." }
    }
    $skus = Invoke-UpgradeAz @('vm','list-skus','--subscription',$SubscriptionId,'--location',$Location,'--resource-type','virtualMachines','--all')
    $usage = Invoke-UpgradeAz @('vm','list-usage','--subscription',$SubscriptionId,'--location',$Location)
    $image = Invoke-UpgradeAz @('vm','image','show','--subscription',$SubscriptionId,'--location',$Location,'--urn',$ImageUrn)
    if ($ImageUrn -match ':latest$' -or $image.hyperVGeneration -ne 'V2') { throw 'Select and pin an available Generation 2 image version, not latest.' }
    $selected = @()
    foreach ($size in @($SourceSize,$TargetSize | Sort-Object -Unique)) {
        $sku = @($skus | Where-Object name -CEQ $size)
        if ($sku.Count -ne 1) { throw "SKU $size is not uniquely advertised." }
        if ($EncryptionAtHost -and (Get-SkuCapability $sku[0] 'EncryptionAtHostSupported') -ne 'True') {
            throw "SKU $size does not prove encryption-at-host support."
        }
        if ((Get-SkuCapability $sku[0] 'MaxResourceVolumeMB') -ne '0' -or
            [double](Get-SkuCapability $sku[0] 'NvmeDiskSizeInMiB') -gt 0) { throw "SKU $size is not a supported no-temp-disk lab size." }
        if (@($sku[0].restrictions).Count) { throw "SKU $size has restrictions; review exact zone/subscription restrictions before a lab deployment." }
        if ($Zone -and @($sku[0].locationInfo | Where-Object { $_.location -ieq $Location -and $Zone -in $_.zones }).Count -ne 1) { throw "SKU $size is not advertised in exact zone $Zone." }
        $cores = Get-SkuCapability $sku[0] 'vCPUs'
        if (-not $cores) { throw "Missing quota core count for $size." }
        foreach ($quota in @(@('cores',[int]$cores),@($sku[0].family,[int]$cores),@('virtualMachines',1))) {
            $record = @($usage | Where-Object { $_.name.value -ieq $quota[0] })
            if ($record.Count -ne 1 -or $null -eq $record[0].currentValue -or $null -eq $record[0].limit -or
                ([int]$record[0].currentValue + [int]$quota[1]) -gt [int]$record[0].limit) { throw "Insufficient or unknown quota $($quota[0]) for $size." }
        }
        $selected += $sku[0]
    }
    @{
        observedAt = [DateTimeOffset]::UtcNow.ToString('o'); tenantId = $account.tenantId
        subscriptionId = $SubscriptionId; location = $Location; zone = $Zone
        skus = $selected; image = @{ urn = $ImageUrn; generation = $image.hyperVGeneration; plan = $image.plan }
        estimatedHourlyCost = $EstimatedHourlyCost; maximumHours = $MaximumHours; budgetLimit = $BudgetLimit
        encryptionAtHost = $EncryptionAtHost; encryptionAtHostFeature = $featureState
        cost = @{ reportedMonthToDateUSD = [decimal]$amount; monthlyCeilingUSD = $MonthlyBudgetLimit
            safetyReserveUSD = $CostSafetyReserve; conservativeHeadroomUSD = $headroom
            caveat = 'Delayed pretax telemetry, not a current total or hard-stop budget. Include disks/snapshots/IP/transactions/transfer in the lab estimate.' }
        allocationRisk = 'Unknown: quota and SKU availability are not capacity guarantees.'
        deploymentApproved = $false; cleanupApproved = $false
    }
} $SubscriptionId $Location $SourceSize $TargetSize $ImageUrn $Zone $EstimatedHourlyCost $BudgetLimit $MaximumHours $MonthlyBudgetLimit $CostSafetyReserve $EncryptionAtHost
Write-UpgradeJson $result $OutputPath
$result
