#!/bin/bash
# Remove the Homebrew-managed MacTeX suite, not Homebrew or user templates.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { printf 'Nur fuer macOS.\n' >&2; exit 1; }
tex_brew=$(command -v brew) || tex_brew=
if [ -z "$tex_brew" ] && [ -x /opt/homebrew/bin/brew ]; then tex_brew=/opt/homebrew/bin/brew; fi
if [ -z "$tex_brew" ] && [ -x /usr/local/bin/brew ]; then tex_brew=/usr/local/bin/brew; fi
[ -n "$tex_brew" ] || { printf 'Kein Homebrew gefunden. Nichts entfernt.\n'; exit 0; }
tex_casks=$("$tex_brew" list --cask)
if ! printf '%s\n' "$tex_casks" | /usr/bin/grep -qx mactex; then
  printf 'Kein durch Homebrew verwaltetes MacTeX gefunden. Nichts entfernt.\n'
  exit 0
fi
# Never --zap, --force, autoremove, or a hand-written recursive deletion.
HOMEBREW_NO_AUTOREMOVE=1 "$tex_brew" uninstall --cask mactex
tex_casks=$("$tex_brew" list --cask)
if printf '%s\n' "$tex_casks" | /usr/bin/grep -qx mactex; then exit 1; fi
printf 'MacTeX samt TeXShop entfernt. Homebrew bleibt erhalten.\n'
