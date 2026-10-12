Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
InModuleScope AzVmUpgrade {
    BeforeAll { . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1') }
    Describe 'Native size-only resize planning and runtime verification' {
        It 'distinguishes cluster options without promising capacity: <Case>' -ForEach @(
            @{Case='listed';Expected='listed-on-current-cluster'},
            @{Case='absent';Expected='requires-deallocation'},
            @{Case='deallocated-listed';Expected='listed-while-deallocated'},
            @{Case='deallocated-absent';Expected='not-listed-while-deallocated'},
            @{Case='missing';Expected='unknown'},@{Case='stale';Expected='unknown'},
            @{Case='denied';Expected='unknown'},@{Case='stopped';Expected='unknown'},
            @{Case='contradictory-power';Expected='unknown'},@{Case='missing-power';Expected='unknown'}
        ) {
            $e=New-FixtureEvidence
            switch($Case) {
                absent {$e.resizeOptions.sizes=@('Standard_D2s_v5')}
                deallocated-listed {$e.instanceView.statuses[1].code='PowerState/deallocated'}
                deallocated-absent {$e.instanceView.statuses[1].code='PowerState/deallocated';$e.resizeOptions.sizes=@()}
                missing {$e.Remove('resizeOptions')}
                stale {$e.resizeOptions.observedAt='2000-01-01T00:00:00Z'}
                denied {$e.resizeOptions.status='denied'}
                stopped {$e.instanceView.statuses[1].code='PowerState/stopped'}
                contradictory-power {$e.instanceView.statuses+=@{code='PowerState/deallocated'}}
                missing-power {$e.instanceView.statuses=@(@{code='ProvisioningState/succeeded'})}
            }
            $r=Get-ResizePlacementAssessment $e Standard_D2s_v6
            $r.status | Should -Be $Expected
            $r.execution | Should -Be 'deallocate-size-update-start'
            if($Case -eq 'absent') {$r.detail | Should -Match 'releases the current allocation'}
        }
        It 'needs no NVMe boot staging or utility package for a native SCSI target' {
            $e=New-FixtureEvidence
            $e.guest.nvmeDriver='failed';$e.guest.nvmeBoot='failed';$e.guest.azureVmUtils='failed'
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'ready'
            $p.checks.name | Should -Not -Contain 'nvme-boot'
            @($p.advisories | Where-Object {$_ -match 'NVMe boot-driver staging'}).Count | Should -Be 0
            $out=Join-Path $TestDrive 'report'
            Export-VmUpgradeReport $p $out | Out-Null
            Get-Content (Join-Path $out 'guide.md') -Raw | Should -Match 'size-only VM update'
        }
        It 'does not treat regional SKU advertising as fresh cluster evidence' {
            $e=New-FixtureEvidence;$e.Remove('resizeOptions')
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)).classification | Should -Be 'incomplete-evidence'
        }
        It 'keeps controller conversion distinct from native resize-list availability' {
            $p=New-FixturePlan
            $p.resize.status | Should -Be 'controller-conversion-required'
            $p.resize.execution | Should -Be 'deallocate-size-controller-update-start'
            $p.resize.detail | Should -Match 'not conversion authorization'
        }
        It 'does not make an absent Windows NVMe service fatal to the SCSI probe' {
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot 'guest\windows-probe.ps1'),[ref]$tokens,[ref]$errors)
            $assignment=$ast.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$stornvme'},$true)
            $assignment | Should -Not -BeNullOrEmpty
            Mock Test-Path { $false }
            Mock Get-ItemProperty { throw 'Unexpected NVMe registry requirement' }
            . ([scriptblock]::Create($assignment.Extent.Text))
            $stornvme | Should -BeNullOrEmpty
            Should -Invoke Get-ItemProperty -Times 0 -Exactly
        }
        It 'suggests only the Terraform size change and retaining the existing controller' {
            $p=New-VmUpgradePlan (New-FixtureEvidence) -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview) -TerraformMapping @{vmAddress='azurerm_linux_virtual_machine.test'}
            $p.terraform.suggestions[0] | Should -Match '\.size = Standard_D2s_v6'
            $p.terraform.suggestions[1] | Should -Match '^Retain existing'
        }
        It 'executes the actual Linux runtime-size probe offline and retains its response: <Case>' -ForEach @(
            @{Case='valid';Raw=' Standard_D2s_v6 ';Expected='collected'},
            @{Case='empty';Raw='';Expected='failed'},
            @{Case='malformed';Raw='{"vmSize":"Standard_D2s_v6"}';Expected='failed'},
            @{Case='overlong';Raw=('x' * 300);Expected='failed'}
        ) {
            $source=Get-Content (Join-Path $script:RepositoryRoot 'guest\linux-probe.sh') -Raw
            $code=[regex]::Match($source,'(?ms)^runtime = .*?(?=^probe = )').Value
            $code | Should -Not -BeNullOrEmpty
            $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($code))
            $rawEncoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Raw))
            $harness=@'
