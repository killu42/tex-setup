# Parse only the fallback function; no actual network/Appx/bootstrap on this host.
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'win.ps1'),[ref]$tokens,[ref]$errors)
if ($errors) { throw ($errors | Out-String) }
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-TeXWinGetRelease'},$false)
. ([scriptblock]::Create($function.Extent.Text))
$script:count=0
function Assert($condition) { if (-not $condition) { throw 'Assertion failed' } }
function Invoke-WebRequest([switch]$UseBasicParsing,$Uri,$OutFile) {
    Assert ($Uri -like 'https://github.com/microsoft/winget-cli/releases/latest/download/*')
    if ($script:failDownload) { throw 'mock network failure' }
    $script:directory=Split-Path -Parent $OutFile
    Set-Content -LiteralPath $OutFile 'mock release asset'
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
Write-Host "$script:count isolated WinGet release checks passed. No real Appx installation."
