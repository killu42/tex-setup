# Parse the direct installer; no actual network/Appx/bootstrap on this host.
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'win.ps1'),[ref]$tokens,[ref]$errors)
if ($errors) { throw ($errors | Out-String) }
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-TeXWinGetRelease'},$false)
. ([scriptblock]::Create($function.Extent.Text))
$script:count=0
Add-Type -AssemblyName System.IO.Compression.FileSystem,System.IO.Compression
function Assert($condition) { if (-not $condition) { throw 'Assertion failed' } }
function Invoke-WebRequest([switch]$UseBasicParsing,$Uri,$OutFile) {
    Assert ($ProgressPreference -eq 'SilentlyContinue')
    Assert ($Uri -like 'https://github.com/microsoft/winget-cli/releases/latest/download/*')
    if ($script:failDownload) { throw 'mock network failure' }
    $script:directory=Split-Path -Parent $OutFile
    if ($OutFile.EndsWith('.msixbundle')) {
        $zip=[IO.Compression.ZipFile]::Open($OutFile,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $writer=[IO.StreamWriter]::new($zip.CreateEntry('AppxMetadata/AppxBundleManifest.xml').Open())
            try { $writer.Write('<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle"><Identity Version="2026.1010.1234.0" /><Packages><Package Type="resource" Version="1.29.380.0"/><Package Type="application" Version="1.29.379.0" Architecture="arm64" IsStub="true"/><Package Type="application" Version="1.29.380.0" Architecture="x64"/><Package Type="application" Version="1.29.380.0" Architecture="arm64"/><Package Type="application" Version="1.29.380.0" Architecture="x86"/></Packages></Bundle>') }
            finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
    } else { Set-Content -LiteralPath $OutFile 'mock release asset' }
}
function Get-AppxPackage {
    if ($script:installedVersion) { [pscustomobject]@{Version=$script:installedVersion;Status=$script:installedStatus} }
}
function Expand-Archive($LiteralPath,$DestinationPath) {
    foreach ($architecture in @('x64','arm64','x86')) {
        $dir=Join-Path $DestinationPath $architecture
        [void][IO.Directory]::CreateDirectory($dir)
        if (-not $script:missingDependencies) { Set-Content -LiteralPath (Join-Path $dir 'Microsoft.Framework.appx') 'mock dependency' }
    }
}
function Add-AppxPackage($Path,$DependencyPath) {
    $script:attempts++
    Assert (Test-Path -LiteralPath $Path)
    if ($script:failInstall) { throw 'mock Appx policy rejection' }
    if (-not $DependencyPath -and $script:needsDependencies) { throw '0x80073CF3: dependency missing' }
    $script:installs++
    if (-not $DependencyPath) { return }
    Assert (@($DependencyPath).Count -eq 1)
    Assert ((Split-Path -Leaf (Split-Path -Parent $DependencyPath[0])) -eq $script:expected)
}
function Case($Name,[scriptblock]$Action) {
    $script:installs=0; $script:directory=$null
    $script:attempts=0; $script:needsDependencies=$true
    $script:failDownload=$false; $script:missingDependencies=$false; $script:failInstall=$false
    $script:installedVersion=$null; $script:installedStatus='Ok'
    & $Action
    if ($script:directory) { Assert (-not (Test-Path -LiteralPath $script:directory)) }
    $script:count++; Write-Host "PASS $Name"
}
function Throws([scriptblock]$Action) { $thrown=$false; try { & $Action } catch {$thrown=$true}; Assert $thrown }
foreach ($pair in @(@('AMD64','x64'),@('ARM64','arm64'),@('x86','x86'))) {
    Case "matching dependencies for $($pair[0]) and temporary download cleanup" {
        $script:expected=$pair[1]; Install-TeXWinGetRelease -Architecture $pair[0]; Assert ($script:installs -eq 1)
    }
}
Case 'unknown architecture never installs' { Throws { Install-TeXWinGetRelease -Architecture 'unknown' }; Assert ($script:installs -eq 0) }
Case 'missing dependencies never installs' { $script:missingDependencies=$true; Throws { Install-TeXWinGetRelease -Architecture 'AMD64' }; Assert ($script:installs -eq 0) }
Case 'download failure never installs' { $script:failDownload=$true; Throws { Install-TeXWinGetRelease -Architecture 'AMD64' }; Assert ($script:installs -eq 0) }
Case 'Appx security rejection propagates without dependency retry' { $script:expected='x64'; $script:failInstall=$true; Throws { Install-TeXWinGetRelease -Architecture 'AMD64' }; Assert ($script:installs -eq 0 -and $script:attempts -eq 1) }
Case 'sufficient existing frameworks reused without reinstalling them' {
    $script:needsDependencies=$false
    Install-TeXWinGetRelease -Architecture 'AMD64'
    Assert ($script:installs -eq 1 -and $script:attempts -eq 1)
}
Case 'download progress preference stays local to the function' {
    $ProgressPreference='Continue'; $script:expected='x64'
    Install-TeXWinGetRelease -Architecture 'AMD64'
    Assert ($ProgressPreference -eq 'Continue')
}
foreach ($version in @('1.29.380.0','1.30.100.0')) {
    Case "current or newer package $version retained without reinstall/downgrade" {
        $script:installedVersion=$version
        Install-TeXWinGetRelease -Architecture 'AMD64'; Assert ($script:installs -eq 0)
    }
}
Case 'older package updated' {
    $script:installedVersion='1.29.290.0'; $script:expected='x64'
    Install-TeXWinGetRelease -Architecture 'AMD64'; Assert ($script:installs -eq 1)
}
Case 'unhealthy current package is not silently skipped' {
    $script:installedVersion='1.29.380.0'; $script:installedStatus='Modified'; $script:expected='x64'
    Install-TeXWinGetRelease -Architecture 'AMD64'; Assert ($script:installs -eq 1)
}
# Exercise the actual routing: direct success needs no module; only failure falls back.
$setup=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and
    $node.Body.Extent.Text -match '^\{\s*Install-TeXWinGetRelease\s*\}$'},$true)
