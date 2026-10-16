# Local-only provenance. Loading this file does not install or remove anything.
# TeX installation stays visible in the separately supplied command block.
function Get-TeXRecordPath {
    if ($env:OS -ne 'Windows_NT') { throw 'Nur fuer Windows.' }
    if (-not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) { throw 'Ungueltiger Benutzerpfad.' }
    Join-Path $env:LOCALAPPDATA 'TeX-Setup'
}
function Assert-TeXPlainPath([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Ein Protokoll- oder Programmpfad ist ein Link. Abbruch.'
        }
    }
}
function Get-TeXUser { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Read-TeXRecord([string]$Dir) {
    $file = Join-Path $Dir 'state.json'
    Assert-TeXPlainPath $file
    if (-not (Test-Path -LiteralPath $file)) {
        if (@(Get-ChildItem -LiteralPath $Dir -Force | Where-Object Name -ne 'lock').Count -gt 0) {
            throw 'Unvollstaendiges oder unbekanntes Protokoll. Nichts entfernt.'
        }
        return $null
    }
    $record = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($record.schema -ne 1 -or $record.user -ne (Get-TeXUser) -or
        $record.baseline -notin @('present','absent') -or $record.status -notin @('prepared','pending','complete')) {
        throw 'Ungueltiges Installationsprotokoll. Nichts entfernt.'
    }
    $record
}
function Save-TeXRecord([string]$Dir, $Record) {
    $tmp = Join-Path $Dir 'state.new'
    $file = Join-Path $Dir 'state.json'
    Assert-TeXPlainPath $tmp
    Assert-TeXPlainPath $file
    $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
    Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
}
function Use-TeXRecord([scriptblock]$Action, [switch]$ExistingOnly) {
    $ErrorActionPreference = 'Stop'
    $dir = Get-TeXRecordPath
    if ($ExistingOnly -and -not (Test-Path -LiteralPath $dir)) {
        Write-Host 'Kein Installationsprotokoll. Nichts entfernt.'
        return
    }
    Assert-TeXPlainPath $dir
    if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $item = Get-Item -LiteralPath $dir -Force
    $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
    $lockFile = Join-Path $dir 'lock'
    Assert-TeXPlainPath $lockFile
    # CreateNew fails closed on a concurrent or previously interrupted process.
    $lock = [IO.File]::Open($lockFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { & $Action $dir } finally {
        $lock.Dispose()
        Remove-Item -LiteralPath $lockFile -Force
    }
    if ((Get-ChildItem -LiteralPath $dir -Force | Measure-Object).Count -eq 0) {
        Remove-Item -LiteralPath $dir -Force
    }
}
function Get-TeXRegistrations {
    $roots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -ErrorAction Stop | ForEach-Object {
                $app = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                if ($app.DisplayName -like '*MiKTeX*') {
                    [pscustomobject]@{Key=$_.Name; Name=$app.DisplayName; Version=$app.DisplayVersion; Location=$app.InstallLocation}
                }
            }
        }
    }
}
function Get-TeXInstallRoot { Join-Path $env:LOCALAPPDATA 'Programs\MiKTeX' }
function Get-TeXInventory {
    $root = Get-TeXInstallRoot
    Assert-TeXPlainPath $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'MiKTeX-Programmordner fehlt.' }
    # Metadata guards later user additions and modifications. No personal
    # AppData settings/cache directories are deleted by our code.
    $rows = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Link im Programmordner; keine automatische Entfernung.' }
        '{0}|{1}|{2}' -f $_.FullName.Substring($root.Length), $_.Length, $_.LastWriteTimeUtc.Ticks
    } | Sort-Object)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Initialize-TeX {
    Use-TeXRecord {
        param($dir)
        $record = Read-TeXRecord $dir
        if (-not $record) {
            $present = @(Get-TeXRegistrations).Count -gt 0 -or
                (Test-Path -LiteralPath (Get-TeXInstallRoot)) -or
                [bool](Get-Command miktex.exe,pdflatex.exe -ErrorAction SilentlyContinue)
            $record = [pscustomobject]@{
                schema=1; user=(Get-TeXUser)
                baseline=$(if ($present) {'present'} else {'absent'}); status='prepared'
                registration=@(); fingerprint=''
                appInstallerBefore=@(Get-AppxPackage Microsoft.DesktopAppInstaller | Select-Object Name,Version,PackageFullName)
                helpers='Shared infrastructure; not automatically removed'
            }
            Save-TeXRecord $dir $record
        }
        if ($record.status -eq 'pending') { throw 'Vorherige Installation unvollstaendig. Nachweis bleibt erhalten.' }
        $bootstrap = Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/main/win.ps1' -ErrorAction Stop
        Invoke-Expression $bootstrap
    }
}
function Install-TeX([scriptblock]$Command) {
    if (($Command.ToString().Trim() -replace '\s+',' ') -ne 'winget install --id MiKTeX.MiKTeX -e --scope user -s winget') {
        throw 'Nur der MiKTeX-Befehl aus der Anleitung ist erlaubt.'
    }
    Use-TeXRecord {
        param($dir)
        $record = Read-TeXRecord $dir
        if (-not $record -or $record.status -eq 'pending') { throw 'Kein gueltiger Installationsbeginn.' }
        if ($record.status -eq 'complete' -and $record.baseline -eq 'absent') {
            if ((Get-TeXInventory) -ne $record.fingerprint) { throw 'Installation nachtraeglich veraendert; Nachweis bleibt unveraendert.' }
        }
        # A program installed between Initialize and Install is NOT ours.
        if ($record.status -eq 'prepared' -and (@(Get-TeXRegistrations).Count -gt 0 -or (Test-Path -LiteralPath (Get-TeXInstallRoot)))) {
            $record.baseline = 'present'
        }
        $record.status = 'pending'
        Save-TeXRecord $dir $record
        & $Command
        # WinGet returns 0x8A15002B when the newest version is already present.
        if ($LASTEXITCODE -ne 0 -and -not ($record.baseline -eq 'present' -and $LASTEXITCODE -eq -1978335189)) {
            throw "MiKTeX-Installation nicht erfolgreich ($LASTEXITCODE). Keine automatische Entfernung."
        }
        $apps = @(Get-TeXRegistrations)
        if ($apps.Count -eq 0) { throw 'MiKTeX-Installation konnte nicht bestaetigt werden.' }
        if ($record.baseline -eq 'absent') {
            if ($apps.Count -ne 1 -or $apps[0].Key -notlike 'HKEY_CURRENT_USER\*') { throw 'Installation nicht eindeutig dem Benutzer zuzuordnen.' }
            $record.registration = $apps
            $record.fingerprint = Get-TeXInventory
        }
        $record.status = 'complete'
        Save-TeXRecord $dir $record
        Write-Host 'Installation abgeschlossen. Lokales Protokoll gespeichert.'
    }
}
function Invoke-TeXUninstall {
    $wg = Get-Command winget.exe -ErrorAction Stop
    & $wg.Source uninstall --id MiKTeX.MiKTeX -e --scope user -s winget --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "MiKTeX-Deinstallation fehlgeschlagen ($LASTEXITCODE)." }
}
function Remove-TeX {
    Use-TeXRecord -ExistingOnly -Action {
        param($dir)
        $record = Read-TeXRecord $dir
        if (-not $record -or $record.status -ne 'complete') { throw 'Kein abgeschlossener Nachweis. Nichts entfernt.' }
        if ($record.baseline -eq 'present') {
            Write-Host 'Vorhandenes MiKTeX und seine Updates bleiben erhalten.'
        } else {
            $apps = @(Get-TeXRegistrations)
            if ($apps.Count -gt 0) {
                $saved = @($record.registration)
                if ($saved.Count -ne 1 -or $apps.Count -ne 1 -or $apps[0].Key -ne $saved[0].Key -or
                    $apps[0].Key -notlike 'HKEY_CURRENT_USER\*' -or $apps[0].Version -ne $saved[0].Version -or
                    $apps[0].Location -ne $saved[0].Location -or (Get-TeXInventory) -ne $record.fingerprint) {
                    throw 'MiKTeX wurde nachtraeglich veraendert. Nichts entfernt; Protokoll bleibt erhalten.'
                }
                Invoke-TeXUninstall
                if (@(Get-TeXRegistrations).Count -ne 0) { throw 'Deinstallation unvollstaendig. Protokoll bleibt fuer einen erneuten Aufruf erhalten.' }
            } elseif (Test-Path -LiteralPath (Get-TeXInstallRoot)) {
                throw 'MiKTeX-Nachweis fehlt, aber der Programmordner existiert noch. Protokoll bleibt erhalten.'
            }
        }
        Remove-Item -LiteralPath (Join-Path $dir 'state.json') -Force
        Write-Host 'Entfernung abgeschlossen; lokales Protokoll geloescht.'
        Write-Host 'WinGet, Einrichtungshilfen und eigene Dokumente bleiben erhalten.'
    }
}
