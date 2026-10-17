# Isolated editor/shortcut tests. COM and package operations are mocked.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'track.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('tex-editor-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$count = 0
function Assert($Value) { if (-not $Value) { throw 'Assertion failed' } }
function Throws([scriptblock]$Action) { $caught=$false; try { & $Action } catch { $caught=$true }; Assert $caught }
function Get-TeXProgramsFolders { $script:programs; $script:common }
function Get-TeXShortcut([string]$Path) {
    Assert-TeXPlainPath $Path
    $link = [pscustomobject]@{Path=$Path; TargetPath=''; Arguments=''; WorkingDirectory=''; Description=''}
    if (Test-Path -LiteralPath $Path) { $link = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    $link | Add-Member -MemberType ScriptMethod -Name Save -Value { $this | ConvertTo-Json | Set-Content -LiteralPath $this.Path }
    $link
}
function Invoke-TeXNative($File,$Arguments) {
    $script:calls += ,@($Arguments)
    if ($script:failPackage) { return 9 }
    if (-not $script:missingAfter) { Set-Content -LiteralPath $script:editor -Value 'mock executable' }
    0
}
function Case($Name,[scriptblock]$Test) {
    $base = Join-Path $root ([guid]::NewGuid())
    $script:programs=Join-Path $base 'programs'; $script:common=Join-Path $base 'common'
    $script:bin=Join-Path $base 'x64'
    foreach ($p in @($script:programs,$script:common,$script:bin)) { [void][IO.Directory]::CreateDirectory($p) }
    $script:editor=Join-Path $script:bin 'miktex-texworks.exe'
    Set-Content -LiteralPath $script:editor -Value 'mock executable'
    $script:updater=[pscustomobject]@{File=(Join-Path $script:bin 'miktex.exe');Admin=$false}
    $script:record=[pscustomobject]@{baseline='absent'}
    $script:calls=@();$script:failPackage=$false;$script:missingAfter=$false
    & $Test
    $script:count++; Write-Host "PASS $Name"
}
function Link($Path,$Target) { $l=Get-TeXShortcut $Path; $l.TargetPath=$Target; $l.Save() }
Case 'missing shortcut created and points to registered editor' {
    Ensure-TeXEditor $updater $record
    Assert ((Find-TeXEditorShortcut $editor) -eq (Join-Path $programs 'TeXworks.lnk'))
    Assert ($record.editorLinks.Count -eq 1); Assert ($calls.Count -eq 0)
}
Case 'repeat leaves matching shortcut untouched and ownership unchanged' {
    Ensure-TeXEditor $updater $record; $hash=$record.editorLinks[0].Hash
    Ensure-TeXEditor $updater $record
    Assert ($record.editorLinks.Count -eq 1); Assert ($record.editorLinks[0].Hash -eq $hash)
}
Case 'existing shortcut in MiKTeX subfolder is preserved' {
    $folder=Join-Path $programs 'MiKTeX'; [void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder 'TeXworks.lnk'; Link $path $editor
    $hash=(Get-FileHash $path).Hash; Ensure-TeXEditor $updater $record
    Assert ((Get-FileHash $path).Hash -eq $hash); Assert (-not $record.editorLinks)
}
Case 'shared matching shortcut reused without writing shared folder' {
    $path=Join-Path $common 'TeXworks.lnk'; Link $path $editor
    Ensure-TeXEditor $updater $record
    Assert ((Find-TeXEditorShortcut $editor) -eq $path); Assert (-not $record.editorLinks)
}
Case 'different editor shortcut preserved; separate named link created' {
    $path=Join-Path $programs 'TeXworks.lnk'; Link $path 'different.exe'
    Ensure-TeXEditor $updater $record
    Assert ((Get-TeXShortcut $path).TargetPath -eq 'different.exe')
    Assert ((Find-TeXEditorShortcut $editor) -eq (Join-Path $programs 'TeXworks (MiKTeX).lnk'))
}
Case 'conflicting user shortcuts never overwritten' {
    Link (Join-Path $programs 'TeXworks.lnk') 'different.exe'
    Link (Join-Path $programs 'TeXworks (MiKTeX).lnk') 'other.exe'
    Throws { Ensure-TeXEditor $updater $record }; Assert (-not $record.editorLinks)
}
Case 'missing editor package installed using registered x64 updater' {
    Remove-Item -LiteralPath $editor; Ensure-TeXEditor $updater $record
    Assert (($calls[0] -join ' ') -eq 'packages install miktex-texworks-bin-x64-2.9')
    Assert (Find-TeXEditorShortcut $editor)
}
Case 'shared editor package uses administrator mode' {
    $updater.Admin=$true; Remove-Item -LiteralPath $editor; Ensure-TeXEditor $updater $record
    Assert (($calls[0] -join ' ') -eq '--admin packages install miktex-texworks-bin-x64-2.9')
}
Case 'failed package repair cannot report success' {
    Remove-Item -LiteralPath $editor; $script:failPackage=$true
    Throws { Ensure-TeXEditor $updater $record }; Assert (-not (Find-TeXEditorShortcut $editor))
}
Case 'success exit without executable is rejected' {
    Remove-Item -LiteralPath $editor; $script:missingAfter=$true
    Throws { Ensure-TeXEditor $updater $record }; Assert (-not $record.editorLinks)
}
Case 'own unmodified shortcut removed only by explicit cleanup' {
    Ensure-TeXEditor $updater $record; Remove-TeXEditorLinks $record
    Assert (-not (Find-TeXEditorShortcut $editor))
}
Case 'changed shortcut preserved on cleanup' {
    Ensure-TeXEditor $updater $record; $path=$record.editorLinks[0].Path; Link $path 'different.exe'
    Remove-TeXEditorLinks $record; Assert (Test-Path $path)
}
Case 'outside path in record never deleted' {
    Ensure-TeXEditor $updater $record; $path=Join-Path $common 'TeXworks.lnk'; Link $path $editor
    $record.editorLinks[0].Path=$path; $record.editorLinks[0].Hash=(Get-FileHash $path).Hash
    Remove-TeXEditorLinks $record; Assert (Test-Path $path)
}
Case 'previous installation without editor record is repairable' {
    $record.baseline='present'; Ensure-TeXEditor $updater $record
    Assert ($record.baseline -eq 'present'); Assert (Find-TeXEditorShortcut $editor)
}
Write-Host "$count isolated editor checks passed. No native COM/Windows test."
