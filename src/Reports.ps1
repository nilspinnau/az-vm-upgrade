function ConvertTo-MarkdownCell {
    param($Value)
    ([string]$Value).Replace('|','\|').Replace("`r",' ').Replace("`n",' ').Replace('<','&lt;').Replace('>','&gt;')
}

function Get-SettingDisplay {
    param($Value)
    if ($null -eq $Value -or $Value -ceq '') { return 'unknown (not exposed)' }
    if ($Value -is [bool]) { return $(if ($Value) { 'enabled' } else { 'disabled' }) }
    ConvertTo-MarkdownCell $Value
}

function Export-VmUpgradeReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$OutputDirectory)
    Test-UpgradeDocument $Plan plan | Out-Null
    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)) | Out-Null
    $planPath = Join-Path $OutputDirectory 'plan.json'
    Write-UpgradeJson $Plan $planPath
    Write-UpgradeJson $Plan.evidence (Join-Path $OutputDirectory 'evidence.json')
    $Plan.evidence.vm | Select-Object id,location,@{n='size';e={$_.hardwareProfile.vmSize}},
        @{n='controller';e={$_.storageProfile.diskControllerType}},
        @{n='os';e={$_.storageProfile.osDisk.osType}} |
        Export-Csv (Join-Path $OutputDirectory 'inventory.csv') -NoTypeInformation
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# VM upgrade guide")
    $lines.Add('')
    $lines.Add("VM: ``$($Plan.vmId)``")
    $lines.Add("Classification: **$($Plan.classification)**. Execution boundary: **$($Plan.executionBoundary)**.")
    $lines.Add("Current: $($Plan.sourceSize)/$($Plan.sourceController). Selected target: $($Plan.targetSize)/$($Plan.targetController).")
    $lines.Add("Evidence collected: $($Plan.evidence.observedAt). Plan expires: $($Plan.expiresAt).")
    $lines.Add('')
    $catalog = Read-UpgradeJson (Join-Path $script:RepositoryRoot 'catalog\lifecycle.json')
    $affected = @(Get-LifecycleFinding $Plan.sourceSize $catalog)
    $lines.Add('## Lifecycle')
    if (-not $affected.Count) { $lines.Add('No match in the curated catalog. This is not proof that the VM is unaffected; consult current lifecycle sources.') }
    foreach ($item in $affected) {
        $lines.Add("$($item.series): retirement $($item.retirementDate); growth restrictions $($item.growthRestrictedFrom). [Source]($($item.source)); reviewed $($item.reviewedAt); stale: $($item.catalogStale).")
    }
    $lines.Add('')
    $lines.Add('## Configuration, capability and actual use')
    $lines.Add('| Setting | Control plane | Guest capability | Actual guest use |')
    $lines.Add('|---|---|---|---|')
    $guest = $Plan.evidence.guest
    if (-not $guest) {
        $guest = @{
            nvmeDriver = 'unknown'; nvmeBoot = 'unknown'; actualController = 'unknown'
            manaDriver = 'unknown'; mellanoxDriver = 'unknown'; accelerationInUse = 'unknown'; manaInUse = 'unknown'
            persistentMounts = 'unknown'; layoutSupported = 'unknown'; storageIdentityHash = 'unknown'
        }
    }
    $lines.Add("| Controller | $($Plan.sourceController) | NVMe driver: $($guest.nvmeDriver); boot: $($guest.nvmeBoot) | $($guest.actualController) |")
    $an = @($Plan.evidence.nics | ForEach-Object { "$($_.id): $(Get-SettingDisplay $_.acceleratedNetworking)" }) -join '; '
    $lines.Add("| Networking | $(ConvertTo-MarkdownCell $an) | MANA: $($guest.manaDriver); Mellanox: $($guest.mellanoxDriver) | acceleration: $($guest.accelerationInUse); MANA: $($guest.manaInUse) |")
    $lines.Add("| Persistent storage | Managed disk count: $(@($Plan.evidence.disks).Count) | stable mounts: $($guest.persistentMounts); layout: $($guest.layoutSupported) | identity hash: $($guest.storageIdentityHash) |")
    $lines.Add("| OS / image | $(Get-SettingDisplay $Plan.evidence.vm.storageProfile.osDisk.osType); image fields in evidence.json | $(Get-SettingDisplay $guest.osProfile) | agent: $(Get-SettingDisplay $guest.agentReady); pending reboot: $(Get-SettingDisplay $guest.pendingReboot) |")
    $lines.Add("| Security | type: $(Get-SettingDisplay $Plan.evidence.vm.securityProfile.securityType); at-host encryption: $(Get-SettingDisplay $Plan.evidence.vm.securityProfile.encryptionAtHost) | Workload/boot-filter review required | No implicit security change |")
    $lines.Add('')
    $lines.Add('## Attached managed disks')
    $lines.Add('| ID | Tier | Boot generation | ADE | Encryption type |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($disk in $Plan.evidence.disks) {
        $lines.Add("| $(ConvertTo-MarkdownCell $disk.id) | $(Get-SettingDisplay $disk.sku.name) | $(Get-SettingDisplay $disk.hyperVGeneration) | $(Get-SettingDisplay $disk.adeEnabled) | $(Get-SettingDisplay $disk.encryption.type) |")
    }
    $lines.Add('')
    $lines.Add('## Checks and gaps')
    $lines.Add('| Check | Outcome | Evidence/remediation | Source |')
    $lines.Add('|---|---|---|---|')
    foreach ($check in $Plan.checks) {
        $lines.Add("| $(ConvertTo-MarkdownCell $check.name) | $($check.status) | $(ConvertTo-MarkdownCell $check.detail) | $(ConvertTo-MarkdownCell $check.source) |")
    }
    $lines.Add('')
    $lines.Add('## Target candidates and quota')
    $lines.Add('| Target | Compatible metadata | Family | vCPUs | Memory GB | Quota | Capacity |')
    $lines.Add('|---|---|---|---|---|---|---|')
    foreach ($candidate in $Plan.candidates | Select-Object -First 20) {
        $lines.Add("| $($candidate.name) | $($candidate.compatible) | $($candidate.family) | $($candidate.vCPUs) | $($candidate.memoryGB) | $($candidate.quota.status) | unknown |")
    }
    $lines.Add('Full candidate checks are in plan.json. Ranking uses minimum vCPU/memory, not workload benchmarks, price or certification.')
    $lines.Add("Quota: $($Plan.quota.status). $($Plan.quota.detail)")
    foreach ($quota in $Plan.quota.checks) {
        $lines.Add("- $($quota.name): $($quota.status); current $($quota.current), delta $($quota.delta), projected $($quota.projected), limit $($quota.limit).")
    }
    $lines.Add('Allocation risk remains: no capacity reservation is created and no other zone/region is selected.')
    $lines.Add('')
    $lines.Add('## Action plan')
    $lines.Add('Resolve every non-pass check; obtain workload-owner review and independently test application health. Reassess after guest preparation or configuration changes.')
    $lines.Add('Obtain approved application-consistent backup or explicitly accepted recovery evidence. Accept single-VM downtime and temporary-data loss; pause other configuration writers.')
    $lines.Add('Review target size/controller and exact Terraform mapping/plan. This version changes only size/controller and, for eligible NVMe transitions, OS disk controller capability; NIC, security, image, placement and storage tiers are retained.')
    $lines.Add("Expected disruption: $($Plan.disruption)")
    foreach ($suggestion in $Plan.terraform.suggestions) { $lines.Add("- $(ConvertTo-MarkdownCell $suggestion)") }
    $lines.Add('Do not use permanent ignore_changes or overlapping AzAPI/AzureRM ownership. Complete supported Terraform refresh/reconciliation and require a normal no-op plan.')
    $lines.Add('After execution verify provisioning, guest controller, persistent disk identities, managed data checksum, networking VF traffic, health sentinel and owner acceptance. Restart and deallocate/start resilience still require explicitly approved live acceptance tests.')
    $lines.Add('Keep the journal and recovery guide. Rollback allocation is not guaranteed; destructive restore is never automatic.')
    foreach ($name in @('upgrade.ps1','upgrade.sh')) {
        $path = Join-Path $OutputDirectory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    if ($Plan.classification -eq 'ready' -and $Plan.targetSize -and $Plan.executionBoundary -eq 'disposable-lab-only') {
        # Data values remain inside JSON files, never interpolated into executable source.
        $psTemplate = @'
param([Parameter(Mandatory)][string]$ToolkitRoot, [Parameter(Mandatory)][string]$ApprovalPath, [switch]$Resume, [string]$OwnerAcceptancePath, [string]$TerraformReconciliationPath)
& (Join-Path $ToolkitRoot 'scripts\Invoke-VmUpgrade.ps1') -PlanPath (Join-Path $PSScriptRoot 'plan.json') -ApprovalPath $ApprovalPath -Resume:$Resume -OwnerAcceptancePath $OwnerAcceptancePath -TerraformReconciliationPath $TerraformReconciliationPath
'@
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'upgrade.ps1'),$psTemplate,[Text.UTF8Encoding]::new($false))
        $shTemplate = @'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -lt 2 ]; then echo "Usage: upgrade.sh TOOLKIT_ROOT APPROVAL_JSON [PowerShell resume/acceptance options]" >&2; exit 2; fi
here="$(cd -- "$(dirname -- "$0")" && pwd)"
root="$1"; approval="$2"; shift 2
pwsh -NoProfile -File "$root/scripts/Invoke-VmUpgrade.ps1" -PlanPath "$here/plan.json" -ApprovalPath "$approval" "$@"
'@
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'upgrade.sh'),$shTemplate,[Text.UTF8Encoding]::new($false))
        $lines.Add('Lab-only launchers were generated. They read the exact VM/target/hash from plan.json and still require an exact approval file and live rechecks.')
    } else { $lines.Add('**No executable upgrade launcher generated.** Use the remediation guidance and reassess.') }
    $reportPath = Join-Path $OutputDirectory 'guide.md'
    [IO.File]::WriteAllLines($reportPath,$lines,[Text.UTF8Encoding]::new($false))
    return @{ plan = $planPath; report = $reportPath; classification = $Plan.classification }
}
