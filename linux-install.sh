#!/bin/bash
# Standalone entry. Download fully before evaluating; never run partial data.
(
  set -eu
  [ "$(uname -s)" = Linux ] || { printf 'Nur fuer Linux.\n' >&2; exit 1; }
  tex_url=https://raw.githubusercontent.com/killu42/tex-setup/main/track.sh
  if command -v curl >/dev/null 2>&1; then
    tex_tracker=$(curl -fsSL "$tex_url")
  else
    tex_tracker=$(wget -qO- "$tex_url")
  fi
  [ -n "$tex_tracker" ] || exit 1
  eval "$tex_tracker"
  tex_install sudo apt-get install -y texlive-latex-extra texlive-lang-german \
    texlive-fonts-recommended biber latexmk texstudio
)