Assert (@($setup).Count -eq 1)
$bootstrap=[scriptblock]::Create($setup[0].Extent.Text)
function Stage($Name) {
    $script:steps+=,$Name
    if ($script:failStage -eq $Name) { throw 'Format.ps1xml cannot be loaded: publisher execution declined.' }
}
function Install-PackageProvider { Stage 'provider' }
function Install-Module { Stage 'module' }
function Import-Module { Stage 'import' }
function Repair-WinGetPackageManager { Stage 'repair' }
function Install-TeXWinGetRelease {
    $script:steps+=,'direct'
    if ($script:failDirect) { throw 'Direct download unavailable' }
}
Case 'direct success never installs or loads additional modules' {
    $script:steps=@(); $script:failDirect=$false; $script:failStage='none'
    & $bootstrap; Assert (($script:steps -join ',') -eq 'direct')
}
Case 'direct failure uses Microsoft module as fallback' {
    $script:steps=@(); $script:failDirect=$true; $script:failStage='none'
    & $bootstrap; Assert (($script:steps -join ',') -eq 'direct,provider,module,import,repair')
}
foreach ($stage in @('provider','module','import','repair')) {
    Case "fallback $stage rejection remains a real failure, never false success" {
        $script:steps=@(); $script:failDirect=$true; $script:failStage=$stage
        Throws { & $bootstrap }
        Assert ($script:steps[-1] -eq $stage)
    }
}
# Actual startup error handler: repair once, then require a successful real start.
$startup=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and
    $node.Body.Extent.Text -match '^\{\s*\$wg = Get-TeXWinGet\s*\}$'},$true)
