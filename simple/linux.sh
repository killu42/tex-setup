#!/bin/bash
# Explicit package removal, without provenance/state or package-manager removal.
set -euo pipefail
[ "$(uname -s)" = Linux ] || { printf 'Nur fuer Linux mit APT.\n' >&2; exit 1; }
command -v apt-get >/dev/null
command -v dpkg-query >/dev/null
case "${1:-}" in
  install)
    sudo apt-get update
    sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio
    ;;
  remove)
    tex_inventory=$(dpkg-query -W '-f=${binary:Package}\t${db:Status-Abbrev}\n')
    tex_packages=()
    while read -r tex_name tex_status; do
      if [[ "$tex_status" = ii && "$tex_name" =~ ^(texlive(-[a-z0-9+.-]+)?|biber|latexmk|texstudio)(:[a-z0-9-]+)?$ ]]; then
        tex_packages+=("$tex_name")
      fi
    done <<< "$tex_inventory"
    if [ "${#tex_packages[@]}" -eq 0 ]; then printf 'Keine passenden TeX-Pakete installiert.\n'; exit 0; fi
    tex_plan=$(LC_ALL=C apt-get -s remove -- "${tex_packages[@]}")
    # APT must not remove unrelated reverse dependencies along with TeX.
    while read -r tex_action tex_name tex_rest; do
      [ "$tex_action" = Remv ] || continue
      tex_found=0
      for tex_package in "${tex_packages[@]}"; do
        if [ "$tex_name" = "$tex_package" ] || [ "$tex_name" = "${tex_package%%:*}" ]; then tex_found=1; break; fi
      done
      [ "$tex_found" = 1 ] || { printf 'Abbruch: Ein anderes Programm benoetigt TeX (%s).\n' "$tex_name" >&2; exit 1; }
    done <<< "$tex_plan"
    sudo apt-get remove -y -- "${tex_packages[@]}"
    printf 'TeX-Live-Pakete und TeXstudio entfernt. APT und gemeinsame Hilfsprogramme bleiben.\n'
    ;;
  *) printf 'Aufruf: bash linux.sh install|remove\n' >&2; exit 2 ;;
esac
