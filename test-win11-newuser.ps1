# Disposable Windows 11 VM only. No protected package is removed or hidden.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -ne 'killu42/tex-setup' -or $env:TEST_REF -notmatch '^[a-f0-9]{40}$') {
    throw 'Disposable repository runner and explicit commit required.'
}
$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000) { throw 'Real Windows 11 desktop required.' }
Write-Host "OS: $($os.Caption), build $($os.BuildNumber), $($os.OSArchitecture)"
Get-CimInstance Win32_Processor | Select-Object Name,VirtualizationFirmwareEnabled,SecondLevelAddressTranslationExtensions | Format-List
try { Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM | Select-Object FeatureName,State | Format-List }
catch { Write-Host 'Windows Sandbox feature is not available on this runner.' }

$name = 'TeXPdf' + ([guid]::NewGuid().ToString('N').Substring(0,8))
$password = ConvertTo-SecureString ('TeX!' + [guid]::NewGuid().ToString('N') + 'aA7!') -AsPlainText -Force
$user = New-LocalUser -Name $name -Password $password -AccountExpires (Get-Date).AddHours(1) -Description 'Disposable TeX installation test'
Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
$work = Join-Path $env:RUNNER_TEMP ('tex-newuser-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($work)
$acl = Get-Acl -LiteralPath $work
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user.SID,'Modify','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl -LiteralPath $work -AclObject $acl
$child = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message }; Write-Host "PASS $Message" }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
Check ($identity.User.Value -eq '__SID__') 'Fresh test identity'
Check (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Standard user, not elevated'
# Start-Process must not inherit the runner's user paths. Use this profile's normal environment.
$profilePath = [Environment]::GetFolderPath('UserProfile')
Check ($profilePath -and (Split-Path -Leaf $profilePath) -eq '__NAME__') 'Own loaded Windows profile'
$env:USERPROFILE = $profilePath
$env:APPDATA = [Environment]::GetFolderPath('ApplicationData')
$env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
$env:TEMP = Join-Path $env:LOCALAPPDATA 'Temp'
$env:TMP = $env:TEMP
[void][IO.Directory]::CreateDirectory($env:TEMP)
$env:Path = [Environment]::ExpandEnvironmentVariables([Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User'))
Check (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) 'WinGet command absent before installation'
Check (@(Get-AppxPackage Microsoft.DesktopAppInstaller).Count -eq 0) 'No App Installer registered for this user'
Check (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))) 'No existing WinGet execution alias'
# A staged system package can remain: this is a fresh-user test, not a clean Windows image.
Write-Host 'BASELINE VERIFIED: no user WinGet, no masking or package removal'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$commands = Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/__REF__/pdf-commands.json'
$work = Join-Path $env:TEMP ('tex-document-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($work)
$doc = Join-Path $work 'keep.tex'
'\documentclass{article}\begin{document}Test.\end{document}' | Set-Content -LiteralPath $doc -Encoding ASCII
$hash = (Get-FileHash $doc).Hash
for ($pass = 1; $pass -le 2; $pass++) {
    Write-Host "STAGE exact PDF install, pass $pass"
    Invoke-Expression $commands.windows
    winget --version
    Check ($LASTEXITCODE -eq 0) "WinGet usable after pass $pass"
    $updater = Get-TeXUpdater @(Get-TeXRegistrations)
    $editor = Join-Path (Split-Path -Parent $updater.File) 'miktex-texworks.exe'
    Check (Test-Path -LiteralPath $editor) "Editor installed after pass $pass"
    Check ([bool](Find-TeXEditorShortcut $editor)) "Start-menu entry after pass $pass"
}
$compiler = Join-Path (Split-Path -Parent $updater.File) 'pdflatex.exe'
& $compiler --interaction=nonstopmode --halt-on-error --output-directory=$work $doc
Check ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $work 'keep.pdf'))) 'Actual PDF created'
Invoke-Expression $commands.windows_remove
Check (@(Get-TeXRegistrations).Count -eq 0 -and -not (Test-Path $editor)) 'Distribution and editor removed'
Invoke-Expression $commands.windows_remove
winget --version
Check ($LASTEXITCODE -eq 0) 'WinGet retained'
Check ((Get-FileHash $doc).Hash -eq $hash) 'Own document retained'
Write-Host 'PASS complete Windows 11 fresh-user lifecycle without initial WinGet'
'@
$child = $child.Replace('__SID__',$user.SID.Value).Replace('__NAME__',$name).Replace('__REF__',$env:TEST_REF)
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("try {`n" + $child + "`nexit 0`n} catch { Write-Error (`$_ | Out-String) -ErrorAction Continue; exit 1 }"))
$process = $null
try {
    $credential = [pscredential]::new("$env:COMPUTERNAME\$name",$password)
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -Credential $credential -LoadUserProfile -UseNewEnvironment -WorkingDirectory $work -PassThru -RedirectStandardOutput (Join-Path $work 'stdout.txt') -RedirectStandardError (Join-Path $work 'stderr.txt')
    $offset = 0
    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    do {
        Start-Sleep -Seconds 10
        $lines = @(Get-Content -LiteralPath (Join-Path $work 'stdout.txt') -ErrorAction SilentlyContinue)
        $lines | Select-Object -Skip $offset | ForEach-Object { Write-Host $_ }
        $offset = $lines.Count
        $process.Refresh()
    } until ($process.HasExited -or [DateTime]::UtcNow -gt $deadline)
    if (-not $process.HasExited) { throw 'Fresh-user test timed out.' }
    $process.WaitForExit()
    Get-Content -LiteralPath (Join-Path $work 'stderr.txt') -ErrorAction SilentlyContinue | Write-Host
    if ($process.ExitCode -ne 0) { throw "Fresh-user test failed: $($process.ExitCode)" }
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-LocalUser -SID $user.SID
}
