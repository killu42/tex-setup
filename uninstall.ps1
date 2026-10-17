# Remove MiKTeX and its TeXworks via the vendor uninstaller; no history.
& {
$ErrorActionPreference = 'Stop'
Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/main/install.ps1' -ErrorAction Stop)
function Read-TeXConfigReport([string]$File) {
    $PSNativeCommandUseErrorActionPreference = $false
    $report = @(& $File --report)
    if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { throw 'MiKTeX-Konfiguration nicht lesbar. Nichts entfernt.' }
    $report
}
function Assert-TeXRemovalRoots($Updater) {
    $reporter = Join-Path (Split-Path -Parent $Updater.File) 'initexmf.exe'
    Assert-TeXPlainPath $reporter
    if (-not (Test-Path -LiteralPath $reporter -PathType Leaf)) { throw 'MiKTeX-Konfigurationspruefung fehlt. Nichts entfernt.' }
    $report = @(Read-TeXConfigReport $reporter)
    $data = @(Get-TeXDataRoots)
    $expected = @{UserInstall=(Get-TeXInstallRoot); UserConfig=$data[0]; UserData=$data[1]}
    foreach ($key in @('UserInstall','UserConfig','UserData')) {
        $values = @($report | Where-Object { $_ -match "^${key}:\s*(.+)$" } | ForEach-Object { ($_ -split ':\s*',2)[1].Trim() })
        if ($values.Count -ne 1 -or -not [IO.Path]::IsPathRooted($values[0]) -or
            [IO.Path]::GetFullPath($values[0]).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($expected[$key]).TrimEnd('\','/')) {
            throw 'Benutzerdefinierte MiKTeX-Datenordner bleiben geschuetzt. Nichts entfernt.'
        }
        Assert-TeXPlainPath $expected[$key]
        if (Test-Path -LiteralPath $expected[$key]) {
            $links = @(Get-ChildItem -LiteralPath $expected[$key] -Recurse -Force -ErrorAction Stop |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
            if ($links.Count -gt 0) { throw 'Link in MiKTeX-Datenordnern. Nichts entfernt.' }
        }
    }
}
function Remove-TeX {
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Nur fuer Windows.' }
    $apps = @(Get-TeXRegistrations)
    if ($apps.Count -eq 0) { Write-Host 'Keine registrierte MiKTeX-Installation gefunden.'; return }
    $updater = Get-TeXUpdater $apps
    if ($updater.Admin) { throw 'Diese kurze Entfernung ist fuer die Benutzerinstallation der Anleitung vorgesehen.' }
    Assert-TeXRemovalRoots $updater
    $bin = Split-Path -Parent $updater.File
    $uninstaller = Join-Path $bin 'miktexsetup.exe'
    Assert-TeXPlainPath $uninstaller
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'MiKTeX-Uninstaller fehlt.' }
    $editor = Join-Path $bin 'miktex-texworks.exe'
    # Keep only exact matching shortcuts in memory, never a disk history.
    $links = @()
    foreach ($folder in @(Get-TeXProgramsFolders)) {
        if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) { continue }
        if (-not $updater.Admin -and $folder -ne @(Get-TeXProgramsFolders)[0]) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*TeXworks*.lnk' -Recurse)) {
            $link = Get-TeXShortcut $file.FullName
            if ($link.TargetPath -eq $editor -and [string]::IsNullOrWhiteSpace($link.Arguments)) { $links += $file.FullName }
        }
    }
    $shared = if ($updater.Admin) { '--shared=yes' } else { '--shared=no' }
    $code = Invoke-TeXNative $uninstaller @('--verbose',$shared,'uninstall')
    if ($null -eq $code -or $code -ne 0) { throw 'MiKTeX-Deinstallation fehlgeschlagen.' }
    if (@(Get-TeXRegistrations | Where-Object Key -eq $updater.Key).Count -gt 0) { throw 'MiKTeX ist noch registriert.' }
    foreach ($path in $links) {
        if (Test-Path -LiteralPath $path) {
            $link = Get-TeXShortcut $path
            if ($link.TargetPath -eq $editor -and [string]::IsNullOrWhiteSpace($link.Arguments)) {
                Remove-Item -LiteralPath $path -ErrorAction Stop
            }
        }
    }
    Write-Host 'MiKTeX und sein TeXworks entfernt. WinGet bleibt erhalten.'
}


Remove-TeX
}
