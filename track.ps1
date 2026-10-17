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
function Test-TeXFootprint {
    (Test-Path -LiteralPath (Get-TeXInstallRoot)) -or
        [bool](Get-Command miktex.exe,pdflatex.exe -ErrorAction SilentlyContinue)
}
function Test-TeXAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-TeXUpdater($Apps) {
    if (@($Apps).Count -ne 1) { throw 'MiKTeX-Installation nicht eindeutig. Keine zweite Installation angelegt.' }
    $app = @($Apps)[0]
    $admin = $app.Key -like 'HKEY_LOCAL_MACHINE\*'
    if (-not $admin -and $app.Key -notlike 'HKEY_CURRENT_USER\*') { throw 'Unbekannter MiKTeX-Installationsbereich.' }
    if ($admin -and -not (Test-TeXAdministrator)) {
        throw 'Dieses MiKTeX wurde fuer alle Benutzer installiert. PowerShell als Administrator starten und den Befehl erneut ausfuehren.'
    }
    $root = $app.Location
    if ([string]::IsNullOrWhiteSpace($root) -and -not $admin) { $root = Get-TeXInstallRoot }
    if ([string]::IsNullOrWhiteSpace($root) -or -not [IO.Path]::IsPathRooted($root)) {
        throw 'MiKTeX-Installationsordner nicht eindeutig. Keine zweite Installation angelegt.'
    }
    Assert-TeXPlainPath $root
    # Resolve only inside the registered installation, never a different PATH copy.
    $bin = Join-Path (Join-Path $root 'miktex') 'bin'
    Assert-TeXPlainPath (Join-Path $root 'miktex')
    Assert-TeXPlainPath $bin
    $candidates = @(
        (Join-Path (Join-Path $bin 'x64') 'miktex.exe'),
        (Join-Path $bin 'miktex.exe')
    )
    $files = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($files.Count -ne 1) { throw 'MiKTeX-Updater fehlt oder ist nicht eindeutig. Keine zweite Installation angelegt.' }
    Assert-TeXPlainPath (Split-Path -Parent $files[0])
    Assert-TeXPlainPath $files[0]
    [pscustomobject]@{ File=$files[0]; Admin=$admin; Key=$app.Key; Location=$app.Location }
}
function Invoke-TeXNative([string]$File, [string[]]$Arguments) {
    # check-update uses exit code 100 for available updates, not an execution error.
    $PSNativeCommandUseErrorActionPreference = $false
    & $File @Arguments | Out-Host
    $LASTEXITCODE
}
function Update-TeX($Updater) {
    # Shared packages need --admin; also update this user's own packages.
    $modes = @($false)
    if ($Updater.Admin) { $modes = @($true, $false) }
    foreach ($admin in $modes) {
        $prefix = @()
        if ($admin) { $prefix = @('--admin') }
        $finished = $false
        # A core update can require another invocation of the newly updated utility.
        for ($pass = 0; $pass -lt 3; $pass++) {
            foreach ($command in @('update-package-database', 'update')) {
                $code = Invoke-TeXNative $Updater.File ($prefix + @('packages', $command))
                if ($null -eq $code -or $code -ne 0) { throw "MiKTeX-Aktualisierung fehlgeschlagen ($command, $code)." }
            }
            $code = Invoke-TeXNative $Updater.File ($prefix + @('packages', 'check-update'))
            if ($null -ne $code -and $code -eq 0) { $finished = $true; break }
            if ($null -eq $code -or $code -ne 100) { throw "MiKTeX-Updatepruefung fehlgeschlagen ($code)." }
        }
        if (-not $finished) { throw 'MiKTeX meldet weiterhin offene Updates. Aktualisierung nicht als abgeschlossen vermerkt.' }
    }
}
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
            $present = @(Get-TeXRegistrations).Count -gt 0 -or (Test-TeXFootprint)
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
    # Local only: callers need neither a preparation call nor a preference block.
    $ErrorActionPreference = 'Stop'
    if (($Command.ToString().Trim() -replace '\s+',' ') -ne 'winget install --id MiKTeX.MiKTeX -e --scope user -s winget') {
        throw 'Nur der MiKTeX-Befehl aus der Anleitung ist erlaubt.'
    }
    Initialize-TeX
    Use-TeXRecord {
        param($dir)
        $record = Read-TeXRecord $dir
        if (-not $record -or $record.status -eq 'pending') { throw 'Kein gueltiger Installationsbeginn.' }
        $apps = @(Get-TeXRegistrations)
        if ($record.status -eq 'complete' -and $record.baseline -eq 'absent') {
            $saved = @($record.registration)
            if ($saved.Count -ne 1 -or $apps.Count -ne 1 -or $apps[0].Key -ne $saved[0].Key -or
                $apps[0].Key -notlike 'HKEY_CURRENT_USER\*' -or $apps[0].Version -ne $saved[0].Version -or
                $apps[0].Location -ne $saved[0].Location -or (Get-TeXInventory) -ne $record.fingerprint) {
                throw 'Installation nachtraeglich veraendert; Nachweis bleibt unveraendert.'
            }
        }
        # A program installed between Initialize and Install is NOT ours.
        if ($record.status -eq 'prepared' -and ($apps.Count -gt 0 -or (Test-TeXFootprint))) {
            $record.baseline = 'present'
        }
        $updater = $null
        if ($apps.Count -gt 0) { $updater = Get-TeXUpdater $apps }
        elseif (Test-TeXFootprint) { throw 'Vorhandene TeX-Installation nicht eindeutig zuzuordnen. Keine zweite Installation angelegt.' }
        $record.status = 'pending'
        Save-TeXRecord $dir $record
        if (-not $updater) {
            & $Command
            if ($LASTEXITCODE -ne 0) {
                throw "MiKTeX-Installation nicht erfolgreich ($LASTEXITCODE). Keine automatische Entfernung."
            }
            $updater = Get-TeXUpdater @(Get-TeXRegistrations)
        }
        # WinGet's MiKTeX manifest denies upgrades; use MiKTeX's own updater instead.
        Update-TeX $updater
        $apps = @(Get-TeXRegistrations)
        if ($apps.Count -ne 1 -or $apps[0].Key -ne $updater.Key -or $apps[0].Location -ne $updater.Location) {
            throw 'MiKTeX-Installation nach Aktualisierung nicht eindeutig. Nachweis bleibt erhalten.'
        }
        if ($record.baseline -eq 'absent') {
            if ($apps.Count -ne 1 -or $apps[0].Key -notlike 'HKEY_CURRENT_USER\*') { throw 'Installation nicht eindeutig dem Benutzer zuzuordnen.' }
            $record.registration = $apps
            $record.fingerprint = Get-TeXInventory
        }
        $record.status = 'complete'
        Save-TeXRecord $dir $record
        Write-Host 'MiKTeX installiert/aktualisiert. Lokales Protokoll gespeichert.'
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
