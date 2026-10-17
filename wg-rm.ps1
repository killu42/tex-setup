# Optional WinGet removal; never bootstrap or remove without a valid record.
& {
    $ErrorActionPreference = 'Stop'
    $tracker = Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/main/track.ps1' -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($tracker)) { throw 'Download ist leer. Nichts entfernt.' }
    Invoke-Expression $tracker
    Remove-TeXManager
}
