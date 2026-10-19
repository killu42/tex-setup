# Make winget available in the current PowerShell after successful setup.
# Loading only prepares WinGet; Update-TeX runs after the explicit winget install.
function Update-TeX {
    # --no-upgrade leaves existing MiKTeX to its own updater, including core updates.
    $installExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    if ($null -eq $installExit -or $installExit -notin @(0, -1978335135, -1978335189)) {
        throw "MiKTeX-Installation fehlgeschlagen ($installExit)."
    }
    $apps = @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object DisplayName -Like '*MiKTeX*')
    if ($apps.Count -ne 1) { throw 'Keine eindeutige MiKTeX-Benutzerinstallation gefunden.' }
    $root = $apps[0].InstallLocation
    if (-not $root) { $root = Join-Path $env:LOCALAPPDATA 'Programs\MiKTeX' }
    $files = @('miktex\bin\x64\miktex.exe','miktex\bin\miktex.exe' |
        ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($files.Count -ne 1) { throw 'MiKTeX-Updater fehlt oder ist nicht eindeutig.' }
    $miktex = $files[0]
    $bin = Split-Path -Parent $miktex
    function Invoke-MiKTeX([string[]]$Arguments) {
        & $miktex @Arguments | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "MiKTeX fehlgeschlagen: $Arguments ($LASTEXITCODE)." }
    }
    for ($pass = 0; $pass -lt 3; $pass++) {
        Invoke-MiKTeX @('packages','update-package-database')
        Invoke-MiKTeX @('packages','update')
        # A mirror timeout must not turn a completed update into an immediate failure.
        for ($retry = 0; $retry -lt 3; $retry++) {
            & $miktex packages check-update | Out-Host
            if ($LASTEXITCODE -in @(0,100)) { break }
        }
        if ($LASTEXITCODE -eq 0) { break }
        if ($LASTEXITCODE -ne 100 -or $pass -eq 2) { throw 'MiKTeX-Updates nicht abgeschlossen.' }
    }
    $editor = Join-Path $bin 'miktex-texworks.exe'
    if (-not (Test-Path -LiteralPath $editor -PathType Leaf)) {
        $package = if ((Split-Path -Leaf $bin) -eq 'x64') { 'miktex-texworks-bin-x64-2.9' } else { 'miktex-texworks-bin-2.9' }
        Invoke-MiKTeX @('packages','install',$package)
    }
    if (-not (Test-Path -LiteralPath $editor -PathType Leaf)) { throw 'TeXworks fehlt nach der Reparatur.' }
    # Use MiKTeX's own Start-menu folder, which its uninstaller already manages.
    $folder = Join-Path ([Environment]::GetFolderPath('Programs')) 'MiKTeX'
    [void][IO.Directory]::CreateDirectory($folder)
    $path = Join-Path $folder 'TeXworks.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($path)
    if ((Test-Path -LiteralPath $path) -and $link.TargetPath -ine $editor) {
        throw 'Eine andere TeXworks-Verknuepfung bleibt unveraendert.'
    }
    $link.TargetPath = $editor
    $link.WorkingDirectory = [Environment]::GetFolderPath('MyDocuments')
    $link.Save()
    if ($shell.CreateShortcut($path).TargetPath -ine $editor) { throw 'Startmenue-Eintrag fehlt.' }
    $env:Path = $bin + ';' + $env:Path
    $global:LASTEXITCODE = 0
    Write-Host 'MiKTeX aktualisiert; TeXworks ist im Startmenue bereit.'
}
function Install-TeXWinGetRelease {
    param([string]$Architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE','Machine'))
    # Local only: PowerShell 5's per-chunk progress rendering slows large files.
    $ProgressPreference = 'SilentlyContinue'
    # Microsoft's signed release assets are also the documented offline route.
    # Appx performs publisher/signature/dependency checks; no policy bypass.
    $release = 'https://github.com/microsoft/winget-cli/releases/latest/download/'
    $download = Join-Path ([IO.Path]::GetTempPath()) ('tex-winget-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($download)
    try {
        $folder = switch ($Architecture) { 'AMD64' {'x64'} 'ARM64' {'arm64'} 'x86' {'x86'} default { throw 'Unbekannte Windows-Architektur.' } }
        $bundle = Join-Path $download 'AppInstaller.msixbundle'
        $archive = Join-Path $download 'Dependencies.zip'
        Invoke-WebRequest -UseBasicParsing -Uri ($release + 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle') -OutFile $bundle -ErrorAction Stop
        # Compare the actual app package, not the date-numbered bundle or stub.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($bundle)
        try {
            $reader = [IO.StreamReader]::new($zip.GetEntry('AppxMetadata/AppxBundleManifest.xml').Open())
            try {
                $package = ([xml]$reader.ReadToEnd()).Bundle.Packages.Package | Where-Object {
                    $_.Type -eq 'application' -and $_.Architecture -eq $folder -and $_.IsStub -ne 'true'
                } | Select-Object -First 1
                $version = [version]$package.Version
                if (-not $version) { throw 'WinGet-Paketversion fehlt.' }
            }
            finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
        $installed = Get-AppxPackage Microsoft.DesktopAppInstaller | Sort-Object Version -Descending | Select-Object -First 1
        if ($installed -and [version]$installed.Version -ge $version -and $installed.Status -eq 'Ok') { return }
        # Reuse sufficient Windows frameworks; do not reinstall ones in use.
        try { Add-AppxPackage -Path $bundle -ErrorAction Stop; return }
        catch { if ($_ -notmatch '0x80073CF3') { throw } }
        # Only a missing/conflicting dependency triggers the dependency package route.
        Invoke-WebRequest -UseBasicParsing -Uri ($release + 'DesktopAppInstaller_Dependencies.zip') -OutFile $archive -ErrorAction Stop
        $dependencies = Join-Path $download 'Dependencies'
        Expand-Archive -LiteralPath $archive -DestinationPath $dependencies -ErrorAction Stop
        $packages = @(Get-ChildItem -LiteralPath (Join-Path $dependencies $folder) -File -Recurse |
            Where-Object { $_.Extension -in @('.appx','.msix') } | ForEach-Object FullName)
        if ($packages.Count -eq 0) { throw 'WinGet-Abhaengigkeiten fehlen.' }
        Add-AppxPackage -Path $bundle -DependencyPath $packages -ErrorAction Stop
    } finally {
        # Only the unique temporary download created above, never user folders.
        Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction Stop
    }
}
function Repair-TeXWinGetLicense {
    # Microsoft provisions the signed bundle with its matching official offline license.
    # Only this repair is elevated; MiKTeX stays in the original user's account.
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        $code = 'function Repair-TeXWinGetLicense {' + ${function:Repair-TeXWinGetLicense}.ToString() +
            '}; try { Repair-TeXWinGetLicense; exit 0 } catch { Write-Error $_; exit 1 }'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            $hostExe = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        }
        Write-Host 'Windows benoetigt zur WinGet-Lizenzreparatur die Administratorbestaetigung.'
        $process = Start-Process $hostExe -Verb RunAs -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw 'WinGet-Lizenzreparatur fehlgeschlagen.' }
        return
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Public download pages avoid the unauthenticated GitHub API's shared-IP limit.
    $page = Invoke-WebRequest -UseBasicParsing 'https://github.com/microsoft/winget-cli/releases/latest' -ErrorAction Stop
    $uri = $page.BaseResponse.ResponseUri
    if (-not $uri) { $uri = $page.BaseResponse.RequestMessage.RequestUri }
    $tag = ($uri.AbsolutePath -split '/')[-1]
    if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Microsoft-Releaseversion konnte nicht ermittelt werden.' }
    $assets = Invoke-WebRequest -UseBasicParsing ("https://github.com/microsoft/winget-cli/releases/expanded_assets/$tag") -ErrorAction Stop
    $prefix = "/microsoft/winget-cli/releases/download/$tag/"
    $license = @($assets.Links.href | Where-Object { $_.StartsWith($prefix) -and $_ -match '/[a-zA-Z0-9_]+License1\.xml$' } | Select-Object -Unique)
    if ($license.Count -ne 1) { throw 'Microsoft-Lizenzdatei fehlt.' }
    $download = Join-Path ([IO.Path]::GetTempPath()) ('tex-winget-license-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($download)
    try {
        $packagePath = Join-Path $download 'AppInstaller.msixbundle'
        $licensePath = Join-Path $download 'License.xml'
        Invoke-WebRequest -UseBasicParsing ("https://github.com${prefix}Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle") -OutFile $packagePath -ErrorAction Stop
        Invoke-WebRequest -UseBasicParsing ("https://github.com" + $license[0]) -OutFile $licensePath -ErrorAction Stop
        Add-AppxProvisionedPackage -Online -PackagePath $packagePath -LicensePath $licensePath -ErrorAction Stop | Out-Null
    } finally {
        Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction Stop
    }
}
function Get-TeXWinGet {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    $wg = if ($cmd) { $cmd.Source } else { $null }
    if (-not $wg) {
        $app = Get-AppxPackage Microsoft.DesktopAppInstaller |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($app) { $wg = Join-Path $app.InstallLocation 'winget.exe' }
    }
    if (-not $wg -or -not (Test-Path -LiteralPath $wg -PathType Leaf)) {
        throw 'WinGet konnte nicht eingerichtet werden.'
    }
    & $wg --version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'WinGet kann nicht gestartet werden.' }
    return $wg
}
& {
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Dieses Skript ist nur fuer Windows.' }
    if ([Environment]::OSVersion.Version.Build -lt 17763) {
        throw 'Windows 10 ab Version 1809 oder Windows 11 wird benoetigt.'
    }
    Write-Host 'WinGet wird eingerichtet bzw. aktualisiert ...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        Install-TeXWinGetRelease
    } catch {
        Write-Host 'Direkter Download/Installation fehlgeschlagen; Microsoft-Modul wird als Alternative verwendet ...'
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force
        Import-Module Microsoft.WinGet.Client -Force
        Repair-WinGetPackageManager -Latest -ErrorAction Stop | Out-Null
    }
    try { $wg = Get-TeXWinGet }
    catch [System.Management.Automation.ApplicationFailedException] {
        Write-Host 'WinGet ist installiert, startet aber nicht. Microsoft-App-Lizenz wird repariert ...'
        Write-Host $_.Exception.Message
        Repair-TeXWinGetLicense
        # Register again in the original account, even if UAC used another administrator.
        $app = Get-AppxPackage Microsoft.DesktopAppInstaller |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($app) { Add-AppxPackage -Register (Join-Path $app.InstallLocation 'AppxManifest.xml') -DisableDevelopmentMode -ErrorAction Stop }
        $wg = Get-TeXWinGet
    }
    $env:Path = (Split-Path -Parent $wg) + ';' + $env:Path
}
