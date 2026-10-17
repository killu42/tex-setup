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
function Get-TeXManagerPath { (Get-TeXRecordPath) + '-manager' }
function Read-TeXManagerRecord([string]$Dir) {
    $file = Join-Path $Dir 'state.json'
    Assert-TeXPlainPath $file
    if (-not (Test-Path -LiteralPath $file)) {
        if (@(Get-ChildItem -LiteralPath $Dir -Force | Where-Object Name -ne 'lock').Count -gt 0) {
            throw 'Unvollstaendiger Paketmanager-Nachweis. Nichts entfernt.'
        }
        return $null
    }
    $record = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($record.schema -ne 'tex-manager-1' -or $record.user -ne (Get-TeXUser) -or
        $record.baseline -notin @('present','absent','protected') -or $record.status -notin @('pending','complete')) {
        throw 'Ungueltiger Paketmanager-Nachweis. Nichts entfernt.'
    }
    $record
}
function Use-TeXManagerRecord([scriptblock]$Action, [switch]$ExistingOnly) {
    $ErrorActionPreference = 'Stop'
    $dir = Get-TeXManagerPath
    Assert-TeXPlainPath $dir
    if ($ExistingOnly -and -not (Test-Path -LiteralPath $dir)) {
        Write-Host 'Kein eindeutiger WinGet-Nachweis. Nichts entfernt.'
        return
    }
    if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $item = Get-Item -LiteralPath $dir -Force
    $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
    $lockFile = Join-Path $dir 'lock'
    Assert-TeXPlainPath $lockFile
    $lock = [IO.File]::Open($lockFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { & $Action $dir } finally {
        $lock.Dispose()
        Remove-Item -LiteralPath $lockFile -Force
    }
    if (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { Remove-Item -LiteralPath $dir -Force }
}
function Get-TeXManagerPackages {
    # Current user only; never uninstall provisioned packages or other users' copies.
    @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop)
}
function Test-TeXManagerCommand { [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }
function Get-TeXManagerIdentity($Packages) {
    $apps = @($Packages)
    if ($apps.Count -ne 1 -or $apps[0].Name -ne 'Microsoft.DesktopAppInstaller' -or
        $apps[0].PackageFamilyName -ne 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -or
        $apps[0].PublisherId -ne '8wekyb3d8bbwe' -or
        [string]::IsNullOrWhiteSpace($apps[0].PackageFullName) -or
        [string]::IsNullOrWhiteSpace([string]$apps[0].Version) -or
        [string]::IsNullOrWhiteSpace($apps[0].InstallLocation)) {
        throw 'App-Installer nicht eindeutig zuzuordnen. Nichts entfernt.'
    }
    $apps[0] | Select-Object Name,PackageFamilyName,PublisherId,PackageFullName,
        @{Name='Version';Expression={[string]$_.Version}},InstallLocation
}
function Test-TeXManagerIdentity($Saved, $Current) {
    if (-not $Saved -or -not $Current) { return $false }
    foreach ($key in @('Name','PackageFamilyName','PublisherId','PackageFullName','Version','InstallLocation')) {
        if ([string]::IsNullOrWhiteSpace([string]$Saved.$key) -or $Saved.$key -cne $Current.$key) { return $false }
    }
    $true
}
function Initialize-TeXManager([scriptblock]$Bootstrap) {
    Use-TeXManagerRecord {
        param($dir)
        $record = Read-TeXManagerRecord $dir
        $before = @(Get-TeXManagerPackages)
        if (-not $record) {
            # Old TeX records are deliberately NOT treated as proof of ownership.
            $present = $before.Count -gt 0 -or (Test-TeXManagerCommand)
            $record = [pscustomobject]@{
                schema='tex-manager-1'; user=(Get-TeXUser)
                baseline=$(if ($present) {'present'} else {'absent'}); status='pending'; after=$null
            }
        } else {
            if ($record.status -ne 'complete') { throw 'Fruehere WinGet-Einrichtung unvollstaendig. Nachweis bleibt erhalten.' }
            if ($record.baseline -eq 'absent') {
                $identity = $null
                try { $identity = Get-TeXManagerIdentity $before } catch { }
                if (-not (Test-TeXManagerIdentity $record.after $identity)) { $record.baseline = 'protected' }
            }
            $record.status = 'pending'
        }
        Save-TeXRecord $dir $record
        & $Bootstrap
        if ($record.baseline -eq 'absent') {
            $record.after = Get-TeXManagerIdentity @(Get-TeXManagerPackages)
        }
        $record.status = 'complete'
        Save-TeXRecord $dir $record
    }
}
function Remove-TeXManager {
    Use-TeXManagerRecord -ExistingOnly {
        param($dir)
        $record = Read-TeXManagerRecord $dir
        if (-not $record -or $record.status -ne 'complete') { throw 'Kein abgeschlossener WinGet-Nachweis. Nichts entfernt.' }
        if ($record.baseline -ne 'absent') {
            Write-Host 'Vorhandenes oder inzwischen veraendertes WinGet bleibt erhalten.'
            return
        }
        if (Test-Path -LiteralPath (Get-TeXRecordPath)) { throw 'Zuerst die TeX-Entfernung abschliessen.' }
        $apps = @(Get-TeXManagerPackages)
        $identity = Get-TeXManagerIdentity $apps
        if (-not (Test-TeXManagerIdentity $record.after $identity)) { throw 'App-Installer inzwischen veraendert. Nichts entfernt.' }
        if ($apps[0].NonRemovable) { throw 'Windows schuetzt den App-Installer als Systemkomponente. Er bleibt erhalten.' }
        Remove-AppxPackage -Package $identity.PackageFullName -ErrorAction Stop
        if (@(Get-TeXManagerPackages).Count -ne 0) { throw 'WinGet-Entfernung nicht abgeschlossen. Nachweis bleibt erhalten.' }
        Remove-Item -LiteralPath (Join-Path $dir 'state.json') -Force -ErrorAction Stop
        Write-Host 'Neu eingerichtetes WinGet samt App-Installer fuer dieses Konto entfernt.'
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
function Get-TeXDataRoots {
    @((Join-Path $env:APPDATA 'MiKTeX'), (Join-Path $env:LOCALAPPDATA 'MiKTeX'))
}
function Test-TeXFootprint {
    (Test-Path -LiteralPath (Get-TeXInstallRoot)) -or
        @((Get-TeXDataRoots) | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0 -or
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
function Get-TeXProgramsFolders {
    @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'))
}
function Get-TeXShortcut([string]$Path) {
    Assert-TeXPlainPath $Path
    $shell = New-Object -ComObject WScript.Shell
    $shell.CreateShortcut($Path)
}
function Find-TeXEditorShortcut([string]$Editor) {
    foreach ($folder in @(Get-TeXProgramsFolders)) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*TeXworks*.lnk' -Recurse -ErrorAction Stop)) {
            $link = Get-TeXShortcut $file.FullName
            if ($link.TargetPath -eq $Editor -and [string]::IsNullOrWhiteSpace($link.Arguments)) { return $file.FullName }
        }
    }
}
function Ensure-TeXEditor($Updater, $Record) {
    $bin = Split-Path -Parent $Updater.File
    $editor = Join-Path $bin 'miktex-texworks.exe'
    if (-not (Test-Path -LiteralPath $editor -PathType Leaf)) {
        $prefix = @()
        if ($Updater.Admin) { $prefix = @('--admin') }
        $package = if ((Split-Path -Leaf $bin) -eq 'x64') { 'miktex-texworks-bin-x64-2.9' } else { 'miktex-texworks-bin-2.9' }
        if ((Invoke-TeXNative $Updater.File ($prefix + @('packages','install',$package))) -ne 0) {
            throw 'TeXworks konnte nicht nachinstalliert werden.'
        }
    }
    if (-not (Test-Path -LiteralPath $editor -PathType Leaf)) { throw 'TeXworks fehlt nach der Installation.' }
    Assert-TeXPlainPath $editor
    if (Find-TeXEditorShortcut $editor) { return }
    # Only add a missing per-user shortcut; never overwrite another editor/link.
    $programs = @(Get-TeXProgramsFolders)[0]
    if (-not [IO.Path]::IsPathRooted($programs)) { throw 'Startmenue-Ordner nicht verfuegbar.' }
    Assert-TeXPlainPath $programs
    [void][IO.Directory]::CreateDirectory($programs)
    $path = $null
    foreach ($name in @('TeXworks.lnk','TeXworks (MiKTeX).lnk')) {
        $candidate = Join-Path $programs $name
        if (-not (Test-Path -LiteralPath $candidate)) { $path = $candidate; break }
    }
    if (-not $path) { throw 'Vorhandene Startmenue-Verknuepfungen bleiben unveraendert.' }
    $link = Get-TeXShortcut $path
    $link.TargetPath = $editor
    $link.WorkingDirectory = [Environment]::GetFolderPath('MyDocuments')
    $link.Description = 'TeXworks - LaTeX-Editor (MiKTeX)'
    $link.Save()
    if ((Get-TeXShortcut $path).TargetPath -ne $editor) { throw 'TeXworks-Verknuepfung konnte nicht angelegt werden.' }
    $links = @($Record.editorLinks | Where-Object { $_ })
    $links += [pscustomobject]@{Path=$path; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    $Record | Add-Member -NotePropertyName editorLinks -NotePropertyValue $links -Force
}
function Remove-TeXEditorLinks($Record) {
    # Called only after a newly installed MiKTeX has actually been removed.
    $programs = @(Get-TeXProgramsFolders)[0]
    foreach ($link in @($Record.editorLinks | Where-Object { $_ })) {
        if ((Split-Path -Parent $link.Path) -ne $programs -or
            (Split-Path -Leaf $link.Path) -notin @('TeXworks.lnk','TeXworks (MiKTeX).lnk')) { continue }
        Assert-TeXPlainPath $link.Path
        if ((Test-Path -LiteralPath $link.Path -PathType Leaf) -and
            (Get-FileHash -LiteralPath $link.Path -Algorithm SHA256).Hash -eq $link.Hash) {
            Remove-Item -LiteralPath $link.Path -Force -ErrorAction Stop
        }
    }
}
function Get-TeXInventory([switch]$Stable) {
    $root = Get-TeXInstallRoot
    Assert-TeXPlainPath $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'MiKTeX-Programmordner fehlt.' }
    # Metadata guards later user additions and modifications in the program tree.
    $rows = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Link im Programmordner; keine automatische Entfernung.' }
        $relative = $_.FullName.Substring($root.Length)
        if ($Stable -and $_.PSIsContainer) {
            # Directory timestamps change when MiKTeX touches its runtime lock.
            # Names/types still detect added directories; every file is checked.
            '{0}|directory' -f $relative
        } elseif ($Stable -and $relative.Replace('/','\') -ieq '\miktex\lock') {
            # MiKTeX rewrites this one-byte lock during ordinary compiler use.
            '{0}|{1}|runtime-lock' -f $relative, $_.Length
        } else {
            '{0}|{1}|{2}' -f $relative, $_.Length, $_.LastWriteTimeUtc.Ticks
        }
    } | Sort-Object)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Test-TeXOwnedRegistration($Record, $Apps) {
    $saved = @($Record.registration)
    $current = @($Apps)
    if ($saved.Count -ne 1 -or $current.Count -ne 1 -or $current[0].Key -notlike 'HKEY_CURRENT_USER\*') { return $false }
    foreach ($field in @('Key','Name','Version','Location')) {
        # Registry values can be null; JSON reload and live registry must agree
        # semantically, not differ merely because an absent value became ''.
        if ([string]$current[0].$field -cne [string]$saved[0].$field) { return $false }
    }
    $true
}
function Test-TeXOwnedInventory($Record) {
    if ($Record.inventoryVersion -and $Record.inventoryVersion -ne 2) { throw 'Unbekannte Inventarversion. Nichts entfernt.' }
    (Get-TeXInventory -Stable:($Record.inventoryVersion -eq 2)) -eq $Record.fingerprint
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
                cleanupRootsFresh=(-not $present)
                registration=@(); fingerprint=''
                appInstallerBefore=@(Get-AppxPackage Microsoft.DesktopAppInstaller | Select-Object Name,Version,PackageFullName)
                helpers='Shared infrastructure; not automatically removed'
            }
            Save-TeXRecord $dir $record
        }
        if ($record.status -eq 'pending') { throw 'Vorherige Installation unvollstaendig. Nachweis bleibt erhalten.' }
        Initialize-TeXManager {
            $bootstrap = Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/main/win.ps1' -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($bootstrap)) { throw 'Download ist leer.' }
            Invoke-Expression $bootstrap
        }
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
            if (-not $record.cleanupRootsFresh) {
                # Old records did not inventory preexisting MiKTeX settings.
                # Permit repair, but do not authorize a new automatic cleanup.
                $record.baseline = 'present'
                Write-Host 'Aeltere Installation wird repariert und vor automatischer Entfernung geschuetzt.'
            }
        }
        if ($record.status -eq 'complete' -and $record.baseline -eq 'absent') {
            if (-not (Test-TeXOwnedRegistration $record $apps)) {
                throw 'Installation nachtraeglich veraendert; Nachweis bleibt unveraendert.'
            }
            if (-not (Test-TeXOwnedInventory $record)) {
                if ($record.inventoryVersion -eq 2) { throw 'Installation nachtraeglich veraendert; Nachweis bleibt unveraendert.' }
                # An old aggregate hash cannot explain a changed lock timestamp.
                # Repair/update is safe, but never adopt unproven files for deletion.
                $record.baseline = 'present'
                Write-Host 'Aeltere Installation wird repariert; ihre automatische Entfernung bleibt aus Sicherheitsgruenden gesperrt.'
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
        Ensure-TeXEditor $updater $record
        $apps = @(Get-TeXRegistrations)
        if ($apps.Count -ne 1 -or $apps[0].Key -ne $updater.Key -or $apps[0].Location -ne $updater.Location) {
            throw 'MiKTeX-Installation nach Aktualisierung nicht eindeutig. Nachweis bleibt erhalten.'
        }
        if ($record.baseline -eq 'absent') {
            if ($apps.Count -ne 1 -or $apps[0].Key -notlike 'HKEY_CURRENT_USER\*') { throw 'Installation nicht eindeutig dem Benutzer zuzuordnen.' }
            $record.registration = $apps
            $record | Add-Member -NotePropertyName inventoryVersion -NotePropertyValue 2 -Force
            $record.fingerprint = Get-TeXInventory -Stable
        }
        $record.status = 'complete'
        Save-TeXRecord $dir $record
        Write-Host 'MiKTeX installiert/aktualisiert. Lokales Protokoll gespeichert.'
    }
}
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
function Invoke-TeXUninstall {
    # WinGet's registered uninstall command only opens MiKTeX Console's GUI.
    # Use the integrated vendor utility from the already verified installation.
    $updater = Get-TeXUpdater @(Get-TeXRegistrations)
    if ($updater.Admin) { throw 'Keine automatische Entfernung systemweiter Installationen.' }
    $uninstaller = Join-Path (Split-Path -Parent $updater.File) 'miktexsetup.exe'
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'MiKTeX-Uninstaller fehlt. Nichts entfernt.' }
    Assert-TeXPlainPath $uninstaller
    Assert-TeXRemovalRoots $updater
    $code = Invoke-TeXNative $uninstaller @('--verbose','--shared=no','uninstall')
    if ($null -eq $code -or $code -ne 0) { throw "MiKTeX-Deinstallation fehlgeschlagen ($code)." }
}
function Remove-TeX {
    Use-TeXRecord -ExistingOnly -Action {
        param($dir)
        $record = Read-TeXRecord $dir
        if (-not $record -or $record.status -ne 'complete') { throw 'Kein abgeschlossener Nachweis. Nichts entfernt.' }
        if ($record.baseline -eq 'present' -or -not $record.cleanupRootsFresh) {
            Write-Host 'Vorhandenes MiKTeX und seine Updates bleiben erhalten.'
        } else {
            $apps = @(Get-TeXRegistrations)
            if ($apps.Count -gt 0) {
                if (-not (Test-TeXOwnedRegistration $record $apps) -or -not (Test-TeXOwnedInventory $record)) {
                    throw 'MiKTeX wurde nachtraeglich veraendert. Nichts entfernt; Protokoll bleibt erhalten.'
                }
                Invoke-TeXUninstall
                if (@(Get-TeXRegistrations).Count -ne 0) { throw 'Deinstallation unvollstaendig. Protokoll bleibt fuer einen erneuten Aufruf erhalten.' }
            } elseif (Test-Path -LiteralPath (Get-TeXInstallRoot)) {
                throw 'MiKTeX-Nachweis fehlt, aber der Programmordner existiert noch. Protokoll bleibt erhalten.'
            }
            Remove-TeXEditorLinks $record
        }
        Remove-Item -LiteralPath (Join-Path $dir 'state.json') -Force
        Write-Host 'Entfernung abgeschlossen; lokales Protokoll geloescht.'
        Write-Host 'WinGet, Einrichtungshilfen und eigene Dokumente bleiben erhalten.'
    }
}
