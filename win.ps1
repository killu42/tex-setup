# Windows PowerShell 5.1 or newer. No execution-policy or security-setting changes.
& {
    $ErrorActionPreference = 'Stop'
    function Invoke-Checked {
        param([string]$Program, [string[]]$Arguments)
        & $Program @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$Program meldet Fehlercode $LASTEXITCODE." }
    }
    function Find-MiKTeX {
        $cmd = Get-Command miktex.exe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $roots = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\MiKTeX'),
            (Join-Path $env:ProgramFiles 'MiKTeX')
        )
        foreach ($root in $roots) {
            foreach ($suffix in @('miktex\bin\x64\miktex.exe', 'miktex\bin\miktex.exe')) {
                $candidate = Join-Path $root $suffix
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
        return $null
    }

    try {
        if ($env:OS -ne 'Windows_NT') { throw 'Dieses Skript ist nur fuer Windows.' }
        if ([Environment]::OSVersion.Version.Build -lt 17763) {
            throw 'Windows 10 ab Version 1809 oder Windows 11 wird benoetigt.'
        }
        $miktex = Find-MiKTeX
        $engine = Get-Command pdflatex.exe -ErrorAction SilentlyContinue
        if ($engine) {
            $engineInfo = & $engine.Source --version
            if ($LASTEXITCODE -ne 0 -or ($engineInfo -join ' ') -notmatch 'MiKTeX') {
                throw 'Eine andere TeX-Installation ist vorhanden; sie bleibt unveraendert.'
            }
        }

        Write-Host 'WinGet wird eingerichtet bzw. aktualisiert ...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force
        Import-Module Microsoft.WinGet.Client -Force
        Repair-WinGetPackageManager -Latest | Out-Null
        $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        $winget = if ($wingetCmd) { $wingetCmd.Source } else { $null }
        if (-not $winget) {
            $app = Get-AppxPackage Microsoft.DesktopAppInstaller | Sort-Object Version -Descending | Select-Object -First 1
            if ($app) { $winget = Join-Path $app.InstallLocation 'winget.exe' }
        }
        if (-not $winget -or -not (Test-Path -LiteralPath $winget)) {
            throw 'WinGet konnte nicht eingerichtet werden.'
        }
        if (-not $miktex) {
            Invoke-Checked $winget @('install', '--id', 'MiKTeX.MiKTeX', '--exact', '--scope', 'user', '--source', 'winget')
            # Installer PATH changes are not inherited by an already-open PowerShell.
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
            $miktex = Find-MiKTeX
        }
        if (-not $miktex) { throw 'MiKTeX wurde nicht vollstaendig installiert.' }
        # MiKTeX intentionally does not support winget upgrade: use its own updater.
        $isShared = $miktex.StartsWith($env:ProgramFiles + '\', [StringComparison]::OrdinalIgnoreCase)
        $updateArgs = @()
        if ($isShared) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'MiKTeX ist systemweit installiert. Fuer das Update ist eine als Administrator geoeffnete PowerShell erforderlich.'
            }
            $updateArgs = @('--admin')
        }
        Invoke-Checked $miktex ($updateArgs + @('packages', 'update-package-database'))
        Invoke-Checked $miktex ($updateArgs + @('packages', 'update'))
        $texworks = Join-Path (Split-Path -Parent $miktex) 'texworks.exe'
        if (-not (Test-Path -LiteralPath $texworks)) { throw 'TeXworks wurde nicht gefunden.' }
        Start-Process -FilePath $texworks
        Write-Host 'Fertig: MiKTeX ist eingerichtet; TeXworks wird geoeffnet.'
    }
    catch {
        Write-Error "TeX-Setup abgebrochen: $($_.Exception.Message)" -ErrorAction Continue
        throw
    }
}
