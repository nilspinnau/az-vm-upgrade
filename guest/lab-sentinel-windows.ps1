param(
    [Parameter(Mandatory)][switch]$ApprovedNewDisposableTestDataDisk,
    [Parameter(Mandatory)][string]$ExpectedDiskId,
    [Parameter(Mandatory)][string]$ExpectedDiskUniqueId
)
$ErrorActionPreference = 'Stop'
if (-not $ApprovedNewDisposableTestDataDisk) { throw 'Formatting is off by default; approve the exact new test data disk.' }
$metadata = Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/instance/compute/storageProfile?api-version=2021-02-01' -TimeoutSec 10
$references = @($metadata.dataDisks | Where-Object { $_.lun -eq 0 -and $_.managedDisk.id -ieq $ExpectedDiskId })
if ($references.Count -ne 1) { throw 'IMDS did not confirm the exact managed data disk and LUN.' }
$expected = $ExpectedDiskUniqueId.Replace('-','').Trim().ToLowerInvariant()
$candidates = @(Get-Disk | Where-Object {
    $_.SerialNumber -and $_.SerialNumber.Replace('-','').Trim().ToLowerInvariant() -eq $expected
})
if ($candidates.Count -ne 1) { throw 'Guest serial did not uniquely match the ARM disk uniqueId; no fallback by disk number/size/model.' }
$disk = $candidates[0]
if ($disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'RAW' -or $disk.NumberOfPartitions -ne 0) { throw 'Disk is not an untouched new test data disk.' }
if (Get-Volume | Where-Object DriveLetter -EQ 'F') { throw 'F: is already assigned; never reassign an existing data disk.' }
$disk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter F |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel 'AZVM-LAB-DATA' -Confirm:$false | Out-Null
Set-Content -LiteralPath 'F:\azvm-sentinel.txt' -Value 'az-vm-upgrade synthetic managed-data sentinel' -NoNewline
New-Item -ItemType Directory -Path 'C:\ProgramData\az-vm-upgrade' -Force | Out-Null
Set-Content 'C:\ProgramData\az-vm-upgrade\healthy' 'healthy'
Get-FileHash 'F:\azvm-sentinel.txt' -Algorithm SHA256
