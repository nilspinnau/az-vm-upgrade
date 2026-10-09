param([Parameter(Mandatory)][switch]$ApprovedDisposableLab)
$ErrorActionPreference = 'Stop'
if (-not $ApprovedDisposableLab) { throw 'Explicit guest-change consent is required.' }
if ([Environment]::OSVersion.Version.Build -ne 20348) { throw 'Only the Windows Server 2022 lab preparation profile is implemented.' }
$folder = 'C:\ProgramData\az-vm-upgrade\preparation'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$original = Join-Path $folder 'stornvme-original.json'
if (-not (Test-Path -LiteralPath $original)) {
    @{
        Start = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme').Start
        recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $original
}
& sc.exe config stornvme start= boot
if ($LASTEXITCODE -ne 0) { throw 'stornvme boot configuration failed.' }
Write-Output "Prepared stornvme. Install reviewed Microsoft networking drivers separately; reassess. Original: $original"
