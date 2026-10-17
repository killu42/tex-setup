#!/bin/bash
# Remove the active standard MacTeX distribution and TeXShop, not user documents.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || exit 1
tex_bin=/Library/TeX/texbin
if [ -x "$tex_bin/kpsewhich" ]; then
  tex_root=$("$tex_bin/kpsewhich" -var-value=TEXMFROOT)
  [[ "$tex_root" =~ ^/usr/local/texlive/[0-9]{4}$ ]] &&
    [ ! -L "$tex_root" ] && [ -f "$tex_root/tlpkg/texlive.tlpdb" ] ||
    { printf 'Keine eindeutige MacTeX-Installation. Nichts entfernt.\n' >&2; exit 1; }
  sudo "$tex_bin/tlmgr" uninstall --all --force
  [ ! -x "$tex_bin/pdflatex" ]
fi
tex_app=/Applications/TeX/TeXShop.app
if [ -e "$tex_app" ]; then
  [ ! -L /Applications/TeX ] && [ ! -L "$tex_app" ] &&
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$tex_app/Contents/Info.plist")" = TeXShop ] ||
    { printf 'Unbekannte TeXShop-App. Nicht entfernt.\n' >&2; exit 1; }
  sudo /bin/rm -rf -- /Applications/TeX/TeXShop.app
fi
printf 'MacTeX und TeXShop entfernt. Eigene Dokumente bleiben erhalten.\n'
