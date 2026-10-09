$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
foreach ($file in @('Common','Cloud','Advisor','Health','Planning','Execution','Backends','Reports')) {
    . (Join-Path $PSScriptRoot "$file.ps1")
}
