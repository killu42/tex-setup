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
            try { $writer.Write('<Bundle><Identity Version="1.29.380.0" /></Bundle>') }
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
    $script:installs++
    Assert (Test-Path -LiteralPath $Path)
    Assert (@($DependencyPath).Count -eq 1)
    Assert ((Split-Path -Leaf (Split-Path -Parent $DependencyPath[0])) -eq $script:expected)
    if ($script:failInstall) { throw 'mock Appx policy rejection' }
}
function Case($Name,[scriptblock]$Action) {
    $script:installs=0; $script:directory=$null
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
Case 'Appx security rejection propagates and cleans only temporary assets' { $script:expected='x64'; $script:failInstall=$true; Throws { Install-TeXWinGetRelease -Architecture 'AMD64' }; Assert ($script:installs -eq 1) }
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
Write-Host "$script:count isolated WinGet checks passed. No real Appx installation."
