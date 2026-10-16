#!/bin/bash
# Download completely before execution. No personal data or telemetry is sent by this script.
set -euo pipefail

fail() { printf 'TeX-Setup: %s\n' "$*" >&2; exit 1; }

direct_mactex() (
  # The official, version-independent MacTeX package supports Intel as well.
  local tex_tmp
  tex_tmp=$(mktemp -d)
  trap 'rm -f "$tex_tmp/MacTeX.pkg"; rmdir "$tex_tmp" 2>/dev/null || true' EXIT
  curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
    https://mirror.ctan.org/systems/mac/mactex/MacTeX.pkg -o "$tex_tmp/MacTeX.pkg"
  spctl --assess --type install "$tex_tmp/MacTeX.pkg"
  sudo installer -pkg "$tex_tmp/MacTeX.pkg" -target /
)

main() {
  [[ $(uname -s) == Darwin ]] || fail 'Dieses Skript ist nur fuer macOS.'
  [[ $EUID -ne 0 ]] || fail 'Ohne sudo starten; das Passwort wird bei Bedarf abgefragt.'
  local tex_engine tex_info tex_brew tex_bootstrap tex_arch tex_os
  tex_engine=$(command -v pdflatex || true)
  if [[ -n $tex_engine ]]; then
    tex_info=$("$tex_engine" --version)
    [[ $tex_info == *'TeX Live'* && -x /Library/TeX/texbin/tlmgr ]] ||
      fail 'Eine andere TeX-Installation ist vorhanden; sie bleibt unveraendert.'
  fi
  # BasicTeX is intentionally not silently replaced by the full distribution.
  if [[ -x /Library/TeX/texbin/tlmgr && ! -d /Applications/TeX/TeXShop.app ]]; then
    fail 'Eine andere oder unvollstaendige TeX-Installation ist vorhanden; sie bleibt erhalten.'
  fi

  tex_arch=$(uname -m)
  if [[ $(sysctl -in sysctl.proc_translated 2>/dev/null || true) == 1 ]]; then
    fail 'Das Terminal laeuft im Intel-Kompatibilitaetsmodus. Es wurde nichts installiert.'
  fi
  tex_os=$(sw_vers -productVersion)
  tex_brew=$(command -v brew || true)
  if [[ -z $tex_brew && -x /opt/homebrew/bin/brew ]]; then
    tex_brew=/opt/homebrew/bin/brew
  elif [[ -z $tex_brew && -x /usr/local/bin/brew ]]; then
    tex_brew=/usr/local/bin/brew
  fi

  # Use official MacTeX directly on older/Intel Macs; do not install unsupported Homebrew.
  if [[ $tex_arch != arm64 || ${tex_os%%.*} -lt 15 ]]; then
    direct_mactex
  else
    export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1
    if [[ -z $tex_brew ]]; then
      tex_bootstrap=$(curl --fail --silent --show-error --location --retry 3 \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
      /bin/bash -c "$tex_bootstrap"
      tex_brew=/opt/homebrew/bin/brew
    fi
    [[ -x $tex_brew ]] || fail 'Homebrew konnte nicht eingerichtet werden.'
    "$tex_brew" update
    if "$tex_brew" list --cask mactex >/dev/null 2>&1; then
      if [[ -x /Library/TeX/texbin/tlmgr ]]; then
        "$tex_brew" upgrade --cask mactex
      else
        "$tex_brew" reinstall --cask mactex
      fi
    elif [[ -x /Library/TeX/texbin/tlmgr ]]; then
      # Do not adopt an unmanaged installation into Homebrew.
      direct_mactex
    else
      "$tex_brew" install --cask mactex
    fi
  fi
  [[ -x /Library/TeX/texbin/tlmgr ]] || fail 'MacTeX wurde nicht vollstaendig installiert.'
  sudo /Library/TeX/texbin/tlmgr update --self --all
  open /Applications/TeX/TeXShop.app
  printf 'Fertig: MacTeX ist eingerichtet; TeXShop wird geoeffnet.\n'
}

main "$@"