import base64,json,os,re,sys,urllib.error,urllib.request
raw=base64.b64decode(sys.argv[2])
class Response:
    def __enter__(self): return self
    def __exit__(self,*args): pass
    def read(self,n): return raw[:n]
class Opener:
    def open(self,request,timeout):
        assert timeout == 5
        assert request.full_url == "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text"
        assert request.get_header("Metadata") == "true"
        return Response()
def opener(*handlers):
    assert len(handlers) == 1 and handlers[0].proxies == {}
    return Opener()
urllib.request.build_opener=opener
os.cpu_count=lambda:2
exec(base64.b64decode(sys.argv[1]).decode())
print(json.dumps(runtime))
'@
            $observed=(& python -c $harness $encoded " $rawEncoded").Trim() | ConvertFrom-Json -AsHashtable
            $LASTEXITCODE | Should -Be 0
            $observed.status | Should -Be $Expected
            $observed.rawResponse | Should -Be $Raw.Substring(0,[Math]::Min(256,$Raw.Length))
            if ($Expected -eq 'failed') {$observed.error | Should -Match 'missing or malformed'}
        }
        It 'blocks a desired-model versus guest-size discrepancy before a new maintenance window' {
            $e=New-FixtureEvidence;$e.guest.runtimeSizeEvidence.vmSize='Standard_D1_v2'
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'blocked'
            ($p.checks | Where-Object name -EQ 'guest-runtime-size').detail | Should -Match 'failed resize'
        }
        It 'refuses runtime disagreement or missing evidence despite a healthy desired model: <Case>' -ForEach @(
            @{Case='old-size'},@{Case='old-cpus'},@{Case='missing'},@{Case='failed'},@{Case='string-cpus'}
        ) {
            $p=New-FixturePlan;$live=New-FixtureEvidence
            $live.vm.hardwareProfile.vmSize=$p.targetSize
            $live.vm.storageProfile.diskControllerType='NVMe';$live.guest.actualController='NVMe'
            $live.guest.runtimeSizeEvidence.vmSize=$p.targetSize
            switch($Case) {
                old-size {$live.guest.runtimeSizeEvidence.vmSize=$p.sourceSize}
                old-cpus {$live.guest.runtimeSizeEvidence.logicalProcessors=1}
                missing {$live.guest.Remove('runtimeSizeEvidence')}
                failed {$live.guest.runtimeSizeEvidence.status='failed'}
                string-cpus {$live.guest.runtimeSizeEvidence.logicalProcessors='2'}
            }
            {Test-PostUpgradeGuest $p $live} | Should -Throw '*runtime size/CPU*'
        }
        It 'checks active constrained cores rather than the billed quota count' {
            $p=New-FixturePlan;$live=New-FixtureEvidence
            $live.vm.hardwareProfile.vmSize=$p.targetSize
            $live.vm.storageProfile.diskControllerType='NVMe';$live.guest.actualController='NVMe'
            $live.guest.runtimeSizeEvidence.vmSize=$p.targetSize
            ($live.skus[1].capabilities | Where-Object name -EQ 'vCPUs').value='4'
            {Test-PostUpgradeGuest $p $live} | Should -Not -Throw
        }
    }
}
