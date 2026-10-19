# Isolated control-flow checks; no real downloads, registry or uninstallations.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows.ps1')
$oldOS=$env:OS; $env:OS='Windows_NT'
$root=Join-Path ([IO.Path]::GetTempPath()) ('tex-simple-tests-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$script:count=0
function Assert($condition) { if (-not $condition) { throw 'Assertion failed' } }
function Throws([scriptblock]$action) { $caught=$false; try { & $action } catch {$caught=$true}; Assert $caught }
function Get-TeXInstallRoot { $root }
function Get-TeXDataRoots { (Join-Path $root 'config'); (Join-Path $root 'data') }
function Get-TeXRegistrations { if ($script:present) { $script:app } }
function Test-TeXFootprint { $script:footprint }
function Test-TeXAdministrator { $script:admin }
function Get-TeXProgramsFolders { (Join-Path $root 'programs') }
function Read-TeXConfigReport { "UserInstall: $root"; "UserConfig: $script:config"; "UserData: $(Join-Path $root 'data')" }
function Invoke-RestMethod { $script:downloads++; if ($script:downloadFails) { throw 'mock network failure' }; 'Write-Output $null' }
function Update-TeX { $script:updates++; if ($script:updateFails) { throw 'mock update failure' } }
function Ensure-TeXEditor { $script:editors++ }
function winget { $script:installs++; $script:present=$true; $global:LASTEXITCODE=$script:installCode }
function Invoke-TeXNative($File,$Arguments) {
    Assert ($File -eq (Join-Path $script:bin 'miktexsetup.exe'))
    Assert (($Arguments -join ' ') -eq '--verbose --shared=no uninstall')
    $script:removals++
    if (-not $script:removeFails) { $script:present=$false; return 0 }
    1
}
function Case($name,[scriptblock]$action) {
    $script:present=$false; $script:footprint=$false; $script:admin=$false
    $script:installs=0; $script:downloads=0; $script:updates=0; $script:editors=0; $script:removals=0
    $script:installCode=0; $script:downloadFails=$false; $script:updateFails=$false; $script:removeFails=$false
    $script:config=Join-Path $root 'config'
    $script:app=[pscustomobject]@{Key='HKEY_CURRENT_USER\Software\MiKTeX';Location=$root}
    & $action; $script:count++; Write-Host "PASS $name"
}
try {
    $script:bin=Join-Path $root 'miktex/bin/x64'
    [void][IO.Directory]::CreateDirectory($script:bin)
    foreach($name in @('miktex.exe','miktexsetup.exe','initexmf.exe')) { Set-Content (Join-Path $script:bin $name) 'mock only' }
    $command={ winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
    Case 'new installation, updates and editor repair without history' {
        Install-TeX $command; Assert ($installs -eq 1 -and $updates -eq 1 -and $editors -eq 1)
    }
    Case 'existing installation is updated and repaired without reinstall' {
        $script:present=$true; Install-TeX $command; Assert ($installs -eq 0 -and $updates -eq 1 -and $editors -eq 1)
    }
    Case 'repeated install calls do not reinstall' {
        Install-TeX $command; Install-TeX $command; Assert ($installs -eq 1 -and $updates -eq 2)
    }
    Case 'handled update error does not require a state-file repair' {
        $script:updateFails=$true; Throws { Install-TeX $command }
        $script:updateFails=$false; Install-TeX $command; Assert ($installs -eq 1 -and $editors -eq 1)
    }
    Case 'unrelated command rejected before downloads' { Throws { Install-TeX { winget uninstall other } }; Assert ($downloads -eq 0) }
    Case 'unregistered other TeX footprint does not install a second distribution' {
        $script:footprint=$true; Throws { Install-TeX $command }; Assert ($downloads -eq 0)
    }
    Case 'failed bootstrap does not install TeX' {
        $script:downloadFails=$true; Throws { Install-TeX $command }; Assert ($installs -eq 0)
    }
    Case 'failed installer is not reported as complete' {
        $script:installCode=1; Throws { Install-TeX $command }; Assert ($updates -eq 0)
    }
    Case 'remove without installation is harmless and offline' {
        Remove-TeX; Assert ($removals -eq 0 -and $downloads -eq 0)
    }
    Case 'previously installed MiKTeX is deliberately removable, without history' {
        $script:present=$true; Remove-TeX; Assert ($removals -eq 1 -and -not $present -and $downloads -eq 0)
    }
    Case 'install twice, remove twice' {
        Install-TeX $command; Install-TeX $command; Remove-TeX; Remove-TeX
        Assert ($installs -eq 1 -and $removals -eq 1)
    }
    Case 'manufacturer uninstall error propagates' {
        $script:present=$true; $script:removeFails=$true; Throws { Remove-TeX }; Assert $present
    }
    Case 'custom data folder not recursively removed' {
        $script:present=$true; $script:config=Join-Path $root 'Documents'; Throws { Remove-TeX }; Assert ($removals -eq 0)
    }
    Case 'shared installation not silently removed' {
        $script:present=$true; $script:admin=$true; $script:app.Key='HKEY_LOCAL_MACHINE\Software\MiKTeX'
        Throws { Remove-TeX }; Assert ($removals -eq 0)
    }
    Assert (-not (Test-Path (Join-Path $root 'state.json')))
    Write-Host "$count simplified Windows checks passed; no real installation."
} finally {
    $env:OS=$oldOS
    Remove-Item -LiteralPath $root -Recurse -Force
}
