# Isolated Update-TeX checks: external processes and Windows-only COM/registry are mocked.
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'win.ps1'),[ref]$tokens,[ref]$errors)
if ($errors) { throw ($errors | Out-String) }
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-TeX'},$false).Extent.Text
$fn=$fn.Replace('& $miktex @Arguments | Out-Host','Invoke-MockMiKTeX $Arguments')
$fn=$fn.Replace('& $miktex packages check-update | Out-Host',"Invoke-MockMiKTeX @('packages','check-update')")
$fn=$fn.Replace("[Environment]::GetFolderPath('Programs')",'$script:programs')
. ([scriptblock]::Create($fn))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('tex-update-check-'+[guid]::NewGuid())
$script:count=0
function Assert($ok,$message) { if (-not $ok) { throw $message } }
function Get-ItemProperty($Path) { @($script:registrations) }
function New-Object($ComObject) {
    Assert ($ComObject -eq 'WScript.Shell') 'Unexpected COM request'
    $obj=[pscustomobject]@{}
    $obj | Add-Member ScriptMethod CreateShortcut {
        param($path)
        if (-not $script:links.ContainsKey($path)) {
            $link=[pscustomobject]@{Path=$path;TargetPath='';WorkingDirectory=''}
            $link | Add-Member ScriptMethod Save { [IO.File]::WriteAllText($this.Path,'mock shortcut') }
            $script:links[$path]=$link
        }
        $script:links[$path]
    }
    $obj
}
function Invoke-MockMiKTeX([string[]]$Arguments) {
    $command=$Arguments -join ' '
    $script:calls.Add($command)
    $global:LASTEXITCODE=0
    if ($command -eq 'packages check-update') {
        $script:checks++
        if ($script:checks -le $script:updatesPending) { $global:LASTEXITCODE=100 }
        if ($script:checks -le $script:checkFailures) { $global:LASTEXITCODE=1 }
    }
    if ($command -eq 'packages update' -and $script:failUpdate) { $global:LASTEXITCODE=5 }
    if ($command -like 'packages install miktex-texworks*') { [IO.File]::WriteAllText($script:editor,'mock executable') }
}
function Throws([scriptblock]$action,$pattern) {
    $caught=$null; try { & $action } catch { $caught=$_.Exception.Message }
    Assert ($caught -match $pattern) "Expected error $pattern; got $caught"
}
function Case($name,[scriptblock]$action) {
    $dir=Join-Path $testRoot ([guid]::NewGuid())
    $root=Join-Path $dir 'MiKTeX'; $bin=Join-Path $root 'miktex/bin/x64'
    [void][IO.Directory]::CreateDirectory($bin)
    [IO.File]::WriteAllText((Join-Path $bin 'miktex.exe'),'mock updater')
    $script:editor=Join-Path $bin 'miktex-texworks.exe'
    [IO.File]::WriteAllText($script:editor,'mock editor')
    $script:programs=Join-Path $dir 'Programs'
    $script:registrations=@([pscustomobject]@{DisplayName='MiKTeX';InstallLocation=$root})
    $script:links=@{}; $script:calls=[Collections.Generic.List[string]]::new()
    $script:checks=0; $script:updatesPending=0; $script:checkFailures=0; $script:failUpdate=$false
    $global:LASTEXITCODE=0
    $pathBefore=$env:Path
    try { & $action } finally { $env:Path=$pathBefore }
    $script:count++; Write-Host "PASS $name"
}
foreach ($code in @(0,-1978335135,-1978335189)) {
    Case "install/current-package exit $code updates and repairs" {
        $global:LASTEXITCODE=$code; Update-TeX
        Assert ($script:calls -contains 'packages update') 'Update not executed'
        Assert ($script:links.Values.TargetPath -contains $script:editor) 'Shortcut not repaired'
    }
}
Case 'real installer failure stops before mutations' {
    $global:LASTEXITCODE=5; Throws {Update-TeX} 'Installation fehlgeschlagen'
    Assert ($script:calls.Count -eq 0 -and $script:links.Count -eq 0) 'Changed after failure'
}
Case 'core update triggers another update pass' {
    $script:updatesPending=1; Update-TeX; Assert ($script:checks -eq 2) 'Second pass missing'
}
Case 'unfinished updates never report success' {
    $script:updatesPending=5; Throws {Update-TeX} 'Updates nicht abgeschlossen'
}
Case 'temporary update-check timeout is retried' {
    $script:checkFailures=1; Update-TeX
    Assert ($script:checks -eq 2) 'Timeout was not retried'
}
Case 'persistent update-check failure stops after three attempts' {
    $script:checkFailures=10; Throws {Update-TeX} 'Updates nicht abgeschlossen'
    Assert ($script:checks -eq 3 -and $script:links.Count -eq 0) 'Retry limit or failure handling wrong'
}
Case 'package update failure never reports success' {
    $script:failUpdate=$true; Throws {Update-TeX} 'MiKTeX fehlgeschlagen'
}
Case 'missing editor is installed before shortcut creation' {
    Remove-Item -LiteralPath $script:editor; Update-TeX
    Assert ($script:calls -contains 'packages install miktex-texworks-bin-x64-2.9') 'Editor install missing'
}
Case 'repeat does not create duplicate shortcuts' {
    Update-TeX; $global:LASTEXITCODE=-1978335135; Update-TeX
    Assert ($script:links.Count -eq 1) 'Duplicate shortcut'
}
Case 'unrelated shortcut is never overwritten' {
    Update-TeX; $script:links.Values | ForEach-Object {$_.TargetPath='another-editor.exe'}
    Throws {Update-TeX} 'andere TeXworks-Verknuepfung'
    Assert ($script:links.Values.TargetPath -contains 'another-editor.exe') 'Foreign shortcut changed'
}
Case 'ambiguous installations rejected' {
    $script:registrations+=@($script:registrations)[0]
    Throws {Update-TeX} 'Keine eindeutige'
}
Write-Host "$script:count isolated update/repair checks passed; no real installation."
