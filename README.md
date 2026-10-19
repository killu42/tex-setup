# TeX-Setup

Zwei Hilfsskripte richten Homebrew bzw. WinGet ein oder aktualisieren sie.
Die TeX-Installation erfolgt separat mit dem sichtbaren Paketmanager-Befehl.
Ein expliziter kurzer Folgeaufruf aktualisiert die TeX-Pakete und repariert
den fehlenden TeXworks-Startmenueeintrag. Keine Installationshistorie.

## Mac: MacTeX mit TeXShop

```sh
s=$(curl -fsSL https://raw.githubusercontent.com/killu42/tex-setup/main/mac.sh) && eval "$s" &&
brew install --cask mactex && tex_update
```

Entfernen:

```sh
HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --cask mactex
```

Der Zusatz verhindert das automatische Entfernen weiterer ungenutzter Pakete.

## Windows: MiKTeX mit TeXworks

In Windows PowerShell:

WinGet wird zuerst direkt aus Microsofts signiertem Installationspaket
eingerichtet/aktualisiert. Nur wenn das scheitert, wird das Microsoft-
PowerShell-Modul als Alternative verwendet. Aktuelle oder neuere
App-Installer-Pakete werden nicht zurueckgestuft.
Auch der tatsaechliche Start wird geprueft. Bei einem Windows-Startfehler
wird Microsofts signiertes Paket mit seiner offiziellen Offline-Lizenz
repariert und erneut gestartet. Nur diese Reparatur fordert bei Bedarf
Administratorrechte an; MiKTeX bleibt im urspruenglichen Benutzerkonto.

```powershell
irm https://raw.githubusercontent.com/killu42/tex-setup/main/win.ps1 | iex
winget install --id MiKTeX.MiKTeX -e --scope user -s winget --no-upgrade; Update-TeX
```

Entfernen:

```powershell
winget uninstall --id MiKTeX.MiKTeX -e --scope user -s winget
```

Im geöffneten MiKTeX-Fenster **Remove MiKTeX** wählen und bestätigen.
Homebrew und WinGet bleiben erhalten. TeX wird auch entfernt, wenn es bereits
vor dieser Anleitung installiert war. Eigene Dokumente gehören in Dokumente-
oder Projektordner, nicht in die Programmordner.

`--no-upgrade` laesst vorhandenes MiKTeX seinem eigenen Updater; `Update-TeX`
aktualisiert danach Pakete und Programmkomponenten, prueft TeXworks und stellt
den Eintrag unter Startmenue/MiKTeX her. Auch bei wiederholtem Aufruf.
Die Windows-Anleitung gilt fuer eine Benutzerinstallation, nicht fuer portable,
mehrfache oder systemweite MiKTeX-Installationen. MacTeX wird im von Homebrew
angebotenen Paketstand installiert/aktualisiert; `tex_update` aktualisiert
zusaetzlich TeX Live. Intel nutzt das aktuelle offizielle MacTeX-Paket ohne Brew.
Linux nutzt die Paketversionen der jeweiligen Ubuntu-/Debian-/Mint-Version.

## Prüfungen

`node test-setup.mjs` und `pwsh -NoProfile -File test-winget-bootstrap.ps1`
prüfen die Paketmanager-Skripte isoliert, ohne echte Programme zu installieren.
Sie ersetzen keinen vollständigen Installationstest auf einem Nutzerrechner.
Alte Zusatzskripte und deren Tests bleiben in der Git-Historie wiederherstellbar.

`check-pdf.mjs QUELLE PDF PDFTOTEXT` vergleicht die acht aus der PDF kopierten
Bloecke exakt und erzeugt `pdf-commands.json`. Die Lifecycle-Tests fuehren diese
Bloecke nur in wegwerfbaren GitHub-hosted VMs aus: zweimal installieren/updaten,
Windows-Startmenue reparieren, Editor starten, PDF erzeugen, entfernen und
eigene Dokumente sowie Paketmanager erhalten. Keine Freigabe durch einen
blossen Syntax- oder Mocktest; der jeweilige native Workflow muss gruen sein.
