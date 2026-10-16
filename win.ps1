# Return the executable path only after successful WinGet setup.
# Only WinGet is installed/updated here, never a TeX distribution.
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
    Repair-WinGetPackageManager -Latest -ErrorAction Stop | Out-Null
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
