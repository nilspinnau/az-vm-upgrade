param([Parameter(Mandatory)][string]$WrapperPath)
Import-Module (Join-Path $PSScriptRoot '..\..\src\AzVmUpgrade.psd1') -Force
BeforeAll {
    & (Get-Module AzVmUpgrade) { param($Path) $script:wrapperText = Get-Content $Path -Raw } $WrapperPath
}
InModuleScope AzVmUpgrade {
    Describe 'Private same-interface wrapper as one program, offline' {
        BeforeAll {
            $script:wrapper = [scriptblock]::Create($script:wrapperText)
            function terraform {}
            $script:wrapperSub = [regex]::Match($script:wrapperText, "(?m)^\`$sub='([^']+)'").Groups[1].Value
            $script:wrapperGroup = [regex]::Match($script:wrapperText, "(?m)^\`$rg='([^']+)'").Groups[1].Value
            if (-not $script:wrapperSub -or -not $script:wrapperGroup) { throw 'Unsupported wrapper scope declaration' }
            $script:oldConfig = $env:AZURE_CONFIG_DIR
        }
        BeforeEach {
            $script:identityRefused = $false
            $script:exists = $false
            $script:deleted = $false
            $script:guestCalls = 0
            $script:sub = $script:wrapperSub
            $script:group = $script:wrapperGroup
            $script:vm = "/subscriptions/$script:sub/resourceGroups/$script:group/providers/Microsoft.Compute/virtualMachines/testvm"
            $script:disk = "/subscriptions/$script:sub/resourceGroups/$script:group/providers/Microsoft.Compute/disks/testvm-sentinel"
            $script:os = "/subscriptions/$script:sub/resourceGroups/$script:group/providers/Microsoft.Compute/disks/os"
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach ($dir in @('out\lab-discovery\resize06','infra\test-vm','tests\integration','guest','src')) {
                [IO.Directory]::CreateDirectory((Join-Path $root $dir)) | Out-Null
            }
            $script:out = Join-Path $root 'out\lab-discovery\resize06'
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
                    @{productName='Standard SSD Managed Disks';skuName='Disk Transactions LRS';meterName='Disk Transactions LRS Disk Operations';unitPrice=.0026}) }
            }
            Mock terraform {
                $global:LASTEXITCODE = 0
                $argsText = $args -join ' '
                if ($argsText -match 'apply') { $script:exists = $true; return }
                if ($argsText -match 'output') {
                    return (@{vm_id=@{value=$script:vm};data_disk_id=@{value=$script:disk}} | ConvertTo-Json -Depth 6)
                }
                if ($argsText -match 'show') { return '{"resource_changes":[]}' }
            }
            Mock Get-VmEvidence { $script:syntheticEvidence }
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
                    return @{location='swedencentral';tags=@{'az-vm-upgrade-disposable'='true'};properties=@{
                        securityProfile=@{encryptionAtHost=$true};storageProfile=@{diskControllerType='SCSI'
                        osDisk=@{managedDisk=@{id=$script:os}}
                        dataDisks=@(@{lun=0;managedDisk=@{id=$script:disk}})}}}
                }
                if ($Id -eq $script:disk) {
                    return @{managedBy=$script:vm;tags=@{'az-vm-upgrade-disposable'='true'}
                        properties=@{diskSizeGB=8;creationData=@{createOption='Empty'}}}
                }
                @{properties=@{diskSizeGB=64}}
            }
            Mock Invoke-UpgradeAz {
                param($Arguments)
                switch ($Arguments[0]+':'+$Arguments[1]) {
                    'account:show' { return @{ id=$script:sub } }
                    'group:exists' { return $script:exists }
                    'group:show' { return @{location='swedencentral';tags=@{'az-vm-upgrade-disposable'='true'}} }
                    'group:delete' { $script:exists=$false;$script:deleted=$true;return }
                    'resource:list' { return @() }
                    'snapshot:create' { return @{id=($script:vm -replace '/virtualMachines/.*$', '/snapshots/synthetic')} }
                    'vm:run-command' {
                        $script:guestCalls++
                        $message = if ($script:guestCalls -eq 1) {
                            "ID_BUS=scsi`nID_SERIAL_SHORT=60022480aabb`nAZURE_DISK_LUN=0`nAZURE_DISK_TYPE=data`n"
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
            (Read-UpgradeJson (Join-Path $script:out 'resize-initialize-result.json')).value[0].message |
                Should -Match 'Exact managed disk identity'
        }
    }
}
