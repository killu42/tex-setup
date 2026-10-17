# Explicit simplified removal, including previously installed MiKTeX.
$texCode = Invoke-RestMethod 'https://raw.githubusercontent.com/killu42/tex-setup/main/simple/windows.ps1' -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($texCode)) { throw 'Leerer Download.' }
Invoke-Expression $texCode
Remove-TeX
