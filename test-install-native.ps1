# Real software test: disposable GitHub-hosted Windows runners only.
param([ValidateSet('fresh','legacy')][string]$Scenario='fresh')
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -ne 'true' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'killu42/tex-setup') {
    throw 'Disposable GitHub-hosted Windows VM required.'
}
if ($env:TEST_REF -notmatch '^[a-f0-9]{40}$') { throw 'Explicit tested commit required.' }
$base="https://raw.githubusercontent.com/killu42/tex-setup/$env:TEST_REF"
$code=(Invoke-RestMethod "$base/install.ps1").Replace('https://raw.githubusercontent.com/killu42/tex-setup/main/',"$base/")
Invoke-Expression $code
function Check([bool]$Value,[string]$Message) { if (-not $Value) {throw $Message}; Write-Host "PASS: $Message" }
Check (@(Get-TeXRegistrations).Count -eq 0 -and -not (Test-TeXFootprint)) 'Runner starts without MiKTeX'
$git=(Get-Command git.exe).Source
$gitHash=(Get-FileHash $git).Hash
$work=Join-Path $env:RUNNER_TEMP ('tex-simple-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($work)
$doc=Join-Path $work 'keep.tex'
'\documentclass{article}\begin{document}Test.\end{document}' | Set-Content -LiteralPath $doc -Encoding ASCII
$hash=(Get-FileHash $doc).Hash
if ($Scenario -eq 'legacy') {
    # Reproduce the earlier PDF: ordinary per-user MiKTeX without our new repair.
    Invoke-Expression (Invoke-RestMethod "$base/win.ps1")
    winget install --id MiKTeX.MiKTeX -e --scope user -s winget
    Check ($LASTEXITCODE -eq 0) 'Legacy fixture installation succeeds'
    $updater=Get-TeXUpdater @(Get-TeXRegistrations)
    $editor=Join-Path (Split-Path -Parent $updater.File) 'miktex-texworks.exe'
    foreach ($folder in @(Get-TeXProgramsFolders)) {
        if (Test-Path -LiteralPath $folder) {
            foreach ($link in @(Get-ChildItem -LiteralPath $folder -Recurse -Filter '*TeXworks*.lnk')) {
                if ((Get-TeXShortcut $link.FullName).TargetPath -eq $editor) {
                    Remove-Item -LiteralPath $link.FullName -ErrorAction Stop
                }
            }
        }
    }
    Check (-not (Find-TeXEditorShortcut $editor)) 'Fixture has no matching Start-menu entry'
}
for ($pass=1;$pass -le 2;$pass++) {
    Write-Host "STAGE: install/update/repair pass $pass"
    Install-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }
    $updater=Get-TeXUpdater @(Get-TeXRegistrations)
    $editor=Join-Path (Split-Path -Parent $updater.File) 'miktex-texworks.exe'
    Check (Test-Path -LiteralPath $editor) "TeXworks installed after pass $pass"
    Check ([bool](Find-TeXEditorShortcut $editor)) "Matching Start-menu shortcut after pass $pass"
    Check ((Invoke-TeXPackageCommand $updater.File @('packages','check-update') @(0,100)) -eq 0) "No pending MiKTeX updates after pass $pass"
}
$editorProcess=Start-Process -FilePath $editor -PassThru
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    do {
        $windows=@(Get-Process -Name '*texworks*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $editor -and $_.MainWindowHandle -ne 0 })
        if ($windows.Count) {break}; Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($windows.Count -gt 0) 'TeXworks opens an actual GUI window'
} finally {
    foreach ($p in @(Get-Process -Name '*texworks*' -ErrorAction SilentlyContinue | Where-Object Path -eq $editor)) {
        [void]$p.CloseMainWindow()
        if (-not $p.WaitForExit(10000)) {Stop-Process -Id $p.Id -Force}
    }
}
$compiler=Join-Path (Split-Path -Parent $updater.File) 'pdflatex.exe'
& $compiler --interaction=nonstopmode --halt-on-error --output-directory=$work $doc
Check ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $work 'keep.pdf'))) 'Actual document compiles'
winget --version
Check ($LASTEXITCODE -eq 0) 'WinGet remains usable'
Check ((Get-FileHash $git).Hash -eq $gitHash) 'Unrelated program unchanged'
Check ((Get-FileHash $doc).Hash -eq $hash) 'Own document unchanged'
Write-Host "PASS: native install/update/editor repair ($Scenario)"
