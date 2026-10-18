# Real lifecycle test. Never run on a private workstation.
param([ValidateSet('fresh','legacy','publisher-refused')][string]$Scenario='fresh')
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
if ($Scenario -in @('legacy','publisher-refused')) {
    Invoke-Expression ($commands.windows -split "`n")[0]
    winget install --id MiKTeX.MiKTeX -e --scope user -s winget
    Check ($LASTEXITCODE -eq 0) 'Old direct install succeeds'
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link }
    Check (-not (Test-Path $link)) 'Missing Start-menu entry reproduced'
}
$refusalHost=$null; $testShell=$null
if ($Scenario -eq 'publisher-refused') {
    # Real signed-module prompt; test host chooses its default "Do not run".
    # No certificate-store edits, no mocked Import-Module, disposable VM only.
    $module=Get-Module Microsoft.WinGet.Client -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    $format=Join-Path $module.ModuleBase 'Format.ps1xml'
    $signature=Get-AuthenticodeSignature -FilePath $format
    Check ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -like '*CN=Microsoft Corporation*') 'Genuine Microsoft-signed Format.ps1xml'
    foreach ($store in @('Cert:\CurrentUser\TrustedPublisher','Cert:\LocalMachine\TrustedPublisher')) {
        $trusted=Join-Path $store $signature.SignerCertificate.Thumbprint
        Check (-not (Test-Path -LiteralPath $trusted)) 'Publisher not pre-trusted; certificate store unchanged'
    }
    Add-Type -Path (Join-Path $PSScriptRoot 'test-publisher-host.cs')
    $refusalHost=New-Object PublisherRefusalHost($Host)
    $testShell=[powershell]::Create()
    $testShell.Runspace=[runspacefactory]::CreateRunspace($refusalHost)
    # Match Windows PowerShell's normal STA console for Windows Appx/COM.
    $testShell.Runspace.ApartmentState='STA'
    $testShell.Runspace.ThreadOptions='ReuseThread'
    $testShell.Runspace.Open()
    [void]$testShell.AddScript('Import-Module PackageManagement; Import-Module PowerShellGet')
    [void]$testShell.Invoke()
    Check ($testShell.Streams.Error.Count -eq 0) 'Publisher-test prerequisites loaded'
    $testShell.Commands.Clear()
    $previousPolicy=Get-ExecutionPolicy -Scope Process
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy AllSigned -Force
}
try {
for ($pass=1;$pass -le 2;$pass++) {
    Write-Host "STAGE install/update/repair $pass"
    if ($testShell) {
        # Only the first PDF line needs a custom host to answer its prompt.
        # Run native MiKTeX in the normal ConsoleHost, just like the PDF:
        # a custom runspace redirects native stderr and changes PS5 behavior.
        $lines=$commands.windows -split "\r?\n",2
        [void]$testShell.AddScript($lines[0])
        $testShell.Invoke() | Out-Host
        if ($testShell.Streams.Error.Count) { throw ($testShell.Streams.Error | Out-String) }
        $testShell.Commands.Clear()
        Check ($refusalHost.RefusalUI.Denials -ge $pass) "Actual Format.ps1xml publisher prompt declined, pass $pass"
        Check ((Get-ExecutionPolicy -Scope Process) -eq 'AllSigned') "Security policy unchanged, pass $pass"
        [void]$testShell.AddScript('(Get-Command Update-TeX).Definition')
        $definition=$testShell.Invoke()
        $testShell.Commands.Clear()
        Check ($definition[0].ToString() -eq (Get-Command Update-TeX).Definition) 'Same published Update-TeX in both hosts'
        Invoke-Expression $lines[1]
    } else {
        Invoke-Expression $commands.windows
    }
    Check (Test-Path $editor) "Editor exists, pass $pass"
    Check ((New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath -eq $editor) "Start menu repaired, pass $pass"
    & (Join-Path $bin 'miktex.exe') packages check-update
    Check ($LASTEXITCODE -eq 0) "Packages current, pass $pass"
}
} finally {
    if ($testShell) {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy $previousPolicy -Force
        $testShell.Runspace.Dispose(); $testShell.Dispose()
    }
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
