# Plan-bound Windows Server 2022 (build 20348) guest preparation.
# Invoke-GuestPreparation prepends a validated $AzvmConfig hashtable:
#   Action (apply|rollback|status), PlanHash, Components, Consent, RollbackAck,
#   DriverPackagePath, DriverPackageSha256.
# Never resizes, deallocates, reboots, downloads, formats or changes pagefile/
# disks. The boot-start procedure follows the reviewed approach in
# Azure/SAP-on-Azure-Scripts-and-Utilities windows-manual-nvme-prepare.ps1 (MIT):
# stornvme/vpci Start=0 and StartOverride removal in every ControlSet, with the
# pre-state recorded here for reversal.
$ErrorActionPreference = 'Stop'
if (-not $AzvmConfig) { throw 'Invoke-GuestPreparation must supply the validated configuration.' }
$action = $AzvmConfig.Action
if ($action -notin 'apply', 'rollback', 'status') { throw 'Invalid action.' }
if ($AzvmConfig.PlanHash -notmatch '^[0-9a-f]{64}$') { throw 'Plan hash is required.' }
$components = @($AzvmConfig.Components -split ',')
if ($components | Where-Object { $_ -notin 'nvme-boot', 'mana-windows-driver' }) { throw 'Invalid component.' }
if ($action -ne 'status' -and $AzvmConfig.Consent -ne 'approved-guest-preparation') { throw 'Explicit guest-change consent is required.' }
if ($action -eq 'rollback' -and $AzvmConfig.RollbackAck -ne 'restored-controller-confirmed') { throw 'Rollback requires confirmation of a compatible controller.' }
if ([Environment]::OSVersion.Version.Build -ne 20348) { throw 'Only the Windows Server 2022 preparation profile is implemented.' }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) { throw 'Run as Administrator.' }

$folder = 'C:\ProgramData\az-vm-upgrade\preparation'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$stateFile = Join-Path $folder 'preparation-state.json'
$state = if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable } else { @{ services = $null; drivers = @() } }
$changes = [System.Collections.Generic.List[object]]::new()
function Add-Change($component, $item, $result, $detail) {
    $changes.Add(@{ component = $component; item = $item; state = $result; detail = ([string]$detail).Substring(0, [Math]::Min(300, ([string]$detail).Length)) })
}
function Save-State { $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile }
$controlSets = @(Get-ChildItem 'HKLM:\SYSTEM' | Where-Object { $_.PSChildName -match '^ControlSet\d+$' } | ForEach-Object { $_.PSChildName })
$services = 'stornvme', 'vpci'

function Get-ServiceBoot {
    $result = @{}
    foreach ($cs in $controlSets) {
        foreach ($svc in $services) {
            $path = "HKLM:\SYSTEM\$cs\Services\$svc"
            if (-not (Test-Path $path)) { continue }
            $override = "$path\StartOverride"
            $values = @{}
            if (Test-Path $override) { (Get-Item $override).GetValueNames() | ForEach-Object { $values[$_] = (Get-ItemProperty $override).$_ } }
            $result["$cs/$svc"] = @{ start = (Get-ItemProperty $path).Start; override = $values; hasOverride = (Test-Path $override) }
        }
    }
    $result
}

function Apply-NvmeBoot {
    if ($controlSets.Count -eq 0) { Add-Change 'nvme-boot' 'controlsets' 'failed' 'No ControlSets found'; return }
    if (-not $state.services) { $state.services = Get-ServiceBoot; $state.recordedAt = [DateTimeOffset]::UtcNow.ToString('o'); Save-State }
    foreach ($svc in $services) { & sc.exe config $svc start= boot | Out-Null; if ($LASTEXITCODE -ne 0) { Add-Change 'nvme-boot' $svc 'failed' "sc.exe exit $LASTEXITCODE"; return } }
    foreach ($key in (Get-ServiceBoot).Keys) {
        $cs, $svc = $key -split '/'
        $path = "HKLM:\SYSTEM\$cs\Services\$svc"
        Set-ItemProperty -Path $path -Name Start -Value 0 -Type DWord
        if (Test-Path "$path\StartOverride") { Remove-Item -Path "$path\StartOverride" -Recurse -Force }
    }
    $bad = @((Get-ServiceBoot).GetEnumerator() | Where-Object { $_.Value.start -ne 0 -or $_.Value.hasOverride })
    if ($bad.Count) { Add-Change 'nvme-boot' 'registry' 'unverified' "Remaining non-boot entries: $($bad.Name -join ',')" }
    else { Add-Change 'nvme-boot' 'registry' 'verified' "Start=0 and no StartOverride in $($controlSets -join ',') for stornvme/vpci; deallocate promptly because a SCSI boot can recreate StartOverride" }
}

function Undo-NvmeBoot {
    if (-not $state.services) { Add-Change 'nvme-boot' 'rollback' 'skipped' 'No recorded pre-state'; return }
    foreach ($entry in $state.services.GetEnumerator()) {
        $cs, $svc = $entry.Key -split '/'
        $path = "HKLM:\SYSTEM\$cs\Services\$svc"
        if (-not (Test-Path $path)) { continue }
        Set-ItemProperty -Path $path -Name Start -Value $entry.Value.start -Type DWord
        if ($entry.Value.hasOverride -and -not (Test-Path "$path\StartOverride")) {
            New-Item -Path "$path\StartOverride" -Force | Out-Null
            foreach ($v in $entry.Value.override.GetEnumerator()) { New-ItemProperty -Path "$path\StartOverride" -Name $v.Key -Value $v.Value -PropertyType DWord -Force | Out-Null }
        }
    }
    $state.services = $null; Save-State
    Add-Change 'nvme-boot' 'rollback' 'restored' 'Recorded Start and StartOverride values restored for all ControlSets'
}

