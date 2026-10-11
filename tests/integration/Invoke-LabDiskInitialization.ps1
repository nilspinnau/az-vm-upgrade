#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmId,
    [Parameter(Mandatory)][string]$DiskId,
    [Parameter(Mandatory)][string]$TestResourceGroup,
    [Parameter(Mandatory)][DateTimeOffset]$ExpiresAt,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('imds-required','arm-azure-udev')][string]$IdentityMode = 'imds-required',
    [switch]$LiveTestConsent,
    [switch]$ArmUdevIdentityConsent,
    [switch]$ExclusiveWindowConsent
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\AzVmUpgrade.psd1') -Force
& (Get-Module AzVmUpgrade) {
    param($VmId,$DiskId,$TestResourceGroup,$ExpiresAt,$OutputPath,$IdentityMode,$LiveTestConsent,$ArmUdevIdentityConsent,$ExclusiveWindowConsent)
    if (-not $LiveTestConsent -or -not $ExclusiveWindowConsent -or ($IdentityMode -eq 'arm-azure-udev' -and -not $ArmUdevIdentityConsent)) {
        throw 'Explicit formatting and identity-method consent required; no fallback.'
    }
    if ($ExpiresAt -le [DateTimeOffset]::UtcNow -or $ExpiresAt -gt [DateTimeOffset]::UtcNow.AddHours(4)) {
        throw 'Fresh bounded lab consent required.'
    }
    if ($TestResourceGroup -notmatch '^azvm-upgrade-lab-[a-zA-Z0-9-]+$' -or
        $VmId -notmatch '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/([^/]+)/providers/Microsoft.Compute/virtualMachines/([^/]+)$') {
        throw 'Exact disposable lab VM scope required.'
    }
    $sub = $Matches[1]; $group = $Matches[2]; $vmName = $Matches[3]
    $scope = "/subscriptions/$sub/resourceGroups/$TestResourceGroup/providers/Microsoft.Compute/disks/"
    if ($group -ine $TestResourceGroup -or -not $DiskId.StartsWith($scope, [StringComparison]::OrdinalIgnoreCase) -or
        $DiskId.Substring($scope.Length) -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Disk outside exact approved scope.' }
    $result = @{ schemaVersion = 'lab-initialization/1.0'; identityMode = $IdentityMode
        vmId = $VmId; diskId = $DiskId; testResourceGroup = $TestResourceGroup
        expiresAt = $ExpiresAt.ToString('o'); labOnly = $true; status = 'in-progress'; observations = @{} }
    Write-UpgradeJson $result $OutputPath
    function Assert-LabAttachment($Vm, $Disk) {
        $storageProfile = $Vm.properties.storageProfile
        $attached = @($storageProfile.dataDisks)
        if ($Vm.id -ine $VmId -or $Disk.id -ine $DiskId -or $Disk.managedBy -ine $VmId -or
            $Vm.tags.'az-vm-upgrade-disposable' -ne 'true' -or $Disk.tags.'az-vm-upgrade-disposable' -ne 'true' -or
            $storageProfile.diskControllerType -ne 'SCSI' -or $Disk.properties.creationData.createOption -ne 'Empty' -or
            -not $Disk.properties.uniqueId -or
            $attached.Count -ne 1 -or $attached[0].lun -ne 0 -or $attached[0].managedDisk.id -ine $DiskId -or
            -not $storageProfile.osDisk.managedDisk.id -or $storageProfile.osDisk.managedDisk.id -ieq $DiskId) {
            throw 'Exact owned new SCSI data disk/unique LUN/OS exclusion not proved.'
        }
    }
    try {
        $account = Invoke-UpgradeAz @('account','show','--subscription',$sub)
        $result.observations.account = $account; Write-UpgradeJson $result $OutputPath
        if ($account.id -ine $sub) { throw 'Subscription mismatch.' }
        $rg = Invoke-UpgradeAz @('group','show','-n',$TestResourceGroup,'--subscription',$sub)
        $result.observations.group = $rg; Write-UpgradeJson $result $OutputPath
        if ($rg.name -ine $TestResourceGroup -or $rg.tags.'az-vm-upgrade-disposable' -ne 'true') { throw 'Lab group ownership not proved.' }
        $vm = Invoke-ArmRead $VmId '2024-07-01'
        $result.observations.vm = $vm; Write-UpgradeJson $result $OutputPath
        $disk = Invoke-ArmRead $DiskId '2024-03-02'
        $result.observations.disk = $disk; Write-UpgradeJson $result $OutputPath
        Assert-LabAttachment $vm $disk
        $probe = Invoke-UpgradeAz @('vm','run-command','invoke','--ids',$VmId,'--subscription',$sub,
            '--command-id','RunShellScript','--scripts','set -eu; udevadm info --query=property --name=/dev/disk/azure/scsi1/lun0 | grep -E "^(ID_BUS|ID_SERIAL_SHORT|AZURE_DISK_LUN|AZURE_DISK_TYPE)="') -TimeoutSeconds 600
        $result.observations.serialProbe = $probe; Write-UpgradeJson $result $OutputPath
        $stdout = Get-RunCommandStdout $probe
        $serials = [regex]::Matches($stdout, '(?m)^ID_SERIAL_SHORT=([0-9a-fA-F]+)\s*$')
        if ($serials.Count -ne 1 -or $stdout -notmatch '(?m)^ID_BUS=scsi\s*$' -or
            $stdout -notmatch '(?m)^AZURE_DISK_LUN=0\s*$' -or $stdout -notmatch '(?m)^AZURE_DISK_TYPE=data\s*$') {
            throw 'Exact Microsoft SCSI data/LUN/serial mapping not captured.'
        }
        $serial = $serials[0].Groups[1].Value
        $freshObservedAt = [DateTimeOffset]::UtcNow
        $freshVm = Invoke-ArmRead $VmId '2024-07-01'
        $result.observations.freshVm = $freshVm; Write-UpgradeJson $result $OutputPath
        $freshDisk = Invoke-ArmRead $DiskId '2024-03-02'
        $result.observations.freshDisk = $freshDisk; Write-UpgradeJson $result $OutputPath
        Assert-LabAttachment $freshVm $freshDisk
        if ($freshVm.properties.storageProfile.osDisk.managedDisk.id -ine $vm.properties.storageProfile.osDisk.managedDisk.id) {
            throw 'OS attachment changed since serial capture.'
        }
        if ($freshDisk.properties.uniqueId -ine $disk.properties.uniqueId) { throw 'Managed disk resource incarnation changed since serial capture.' }
        if ([DateTimeOffset]::UtcNow -ge $ExpiresAt) { throw 'Lab consent expired before initialization.' }
        if (([DateTimeOffset]::UtcNow - $freshObservedAt).TotalMinutes -gt 10) { throw 'Refreshed ARM identity evidence is stale before initialization.' }
        $proof = @{ schemaVersion = 'lab-arm-identity/1.0'; identityMode = $IdentityMode; labOnly = $true
            observedAt = $freshObservedAt.ToString('o'); expiresAt = $ExpiresAt.ToString('o')
            subscriptionId = $sub; testResourceGroup = $TestResourceGroup; vmName = $vmName
            vm = $freshVm; disk = $freshDisk; expectedScsiSerial = $serial }
        $result.identityEvidence = $proof; Write-UpgradeJson $result $OutputPath
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($proof | ConvertTo-Json -Depth 50 -Compress)))
        $encodedId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($DiskId))
        $body = Get-Content (Join-Path $script:RepositoryRoot 'guest\lab-sentinel-linux.sh') -Raw
        $scriptBody = "#!/usr/bin/env bash`nexport AZVM_INITIALIZE_CONSENT='format-new-disposable-test-data-disk'`nexport AZVM_IDENTITY_MODE='$IdentityMode'`nexport AZVM_ARM_IDENTITY_BASE64='$encoded'`nexport AZVM_EXPECTED_DISK_ID=`"`$(printf '%s' '$encodedId' | base64 -d)`"`nexport AZVM_EXPECTED_SCSI_SERIAL='$serial'`n" + ($body -replace '^#!.*\r?\n','')
        $scriptPath = "$OutputPath.initialize.sh"
        [IO.File]::WriteAllText($scriptPath, $scriptBody)
        $response = Invoke-UpgradeAz @('vm','run-command','invoke','--ids',$VmId,'--subscription',$sub,
            '--command-id','RunShellScript','--scripts',"@$scriptPath") -TimeoutSeconds 600
        $result.observations.initialization = $response; Write-UpgradeJson $result $OutputPath
        if ((Get-RunCommandStdout $response) -notlike '*Only the explicitly identified new test data disk was initialized*') {
            throw 'Initialization not proved; inspect retained observation.'
        }
        $result.status = 'initialized'
    } catch {
        $result.status = 'failed'; $result.error = $_.Exception.Message
        throw
    } finally { Write-UpgradeJson $result $OutputPath }
} $VmId $DiskId $TestResourceGroup $ExpiresAt $OutputPath $IdentityMode $LiveTestConsent.IsPresent $ArmUdevIdentityConsent.IsPresent $ExclusiveWindowConsent.IsPresent
