#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WrapperPath,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TestResourceGroup,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][DateTimeOffset]$CleanupDeadline,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][switch]$LiveTestConsent,
    [Parameter(Mandatory)][switch]$CleanupConsent
)
$ErrorActionPreference = 'Stop'
if (-not $LiveTestConsent -or -not $CleanupConsent) { throw 'Exact paid wrapper and owned-group cleanup approval required.' }
if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or $TestResourceGroup -notmatch '^azvm-upgrade-lab-[a-zA-Z0-9-]+$') { throw 'Exact subscription/disposable group required.' }
if ($CleanupDeadline -le [DateTimeOffset]::UtcNow.AddMinutes(45) -or $CleanupDeadline -gt [DateTimeOffset]::UtcNow.AddHours(4)) { throw 'Bounded deadline and 45-minute reserve required.' }
if (Test-Path $OutputPath) { throw 'Never replay a supervisor result.' }
$wrapper = (Resolve-Path -LiteralPath $WrapperPath).Path
$wrapperText = Get-Content -LiteralPath $wrapper -Raw
$declaredSubscription = [regex]::Matches($wrapperText, "(?m)^\`$sub='([^']+)'")
$declaredGroup = [regex]::Matches($wrapperText, "(?m)^\`$rg='([^']+)'")
if ($declaredSubscription.Count -ne 1 -or $declaredGroup.Count -ne 1 -or
    $declaredSubscription[0].Groups[1].Value -ine $SubscriptionId -or
    $declaredGroup[0].Groups[1].Value -ine $TestResourceGroup) {
    throw 'Reviewed wrapper scope declarations must match the exact supervised subscription and cleanup group.'
}
Import-Module (Join-Path $PSScriptRoot '..\..\src\AzVmUpgrade.psd1') -Force
& (Get-Module AzVmUpgrade) {
    param($wrapper,$SubscriptionId,$TestResourceGroup,$Location,$CleanupDeadline,$OutputPath)
    $reserve = $CleanupDeadline.AddMinutes(-45)
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.WorkingDirectory = $script:RepositoryRoot
    foreach ($arg in @('-NoProfile','-NonInteractive','-File',$wrapper)) { $start.ArgumentList.Add($arg) }
    $start.Environment['AZVM_LAB_WORK_DEADLINE'] = $reserve.ToString('o')
    $start.Environment['AZVM_LAB_COMMAND_JOURNAL_DIRECTORY'] = "$OutputPath.commands"
    $result = @{ status='in-progress'; startedAt=[DateTimeOffset]::UtcNow.ToString('o')
        reserveAt=$reserve.ToString('o'); cleanupDeadline=$CleanupDeadline.ToString('o'); cleanup='pending' }
    $oldDeadline = $env:AZVM_LAB_WORK_DEADLINE
    $oldJournal = $env:AZVM_LAB_COMMAND_JOURNAL_DIRECTORY
    try {
        $env:AZVM_LAB_WORK_DEADLINE = $reserve.ToString('o')
        $env:AZVM_LAB_COMMAND_JOURNAL_DIRECTORY = "$OutputPath.commands"
        Write-UpgradeJson $result $OutputPath
        $account = Invoke-UpgradeAz @('account','show','--subscription',$SubscriptionId)
        if ($account.id -ine $SubscriptionId) { throw 'Subscription mismatch.' }
        if ((Invoke-UpgradeAz @('group','exists','-n',$TestResourceGroup,'--subscription',$SubscriptionId)) -ne $false) { throw 'Fresh approved group is not absent.' }
        $result.scopeChecked = $true
        Write-UpgradeJson $result $OutputPath
        $worker = Invoke-UpgradeProcess -StartInfo $start -TimeoutSeconds 14400 -Deadline $reserve -ObservationPath "$OutputPath.worker.json" -Operation 'approved lab wrapper'
        if ($worker.exitCode -ne 0) { throw "Lab worker failed ($($worker.exitCode)); see retained stdout/stderr." }
        $result.status = 'worker-exited'
    } catch {
        $result.status = 'failed'; $result.error = $_.Exception.Message
        throw
    } finally {
        try {
            if ($result.scopeChecked) {
                $result.cleanupStartedAt = [DateTimeOffset]::UtcNow.ToString('o')
                $cleanupLimit = $CleanupDeadline
                if ($cleanupLimit -le [DateTimeOffset]::UtcNow) {
                    $result.deadlineBreached = $true
                    $cleanupLimit = [DateTimeOffset]::UtcNow.AddMinutes(15)
                    Write-Warning 'Cleanup deadline already breached; attempting only exact owned cleanup with a bounded emergency grace, not further work.'
                }
                $env:AZVM_LAB_WORK_DEADLINE = $cleanupLimit.ToString('o')
                $env:AZVM_LAB_COMMAND_JOURNAL_DIRECTORY = "$OutputPath.commands"
                $exists = Invoke-UpgradeAz @('group','exists','-n',$TestResourceGroup,'--subscription',$SubscriptionId) -TimeoutSeconds 60
                if ($exists -ne $false) {
                    $group = Invoke-UpgradeAz @('group','show','-n',$TestResourceGroup,'--subscription',$SubscriptionId) -TimeoutSeconds 60
                    if ($group.name -ine $TestResourceGroup -or $group.location -ine $Location -or $group.tags.'az-vm-upgrade-disposable' -ne 'true') {
                        throw 'Cleanup ownership mismatch; no deletion submitted.'
                    }
                    Write-UpgradeJson $group "$OutputPath.cleanup-owner.json"
                    Invoke-UpgradeAz @('group','delete','-n',$TestResourceGroup,'--yes','--no-wait','--subscription',$SubscriptionId) -TimeoutSeconds 60 | Out-Null
                    do {
                        $exists = Invoke-UpgradeAz @('group','exists','-n',$TestResourceGroup,'--subscription',$SubscriptionId) -TimeoutSeconds 60
                        if ($exists -eq $false) { break }
                        Assert-LabWorkDeadline
                        Start-Sleep -Seconds 5
                    } while ($true)
                }
                $remaining = @(Invoke-UpgradeAz @('resource','list','--subscription',$SubscriptionId) -TimeoutSeconds 60 |
                    Where-Object { $_ -and $_.resourceGroup -ieq $TestResourceGroup })
                Write-UpgradeJson @{groupExists=$exists;resources=$remaining} "$OutputPath.cleanup-absence.json"
                if ($exists -ne $false -or $remaining.Count) { throw 'Exact cleanup absence not proved.' }
                $result.cleanup = 'pass'
            } else { $result.cleanup = 'not-started' }
        } catch {
            $result.status = 'failed'
            $result.cleanup = 'unverified'; $result.cleanupError = $_.Exception.Message
            throw "Exact cleanup is unverified; immediate operator intervention required: $($_.Exception.Message)"
        } finally {
            $env:AZVM_LAB_WORK_DEADLINE = $oldDeadline
            $env:AZVM_LAB_COMMAND_JOURNAL_DIRECTORY = $oldJournal
            $result.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Write-UpgradeJson $result $OutputPath
        }
    }
} $wrapper $SubscriptionId $TestResourceGroup $Location $CleanupDeadline $OutputPath
