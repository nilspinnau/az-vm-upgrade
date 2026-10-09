#Requires -Version 7.5
param([Parameter(Mandatory)][string]$JournalPath, [string]$OutputPath = '.\out\recovery.md')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
$guide = Get-VmRecoveryGuide $JournalPath
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))) | Out-Null
$guide | Set-Content -LiteralPath $OutputPath
$OutputPath
