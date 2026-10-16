#!/bin/bash
set -euo pipefail

fail() { printf 'TeX-Setup: %s\n' "$*" >&2; exit 1; }
main() {
  [[ $(uname -s) == Linux ]] || fail 'Dieses Skript ist nur fuer Linux.'
  command -v apt-get >/dev/null || fail 'Unterstuetzt werden Debian, Ubuntu und Linux Mint.'
  local tex_engine
  tex_engine=$(command -v pdflatex || true)
  if [[ -n $tex_engine ]]; then
    dpkg-query --search "$tex_engine" 2>/dev/null | grep -q '^texlive-' ||
      fail 'Eine andere TeX-Installation ist vorhanden; sie bleibt unveraendert.'
  fi
  sudo apt-get update
  sudo apt-get install -y texlive-latex-extra texlive-lang-german \
    texlive-fonts-recommended biber latexmk texstudio
  printf 'Fertig: TeX Live und TeXstudio sind eingerichtet.\n'
  if [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} && $EUID -ne 0 ]]; then
    nohup texstudio >/dev/null 2>&1 &
  fi
}
main "$@"
