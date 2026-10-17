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
    $script:installs=0; $script:updates=0; $script:failUpdate=$false
    $script:failResolve=$false; $script:footprint=$false; $script:changeAfterUpdate=$false
}
function Get-TeXRecordPath { $script:dir }
function Get-TeXUser { 'S-1-TEST' }
function Get-TeXRegistrations { $script:apps }
function Get-TeXInventory { $script:fingerprint }
function Get-TeXInstallRoot { $script:installRoot }
function Test-TeXFootprint { $script:footprint -or (Test-Path -LiteralPath $script:installRoot) }
function Get-TeXUpdater($Apps) {
    if ($script:failResolve -or @($Apps).Count -ne 1) { throw 'mock ambiguous updater' }
    [pscustomobject]@{File='mock-miktex.exe';Admin=$false;Key=$Apps[0].Key;Location=$Apps[0].Location}
}
function Update-TeX($Updater) {
    $script:updates++
    if ($script:failUpdate) { throw 'mock update failure' }
    $script:apps[0].Version = [string]([int]$script:apps[0].Version + 1)
    $script:fingerprint = 'updated-' + $script:updates
    if ($script:changeAfterUpdate) { $script:apps[0].Location='other-root' }
}
function Get-AppxPackage { @() }
function Ensure-TeXEditor($Updater, $Record) { }
function Remove-TeXEditorLinks($Record) { }
# Manager provenance has its own isolated suite; this suite covers TeX state.
function Initialize-TeXManager([scriptblock]$Bootstrap) { & $Bootstrap }
function Invoke-RestMethod {
    $script:bootstrapCalls++
    if ($script:failBootstrap) { Write-Error 'mock download failure'; return }
    '# bootstrap mocked: no network'
}
function winget {
    $script:installs++
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
    Assert ($script:installs -eq 1); Assert ($script:updates -eq 1)
    Assert ($r.registration[0].Version -eq '2'); Assert ($r.fingerprint -eq 'updated-1')
    Remove-TeX; Assert ($script:removals -eq 1); Assert (-not (Test-Path -LiteralPath $script:dir))
}
Case 'preexisting MiKTeX and updates preserved' {
    winget; Setup; Assert ($script:installs -eq 1); Assert ($script:updates -eq 1)
    Assert ($script:apps[0].Version -eq '2')
    Remove-TeX; Assert ($script:removals -eq 0); Assert ($script:apps.Count -eq 1)
}
Case 'repeat installation keeps original ownership' {
    Setup; Setup; Assert ((Read-TeXRecord $script:dir).baseline -eq 'absent')
    Assert ($script:installs -eq 1); Assert ($script:updates -eq 2)
    Assert ((Read-TeXRecord $script:dir).registration[0].Version -eq '3')
    Remove-TeX; Assert ($script:removals -eq 1)
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
    Setup; $script:apps[0].Version='99'; Throws { Remove-TeX }; Assert ($script:removals -eq 0)
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
Case 'failed update of existing program does not run installer or permit removal' {
    winget; $script:failUpdate=$true; Throws { Setup }
    Assert ($script:installs -eq 1); Assert ($script:updates -eq 1)
    Assert ((Read-TeXRecord $script:dir).baseline -eq 'present')
    Assert ((Read-TeXRecord $script:dir).status -eq 'pending')
    Throws { Setup }; Throws { Remove-TeX }; Assert ($script:removals -eq 0)
}
Case 'failed update of new program retains pending record' {
    $script:failUpdate=$true; Throws { Setup }
    Assert ((Read-TeXRecord $script:dir).baseline -eq 'absent')
    Assert ((Read-TeXRecord $script:dir).status -eq 'pending'); Throws { Remove-TeX }
}
Case 'unknown TeX footprint blocks a second distribution' {
    $script:footprint=$true; Throws { Setup }
    Assert ($script:installs -eq 0); Assert ($script:updates -eq 0)
    Assert ((Read-TeXRecord $script:dir).status -eq 'prepared')
}
Case 'multiple registrations block installation and updates' {
    winget; $script:apps += $script:apps[0]; Throws { Setup }
    Assert ($script:installs -eq 1); Assert ($script:updates -eq 0)
}
Case 'unusable existing updater blocks a second installation before pending' {
    winget; $script:failResolve=$true; Throws { Setup }
    Assert ($script:installs -eq 1); Assert ($script:updates -eq 0)
    Assert ((Read-TeXRecord $script:dir).status -eq 'prepared')
}
Case 'changed owned registration cannot be absorbed by updating' {
    Setup; $script:apps[0].Version='99'; Throws { Setup }
    Assert ($script:updates -eq 1); Assert ((Read-TeXRecord $script:dir).registration[0].Version -eq '2')
}
Case 'changed owned files cannot be absorbed by updating' {
    Setup; $script:fingerprint='user-change'; Throws { Setup }
    Assert ($script:updates -eq 1); Assert ((Read-TeXRecord $script:dir).fingerprint -eq 'updated-1')
}
Case 'registration changes during update cannot be claimed' {
    $script:changeAfterUpdate=$true; Throws { Setup }
    Assert ((Read-TeXRecord $script:dir).status -eq 'pending'); Throws { Remove-TeX }
}
Case 'repeat updates of existing program remain protected' {
    winget; Setup; Setup; Assert ($script:installs -eq 1); Assert ($script:updates -eq 2)
    Assert ((Read-TeXRecord $script:dir).baseline -eq 'present')
    Remove-TeX; Assert ($script:removals -eq 0); Assert ($script:apps[0].Version -eq '3')
}
Case 'old record with unchanged inventory migrates without losing provenance' {
    Setup; $r=Read-TeXRecord $script:dir; $r.PSObject.Properties.Remove('inventoryVersion'); Save-TeXRecord $script:dir $r
    Setup; $r=Read-TeXRecord $script:dir; Assert ($r.baseline -eq 'absent'); Assert ($r.inventoryVersion -eq 2)
    Remove-TeX; Assert ($script:removals -eq 1)
}
Case 'old record with unverifiable inventory permits repair but never deletion' {
    Setup; $r=Read-TeXRecord $script:dir; $r.PSObject.Properties.Remove('inventoryVersion'); Save-TeXRecord $script:dir $r
    $script:fingerprint='changed'; Setup
    Assert ((Read-TeXRecord $script:dir).baseline -eq 'present')
    Remove-TeX; Assert ($script:removals -eq 0)
}
Case 'old settings provenance never grants automatic removal' {
    Setup; $r=Read-TeXRecord $script:dir; $r.PSObject.Properties.Remove('cleanupRootsFresh'); Save-TeXRecord $script:dir $r
    Setup; Assert ((Read-TeXRecord $script:dir).baseline -eq 'present')
    Remove-TeX; Assert ($script:removals -eq 0)
}
Case 'direct removal of old settings provenance preserves installation' {
    Setup; $r=Read-TeXRecord $script:dir; $r.PSObject.Properties.Remove('cleanupRootsFresh'); Save-TeXRecord $script:dir $r
    Remove-TeX; Assert ($script:removals -eq 0); Assert ($script:apps.Count -eq 1)
}
Case 'stable inventory ignores only ordinary runtime lock timestamps' {
    $folder=Join-Path $script:installRoot 'miktex'; [void][IO.Directory]::CreateDirectory($folder)
    $lock=Join-Path $folder 'lock'; [IO.File]::WriteAllText($lock,'x')
    $first=& $nativeInventory -Stable; $legacy=& $nativeInventory
    [IO.File]::SetLastWriteTimeUtc($lock,[DateTime]::UtcNow.AddMinutes(2))
    [IO.Directory]::SetLastWriteTimeUtc($folder,[DateTime]::UtcNow.AddMinutes(2))
    Assert ($first -eq (& $nativeInventory -Stable)); Assert ($legacy -ne (& $nativeInventory))
    [IO.File]::WriteAllText((Join-Path $folder 'personal.tex'),'private')
    Assert ($first -ne (& $nativeInventory -Stable))
}
Case 'stable inventory rejects altered ordinary files and lock replacement' {
    $folder=Join-Path $script:installRoot 'miktex'; [void][IO.Directory]::CreateDirectory($folder)
    $file=Join-Path $folder 'program.dat'; [IO.File]::WriteAllText($file,'data')
    $first=& $nativeInventory -Stable
    [IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow.AddMinutes(2))
    Assert ($first -ne (& $nativeInventory -Stable))
    $lock=Join-Path $folder 'lock'; [IO.File]::WriteAllText($lock,'x'); $first=& $nativeInventory -Stable
    [IO.File]::WriteAllText($lock,'different'); Assert ($first -ne (& $nativeInventory -Stable))
}
Write-Host "$script:count isolated PowerShell checks passed. No native Windows installation test."