function Install-ManaDriver {
    $zip = $AzvmConfig.DriverPackagePath
    $expected = $AzvmConfig.DriverPackageSha256
    if (-not $zip -or -not $expected) { Add-Change 'mana-windows-driver' 'artifact' 'manual-required' 'No operator-supplied signed artifact and SHA256 were bound to this preparation'; return }
    if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or $zip -notmatch '^[A-Za-z]:\\[\w .\\-]+\.zip$') { Add-Change 'mana-windows-driver' 'artifact' 'failed' 'Invalid artifact path or hash'; return }
    $item = Get-Item -LiteralPath $zip -ErrorAction SilentlyContinue
    if (-not $item -or $item.Length -gt 300MB) { Add-Change 'mana-windows-driver' 'artifact' 'failed' 'Artifact missing or too large'; return }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected.ToUpperInvariant()) { Add-Change 'mana-windows-driver' 'artifact' 'failed' 'SHA256 mismatch'; return }
    $stage = Join-Path $folder ('mana-' + $expected.Substring(0, 12))
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $stage
    $files = @(Get-ChildItem $stage -Recurse -File | Where-Object { $_.Extension -in '.cat', '.sys', '.dll', '.exe' })
    if (-not $files.Count -or @(Get-ChildItem $stage -Recurse -Filter *.exe).Count) { Add-Change 'mana-windows-driver' 'artifact' 'failed' 'Package must contain signed driver files and no executables'; return }
    foreach ($f in $files) {
        $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft (Windows|Corporation|Windows Hardware Compatibility Publisher)') {
            Add-Change 'mana-windows-driver' $f.Name 'failed' "Signature is $($sig.Status) or signer is not Microsoft"; return
        }
    }
    $infs = @(Get-ChildItem $stage -Recurse -Filter *.inf | Where-Object { (Get-Content $_.FullName -Raw) -match 'VEN_1414&DEV_00BA' })
    if ($infs.Count -ne 1) { Add-Change 'mana-windows-driver' 'inf' 'failed' "Expected exactly one MANA INF, found $($infs.Count)"; return }
    $before = @(Get-WindowsDriver -Online | ForEach-Object { $_.Driver })
    & pnputil.exe /add-driver $infs[0].FullName /install 2>&1 | Out-Null
    if ($LASTEXITCODE -notin 0, 3010) { Add-Change 'mana-windows-driver' 'pnputil' 'failed' "pnputil exit $LASTEXITCODE"; return }
    $added = @(Get-WindowsDriver -Online | Where-Object { $_.Driver -notin $before } | ForEach-Object { $_.Driver })
    $state.drivers = @($state.drivers) + $added; Save-State
    $present = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA&' }).Count -gt 0
    Add-Change 'mana-windows-driver' 'driver' 'installed' "Staged/installed $($added -join ',') (hash and Microsoft Authenticode verified); device present=$present; Mellanox/synthetic drivers untouched; reboot and verify traffic separately"
}

function Undo-ManaDriver {
    if (-not @($state.drivers).Count) { Add-Change 'mana-windows-driver' 'rollback' 'skipped' 'No driver installed by this toolkit'; return }
    foreach ($d in @($state.drivers)) {
        if ($d -notmatch '^oem\d+\.inf$') { Add-Change 'mana-windows-driver' $d 'failed' 'Unexpected recorded driver name'; continue }
        & pnputil.exe /delete-driver $d /uninstall 2>&1 | Out-Null
        Add-Change 'mana-windows-driver' $d $(if ($LASTEXITCODE -in 0, 3010) { 'removed' } else { 'failed' }) "pnputil exit $LASTEXITCODE"
    }
    if (-not @($changes | Where-Object state -EQ 'failed').Count) { $state.drivers = @(); Save-State }
}

try {
    switch ($action) {
        'apply' {
            if ($components -contains 'nvme-boot') { Apply-NvmeBoot }
            if ($components -contains 'mana-windows-driver') { Install-ManaDriver }
        }
        'rollback' {
            if ($components -contains 'mana-windows-driver') { Undo-ManaDriver }
            if ($components -contains 'nvme-boot') { Undo-NvmeBoot }
        }
        'status' {
            if ($components -contains 'nvme-boot') {
                $bad = @((Get-ServiceBoot).GetEnumerator() | Where-Object { $_.Value.start -ne 0 -or $_.Value.hasOverride })
                Add-Change 'nvme-boot' 'registry' $(if ($bad.Count) { 'absent' } else { 'verified' }) 'Current boot-start state'
            }
            if ($components -contains 'mana-windows-driver') { Add-Change 'mana-windows-driver' 'driver' $(if (@($state.drivers).Count) { 'installed' } else { 'absent' }) 'Toolkit-installed driver state' }
        }
    }
} catch { Add-Change 'preparation' 'exception' 'failed' $_.Exception.Message }

$failed = @($changes | Where-Object { $_.state -in 'failed', 'unverified' })
$manifest = @{
    schemaVersion = 'preparation-manifest/1.0'; action = $action; planHash = $AzvmConfig.PlanHash
    status = $(if ($failed.Count) { 'failed' } else { 'ok' }); bootId = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    rebootRequired = $action -ne 'status'; observedAt = [DateTimeOffset]::UtcNow.ToString('o'); changes = @($changes)
}
$json = $manifest | ConvertTo-Json -Compress -Depth 8
Write-Output "AZVM_PREP_BEGIN`n$json`nAZVM_PREP_END"
if ($failed.Count) { exit 1 }
