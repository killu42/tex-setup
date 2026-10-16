# Isolated state-machine tests. No real registry/package manager/installer used.
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'track.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors | Out-String) }
. (Join-Path $PSScriptRoot 'track.ps1')
$nativeInventory = (Get-Item Function:Get-TeXInventory).ScriptBlock
$nativeRead = (Get-Item Function:Read-TeXRecord).ScriptBlock
$root = Join-Path ([IO.Path]::GetTempPath()) ('tex-state-tests-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$script:count = 0
function Assert($Condition, $Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Action) { $caught=$false; try { & $Action } catch { $caught=$true }; Assert $caught 'Expected rejection' }
function New-Fixture {
    $script:dir = Join-Path $root ([guid]::NewGuid())
    $script:installRoot = Join-Path $root ('program-' + [guid]::NewGuid())
    $script:apps = @(); $script:fingerprint = 'unchanged'; $script:removals=0
    $script:failInstall=$false; $script:failRemove=$false
    $script:failBootstrap=$false; $script:bootstrapCalls=0
}
function Get-TeXRecordPath { $script:dir }
function Get-TeXUser { 'S-1-TEST' }
function Get-TeXRegistrations { $script:apps }
function Get-TeXInventory { $script:fingerprint }
function Get-TeXInstallRoot { $script:installRoot }
function Get-AppxPackage { @() }
function Invoke-RestMethod {
    $script:bootstrapCalls++
    if ($script:failBootstrap) { Write-Error 'mock download failure'; return }
    '# bootstrap mocked: no network'
}
function winget {
    $script:apps = @([pscustomobject]@{Key='HKEY_CURRENT_USER\Software\MiKTeX';Name='MiKTeX';Version='1';Location='mock-root'})
    $global:LASTEXITCODE = if ($script:failInstall) {9} else {0}
}
function Invoke-TeXUninstall {
    $script:removals++
    if ($script:failRemove) { throw 'mock uninstall error' }
    $script:apps=@()
}
function Setup { Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget } }
function Case([string]$Name,[scriptblock]$Test) {
    New-Fixture
    & $Test
    $script:count++
    Write-Host "PASS $Name"
}
Case 'missing log does nothing and creates nothing' {
    Remove-TeX; Assert ($script:removals -eq 0); Assert (-not (Test-Path -LiteralPath $script:dir))
}
Case 'new MiKTeX removed; record deleted' {
    Setup; $r=Read-TeXRecord $script:dir; Assert ($r.baseline -eq 'absent'); Assert ($r.status -eq 'complete')
    Remove-TeX; Assert ($script:removals -eq 1); Assert (-not (Test-Path -LiteralPath $script:dir))
}
Case 'preexisting MiKTeX and updates preserved' {
    winget; Setup; Remove-TeX; Assert ($script:removals -eq 0); Assert ($script:apps.Count -eq 1)
}
Case 'repeat installation keeps original ownership' {
    Setup; Setup; Assert ((Read-TeXRecord $script:dir).baseline -eq 'absent'); Remove-TeX; Assert ($script:removals -eq 1)
}
Case 'program installed between prepare and install is preserved' {
    Initialize-TeX; winget; Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
    Remove-TeX; Assert ($script:removals -eq 0)
}
Case 'failed installation stays pending and cannot be adopted on retry' {
    Initialize-TeX; $script:failInstall=$true
    Throws { Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget } }
    Assert ((Read-TeXRecord $script:dir).status -eq 'pending')
    Throws { Setup }; Throws { Remove-TeX }; Assert ($script:removals -eq 0)
}
Case 'changed files protected' {
    Setup; $script:fingerprint='changed'; Throws { Remove-TeX }; Assert ($script:removals -eq 0)
    Assert ((Read-TeXRecord $script:dir).status -eq 'complete')
}
Case 'changed registration protected' {
    Setup; $script:apps[0].Version='2'; Throws { Remove-TeX }; Assert ($script:removals -eq 0)
}
Case 'other install scope protected' {
    Setup; $script:apps[0].Key='HKEY_LOCAL_MACHINE\Software\MiKTeX'; Throws { Remove-TeX }; Assert ($script:removals -eq 0)
}
Case 'failed removal retains record; retry succeeds' {
    Setup; $script:failRemove=$true; Throws { Remove-TeX }; Assert ((Read-TeXRecord $script:dir).status -eq 'complete')
    $script:failRemove=$false; Remove-TeX; Assert (-not (Test-Path -LiteralPath $script:dir))
}
Case 'corrupt JSON protected' {
    Setup; Set-Content -LiteralPath (Join-Path $script:dir 'state.json') -Value '{bad'
    Throws { Remove-TeX }; Assert ($script:removals -eq 0)
}
Case 'wrong user protected' {
    Setup; $r=Read-TeXRecord $script:dir; $r.user='someone-else'; Save-TeXRecord $script:dir $r
    Throws { Remove-TeX }; Assert ($script:removals -eq 0)
}
Case 'incomplete state write cannot become a fresh installation' {
    [void][IO.Directory]::CreateDirectory($script:dir)
    Set-Content -LiteralPath (Join-Path $script:dir 'state.new') -Value 'incomplete'
    Throws { Initialize-TeX }; Throws { Remove-TeX }; Assert ($script:removals -eq 0)
}
Case 'concurrent operation protected' {
    Setup; Set-Content -LiteralPath (Join-Path $script:dir 'lock') -Value 'busy'
    Throws { Remove-TeX }; Assert ($script:removals -eq 0); Assert (Test-Path -LiteralPath (Join-Path $script:dir 'lock'))
}
Case 'invalid installation command rejected' {
    Throws { Install-TeX { Write-Host 'unexpected' } }; Assert (-not (Test-Path -LiteralPath $script:dir))
}
Case 'missing registration but remaining folder retains record' {
    Setup; $script:apps=@(); [void][IO.Directory]::CreateDirectory($script:installRoot)
    Throws { Remove-TeX }; Assert (Test-Path -LiteralPath (Join-Path $script:dir 'state.json'))
}
Case 'real inventory detects newly added files' {
    [void][IO.Directory]::CreateDirectory($script:installRoot)
    Set-Content -LiteralPath (Join-Path $script:installRoot 'program.txt') -Value 'data'
    $first = & $nativeInventory
    Set-Content -LiteralPath (Join-Path $script:installRoot 'my-work.tex') -Value 'private document'
    Assert ((& $nativeInventory) -ne $first)
}
Case 'preparation is automatic and does not alter caller preferences' {
    $ErrorActionPreference='Continue'
    Setup
    Assert ($script:bootstrapCalls -eq 1)
    Assert ($ErrorActionPreference -eq 'Continue')
    Assert ((Read-TeXRecord $script:dir).status -eq 'complete')
}
Case 'bootstrap error blocks installation even with caller Continue preference' {
    $ErrorActionPreference='Continue'
    $script:failBootstrap=$true
    Throws { Setup }
    Assert ($script:apps.Count -eq 0)
    Assert ((Read-TeXRecord $script:dir).status -eq 'prepared')
    Assert ($ErrorActionPreference -eq 'Continue')
}
Write-Host "$script:count isolated PowerShell checks passed. No native Windows installation test."
