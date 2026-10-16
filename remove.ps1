# Standalone removal. No bootstrap, no global preference/policy changes.
& {
    $ErrorActionPreference = 'Stop'
    $tracker = Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/main/track.ps1' -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($tracker)) { throw 'Download ist leer. Nichts entfernt.' }
    Invoke-Expression $tracker
    Remove-TeX
}
