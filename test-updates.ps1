# Real resolver/update functions with isolated files and mocked native commands.
# No network, registry, installation, update or removal of actual software.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'track.ps1')
$nativeInvoke = (Get-Item Function:Invoke-TeXNative).ScriptBlock
$root = Join-Path ([IO.Path]::GetTempPath()) ('tex-update-tests-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$script:count = 0
function Assert($Condition, $Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Action) { $caught=$false; try { & $Action } catch { $caught=$true }; Assert $caught 'Expected rejection' }
function Test-TeXAdministrator { $script:admin }
function Get-TeXInstallRoot { $script:installRoot }
function Invoke-TeXNative([string]$File, [string[]]$Arguments) {
    $script:calls.Add([pscustomobject]@{File=$File;Arguments=$Arguments})
    if ($script:codes.Count -eq 0) { throw 'Unexpected native call' }
    $script:codes.Dequeue()
}
function Fixture {
    $script:installRoot = Join-Path $root ([guid]::NewGuid())
    $bin = Join-Path (Join-Path (Join-Path $script:installRoot 'miktex') 'bin') 'x64'
    [void][IO.Directory]::CreateDirectory($bin)
    $script:exe = Join-Path $bin 'miktex.exe'
    Set-Content -LiteralPath $script:exe -Value 'mock only - never executed'
    $script:app = [pscustomobject]@{Key='HKEY_CURRENT_USER\Software\MiKTeX';Location=$script:installRoot}
    $script:admin=$false
    $script:calls=[Collections.Generic.List[object]]::new()
    $script:codes=[Collections.Generic.Queue[object]]::new()
}
function Codes($Values) { foreach ($value in $Values) { $script:codes.Enqueue($value) } }
function Case([string]$Name,[scriptblock]$Test) {
    Fixture; & $Test; $script:count++; Write-Host "PASS $Name"
}
Case 'registered user installation resolved without administrator mode' {
    $u=Get-TeXUpdater @($script:app); Assert ($u.File -eq $script:exe); Assert (-not $u.Admin)
}
Case 'missing HKCU location uses default user installation' {
    $script:app.Location=''; Assert ((Get-TeXUpdater @($script:app)).File -eq $script:exe)
}
Case 'custom registered location wins over default installation' {
    $expected=$script:exe; $script:installRoot=Join-Path $root 'nonexistent'
    Assert ((Get-TeXUpdater @($script:app)).File -eq $expected)
}
Case 'legacy bin location supported' {
    $legacy=Join-Path (Split-Path -Parent (Split-Path -Parent $script:exe)) 'miktex.exe'
    Move-Item -LiteralPath $script:exe -Destination $legacy
    Assert ((Get-TeXUpdater @($script:app)).File -eq $legacy)
}
Case 'unregistered or multiple installations rejected' {
    Throws { Get-TeXUpdater @() }; Throws { Get-TeXUpdater @($script:app,$script:app) }
}
Case 'relative installation path rejected' {
    $script:app.Location='relative'; Throws { Get-TeXUpdater @($script:app) }
}
Case 'unknown scope rejected' {
    $script:app.Key='unexpected'; Throws { Get-TeXUpdater @($script:app) }
}
Case 'missing executable rejected rather than reinstalling' {
    Remove-Item -LiteralPath $script:exe; Throws { Get-TeXUpdater @($script:app) }
}
Case 'multiple executables rejected' {
    $legacy=Join-Path (Split-Path -Parent (Split-Path -Parent $script:exe)) 'miktex.exe'
    Set-Content -LiteralPath $legacy -Value 'another mock'; Throws { Get-TeXUpdater @($script:app) }
}
Case 'shared installation requires administrator rights' {
    $script:app.Key='HKEY_LOCAL_MACHINE\Software\MiKTeX'
    Throws { Get-TeXUpdater @($script:app) }
    $script:admin=$true; Assert (Get-TeXUpdater @($script:app)).Admin
}
Case 'missing shared location does not fall back to user installation' {
    $script:admin=$true; $script:app.Key='HKEY_LOCAL_MACHINE\Software\MiKTeX'; $script:app.Location=''
    Throws { Get-TeXUpdater @($script:app) }
}
Case 'updater symbolic link rejected' {
    $target=Join-Path $script:installRoot 'target.exe'; Move-Item -LiteralPath $script:exe -Destination $target
    [void](New-Item -ItemType SymbolicLink -Path $script:exe -Target $target)
    Throws { Get-TeXUpdater @($script:app) }
}
Case 'user update calls database update then package update then verification' {
    Codes @(0,0,0); Update-TeX (Get-TeXUpdater @($script:app))
    Assert ($script:calls.Count -eq 3)
    Assert (($script:calls[0].Arguments -join ' ') -eq 'packages update-package-database')
    Assert (($script:calls[1].Arguments -join ' ') -eq 'packages update')
    Assert (($script:calls[2].Arguments -join ' ') -eq 'packages check-update')
    Assert (@($script:calls | Where-Object File -ne $script:exe).Count -eq 0)
}
Case 'remaining core updates trigger another bounded pass' {
    Codes @(0,0,100,0,0,0); Update-TeX (Get-TeXUpdater @($script:app)); Assert ($script:calls.Count -eq 6)
}
Case 'persistent remaining updates fail after three passes' {
    Codes @(0,0,100,0,0,100,0,0,100)
    Throws { Update-TeX (Get-TeXUpdater @($script:app)) }; Assert ($script:calls.Count -eq 9)
}
Case 'database failure stops before package update' {
    Codes @(9); Throws { Update-TeX (Get-TeXUpdater @($script:app)) }; Assert ($script:calls.Count -eq 1)
}
Case 'package update failure is not success' {
    Codes @(0,9); Throws { Update-TeX (Get-TeXUpdater @($script:app)) }; Assert ($script:calls.Count -eq 2)
}
Case 'verification failure is not treated as available updates' {
    Codes @(0,0,9); Throws { Update-TeX (Get-TeXUpdater @($script:app)) }; Assert ($script:calls.Count -eq 3)
}
Case 'missing exit code fails closed' {
    $script:codes.Enqueue($null); Throws { Update-TeX (Get-TeXUpdater @($script:app)) }
}
Case 'shared installation updates system then user packages in separate modes' {
    $script:admin=$true; $script:app.Key='HKEY_LOCAL_MACHINE\Software\MiKTeX'
    Codes @(0,0,0,0,0,0); Update-TeX (Get-TeXUpdater @($script:app))
    Assert ($script:calls.Count -eq 6)
    Assert (($script:calls[0].Arguments -join ' ') -eq '--admin packages update-package-database')
    Assert (($script:calls[1].Arguments -join ' ') -eq '--admin packages update')
    Assert (($script:calls[2].Arguments -join ' ') -eq '--admin packages check-update')
    Assert (($script:calls[3].Arguments -join ' ') -eq 'packages update-package-database')
}
Case 'native adapter returns only exit code despite stdout and preserves preferences' {
    $PSNativeCommandUseErrorActionPreference=$true
    $engine=(Get-Process -Id $PID).Path
    $result=@(& $nativeInvoke $engine @('-NoProfile','-Command',"Write-Output 'mock native output'; exit 100"))
    Assert ($result.Count -eq 1); Assert ($result[0] -eq 100)
    Assert $PSNativeCommandUseErrorActionPreference
}
Case 'native adapter exposes errors rather than reporting success' {
    $engine=(Get-Process -Id $PID).Path
    Assert ((& $nativeInvoke $engine @('-NoProfile','-Command','exit 9')) -eq 9)
    Throws { & $nativeInvoke (Join-Path $root 'missing-command') @() }
}
Write-Host "$script:count isolated updater checks passed. No native Windows update test."
