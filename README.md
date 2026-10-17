# TeX-Setup

Zwei Hilfsskripte richten Homebrew bzw. WinGet ein oder aktualisieren sie.
Die eigentliche TeX-Installation erfolgt separat mit dem Paketmanager.

## Mac: MacTeX mit TeXShop

```sh
s=$(curl -fsSL https://raw.githubusercontent.com/killu42/tex-setup/main/mac.sh) && eval "$s" &&
brew install --cask mactex
```

Entfernen:

```sh
HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --cask mactex
```

Der Zusatz verhindert das automatische Entfernen weiterer ungenutzter Pakete.

## Windows: MiKTeX mit TeXworks

In Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/killu42/tex-setup/main/win.ps1 | iex
winget install --id MiKTeX.MiKTeX -e --scope user -s winget
```

Entfernen:

```powershell
winget uninstall --id MiKTeX.MiKTeX -e --scope user -s winget
```

Im geöffneten MiKTeX-Fenster **Remove MiKTeX** wählen und bestätigen.
Homebrew und WinGet bleiben erhalten. TeX wird auch entfernt, wenn es bereits
vor dieser Anleitung installiert war. Eigene Dokumente gehören in Dokumente-
oder Projektordner, nicht in die Programmordner.

Der direkte WinGet-Aufruf installiert MiKTeX; MiKTeX-Paketupdates und die
Reparatur einer fehlenden TeXworks-Verknüpfung sind darin nicht enthalten.

## Prüfungen

`node test-setup.mjs` und `pwsh -NoProfile -File test-winget-bootstrap.ps1`
prüfen die Paketmanager-Skripte isoliert, ohne echte Programme zu installieren.
Sie ersetzen keinen vollständigen Installationstest auf einem Nutzerrechner.
Alte Zusatzskripte und deren Tests bleiben in der Git-Historie wiederherstellbar.
