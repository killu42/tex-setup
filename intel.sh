#!/bin/bash
# Official MacTeX package: no Homebrew required.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || exit 1
tex_download=$(mktemp -d)
trap 'rm -f -- "$tex_download/MacTeX.pkg"; rmdir "$tex_download"' EXIT
curl -fL --retry 3 https://mirror.ctan.org/systems/mac/mactex/MacTeX.pkg \
  -o "$tex_download/MacTeX.pkg"
spctl --assess --type install "$tex_download/MacTeX.pkg"
sudo installer -pkg "$tex_download/MacTeX.pkg" -target /
test -x /Library/TeX/texbin/pdflatex
test -x /Applications/TeX/TeXShop.app/Contents/MacOS/TeXShop
printf 'MacTeX und TeXShop sind eingerichtet.\n'
