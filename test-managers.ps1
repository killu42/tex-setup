# Real provenance functions, mocked Appx/WinGet. No native Windows changes.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'track.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('tex-manager-tests-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$script:count=0
function Assert($Condition){if(-not $Condition){throw 'Assertion failed'}}
function Throws([scriptblock]$Action){$caught=$false;try{&$Action}catch{$caught=$true};Assert $caught}
function Get-TeXRecordPath {$script:dir}
function Get-TeXUser {'S-1-TEST'}
function Get-TeXManagerPackages {$script:packages}
function Test-TeXManagerCommand {$script:command}
function Get-TeXRegistrations {@()}
function Test-TeXFootprint {$false}
function Get-AppxPackage {$script:packages}
function Invoke-RestMethod {
 '$script:bootstraps++; $script:packages=@(New-Package); $script:command=$true'
}
function New-Package([string]$Version='1') {
 [pscustomobject]@{Name='Microsoft.DesktopAppInstaller';PackageFamilyName='Microsoft.DesktopAppInstaller_8wekyb3d8bbwe';PublisherId='8wekyb3d8bbwe';PackageFullName="Microsoft.DesktopAppInstaller_${Version}_x64__8wekyb3d8bbwe";Version=$Version;InstallLocation="C:\Mock\AppInstaller-$Version";NonRemovable=$false}
}
function Remove-AppxPackage {
 param([string]$Package,[string]$ErrorAction)
 Assert ($Package -ceq $script:packages[0].PackageFullName)
 $script:removals++
 if($script:failRemove){throw 'Mock Windows refusal'}
 if(-not $script:retain){$script:packages=@();$script:command=$false}
}
function Setup {
 Initialize-TeXManager {
  $script:bootstraps++
  if($script:failBootstrap){throw 'Mock failed setup'}
  $script:packages=@(New-Package ([string]$script:bootstraps));$script:command=$true
 }
}
function Record {Read-TeXManagerRecord (Get-TeXManagerPath)}
function Case($Name,[scriptblock]$Test){
 $script:dir=Join-Path $root ([guid]::NewGuid());$script:packages=@();$script:command=$false
 $script:removals=0;$script:bootstraps=0;$script:failRemove=$false;$script:failBootstrap=$false;$script:retain=$false
 &$Test;$script:count++;Write-Host "PASS $Name"
}
Case 'no record: no removal and no directory created' {Remove-TeXManager;Assert ($script:removals -eq 0);Assert (-not(Test-Path (Get-TeXManagerPath)))}
Case 'real TeX preparation records manager before bootstrap' {Initialize-TeX;Assert ((Record).baseline -eq 'absent');Assert ((Record).status -eq 'complete');Assert ((Read-TeXRecord $script:dir).baseline -eq 'absent');Assert ($script:bootstraps -eq 1)}
Case 'real TeX preparation retains preexisting App Installer' {$script:packages=@(New-Package);Initialize-TeX;Assert ((Record).baseline -eq 'present');Remove-TeXManager;Assert ($script:removals -eq 0)}
Case 'new WinGet removed and only manager record deleted' {Setup;Assert ((Record).baseline -eq 'absent');Remove-TeXManager;Assert ($script:removals -eq 1);Assert (-not(Test-Path (Get-TeXManagerPath)))}
Case 'existing App Installer and updates preserved even without winget PATH' {$script:packages=@(New-Package);Setup;Assert ((Record).baseline -eq 'present');Remove-TeXManager;Assert ($script:removals -eq 0)}
Case 'existing winget command without registration preserved' {$script:command=$true;Setup;Assert ((Record).baseline -eq 'present');Remove-TeXManager;Assert ($script:removals -eq 0)}
Case 'repeat setup preserves original new provenance' {Setup;Setup;Assert ((Record).baseline -eq 'absent');Assert ((Record).after.Version -eq '2');Remove-TeXManager;Assert ($script:removals -eq 1)}
Case 'repeat updates of preexisting manager remain protected' {$script:packages=@(New-Package);Setup;Setup;Remove-TeXManager;Assert ($script:removals -eq 0)}
Case 'later App Installer update is preserved and not adopted' {Setup;$script:packages=@(New-Package '99');Throws {Remove-TeXManager};Setup;Assert ((Record).baseline -eq 'protected');Remove-TeXManager;Assert ($script:removals -eq 0)}
Case 'changed package location rejected' {Setup;$script:packages[0].InstallLocation='elsewhere';Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'wrong publisher rejected' {Setup;$script:packages[0].PublisherId='other';Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'multiple registrations rejected' {Setup;$script:packages+=$script:packages[0];Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'protected Windows component retained' {Setup;$script:packages[0].NonRemovable=$true;Throws {Remove-TeXManager};Assert ($script:removals -eq 0);Assert (Test-Path (Get-TeXManagerPath))}
Case 'failed native removal retains evidence and allows safe retry' {Setup;$script:failRemove=$true;Throws {Remove-TeXManager};Assert (Test-Path (Get-TeXManagerPath));$script:failRemove=$false;Remove-TeXManager;Assert (-not(Test-Path (Get-TeXManagerPath)))}
Case 'native success without removal does not delete record' {Setup;$script:retain=$true;Throws {Remove-TeXManager};Assert (Test-Path (Get-TeXManagerPath))}
Case 'failed bootstrap cannot be adopted on retry' {$script:failBootstrap=$true;Throws {Setup};Assert ((Record).status -eq 'pending');Throws {Setup};Throws {Remove-TeXManager};Assert ($script:bootstraps -eq 1);Assert ($script:removals -eq 0)}
Case 'bootstrap without identifiable App Installer remains pending' {Throws {Initialize-TeXManager {}};Assert ((Record).status -eq 'pending');Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'TeX must be removed before its package manager' {Setup;[void][IO.Directory]::CreateDirectory($script:dir);Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'manager evidence survives real TeX removal' {
 Setup
 Use-TeXRecord {param($d);Save-TeXRecord $d ([pscustomobject]@{schema=1;user='S-1-TEST';baseline='present';status='complete';registration=@();fingerprint=''})}
 Remove-TeX
 Assert (-not(Test-Path $script:dir));Assert (Test-Path (Get-TeXManagerPath))
 Remove-TeXManager;Assert ($script:removals -eq 1)
}
Case 'old TeX record never permits retroactive manager removal' {
 [void][IO.Directory]::CreateDirectory($script:dir)
 Set-Content (Join-Path $script:dir 'state.json') '{"appInstallerBefore":[]}'
 Remove-TeXManager;Assert ($script:removals -eq 0)
 $script:packages=@(New-Package);Setup;Assert ((Record).baseline -eq 'present')
}
Case 'unknown schema rejected' {Setup;$r=Record;$r.schema='old';Save-TeXRecord (Get-TeXManagerPath) $r;Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'wrong user rejected' {Setup;$r=Record;$r.user='other';Save-TeXRecord (Get-TeXManagerPath) $r;Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'corrupt JSON rejected' {Setup;Set-Content (Join-Path (Get-TeXManagerPath) 'state.json') '{bad';Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'partial record not adopted' {[void][IO.Directory]::CreateDirectory((Get-TeXManagerPath));Set-Content (Join-Path (Get-TeXManagerPath) 'state.new') 'unfinished';Throws {Setup};Throws {Remove-TeXManager};Assert ($script:bootstraps -eq 0)}
Case 'simultaneous operation rejected' {Setup;Set-Content (Join-Path (Get-TeXManagerPath) 'lock') 'busy';Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'missing saved package identity rejected' {Setup;$r=Record;$r.after=$null;Save-TeXRecord (Get-TeXManagerPath) $r;Throws {Remove-TeXManager};Assert ($script:removals -eq 0)}
Case 'source never targets all users or provisioned system packages' {
 $source=Get-Content (Join-Path $PSScriptRoot 'track.ps1') -Raw
 Assert ($source -notmatch '(?im)^\s*Remove-AppxPackage.*-AllUsers|Remove-AppxProvisionedPackage|Set-ExecutionPolicy')
}
Write-Host "$script:count isolated WinGet manager checks passed. No native Windows changes."
Remove-Item -LiteralPath $root -Recurse -Force
