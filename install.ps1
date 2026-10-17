# Install/update MiKTeX and repair its TeXworks entry. No setup history or removal logic.
function Assert-TeXPlainPath([string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and
        ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Verknuepfter Programmpfad; keine automatische Aenderung.'
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
function Invoke-TeXPackageCommand([string]$File, [string[]]$Arguments, [int[]]$SuccessCodes = @(0)) {
    # Only idempotent package operations use this retry, never install/uninstall.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $code = Invoke-TeXNative $File $Arguments
        if ($null -eq $code -or $code -in $SuccessCodes -or $attempt -eq 3) { return $code }
        Write-Host 'MiKTeX-Paketserver/Update nicht erreichbar; erneuter Versuch ...'
        Start-Sleep -Seconds 3
    }
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
                $code = Invoke-TeXPackageCommand $Updater.File ($prefix + @('packages', $command))
                if ($null -eq $code -or $code -ne 0) { throw "MiKTeX-Aktualisierung fehlgeschlagen ($command, $code)." }
            }
            $code = Invoke-TeXPackageCommand $Updater.File ($prefix + @('packages', 'check-update')) @(0,100)
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
function Ensure-TeXEditor($Updater) {
    $bin = Split-Path -Parent $Updater.File
    $editor = Join-Path $bin 'miktex-texworks.exe'
    if (-not (Test-Path -LiteralPath $editor -PathType Leaf)) {
        $prefix = @()
        if ($Updater.Admin) { $prefix = @('--admin') }
        $package = if ((Split-Path -Leaf $bin) -eq 'x64') { 'miktex-texworks-bin-x64-2.9' } else { 'miktex-texworks-bin-2.9' }
        if ((Invoke-TeXPackageCommand $Updater.File ($prefix + @('packages','install',$package))) -ne 0) {
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
}

function Install-TeX([scriptblock]$Command) {
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Nur fuer Windows.' }
    if (($Command.ToString().Trim() -replace '\s+',' ') -ne 'winget install --id MiKTeX.MiKTeX -e --scope user -s winget') {
        throw 'Nur der MiKTeX-Befehl aus der Anleitung ist erlaubt.'
    }
    $apps = @(Get-TeXRegistrations)
    $updater = $null
    if ($apps.Count -gt 0) { $updater = Get-TeXUpdater $apps }
    elseif (Test-TeXFootprint) { throw 'Unvollstaendige/andere TeX-Installation gefunden. Keine zweite Installation angelegt.' }
    $bootstrap = Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/main/win.ps1' -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($bootstrap)) { throw 'Leerer Download.' }
    Invoke-Expression $bootstrap
    if (-not $updater) {
        & $Command
        if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { throw 'MiKTeX-Installation fehlgeschlagen.' }
        $updater = Get-TeXUpdater @(Get-TeXRegistrations)
    }
    Update-TeX $updater
    Ensure-TeXEditor $updater
    Write-Host 'MiKTeX und TeXworks sind eingerichtet.'
}
