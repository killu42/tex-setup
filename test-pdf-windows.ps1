# Real lifecycle test. Never run on a private workstation.
param([ValidateSet('fresh','legacy','no-winget')][string]$Scenario='fresh')
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -ne 'true' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'killu42/tex-setup') {
    throw 'Disposable GitHub-hosted Windows VM required.'
}
$commands=Get-Content (Join-Path $PSScriptRoot 'pdf-commands.json') -Raw | ConvertFrom-Json
function Check($ok,$message) { if (-not $ok) {throw $message}; Write-Host "PASS $message" }
$root=Join-Path $env:LOCALAPPDATA 'Programs\MiKTeX'
$bin=Join-Path $root 'miktex\bin\x64'
$editor=Join-Path $bin 'miktex-texworks.exe'
$link=Join-Path ([Environment]::GetFolderPath('Programs')) 'MiKTeX\TeXworks.lnk'
Check (-not (Test-Path $root)) 'Clean MiKTeX baseline'
$git=(Get-Command git.exe).Source; $gitHash=(Get-FileHash $git).Hash
$work=Join-Path $env:RUNNER_TEMP ('tex-pdf-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($work)
$doc=Join-Path $work 'keep.tex'
'\documentclass{article}\begin{document}Test.\end{document}' | Set-Content $doc -Encoding ASCII
$docHash=(Get-FileHash $doc).Hash
# Current-user package only, on the explicitly guarded disposable runner.
$baselineApp=Get-AppxPackage Microsoft.DesktopAppInstaller
$oldVersion=$null
if ($Scenario -eq 'no-winget') {
    # A genuine absent baseline: never downgrade this test to an update test.
    Check (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) 'No WinGet command before setup'
    Check (@(Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller).Count -eq 0) 'No App Installer package for any user before setup'
    Check (@(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller').Count -eq 0) 'No provisioned App Installer before setup'
} elseif ($baselineApp.NonRemovable) {
    $oldVersion=[version]$baselineApp.Version
    Write-Host "Windows system component cannot be removed: test real WinGet update from $oldVersion instead."
} else {
    $baselineApp | Remove-AppxPackage -ErrorAction Stop
    Check (@(Get-AppxPackage Microsoft.DesktopAppInstaller).Count -eq 0) 'No registered WinGet before setup'
}
$modulesBefore=@(Get-Module Microsoft.WinGet.Client -ListAvailable | ForEach-Object Path) -join '|'
$loadedBefore=@(Get-Module Microsoft.WinGet.Client).Count
$policyBefore=Get-ExecutionPolicy -Scope Process
if ($Scenario -eq 'legacy') {
    # Prepare a genuine older signed Microsoft release, not a mocked update.
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'win.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors) { throw ($errors | Out-String) }
    $installer=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-TeXWinGetRelease'},$false)
    & ([scriptblock]::Create($installer.Extent.Text.Replace('/releases/latest/download/','/releases/download/v1.29.290/') + "`nInstall-TeXWinGetRelease"))
    $app=Get-AppxPackage Microsoft.DesktopAppInstaller
    $oldVersion=[version]$app.Version
    $env:Path=$app.InstallLocation+';'+$env:Path
    & (Join-Path $app.InstallLocation 'winget.exe') install --id MiKTeX.MiKTeX -e --scope user -s winget
    Check ($LASTEXITCODE -eq 0) 'Old direct install succeeds'
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link }
    Check (-not (Test-Path $link)) 'Missing Start-menu entry reproduced'
}
for ($pass=1;$pass -le 2;$pass++) {
    Write-Host "STAGE install/update/repair $pass"
    Invoke-Expression $commands.windows
    $version=[version](Get-AppxPackage Microsoft.DesktopAppInstaller).Version
    Write-Host "WinGet package: $version (baseline: $oldVersion)"
    if ($oldVersion) { Check ($version -gt $oldVersion) 'Existing older WinGet updated' }
    Check ((@(Get-Module Microsoft.WinGet.Client -ListAvailable | ForEach-Object Path) -join '|') -eq $modulesBefore) 'No WinGet PowerShell module installed or updated'
    Check (@(Get-Module Microsoft.WinGet.Client).Count -eq $loadedBefore) 'No WinGet PowerShell module loaded'
    Check ((Get-ExecutionPolicy -Scope Process) -eq $policyBefore) 'Security policy unchanged'
    Check (Test-Path $editor) "Editor exists, pass $pass"
    Check ((New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath -eq $editor) "Start menu repaired, pass $pass"
    & (Join-Path $bin 'miktex.exe') packages check-update
    Check ($LASTEXITCODE -eq 0) "Packages current, pass $pass"
}
$p=Start-Process $editor -PassThru
try {
    Start-Sleep 5
    Check (@(Get-Process -Name '*texworks*' -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0).Count -gt 0) 'Editor GUI starts'
} finally {
    foreach ($p in @(Get-Process -Name '*texworks*' -ErrorAction SilentlyContinue | Where-Object Path -eq $editor)) {
        [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(10000)) { $p.Kill() }
    }
}
& (Join-Path $bin 'pdflatex.exe') --interaction=nonstopmode --halt-on-error --output-directory=$work $doc
Check ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $work 'keep.pdf'))) 'Actual PDF compiles'
# Run the exact removal line; automation only supplies the confirmations described in the PDF.
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commands.windows_remove))
$remove=Start-Process powershell.exe -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -PassThru
$deadline=[DateTime]::UtcNow.AddMinutes(5)
$confirmed=@{}
do {
    $desktop=[Windows.Automation.AutomationElement]::RootElement
    foreach ($console in @(Get-Process -Name '*miktex-console*' -ErrorAction SilentlyContinue)) {
        $windows=$desktop.FindAll([Windows.Automation.TreeScope]::Children,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$console.Id))
        foreach ($window in $windows) {
            $buttons=$window.FindAll([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button))
            foreach ($button in $buttons) {
                $name=$button.Current.Name.Replace('&','')
                if ($button.Current.IsEnabled -and $name -in @('Remove MiKTeX','Yes') -and -not $confirmed[$name]) {
                    Write-Host "CONFIRM $name"
                    $pattern=$button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
                    $pattern.Invoke()
                    $confirmed[$name]=$true
                }
            }
        }
    }
    Start-Sleep 2
    $remaining=@(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object DisplayName -Like '*MiKTeX*')
    $removed= -not (Test-Path $editor) -and -not (Test-Path $link) -and $remaining.Count -eq 0
} while (-not $removed -and [DateTime]::UtcNow -lt $deadline)
Check (-not (Test-Path $editor)) 'Exact winget removal removes editor'
Check (-not (Test-Path $link)) 'Removal also removes repaired shortcut'
$apps=@(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' | Where-Object DisplayName -Like '*MiKTeX*')
Check ($apps.Count -eq 0) 'Distribution unregistered'
Invoke-Expression $commands.windows_remove
Write-Host "Repeated removal exit: $LASTEXITCODE (not installed is expected)"
winget --version
Check ($LASTEXITCODE -eq 0) 'WinGet retained'
Check ((Get-FileHash $git).Hash -eq $gitHash) 'Unrelated program retained'
Check ((Get-FileHash $doc).Hash -eq $docHash) 'Own document retained'
