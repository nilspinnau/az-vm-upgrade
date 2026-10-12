param([Parameter(Mandatory)][string]$WrapperPath, [string]$Scenario, [string]$SharedScopePath)
Import-Module (Join-Path $PSScriptRoot '..\..\src\AzVmUpgrade.psd1') -Force
BeforeAll {
    & (Get-Module AzVmUpgrade) {
        param($Path,$Scenario,$SharedScopePath)
        $script:wrapperText = Get-Content $Path -Raw
        $script:currentWrapperPath = $Path
        $script:workerScenario = $Scenario
        $script:sharedScopePath = $SharedScopePath
    } $WrapperPath $Scenario $SharedScopePath
}
InModuleScope AzVmUpgrade {
    Describe 'Private same-interface wrapper as one program, offline' {
        BeforeAll {
            $script:wrapper = [scriptblock]::Create($script:wrapperText)
            function terraform {}
            $script:wrapperSub = [regex]::Match($script:wrapperText, "(?m)^\`$sub='([^']+)'").Groups[1].Value
            $script:wrapperGroup = [regex]::Match($script:wrapperText, "(?m)^\`$rg='([^']+)'").Groups[1].Value
            $script:wrapperOutput = [regex]::Match($script:wrapperText, "(?m)^\`$out=\(Resolve-Path ([^)]+)\)\.Path").Groups[1].Value
            if (-not $script:wrapperSub -or -not $script:wrapperGroup -or -not $script:wrapperOutput) { throw 'Unsupported wrapper scope declaration' }
            $script:oldConfig = $env:AZURE_CONFIG_DIR
            $initSource = Get-Content (Join-Path $script:RepositoryRoot 'tests\integration\Invoke-LabDiskInitialization.ps1') -Raw
            $initBody = $initSource.Substring($initSource.IndexOf('    param($VmId,'))
            $initBody = $initBody.Substring(0, $initBody.LastIndexOf('} $VmId $DiskId'))
            $script:initBody = [scriptblock]::Create($initBody)
            function Invoke-OfflineLabInitialization {
                param($VmId,$DiskId,$TestResourceGroup,$ExpiresAt,$OutputPath,$IdentityMode,
                    [switch]$LiveTestConsent,[switch]$ArmUdevIdentityConsent,[switch]$ExclusiveWindowConsent)
                & $script:initBody $VmId $DiskId $TestResourceGroup $ExpiresAt $OutputPath $IdentityMode $LiveTestConsent.IsPresent $ArmUdevIdentityConsent.IsPresent $ExclusiveWindowConsent.IsPresent
            }
            $pattern = '(?s)& \(Get-Module AzVmUpgrade\) \{\s*param\(\$vmId,\$diskId,\$out,\$sub\).*?\} \$vmId \$o\.data_disk_id\.value \$out \$sub'
            $explicitCall = '.\tests\integration\Invoke-LabDiskInitialization.ps1 -VmId $vmId -DiskId $o.data_disk_id.value -TestResourceGroup $rg -ExpiresAt $reserve -IdentityMode arm-azure-udev -LiveTestConsent -ArmUdevIdentityConsent -ExclusiveWindowConsent -OutputPath "$out\resize-initialization-journal.json"'
            $legacyCount = [regex]::Matches($script:wrapperText, $pattern).Count
            $explicitCount = [regex]::Matches($script:wrapperText, [regex]::Escape($explicitCall)).Count
            $script:initializationPattern = $pattern
            $script:explicitInitializationCall = $explicitCall
            function Assert-OfflineInitializationShape {
                param($Text)
                $legacy = [regex]::Matches($Text,$script:initializationPattern).Count
                $exact = [regex]::Matches($Text,[regex]::Escape($script:explicitInitializationCall)).Count
                $helpers = [regex]::Matches($Text,'Invoke-LabDiskInitialization\.ps1\b').Count
                if (-not (($legacy -eq 1 -and $exact -eq 0 -and $helpers -eq 0) -or
                    ($legacy -eq 0 -and $exact -eq 1 -and $helpers -eq 1))) {
                    throw 'Unsupported initialization block; do not infer replacement scope'
                }
            }
            Assert-OfflineInitializationShape $script:wrapperText
            if ($legacyCount -eq 1 -and $explicitCount -eq 0) {
            $replacement = @'
$result.identityMode='arm-azure-udev'
    Write-UpgradeJson $result "$out\resize-cycle.json"
    Invoke-OfflineLabInitialization -VmId $vmId -DiskId $o.data_disk_id.value -TestResourceGroup $rg -ExpiresAt $reserve -IdentityMode arm-azure-udev -LiveTestConsent -ArmUdevIdentityConsent -ExclusiveWindowConsent -OutputPath "$out\resize-initialization-journal.json"
'@
            $script:armWrapper = [scriptblock]::Create([regex]::Replace($script:wrapperText, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }))
            } elseif ($legacyCount -eq 0 -and $explicitCount -eq 1) {
                $script:armWrapper = [scriptblock]::Create($script:wrapperText.Replace($explicitCall, $explicitCall.Replace('.\tests\integration\Invoke-LabDiskInitialization.ps1', 'Invoke-OfflineLabInitialization')))
                $script:wrapper = $script:armWrapper
            } else { throw 'Unsupported initialization block; do not infer replacement scope' }
            $script:explicitWrapper = $explicitCount -eq 1
        }
        BeforeEach {
            $script:identityRefused = $false
            $script:useArmMode = $script:explicitWrapper
            $script:exists = $false
            $script:deleted = $false
            $script:guestCalls = 0
            $script:sub = $script:wrapperSub
            $script:group = $script:wrapperGroup
            $script:vm = "/subscriptions/$script:sub/resourceGroups/$script:group/providers/Microsoft.Compute/virtualMachines/testvm"
            $script:disk = "/subscriptions/$script:sub/resourceGroups/$script:group/providers/Microsoft.Compute/disks/testvm-sentinel"
            $script:os = "/subscriptions/$script:sub/resourceGroups/$script:group/providers/Microsoft.Compute/disks/os"
            $rootParent = if ($script:sharedScopePath) { Split-Path $script:sharedScopePath -Parent } else { $TestDrive }
            $root = Join-Path $rootParent ([guid]::NewGuid().ToString('N'))
            foreach ($dir in @($script:wrapperOutput,'infra\test-vm','tests\integration','guest','src')) {
                [IO.Directory]::CreateDirectory((Join-Path $root $dir)) | Out-Null
            }
            $script:out = Join-Path $root $script:wrapperOutput
            [IO.File]::WriteAllText((Join-Path $script:out 'lab-key.pub'), 'synthetic public key')
            [IO.File]::WriteAllText((Join-Path $root 'guest\lab-sentinel-linux.sh'), '# synthetic external formatting command; never executed')
            Write-UpgradeJson @{ observedAt = [DateTimeOffset]::UtcNow.ToString('o'); cost = @{ conservativeHeadroomUSD = 470 } } (Join-Path $script:out 'resize-preflight.json')
            Write-UpgradeJson @{ source_size = 'Standard_D2as_v5' } (Join-Path $script:out 'resize.tfvars.json')
            $script:initialTf = @{ resource_changes = @(
                @{ type = 'azurerm_linux_virtual_machine'; change = @{ actions = @('create'); after = @{
                    size = 'Standard_D2as_v5'; disk_controller_type = 'SCSI'; encryption_at_host_enabled = $true
                    os_disk = @(@{ disk_size_gb = 64 }) } } }
            ) + @(1..8 | ForEach-Object { @{ type = 'synthetic-private-resource'; change = @{ actions = @('create') } } }) }
            Write-UpgradeJson $script:initialTf (Join-Path $script:out 'resize-plan.json')
            $script:syntheticPlan = @{ vmId = $script:vm; tenantId = 'synthetic'; hash = 'a' * 64; classification = 'ready'
                targetSize = 'Standard_D4as_v5'; targetController = 'SCSI'; workloadReview = @{} }
            $script:syntheticEvidence = @{ vm = @{ hardwareProfile = @{ vmSize = 'Standard_D2as_v5' } } }
            $prepStub = @'
param($PreparationPath,$TestContextPath,[switch]$LiveTestConsent,$OutputPath,$TerraformNoOpEvidencePath,$JournalDirectory)
Import-Module AzVmUpgrade
Write-UpgradeJson @{status='completed';synthetic=$true} $OutputPath
'@
            $restoreStub = @'
param($PlanPath,$TestContextPath,[switch]$LiveTestConsent,$OutputPath,$JournalDirectory)
Import-Module AzVmUpgrade
Write-UpgradeJson @{status='restoration-verified';synthetic=$true} $OutputPath
'@
            [IO.File]::WriteAllText((Join-Path $root 'tests\integration\Invoke-LabPreparationAcceptance.ps1'), $prepStub)
            [IO.File]::WriteAllText((Join-Path $root 'tests\integration\Invoke-LabRestoreAcceptance.ps1'), $restoreStub)
            Mock Import-Module {}
            Mock Invoke-RestMethod {
                @{ NextPageLink = $null; Items = @(
                    @{productName='Virtual Machines Dasv5 Series';skuName='Standard_D2as_v5';meterName='D2as v5';unitPrice=.092},
                    @{productName='Virtual Machines Dasv5 Series';skuName='Standard_D4as_v5';meterName='D4as v5';unitPrice=.184},
                    @{productName='Standard SSD Managed Disks';skuName='E6 LRS';meterName='E6 LRS Disk';unitPrice=4.8},
                    @{productName='Standard SSD Managed Disks';skuName='E2 LRS';meterName='E2 LRS Disk';unitPrice=.6},
                    @{productName='Standard HDD Managed Disks';skuName='Snapshots LRS';meterName='LRS Snapshots';unitPrice=.05},
                    @{productName='Standard SSD Managed Disks';skuName='Snapshots LRS';meterName='Snapshots LRS Snapshots';unitPrice=.145},
                    @{productName='Standard SSD Managed Disks';skuName='Disk Transactions LRS';meterName='Disk Transactions LRS Disk Operations';unitPrice=.0026}) }
            }
            Mock terraform {
                $global:LASTEXITCODE = 0
                $argsText = $args -join ' '
                if ($argsText -match 'apply') {
                    $script:exists = $true
                    if ($script:sharedScopePath) { Write-UpgradeJson @{exists=$true} $script:sharedScopePath }
                    return
                }
                if ($argsText -match 'output') {
                    return (@{vm_id=@{value=$script:vm};data_disk_id=@{value=$script:disk}} | ConvertTo-Json -Depth 6)
                }
                if ($argsText -match 'show') { return '{"resource_changes":[]}' }
            }
            Mock Get-VmEvidence {
                if ($script:workerScenario -eq 'stall') {
                    Write-UpgradeJson @{exists=$true;stage='evidence-collection'} $script:sharedScopePath
                    Start-Sleep -Seconds 60
                }
                if ($script:workerScenario -eq 'reserve') {
                    $env:AZVM_LAB_WORK_DEADLINE = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
                    Assert-LabWorkDeadline
                }
                $script:syntheticEvidence
            }
            Mock Write-UpgradeJson {
                throw 'Synthetic durable evidence publication failed; no phase promotion'
            } -ParameterFilter { $script:workerScenario -eq 'journal' -and $Path -like '*resize-baseline.json' }
            Mock New-VmUpgradePlan { @{} + $script:syntheticPlan }
            Mock New-GuestPreparationPlan { @{ hash = 'b' * 64 } }
            Mock Invoke-VmUpgrade {
                [IO.Directory]::CreateDirectory((Join-Path $script:out 'journals')) | Out-Null
                $key = Get-UpgradeHash $script:vm.ToLowerInvariant()
                Write-UpgradeJson @{ phase = 'verified'; pendingOperation = $null } (Join-Path $script:out "journals\$key.journal.json")
                throw 'VM technically verified; supply post-verification owner acceptance (synthetic)'
            }
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -eq $script:vm) {
                    return @{id=$script:vm;location='swedencentral';tags=@{'az-vm-upgrade-disposable'='true'};properties=@{
                        securityProfile=@{encryptionAtHost=$true};storageProfile=@{diskControllerType='SCSI'
                        osDisk=@{managedDisk=@{id=$script:os}}
                        dataDisks=@(@{lun=0;managedDisk=@{id=$script:disk}})}}}
                }
                if ($Id -eq $script:disk) {
                    return @{id=$script:disk;managedBy=$script:vm;tags=@{'az-vm-upgrade-disposable'='true'}
                        properties=@{uniqueId='synthetic-incarnation';diskSizeGB=8;creationData=@{createOption='Empty'}}}
                }
                @{properties=@{diskSizeGB=64}}
            }
            Mock Invoke-UpgradeAz {
                param($Arguments)
                switch ($Arguments[0]+':'+$Arguments[1]) {
                    'account:show' { return @{ id=$script:sub } }
                    'group:exists' { return $script:exists }
                    'group:show' { return @{name=$script:group;location='swedencentral';tags=@{'az-vm-upgrade-disposable'='true'}} }
                    'group:delete' {
                        if ($script:workerScenario -eq 'cleanup') { throw 'Synthetic cleanup timeout' }
                        $script:exists=$false;$script:deleted=$true
                        if ($script:sharedScopePath) { Write-UpgradeJson @{exists=$false} $script:sharedScopePath }
                        return
                    }
                    'resource:list' {
                        if ('-g' -in $Arguments) { return @(@{id='synthetic';resourceGroup=$script:group}) }
                        return @()
                    }
                    'snapshot:create' { return @{id=($script:vm -replace '/virtualMachines/.*$', '/snapshots/synthetic')} }
                    'vm:run-command' {
                        $script:guestCalls++
                        $message = if ($script:guestCalls -eq 1) {
                            "ID_BUS=scsi`nID_SERIAL_SHORT=60022480aabb`nAZURE_DISK_LUN=0`nAZURE_DISK_TYPE=data`n"
                        } elseif ($script:useArmMode -and $script:identityRefused) {
                            'AZVM_DISK_IDENTITY_OBSERVATION={"identityMode":"arm-azure-udev","storageProfile":{"dataDisks":[{"lun":"0","managedDisk":{"id":"synthetic-wrong-disk"}}]}} RuntimeError: Exact managed disk identity and unique LUN not confirmed by IMDS'
                        } elseif ($script:useArmMode) {
                            'AZVM_DISK_IDENTITY_OBSERVATION={"identityMode":"arm-azure-udev","storageProfile":{"dataDisks":[]}} Only the explicitly identified new test data disk was initialized'
                        } elseif ($script:identityRefused) {
                            'RuntimeError: Exact managed disk identity and unique LUN not confirmed by IMDS'
                        } else { 'Only the explicitly identified new test data disk was initialized' }
                        return @{value=@(@{code='ComponentStatus/StdOut/succeeded';message=$message})}
                    }
                    default { throw "Unmocked Azure command blocked: $($Arguments -join ' ')" }
                }
            }
            Push-Location $root
        }
        AfterEach { Pop-Location; $env:AZURE_CONFIG_DIR = $script:oldConfig }
        It 'runs unchanged wrapper control flow from fresh gates through cleanup' {
            & $script:wrapper
            $r = Read-UpgradeJson (Join-Path $script:out 'resize-cycle.json')
            $r.status | Should -Be 'completed'
            $r.cleanup | Should -Be 'pass'
            $r.steps.name | Should -Contain 'final-normal-terraform-noop'
            $script:deleted | Should -BeTrue
            $script:exists | Should -BeFalse
        }
        It 'runs initial identity refusal through exact cleanup without preparation or resize' {
            $script:identityRefused = $true
            { & $script:wrapper } | Should -Throw '*Initialization not proved*'
            $r = Read-UpgradeJson (Join-Path $script:out 'resize-cycle.json')
            $r.status | Should -Be 'failed'
            $r.cleanup | Should -Be 'pass'
            $r.steps.Count | Should -Be 1
            $script:deleted | Should -BeTrue
            Should -Invoke Invoke-VmUpgrade -Times 0 -Exactly
            $observation = if ($script:explicitWrapper) {
                (Read-UpgradeJson (Join-Path $script:out 'resize-initialization-journal.json')).observations.initialization
            } else { Read-UpgradeJson (Join-Path $script:out 'resize-initialize-result.json') }
            $observation.value[0].message |
                Should -Match 'Exact managed disk identity'
        }
        It 'runs explicit ARM-mode helper through full mocked cycle and exact cleanup' {
            $script:useArmMode = $true
            & $script:armWrapper
            $r = Read-UpgradeJson (Join-Path $script:out 'resize-cycle.json')
            $r.status | Should -Be 'completed'
            $r.identityMode | Should -Be 'arm-azure-udev'
            $r.cleanup | Should -Be 'pass'
            $j = Read-UpgradeJson (Join-Path $script:out 'resize-initialization-journal.json')
            $j.identityMode | Should -Be 'arm-azure-udev'
            $j.identityEvidence.disk.id | Should -Be $script:disk
            $j.status | Should -Be 'initialized'
            $j.observations.initialization.value[0].message | Should -Match '"dataDisks":\[\]'
            $r.steps.name | Should -Contain 'final-normal-terraform-noop'
            $script:deleted | Should -BeTrue
        }
        It 'runs explicit ARM-mode guest refusal through cleanup without preparation or resize' {
            $script:useArmMode = $true
            $script:identityRefused = $true
            { & $script:armWrapper } | Should -Throw '*Initialization not proved*'
            $r = Read-UpgradeJson (Join-Path $script:out 'resize-cycle.json')
            $r.status | Should -Be 'failed'
            $r.identityMode | Should -Be 'arm-azure-udev'
            $r.cleanup | Should -Be 'pass'
            $r.steps.Count | Should -Be 1
            $j = Read-UpgradeJson (Join-Path $script:out 'resize-initialization-journal.json')
            $j.status | Should -Be 'failed'
            $j.observations.initialization.value[0].message | Should -Match 'Exact managed disk identity'
            $j.observations.initialization.value[0].message | Should -Match 'synthetic-wrong-disk'
            $script:deleted | Should -BeTrue
            Should -Invoke Invoke-VmUpgrade -Times 0 -Exactly
        }
        It 'refuses unknown, consent-altered and duplicate initialization shapes before execution' {
            $call = $script:explicitInitializationCall
            foreach ($text in @(
                $call.Replace('-ExclusiveWindowConsent',''),
                $call.Replace('arm-azure-udev','unknown-mode'),
                "$call`n$call"
            )) {
                { Assert-OfflineInitializationShape $text } | Should -Throw '*Unsupported initialization block*'
            }
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
        It 'executes the actual current wrapper inside the supervised synthetic child' -Tag WorkerChild {
            if (-not $script:explicitWrapper -or -not $script:workerScenario -or -not $script:sharedScopePath) { throw 'Explicit reviewed wrapper and synthetic child scope required' }
            $script:identityRefused = $script:workerScenario -eq 'contradiction'
            try { & $script:wrapper }
            finally {
                Copy-Item (Join-Path $script:out 'resize-cycle.json') "$script:sharedScopePath.cycle.json" -ErrorAction Stop
                $journal = Join-Path $script:out 'resize-initialization-journal.json'
                if (Test-Path $journal) { Copy-Item $journal "$script:sharedScopePath.initialization.json" }
                Write-UpgradeJson @{
                    baselineExists=Test-Path (Join-Path $script:out 'resize-baseline.json')
                    preparationExists=Test-Path (Join-Path $script:out 'resize-preparation.json')
                } "$script:sharedScopePath.stages.json"
            }
        }
    }
}
