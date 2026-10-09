#Requires -Version 7.5
[CmdletBinding()]
param([switch]$SkipTerraform)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$parseFailures = @()
Get-ChildItem (Join-Path $root 'src'),(Join-Path $root 'scripts'),(Join-Path $root 'guest'),(Join-Path $root 'tests') -Recurse -Include *.ps1,*.psm1,*.psd1 |
    ForEach-Object {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        $parseFailures += $errors
    }
if ($parseFailures.Count) { $parseFailures | Out-String | Write-Error; throw 'PowerShell parse failed.' }
Import-Module Pester -MinimumVersion 5.5 -ErrorAction Stop
Import-Module PSScriptAnalyzer -MinimumVersion 1.22 -ErrorAction Stop
$findings = @(foreach ($directory in @('src','scripts','guest','tests\integration')) {
    Invoke-ScriptAnalyzer -Path (Join-Path $root $directory) -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1')
})
if ($findings.Count) { $findings | Format-Table -AutoSize | Out-String | Write-Error; throw 'Static analysis failed.' }
$result = Invoke-Pester -Path (Join-Path $root 'tests') -PassThru -Output Detailed
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { throw 'Offline Pester tests failed or none ran.' }
$bash = (Get-Command bash -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
foreach ($file in Get-ChildItem (Join-Path $root 'guest') -Filter *.sh) {
    & $bash -n $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "Bash syntax check failed: $($file.Name)" }
    $embedded = [regex]::Matches((Get-Content $file.FullName -Raw), "(?ms)^python3\b[^\r\n]*<<'PY'\r?\n(?<code>.*?)^PY\r?$")
    foreach ($match in $embedded) {
        $match.Groups['code'].Value | & $python -c 'import ast,sys; ast.parse(sys.stdin.read())'
        if ($LASTEXITCODE -ne 0) { throw "Embedded Python syntax check failed: $($file.Name)" }
    }
}
if (-not $SkipTerraform) {
    $infra = Join-Path $root 'infra\test-vm'
    & terraform "-chdir=$infra" fmt -check -recursive
    if ($LASTEXITCODE -ne 0) { throw 'Terraform formatting check failed.' }
    & terraform "-chdir=$infra" init -backend=false -input=false -no-color
    if ($LASTEXITCODE -ne 0) { throw 'Terraform provider initialization failed.' }
    & terraform "-chdir=$infra" validate -no-color
    if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed.' }
    & (Join-Path $PSScriptRoot 'Test-ProviderSchema.ps1') -TerraformDirectory $infra
    & terraform "-chdir=$infra" test -no-color
    if ($LASTEXITCODE -ne 0) { throw 'Mocked Terraform tests failed.' }
}
Write-Output "Offline checks passed: $($result.PassedCount) Pester tests. No Azure operations were invoked."
