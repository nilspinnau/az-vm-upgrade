$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
$disks = @(Get-Disk)
$volumes = @(Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' })
$identities = @($volumes | Sort-Object UniqueId | ForEach-Object {
    $paths = @($_ | Get-Partition | ForEach-Object AccessPaths | Sort-Object)
    "$($_.UniqueId)|$($paths -join ',')"
})
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $storageHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($identities -join "`n"))))).Replace('-','').ToLowerInvariant()
} finally { $sha.Dispose() }
$stornvme = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme'
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations)
$adapters = @(Get-NetAdapter)
$drivers = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass = 'NET'")
$manaDriver = @($drivers | Where-Object { $_.DeviceName -match 'Microsoft Azure Network Adapter' }).Count -gt 0
$mellanoxDriver = @($drivers | Where-Object { $_.DeviceName -match 'Mellanox|ConnectX' }).Count -gt 0
if ((-not $manaDriver -or -not $mellanoxDriver) -and (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue)) {
    $packages = @(Get-WindowsDriver -Online -All)
    $manaDriver = $manaDriver -or @($packages | Where-Object {
        $_.OriginalFileName -match '[\\](mana|manadrv)[^\\]*\.inf$' -and $_.ProviderName -match '^Microsoft'
    }).Count -gt 0
    $mellanoxDriver = $mellanoxDriver -or @($packages | Where-Object {
        $_.OriginalFileName -match '[\\]mlx[45][^\\]*\.inf$' -and $_.ProviderName -match 'Mellanox|NVIDIA|Microsoft'
    }).Count -gt 0
}
$overridePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\StartOverride'
$overrideReady = $true
if (Test-Path $overridePath) {
    $overrideReady = (Get-ItemProperty $overridePath).'0' -eq 0
}
$manaPresent = @($adapters | Where-Object InterfaceDescription -Like '*Microsoft Azure Network Adapter*')
$manaTraffic = 'unknown'
$acceleration = 'unknown'
$stats = @{}
foreach ($adapter in $adapters | Where-Object { $_.InterfaceDescription -match 'Azure Network Adapter|Mellanox|ConnectX' }) {
    $stat = $adapter | Get-NetAdapterStatistics
    $stats[$adapter.Name] = $stat.ReceivedBytes + $stat.SentBytes
}
Start-Sleep -Seconds 2
foreach ($adapter in $adapters | Where-Object { $stats.ContainsKey($_.Name) }) {
    $stat = $adapter | Get-NetAdapterStatistics
    if (($stat.ReceivedBytes + $stat.SentBytes) -gt $stats[$adapter.Name]) {
        $acceleration = 'pass'
        if ($adapter.InterfaceDescription -like '*Microsoft Azure Network Adapter*') { $manaTraffic = 'pass' }
    }
}
$pageFiles = @(Get-CimInstance Win32_PageFileUsage)
$tempPageFile = @($pageFiles | Where-Object { $_.Name -notlike 'C:\*' }).Count -gt 0
$systemDisks = @($disks | Where-Object IsBoot -EQ $true)
$actual = 'unknown'
if ($systemDisks.Count -eq 1) {
    if ($systemDisks[0].BusType -eq 'NVMe') { $actual = 'NVMe' }
    elseif ($systemDisks[0].BusType -in @('SCSI','SAS')) { $actual = 'SCSI' }
}
$sentinelPath = 'F:\azvm-sentinel.txt'
$sentinelHash = $null
if (Test-Path -LiteralPath $sentinelPath) {
    if ((Get-Item -LiteralPath $sentinelPath).Length -le 65536) { $sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$health = 'unknown'
if (Test-Path 'C:\ProgramData\az-vm-upgrade\healthy') {
    if ((Get-Content 'C:\ProgramData\az-vm-upgrade\healthy' -Raw).Trim() -eq 'healthy') { $health = 'pass' }
}
$guest = @{
    schemaVersion = 'guest/1.0'; observedAt = [DateTimeOffset]::UtcNow.ToString('o'); complete = $true
    osProfile = "windows:$($os.BuildNumber):$env:PROCESSOR_ARCHITECTURE"
    bootMode = if ($systemDisks.Count -eq 1 -and $systemDisks[0].PartitionStyle -eq 'GPT') { 'UEFI-candidate' } else { 'unknown' }
    agentReady = (Get-Service WindowsAzureGuestAgent).Status -eq 'Running'; pendingReboot = $pending
    nvmeDriver = if (Test-Path "$env:SystemRoot\System32\drivers\stornvme.sys") { 'pass' } else { 'failed' }
    nvmeBoot = if ($stornvme.Start -eq 0 -and $overrideReady) { 'pass' } else { 'failed' }
    manaDriver = if ($manaDriver) { 'pass' } else { 'unknown' }
    mellanoxDriver = if ($mellanoxDriver) { 'pass' } else { 'unknown' }
    actualController = $actual; persistentMounts = $true
    layoutSupported = -not $tempPageFile -and @($disks | Where-Object { $_.BusType -in @('RAID','Spaces') -or $_.OperationalStatus -ne 'Online' }).Count -eq 0 -and
        @(Get-CimInstance Win32_DiskDrive).Count -eq $disks.Count
    storageIdentityHash = $storageHash; sentinelHash = $sentinelHash; applicationHealth = $health
    accelerationInUse = $acceleration; manaInUse = $manaTraffic
    manaDeviceCount = $manaPresent.Count
    manaDevicePresent = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA&' }).Count -gt 0
    bootId = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    diskCount = $disks.Count
    pageFiles = @($pageFiles | ForEach-Object { $_.Name }); limitations = 'Absent non-present drivers are unknown; supplied workload review must exclude third-party storage filters.'
}
$json = $guest | ConvertTo-Json -Compress -Depth 10
if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 3500) { throw 'Evidence exceeds Run Command output budget.' }
Write-Output "AZVM_EVIDENCE_BEGIN`n$json`nAZVM_EVIDENCE_END"