Assert (@($startup).Count -eq 1)
$startupCheck=[scriptblock]::Create($startup[0].Extent.Text)
function Get-TeXWinGet {
    $script:starts++
    if ($script:starts -le $script:failedStarts) {
        throw [System.Management.Automation.ApplicationFailedException]::new('No applicable app licenses found')
    }
    return 'winget.exe'
}
function Repair-TeXWinGetLicense {
    $script:repairs++
    if ($script:repairFails) { throw 'License repair denied or failed' }
}
function Add-AppxPackage { $script:registrations++ }
foreach ($failures in @(0,1,2)) {
    Case "startup failures=${failures}: healthy, repaired, or still rejected" {
        $script:starts=0; $script:repairs=0; $script:registrations=0
        $script:failedStarts=$failures; $script:repairFails=$false
        if ($failures -eq 2) { Throws { & $startupCheck } } else { & $startupCheck }
        Assert ($script:starts -eq [Math]::Min(1+$failures,2))
        Assert ($script:repairs -eq [Math]::Min($failures,1))
    }
}
Case 'denied license repair stops; never reports successful setup' {
    $script:starts=0; $script:repairs=0; $script:failedStarts=1; $script:repairFails=$true
    Throws { & $startupCheck }; Assert ($script:starts -eq 1 -and $script:repairs -eq 1)
}
# Platform identity is stubbed; production download/provision/cleanup/elevation logic is used.
$repair=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Repair-TeXWinGetLicense'},$false)
$identity=$repair.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$admin'},$true)
. ([scriptblock]::Create($repair.Extent.Text.Replace($identity.Extent.Text,'$admin = $script:isAdmin')))
function Invoke-RestMethod { throw 'GitHub API must not be needed' }
function Invoke-WebRequest([switch]$UseBasicParsing,$Uri,$OutFile) {
    if ($Uri -eq 'https://github.com/microsoft/winget-cli/releases/latest') {
        return [pscustomobject]@{BaseResponse=[pscustomobject]@{ResponseUri=[uri]'https://github.com/microsoft/winget-cli/releases/tag/v1.29.380'}}
    }
    if ($Uri -eq 'https://github.com/microsoft/winget-cli/releases/expanded_assets/v1.29.380') {
        $links=@([pscustomobject]@{href='/microsoft/winget-cli/releases/download/v1.29.380/other.zip'})
        if (-not $script:noLicense) { $links+=[pscustomobject]@{href='/microsoft/winget-cli/releases/download/v1.29.380/official_License1.xml'} }
        return [pscustomobject]@{Links=$links}
    }
    Assert ($Uri -like 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380/*')
    $script:directory=Split-Path -Parent $OutFile
    if ($script:failDownload) { throw 'Network unavailable' }
    Set-Content -LiteralPath $OutFile 'test Microsoft asset'
}
function Add-AppxProvisionedPackage([switch]$Online,$PackagePath,$LicensePath) {
    Assert ($Online -and (Test-Path -LiteralPath $PackagePath) -and (Test-Path -LiteralPath $LicensePath))
    $script:provisions++
    if ($script:provisionFails) { throw 'Provision rejected' }
}
function Start-Process($FilePath,$Verb,$ArgumentList,[switch]$Wait,[switch]$PassThru) {
    $script:elevations++
    Assert ($Verb -eq 'RunAs' -and $Wait -and $PassThru)
    Assert ($FilePath -like '*WindowsPowerShell*v1.0*powershell.exe')
    Assert ($ArgumentList[0] -eq '-NoProfile' -and $ArgumentList[1] -eq '-EncodedCommand')
    $child=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[2]))
    Assert ($child -match 'Repair-TeXWinGetLicense; exit 0' -and $child -notmatch 'Update-TeX|Bypass|Set-ExecutionPolicy')
    $childErrors=$null; [void][Management.Automation.Language.Parser]::ParseInput($child,[ref]$null,[ref]$childErrors)
    Assert (-not $childErrors)
    if ($script:cancelUac) { throw 'User cancelled elevation' }
    [pscustomobject]@{ExitCode=$script:childExit}
}
foreach ($mode in @('success','download','missing-license','provision','elevate','child-error','uac-cancel')) {
    Case "official license repair: $mode" {
        $script:provisions=0; $script:elevations=0; $script:isAdmin=$mode -notin @('elevate','child-error','uac-cancel')
        $script:noLicense=$mode -eq 'missing-license'; $script:failDownload=$mode -eq 'download'
        $script:provisionFails=$mode -eq 'provision'; $script:cancelUac=$mode -eq 'uac-cancel'
        $script:childExit=if ($mode -eq 'child-error') {1} else {0}
        $oldRoot=$env:SystemRoot; $env:SystemRoot=[IO.Path]::GetTempPath()
        try {
            if ($mode -in @('success','elevate')) { Repair-TeXWinGetLicense } else { Throws { Repair-TeXWinGetLicense } }
        } finally { $env:SystemRoot=$oldRoot }
        Assert ($script:provisions -eq $(if ($mode -in @('success','provision')) {1} else {0}))
        Assert ($script:elevations -eq $(if ($script:isAdmin) {0} else {1}))
    }
}
Write-Host "$script:count isolated WinGet checks passed. No real Appx installation."
