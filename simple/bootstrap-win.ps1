# Make winget available in the current PowerShell after successful setup.
# Only WinGet is installed/updated here, never a TeX distribution.
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
        $bundle = Join-Path $download 'AppInstaller.msixbundle'
        $archive = Join-Path $download 'Dependencies.zip'
        Invoke-WebRequest -UseBasicParsing -Uri ($release + 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle') -OutFile $bundle -ErrorAction Stop
        Invoke-WebRequest -UseBasicParsing -Uri ($release + 'DesktopAppInstaller_Dependencies.zip') -OutFile $archive -ErrorAction Stop
        $dependencies = Join-Path $download 'Dependencies'
        Expand-Archive -LiteralPath $archive -DestinationPath $dependencies -ErrorAction Stop
        $folder = switch ($Architecture) { 'AMD64' {'x64'} 'ARM64' {'arm64'} 'x86' {'x86'} default { throw 'Unbekannte Windows-Architektur.' } }
        $packages = @(Get-ChildItem -LiteralPath (Join-Path $dependencies $folder) -File -Recurse |
            Where-Object { $_.Extension -in @('.appx','.msix') } | ForEach-Object FullName)
        if ($packages.Count -eq 0) { throw 'WinGet-Abhaengigkeiten fehlen.' }
        Add-AppxPackage -Path $bundle -DependencyPath $packages -ErrorAction Stop
    } finally {
        # Only the unique temporary download created above, never user folders.
        Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction Stop
    }
}
& {
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Dieses Skript ist nur fuer Windows.' }
    if ([Environment]::OSVersion.Version.Build -lt 17763) {
        throw 'Windows 10 ab Version 1809 oder Windows 11 wird benoetigt.'
    }
    Write-Host 'WinGet wird eingerichtet bzw. aktualisiert ...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
    Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force
    Import-Module Microsoft.WinGet.Client -Force
    try {
        Repair-WinGetPackageManager -Latest -ErrorAction Stop | Out-Null
    } catch {
        Write-Host 'WinGet wird ueber das offizielle Microsoft-Installationspaket eingerichtet ...'
        Install-TeXWinGetRelease
    }
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
    $env:Path = (Split-Path -Parent $wg) + ';' + $env:Path
}
