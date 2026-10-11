Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
InModuleScope AzVmUpgrade {
    Describe 'Explicit lab initialization identity harness, offline' {
        BeforeAll {
            $source = Get-Content (Join-Path $script:RepositoryRoot 'tests\integration\Invoke-LabDiskInitialization.ps1') -Raw
            $body = $source.Substring($source.IndexOf('    param($VmId,'))
            $body = $body.Substring(0, $body.LastIndexOf('} $VmId $DiskId'))
            $script:initBody = [scriptblock]::Create($body)
        }
        BeforeEach {
            $script:sub = '00000000-0000-0000-0000-000000000000'
            $script:group = 'azvm-upgrade-lab-offline'
            $prefix = "/subscriptions/$script:sub/resourceGroups/$script:group/providers/Microsoft.Compute"
            $script:vmId = "$prefix/virtualMachines/testvm"
            $script:diskId = "$prefix/disks/sentinel"
            $script:vm = @{id=$script:vmId;tags=@{'az-vm-upgrade-disposable'='true'};properties=@{storageProfile=@{
                diskControllerType='SCSI';osDisk=@{managedDisk=@{id="$prefix/disks/os"}}
                dataDisks=@(@{lun=0;managedDisk=@{id=$script:diskId}})}}}
            $script:disk = @{id=$script:diskId;managedBy=$script:vmId;tags=@{'az-vm-upgrade-disposable'='true'}
                properties=@{uniqueId='synthetic-incarnation';creationData=@{createOption='Empty'}}}
            $script:output = Join-Path $TestDrive 'identity.json'
            $script:calls = 0
            $script:reads = 0
            $script:failure = ''
            $script:sentScript = ''
            Mock Invoke-ArmRead {
                param($Id)
                $script:reads++
                if ($Id -eq $script:vmId) {
                    if ($script:failure -eq 'drift' -and $script:reads -gt 2) {
                        return @{id=$script:vmId;tags=$script:vm.tags;properties=@{storageProfile=@{
                            diskControllerType='SCSI';osDisk=$script:vm.properties.storageProfile.osDisk
                            dataDisks=@(@{lun=1;managedDisk=@{id=$script:diskId}})}}}
                    }
                    return $script:vm
                }
                if ($script:failure -eq 'incarnation' -and $script:reads -gt 2) {
                    return @{id=$script:disk.id;managedBy=$script:disk.managedBy;tags=$script:disk.tags
                        properties=@{uniqueId='different-incarnation';creationData=@{createOption='Empty'}}}
                }
                $script:disk
            }
            Mock Invoke-UpgradeAz {
                param($Arguments)
                switch ($Arguments[0]+':'+$Arguments[1]) {
                    'account:show' { @{id=$script:sub} }
                    'group:show' { @{name=$script:group;tags=@{'az-vm-upgrade-disposable'='true'}} }
                    'vm:run-command' {
                        $script:calls++
                        if ($script:calls -eq 1) {
                            $text = if ($script:failure -eq 'serial') { 'ID_BUS=scsi' } else {
                                "ID_BUS=scsi`nID_SERIAL_SHORT=60022480aabb`nAZURE_DISK_LUN=0`nAZURE_DISK_TYPE=data`n"
                            }
                        } else {
                            $script:sentScript = Get-Content $Arguments[-1].Substring(1) -Raw
                            $text = if ($script:failure -eq 'guest') {
                                'AZVM_DISK_IDENTITY_OBSERVATION={"identityMode":"arm-azure-udev","storageProfile":{"dataDisks":[]}} RuntimeError: contradictory OS identity'
                            } else { 'Only the explicitly identified new test data disk was initialized' }
                        }
                        @{value=@(@{code='ComponentStatus/StdOut/succeeded';message=$text})}
                    }
                    default { throw 'Unmocked cloud operation blocked' }
                }
            }
        }
        It 'binds explicit ARM mode and durable fresh evidence before the mocked guest invocation' {
            & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $true $true
            $r = Read-UpgradeJson $script:output
            $r.status | Should -Be 'initialized'
            $r.identityMode | Should -Be 'arm-azure-udev'
            $r.identityEvidence.disk.id | Should -Be $script:diskId
            $r.observations.freshVm.id | Should -Be $script:vmId
            $script:sentScript | Should -Match "AZVM_IDENTITY_MODE='arm-azure-udev'"
            $script:sentScript | Should -Match 'AZVM_ARM_IDENTITY_BASE64'
            $script:calls | Should -Be 2
            $python = @'
import ast, contextlib, datetime, io, json, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text().split("python3 - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
function = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == "verify_scsi_identity")
scope = {"json": json, "datetime": datetime}
exec(compile(ast.Module(body=[function], type_ignores=[]), "<generated-arm-proof>", "exec"), scope)
result = json.loads(pathlib.Path(sys.argv[2]).read_text())
proof = result["identityEvidence"]
proof["vm"]["irrelevantLargeBlob"] = "x" * 10000
metadata = {"dataDisks": [], "osDisk": proof["vm"]["properties"]["storageProfile"]["osDisk"]}
serial = proof["expectedScsiSerial"]
properties = {"ID_BUS": "scsi", "AZURE_DISK_TYPE": "data", "AZURE_DISK_LUN": "0", "ID_SERIAL_SHORT": serial}
output = io.StringIO()
with contextlib.redirect_stdout(output):
    scope["verify_scsi_identity"](metadata, properties, "1:0:0:0", result["diskId"], serial, result["identityMode"], proof)
assert len(output.getvalue().encode()) < 4096
assert "irrelevantLargeBlob" not in output.getvalue()
print("Actual generated proof accepted by guest validator; compact marker below 4096 bytes")
'@
            $validation = $python | python - (Join-Path $script:RepositoryRoot 'guest\lab-sentinel-linux.sh') $script:output
            $LASTEXITCODE | Should -Be 0
            $validation | Should -Match 'Actual generated proof accepted'
        }
        It 'preserves explicit mandatory IMDS mode' {
            & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'imds-required' $true $false $true
            (Read-UpgradeJson $script:output).identityMode | Should -Be 'imds-required'
            $script:sentScript | Should -Match "AZVM_IDENTITY_MODE='imds-required'"
        }
        It 'requires identity-method approval before any cloud call' {
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $false $true } | Should -Throw '*consent required*'
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
        It 'requires exclusive-window consent before any cloud call' {
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $true $false } | Should -Throw '*consent required*'
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
        It 'refuses stale consent before cloud access' {
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddMinutes(-1)) $script:output 'arm-azure-udev' $true $true $true } | Should -Throw '*bounded lab consent*'
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
        It 'retains ownership refusal before any guest operation' {
            $script:disk.managedBy += '-other'
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $true $true } | Should -Throw '*Exact owned*'
            (Read-UpgradeJson $script:output).observations.disk.managedBy | Should -Match '-other$'
            $script:calls | Should -Be 0
        }
        It 'retains refreshed attachment drift and refuses formatting' {
            $script:failure = 'drift'
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $true $true } | Should -Throw '*Exact owned*'
            (Read-UpgradeJson $script:output).observations.freshVm.properties.storageProfile.dataDisks[0].lun | Should -Be 1
            $script:calls | Should -Be 1
        }
        It 'retains failed serial probe before refusal' {
            $script:failure = 'serial'
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $true $true } | Should -Throw '*mapping not captured*'
            (Read-UpgradeJson $script:output).observations.serialProbe.value[0].message | Should -Be 'ID_BUS=scsi'
            $script:calls | Should -Be 1
        }
        It 'refuses resource recreation even when ARM disk ID is unchanged' {
            $script:failure = 'incarnation'
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $true $true } | Should -Throw '*incarnation changed*'
            (Read-UpgradeJson $script:output).observations.freshDisk.properties.uniqueId | Should -Be 'different-incarnation'
            $script:calls | Should -Be 1
        }
        It 'retains actual guest refusal and does not report initialization success' {
            $script:failure = 'guest'
            { & $script:initBody $script:vmId $script:diskId $script:group ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output 'arm-azure-udev' $true $true $true } | Should -Throw '*Initialization not proved*'
            $r = Read-UpgradeJson $script:output
            $r.status | Should -Be 'failed'
            $r.observations.initialization.value[0].message | Should -Match 'contradictory OS identity'
            $script:calls | Should -Be 2
        }
    }
}
