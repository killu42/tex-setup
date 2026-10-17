# REAL installation/removal test. Run only on a disposable GitHub-hosted VM.
param([ValidateSet('fresh','existing','legacy','manager-new')][string]$Scenario = 'fresh')
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -ne 'true' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'killu42/tex-setup') {
    throw 'This native test is restricted to disposable GitHub-hosted Windows VMs.'
}
$testedRef = $env:TEST_REF
if ($testedRef -notmatch '^[a-f0-9]{40}$') { throw 'An explicit tested commit is required.' }
$base = "https://raw.githubusercontent.com/killu42/tex-setup/$testedRef"
$testDir = Join-Path $env:RUNNER_TEMP ('tex-native-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($testDir)
$script:checks = [Collections.Generic.List[string]]::new()
$script:stage = 'Preflight'
function Check([bool]$Value,[string]$Message) {
    if (-not $Value) { throw $Message }
    $script:checks.Add("PASS: $Message")
    Write-Host "PASS: $Message"
}
function Stage([string]$Name) { $script:stage=$Name; Write-Host "STAGE: $Name" }
function Record-Failure($Failure) {
    $script:failed = $true
    $script:checks.Add("FAIL at $script:stage : $($Failure.Exception.Message)")
    Write-Host "::error::Native test failed at $script:stage : $($Failure.Exception.Message)"
    Write-Host $Failure.ScriptStackTrace
}
function Part([string]$Name,[scriptblock]$Action) {
    Stage $Name
    try { & $Action } catch { Record-Failure $_ }
}
function Get-InventoryRows {
    $root = Get-TeXInstallRoot
    Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object {
        '{0}|{1}|{2}' -f $_.FullName.Substring($root.Length), $_.Length, $_.LastWriteTimeUtc.Ticks
    } | Sort-Object
}
function Get-OtherPrograms {
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root | ForEach-Object {
                $item = Get-ItemProperty -LiteralPath $_.PSPath
                if ($item.DisplayName -and $item.DisplayName -notlike '*MiKTeX*') { $_.Name }
            }
        }
    }
}
function Check-TeXExecutable {
    $updater = Get-TeXUpdater @(Get-TeXRegistrations)
    $bin = Split-Path -Parent $updater.File
    $compiler = Join-Path $bin 'pdflatex.exe'
    Check (Test-Path -LiteralPath $compiler -PathType Leaf) 'Real pdfLaTeX executable exists'
    Check (@(Get-ChildItem -LiteralPath $bin -Filter '*texworks*.exe').Count -gt 0) 'TeXworks editor executable exists'
    $versionOutput = & $compiler --version
    $versionExit = $LASTEXITCODE
    $versionOutput | Out-Host
    Check ($versionExit -eq 0) "Real pdfLaTeX starts (exit $versionExit)"
    $compiler
}
function Check-EditorLaunch {
    $editor = Join-Path (Split-Path -Parent (Get-TeXUpdater @(Get-TeXRegistrations)).File) 'miktex-texworks.exe'
    $shortcut = Find-TeXEditorShortcut $editor
    Check ([bool]$shortcut) 'Start menu contains a shortcut to this TeXworks'
    Write-Host "GUI session: $((Get-Process -Id $PID).SessionId); interactive: $([Environment]::UserInteractive)"
    Get-Process -Name '*texworks*' -ErrorAction SilentlyContinue | Select-Object Id,Path,SessionId,MainWindowHandle | Format-List | Out-Host
    $process = Start-Process -FilePath $editor -PassThru
    try {
        # TeXworks is single-instance: a second process may exit after handing
        # off to an already running editor. Inspect the matching application,
        # not just the launcher PID, and allow first-start initialization.
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            $windows = @(Get-Process -Name '*texworks*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $editor -and $_.MainWindowHandle -ne 0 })
            if ($windows.Count -gt 0) { break }
            Start-Sleep -Seconds 1
        } while ([DateTime]::UtcNow -lt $deadline)
        Get-Process -Name '*texworks*' -ErrorAction SilentlyContinue | Select-Object Id,Path,SessionId,MainWindowHandle | Format-List | Out-Host
        $process.Refresh()
        Write-Host "Launched editor exited: $($process.HasExited); exit code: $($process.ExitCode)"
        if ($windows.Count -eq 0) {
            $log = Join-Path $env:LOCALAPPDATA 'MiKTeX\miktex\log\texworks.log'
            if (Test-Path $log) { Get-Content -LiteralPath $log -Tail 60 | Out-Host }
        }
        Check ($windows.Count -gt 0) 'Real TeXworks opens a GUI window'
    } finally {
        $process.Refresh()
        if (-not $process.HasExited) {
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(10000)) { Stop-Process -Id $process.Id -Force }
        }
        foreach ($window in @($windows)) {
            $window.Refresh()
            if (-not $window.HasExited) {
                [void]$window.CloseMainWindow()
                if (-not $window.WaitForExit(10000)) { Stop-Process -Id $window.Id -Force }
            }
        }
    }
}
$script:failed = $false
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "OS: $($os.Caption); build $($os.BuildNumber); architecture $env:PROCESSOR_ARCHITECTURE"
    Write-Host "Scenario: $Scenario; tested script commit: $testedRef; PowerShell $($PSVersionTable.PSVersion)"
    $tracker = Invoke-RestMethod "$base/track.ps1"
    $tracker = $tracker.Replace('https://raw.githubusercontent.com/killu42/tex-setup/main/', "$base/")
    Invoke-Expression $tracker
    Check (-not (Test-Path -LiteralPath (Get-TeXRecordPath))) 'Fresh VM has no TeX ownership record'
    Check (-not (Test-Path -LiteralPath (Get-TeXManagerPath))) 'Fresh VM has no manager ownership record'
    Check (@(Get-TeXRegistrations).Count -eq 0 -and -not (Test-TeXFootprint)) 'Disposable VM starts without MiKTeX'
    $otherPrograms = @(Get-OtherPrograms)
    $gitPath = (Get-Command git.exe -ErrorAction Stop).Source
    $gitHash = (Get-FileHash -LiteralPath $gitPath -Algorithm SHA256).Hash
    $document = Join-Path $testDir 'keep.tex'
    '\documentclass{article}\begin{document}Native Windows test.\end{document}' |
        Set-Content -LiteralPath $document -Encoding ASCII
    $documentHash = (Get-FileHash -LiteralPath $document -Algorithm SHA256).Hash
    Stage 'Removal before installation'
    Remove-TeX
    Remove-TeXManager
    Check (-not (Test-Path -LiteralPath (Get-TeXRecordPath))) 'Early remove creates no TeX record'
    Check (-not (Test-Path -LiteralPath (Get-TeXManagerPath))) 'Early remove creates no manager record'

    if ($Scenario -eq 'manager-new') {
        Stage 'Create a missing-WinGet fixture in this disposable VM only'
        $fixtureApps = @(Get-TeXManagerPackages)
        if ($fixtureApps.Count -gt 0) {
            $fixtureIdentity = Get-TeXManagerIdentity $fixtureApps
            Check (-not $fixtureApps[0].NonRemovable) 'VM App Installer allows current-user removal'
            Remove-AppxPackage -Package $fixtureIdentity.PackageFullName -ErrorAction Stop
        }
        Check (@(Get-TeXManagerPackages).Count -eq 0 -and -not (Test-TeXManagerCommand)) 'Missing-WinGet fixture has no App Installer or winget command'
        Stage 'Real installation of previously absent WinGet'
        Initialize-TeXManager { Invoke-Expression (Invoke-RestMethod "$base/win.ps1") }
        $managerRecord = Read-TeXManagerRecord (Get-TeXManagerPath)
        Check ($managerRecord.status -eq 'complete' -and $managerRecord.baseline -eq 'absent') 'New WinGet recorded as newly installed'
        Check (@(Get-TeXManagerPackages).Count -eq 1 -and (Test-TeXManagerCommand)) 'New WinGet is actually installed'
        Stage 'Real removal of newly installed WinGet'
        Remove-TeXManager
        Check (@(Get-TeXManagerPackages).Count -eq 0) 'New WinGet App Installer removed'
        Check (-not (Test-Path -LiteralPath (Get-TeXManagerPath))) 'Manager record removed after successful uninstall'
    } else {
    if ($Scenario -eq 'existing') {
        Stage 'Create a real preexisting MiKTeX fixture, outside the tracker'
        Invoke-Expression (Invoke-RestMethod "$base/win.ps1")
        winget install --id MiKTeX.MiKTeX -e --scope user -s winget
        Check ($LASTEXITCODE -eq 0) 'Independent fixture installation succeeds'
        Check (@(Get-TeXRegistrations).Count -eq 1) 'Preexisting fixture registered by real installer'
    }
    if ($Scenario -eq 'legacy') {
        Stage 'Real tracked installation from the old PDF implementation'
        Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/4b150e1bdc045cb8aeabdfc646abf63f409eb389/track.ps1')
        Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
        [void](Check-TeXExecutable)
        Invoke-Expression $tracker
    }
    $managerBefore = @(Get-TeXManagerPackages)
    $managerWasPresent = $managerBefore.Count -gt 0 -or (Test-TeXManagerCommand)
    Write-Host "WinGet/App Installer already present before tracked setup: $managerWasPresent"
    Stage 'Exact PDF installation command'
    Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
    $record = Read-TeXRecord (Get-TeXRecordPath)
    Write-Host ('Saved registration: ' + ($record.registration | ConvertTo-Json -Compress))
    Write-Host ('Current registration: ' + (@(Get-TeXRegistrations) | ConvertTo-Json -Compress))
    Write-Host "Saved fingerprint: $($record.fingerprint)"
    Write-Host "Current fingerprint: $(Get-TeXInventory -Stable:($record.inventoryVersion -eq 2))"
    $shell = New-Object -ComObject WScript.Shell
    foreach ($programs in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'))) {
        Get-ChildItem -LiteralPath $programs -Filter '*TeX*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "Shortcut: $($_.FullName) -> $($shell.CreateShortcut($_.FullName).TargetPath)"
        }
    }
    Check ($record.status -eq 'complete') 'Native installation and update complete'
    if ($Scenario -eq 'legacy') {
        Check ($record.baseline -in @('present','absent')) 'Old setup repaired without assuming unverifiable ownership'
    } else {
        Check ($record.baseline -eq $(if ($Scenario -eq 'existing') {'present'} else {'absent'})) 'MiKTeX provenance matches real initial state'
    }
    $managerRecord = Read-TeXManagerRecord (Get-TeXManagerPath)
    Check ($managerRecord.status -eq 'complete') 'Native manager bootstrap complete'
    Check ($managerRecord.baseline -eq $(if ($managerWasPresent) {'present'} else {'absent'})) 'WinGet provenance matches real initial state'
    $inventoryBefore = @(Get-InventoryRows)
    $compiler = Check-TeXExecutable
    $editor = Join-Path (Split-Path -Parent $compiler) 'miktex-texworks.exe'
    $inventoryAfter = @(Get-InventoryRows)
    $inventoryDiff = @(Compare-Object $inventoryBefore $inventoryAfter)
    Write-Host "Inventory differences after pdfLaTeX --version: $($inventoryDiff.Count)"
    $inventoryDiff | Select-Object -First 30 | Format-Table -AutoSize | Out-Host
    Part 'Repair a missing shortcut on repeated setup' {
        $shortcut = Find-TeXEditorShortcut $editor
        Check ([bool]$shortcut) 'First setup created a valid Start menu entry'
        Remove-Item -LiteralPath $shortcut -Force
        Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
        Check-EditorLaunch
    }
    Part 'Compile a real minimal document' {
        & $compiler --disable-installer --interaction=nonstopmode --halt-on-error "--output-directory=$testDir" $document | Out-Host
        Check ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $testDir 'keep.pdf'))) 'Real document compiles to PDF'
    }
    Part 'Repeat the unchanged installation command' {
        Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
        Check ((Read-TeXRecord (Get-TeXRecordPath)).baseline -eq $record.baseline) 'Repeat update preserves original ownership'
    }
    Part 'Native TeX removal' {
    Remove-TeX
    if ($record.baseline -eq 'absent') {
        Check (@(Get-TeXRegistrations).Count -eq 0) 'New MiKTeX registration removed'
        Check (-not (Test-Path -LiteralPath $compiler)) 'New MiKTeX compiler removed'
        Check (-not (Find-TeXEditorShortcut $editor)) 'Owned TeXworks shortcut removed'
    } else {
        Check (@(Get-TeXRegistrations).Count -eq 1) 'Preexisting MiKTeX remains registered'
        [void](Check-TeXExecutable)
    }
    Check (-not (Test-Path -LiteralPath (Get-TeXRecordPath))) 'Completed TeX record removed'
    Check (Test-Path -LiteralPath (Get-TeXManagerPath)) 'Manager evidence survives TeX removal'
    }
    Part 'Native package-manager removal' {
    Remove-TeXManager
    if ($managerWasPresent) {
        Check (@(Get-TeXManagerPackages).Count -gt 0 -and (Test-TeXManagerCommand)) 'Preexisting WinGet and updates retained'
    } else {
        Check (@(Get-TeXManagerPackages).Count -eq 0) 'New WinGet App Installer removed'
        Check (-not (Test-Path -LiteralPath (Get-TeXManagerPath))) 'Manager record removed after successful uninstall'
    }
    }
    }
    Part 'Unrelated programs and own documents' {
    $afterPrograms = @(Get-OtherPrograms)
    Check (@($otherPrograms | Where-Object { $_ -notin $afterPrograms }).Count -eq 0) 'All preexisting unrelated program registrations retained'
    Check ((Get-FileHash -LiteralPath $gitPath -Algorithm SHA256).Hash -eq $gitHash) 'Preexisting Git executable unchanged'
    Check ((Get-FileHash -LiteralPath $document -Algorithm SHA256).Hash -eq $documentHash) 'Own TeX document unchanged'
    }
    if (-not $script:failed) { Write-Host 'NATIVE TEST COMPLETED SUCCESSFULLY' }
} catch {
    Record-Failure $_
} finally {
    if ($env:GITHUB_STEP_SUMMARY) {
        @("## Native Windows test: $Scenario", "Tested script commit: $testedRef", '',
          ($script:checks | ForEach-Object { '- ' + $_ }), '',
          'Real programs, Start menu links, GUI startup and registry, no mocks. Interactive editing and every private-PC configuration are not covered.') |
            Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
}
if ($script:failed) { exit 1 }
