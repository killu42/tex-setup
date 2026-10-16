# Offline tests for the short Windows loader/removal calls.
$ErrorActionPreference='Stop'
$script:source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'track.ps1') -Raw
$script:remove=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remove.ps1') -Raw
$script:count=0
function Assert($Value) { if (-not $Value) { throw 'Assertion failed' } }
function Throws([scriptblock]$Action) { $caught=$false; try { & $Action } catch { $caught=$true }; Assert $caught }
function Case($Name,[scriptblock]$Test) {
    $script:removals=0; $script:downloadMode='ok'
    & $Test
    $script:count++
    Write-Host "PASS $Name"
}
function Remove-TeX { throw 'Stale function must never run' }
function Invoke-RestMethod {
    param($Uri)
    switch ($script:downloadMode) {
        'fail' { Write-Error 'mock download failed'; return }
        'empty' { return '' }
        'invalid' { return 'function Remove-TeX {' }
        'tracker' { return $script:source }
        default { return 'function Remove-TeX { $script:removals++ }' }
    }
}
Case 'both PowerShell sources parse' {
    foreach ($name in @('track.ps1','remove.ps1')) {
        $tokens=$null; $parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$parseErrors)
        Assert (-not $parseErrors)
    }
}
Case 'short tracker load defines callable installer without setup side effects' {
    $script:downloadMode='tracker'
    irm https://raw.githubusercontent.com/killu42/tex-setup/main/track.ps1 | iex
    Assert ([bool](Get-Command Install-TeX -CommandType Function))
    Throws { Install-TeX { throw 'not the approved command' } }
    Assert ($script:removals -eq 0)
}
Case 'removal entry dispatches once and leaves caller preference intact' {
    $ErrorActionPreference='Continue'
    Invoke-Expression $script:remove
    Assert ($script:removals -eq 1)
    Assert ($ErrorActionPreference -eq 'Continue')
}
Case 'failed download stops before stale function even with Continue preference' {
    $ErrorActionPreference='Continue'
    $script:downloadMode='fail'
    Throws { Invoke-Expression $script:remove }
    Assert ($script:removals -eq 0)
    Assert ($ErrorActionPreference -eq 'Continue')
}
Case 'empty download rejected' {
    $script:downloadMode='empty'
    Throws { Invoke-Expression $script:remove }
    Assert ($script:removals -eq 0)
}
Case 'incomplete downloaded code rejected' {
    $script:downloadMode='invalid'
    Throws { Invoke-Expression $script:remove }
    Assert ($script:removals -eq 0)
}
Write-Host "$script:count isolated Windows entry-point checks passed."
