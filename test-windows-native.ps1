# REAL installation/removal test. Run only on a disposable GitHub-hosted VM.
param([ValidateSet('fresh','existing','manager-new')][string]$Scenario = 'fresh')
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -ne 'true' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'killu42/tex-setup') {
    throw 'This native test is restricted to disposable GitHub-hosted Windows VMs.'
}
$testedRef = '4b150e1bdc045cb8aeabdfc646abf63f409eb389'
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
$failed = $false
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "OS: $($os.Caption); build $($os.BuildNumber); architecture $env:PROCESSOR_ARCHITECTURE"
    Write-Host "Scenario: $Scenario; tested script commit: $testedRef; PowerShell $($PSVersionTable.PSVersion)"
    $tracker = Invoke-RestMethod "$base/track.ps1"
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
    $managerBefore = @(Get-TeXManagerPackages)
    $managerWasPresent = $managerBefore.Count -gt 0 -or (Test-TeXManagerCommand)
    Write-Host "WinGet/App Installer already present before tracked setup: $managerWasPresent"
    Stage 'Exact PDF installation command'
    Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
    $record = Read-TeXRecord (Get-TeXRecordPath)
    Check ($record.status -eq 'complete') 'Native installation and update complete'
    Check ($record.baseline -eq $(if ($Scenario -eq 'existing') {'present'} else {'absent'})) 'MiKTeX provenance matches real initial state'
    $managerRecord = Read-TeXManagerRecord (Get-TeXManagerPath)
    Check ($managerRecord.status -eq 'complete') 'Native manager bootstrap complete'
    Check ($managerRecord.baseline -eq $(if ($managerWasPresent) {'present'} else {'absent'})) 'WinGet provenance matches real initial state'
    $compiler = Check-TeXExecutable
    Stage 'Repeat the unchanged installation command'
    Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
    Check ((Read-TeXRecord (Get-TeXRecordPath)).baseline -eq $record.baseline) 'Repeat update preserves original ownership'
    Stage 'Compile a real minimal document'
    & $compiler --disable-installer --interaction=nonstopmode --halt-on-error "--output-directory=$testDir" $document | Out-Host
    Check ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $testDir 'keep.pdf'))) 'Real document compiles to PDF'
    Stage 'Native TeX removal'
    Remove-TeX
    if ($Scenario -eq 'fresh') {
        Check (@(Get-TeXRegistrations).Count -eq 0) 'New MiKTeX registration removed'
        Check (-not (Test-Path -LiteralPath $compiler)) 'New MiKTeX compiler removed'
    } else {
        Check (@(Get-TeXRegistrations).Count -eq 1) 'Preexisting MiKTeX remains registered'
        [void](Check-TeXExecutable)
    }
    Check (-not (Test-Path -LiteralPath (Get-TeXRecordPath))) 'Completed TeX record removed'
    Check (Test-Path -LiteralPath (Get-TeXManagerPath)) 'Manager evidence survives TeX removal'
    Stage 'Native package-manager removal'
    Remove-TeXManager
    if ($managerWasPresent) {
        Check (@(Get-TeXManagerPackages).Count -gt 0 -and (Test-TeXManagerCommand)) 'Preexisting WinGet and updates retained'
    } else {
        Check (@(Get-TeXManagerPackages).Count -eq 0) 'New WinGet App Installer removed'
        Check (-not (Test-Path -LiteralPath (Get-TeXManagerPath))) 'Manager record removed after successful uninstall'
    }
    }
    Stage 'Unrelated programs and own documents'
    $afterPrograms = @(Get-OtherPrograms)
    Check (@($otherPrograms | Where-Object { $_ -notin $afterPrograms }).Count -eq 0) 'All preexisting unrelated program registrations retained'
    Check ((Get-FileHash -LiteralPath $gitPath -Algorithm SHA256).Hash -eq $gitHash) 'Preexisting Git executable unchanged'
    Check ((Get-FileHash -LiteralPath $document -Algorithm SHA256).Hash -eq $documentHash) 'Own TeX document unchanged'
    Write-Host 'NATIVE TEST COMPLETED SUCCESSFULLY'
} catch {
    $failed = $true
    $script:checks.Add("FAIL at $script:stage : $($_.Exception.Message)")
    Write-Host "::error::Native test failed at $script:stage : $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
} finally {
    if ($env:GITHUB_STEP_SUMMARY) {
        @("## Native Windows test: $Scenario", "Tested script commit: $testedRef", '',
          ($script:checks | ForEach-Object { '- ' + $_ }), '',
          'Real programs and registry, no mocks. GUI interactions and all possible private-PC configurations are not covered.') |
            Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
}
if ($failed) { exit 1 }
