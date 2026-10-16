# Local-only installation records. Source this file; no action runs on loading.
# Supported shells: bash and zsh. Never source/evaluate a saved record.
tex_error() { printf 'TeX-Setup: %s\n' "$*" >&2; return 1; }
tex_location() {
  case "$(uname -s)" in
    Darwin) tex_state="$HOME/Library/Application Support/TeX-Setup" ;;
    Linux) tex_state="${XDG_STATE_HOME:-$HOME/.local/state}/tex-setup" ;;
    *) tex_error 'Dieses Skript unterstuetzt nur macOS und Debian/Ubuntu/Mint.'; return 1 ;;
  esac
  case "$tex_state" in /*) ;; *) tex_error 'Ungueltiger Protokollpfad.'; return 1 ;; esac
  [ ! -L "$tex_state" ] || { tex_error 'Protokollordner ist ein Link.'; return 1; }
}
tex_lock() {
  tex_location || return
  umask 077
  mkdir -p "$tex_state" || return
  [ -O "$tex_state" ] || { tex_error 'Falscher Besitzer des Protokolls.'; return 1; }
  mkdir "$tex_state/lock" 2>/dev/null || { tex_error 'Ein anderer Vorgang laeuft oder wurde unterbrochen. Nichts entfernt.'; return 1; }
  tex_lock_held=1
  if [ -e "$tex_state/schema" ]; then
    [ ! -L "$tex_state/schema" ] && [ "$(cat "$tex_state/schema")" = tex-setup-1 ] || return 1
  else
    # Never adopt an unrelated or incomplete directory as a new record.
    [ "$(ls -A "$tex_state")" = lock ] || { tex_error 'Unbekanntes Protokoll; Abbruch.'; return 1; }
    printf '%s\n' tex-setup-1 > "$tex_state/schema" || return
  fi
  for tex_name in baseline completed pending owned before plan after manager current.tmp completed.tmp new.tmp; do
    [ ! -L "$tex_state/$tex_name" ] || { tex_error 'Ungueltige Protokolldatei.'; return 1; }
  done
  [ ! -e "$tex_state/pending" ] || { tex_error 'Frueherer Vorgang unvollstaendig; keine automatische Entfernung.'; return 1; }
}
tex_brew_path() {
  tex_brew=$(command -v brew 2>/dev/null) || tex_brew=
  if [ -z "$tex_brew" ] && [ -x /opt/homebrew/bin/brew ]; then tex_brew=/opt/homebrew/bin/brew; fi
  if [ -z "$tex_brew" ] && [ -x /usr/local/bin/brew ]; then tex_brew=/usr/local/bin/brew; fi
  [ -n "$tex_brew" ]
}
tex_prepare() {
  # Bootstrap remains separate from the visible TeX installation command.
  if [ "$(uname -s)" = Darwin ]; then
    tex_manager_before=present
    tex_brew_path || tex_manager_before=absent
    (tex_lock_held=0
     trap '[ "$tex_lock_held" != 1 ] || rmdir "$tex_state/lock" 2>/dev/null || :' EXIT
     tex_lock && { [ -e "$tex_state/manager" ] || printf 'Homebrew\t%s\tshared-infrastructure\n' "$tex_manager_before" > "$tex_state/manager"; }) || return
    tex_bootstrap=$(curl -fsSL https://raw.githubusercontent.com/killu42/tex-setup/main/mac.sh) || return
    eval "$tex_bootstrap" || return
  elif [ "$(uname -s)" = Linux ]; then
    command -v apt-get >/dev/null && command -v dpkg-query >/dev/null || return
  else
    tex_error 'Betriebssystem nicht unterstuetzt.'; return 1
  fi
}
tex_mac_existing() {
  # Include non-Homebrew installs, old distributions and standalone editors.
  for tex_path in /Applications/TeX /Applications/TeXShop.app /Library/TeX /usr/local/texlive /etc/paths.d/TeX /etc/manpaths.d/TeX; do
    if [ -e "$tex_path" ] || [ -L "$tex_path" ]; then return 0; fi
  done
  command -v pdflatex >/dev/null 2>&1 || command -v tlmgr >/dev/null 2>&1
}
tex_mac_fingerprint() (
  set -o pipefail
  # Include all entries and metadata, including symlinks; added user files or
  # another distribution make removal stop. Never recursively delete these here.
  for tex_path in /Applications/TeX /Library/TeX /usr/local/texlive /etc/paths.d/TeX /etc/manpaths.d/TeX; do
    if [ -e "$tex_path" ] || [ -L "$tex_path" ]; then
      find "$tex_path" -exec stat -f '%N|%HT|%z|%m|%i|%Y' {} + || exit 1
    fi
  done | LC_ALL=C sort | shasum -a 256
)
tex_packages() {
  LC_ALL=C dpkg-query -W '-f=${binary:Package}\t${db:Status-Abbrev}\t${Version}\n'
}
tex_install() (
  set -eu
  # Keep preparation out of the copy/paste block. Validate before any effects.
  case "$(uname -s):$*" in
    'Darwin:brew install --cask mactex') ;;
    'Linux:sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio') ;;
    *) tex_error 'Nur der Installationsbefehl aus der Anleitung ist erlaubt.'; exit 1 ;;
  esac
  tex_prepare || exit 1
  tex_lock_held=0
  trap '[ "$tex_lock_held" != 1 ] || rmdir "$tex_state/lock" 2>/dev/null || :' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tex_lock
  case "$(uname -s)" in
    Darwin)
      [ "$*" = 'brew install --cask mactex' ] || { tex_error 'Nur der MacTeX-Befehl aus der Anleitung ist erlaubt.'; exit 1; }
      tex_brew_path || { tex_error 'Homebrew fehlt.'; exit 1; }
      if [ ! -e "$tex_state/baseline" ]; then
        if tex_mac_existing || "$tex_brew" list --cask mactex >/dev/null 2>&1; then
          printf 'mac-present\n' > "$tex_state/baseline"
        else
          printf 'mac-absent\n' > "$tex_state/baseline"
        fi
      fi
      case "$(cat "$tex_state/baseline")" in mac-present|mac-absent) ;; *) exit 1 ;; esac
      if [ -f "$tex_state/completed" ] && [ "$(cat "$tex_state/baseline")" = mac-absent ]; then
        [ "$(tex_mac_fingerprint)" = "$(cat "$tex_state/after")" ] || { tex_error 'Installation wurde inzwischen veraendert; Nachweis bleibt unveraendert.'; exit 1; }
      fi
      printf 'install\n' > "$tex_state/pending"
      HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 "$tex_brew" install --cask mactex
      "$tex_brew" list --cask --versions mactex > "$tex_state/owned"
      [ -s "$tex_state/owned" ] || exit 1
      tex_mac_fingerprint > "$tex_state/after"
      ;;
    Linux)
      [ "$*" = 'sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio' ] || { tex_error 'Nur der APT-Befehl aus der Anleitung ist erlaubt.'; exit 1; }
      if [ ! -e "$tex_state/baseline" ]; then
        tex_packages > "$tex_state/before"
        printf 'linux\n' > "$tex_state/baseline"
      fi
      [ "$(cat "$tex_state/baseline")" = linux ] || exit 1
      # Snapshot immediately before each transaction, never claim unrelated deltas.
      tex_packages > "$tex_state/after"
      sudo apt-get update
      LC_ALL=C apt-get --simulate --no-remove install texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio > "$tex_state/plan"
      ! grep -q '^Remv ' "$tex_state/plan" || exit 1
      printf 'install\n' > "$tex_state/pending"
      sudo apt-get --no-remove install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio
      # Pending stays if the native command failed. No retrospective ownership.
      tex_packages > "$tex_state/completed.tmp"
      awk 'FILENAME==ARGV[1] {old[$1]=1; next} /^Inst / && !old[$2] {print $2}' "$tex_state/after" "$tex_state/plan" > "$tex_state/new.tmp"
      if [ -f "$tex_state/owned" ]; then cat "$tex_state/owned" >> "$tex_state/new.tmp"; fi
      LC_ALL=C sort -u "$tex_state/new.tmp" > "$tex_state/owned"
      # Every newly recorded package must be successfully configured.
      awk 'FILENAME==ARGV[1] {if ($2=="ii") ok[$1]=1; next} !ok[$1] {exit 1}' "$tex_state/completed.tmp" "$tex_state/owned"
      mv "$tex_state/completed.tmp" "$tex_state/after"
      rm "$tex_state/new.tmp"
      ;;
    *) exit 1 ;;
  esac
  printf 'complete\n' > "$tex_state/completed.tmp"
  mv "$tex_state/completed.tmp" "$tex_state/completed"
  rm "$tex_state/pending"
  printf 'Installation abgeschlossen. Lokales Protokoll gespeichert.\n'
)
tex_remove() (
  set -eu
  tex_lock_held=0
  trap '[ "$tex_lock_held" != 1 ] || rmdir "$tex_state/lock" 2>/dev/null || :' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tex_location
  if [ ! -d "$tex_state" ]; then printf 'Kein Installationsprotokoll. Nichts entfernt.\n'; exit 0; fi
  tex_lock
  [ -f "$tex_state/completed" ] && [ "$(cat "$tex_state/completed")" = complete ] || { tex_error 'Kein abgeschlossener Installationsnachweis. Nichts entfernt.'; exit 1; }
  case "$(cat "$tex_state/baseline")" in
    mac-present)
      [ "$(uname -s)" = Darwin ] || exit 1
      printf 'Vorhandenes MacTeX und seine Updates bleiben erhalten.\n'
      ;;
    mac-absent)
      [ "$(uname -s)" = Darwin ] || exit 1
      tex_brew_path || { tex_error 'Homebrew nicht erreichbar; Protokoll bleibt erhalten.'; exit 1; }
      tex_current=$("$tex_brew" list --cask --versions mactex)
      if [ -n "$tex_current" ]; then
        [ "$tex_current" = "$(cat "$tex_state/owned")" ] && [ "$(tex_mac_fingerprint)" = "$(cat "$tex_state/after")" ] || { tex_error 'MacTeX oder sein Programmordner wurde nachtraeglich veraendert. Nichts entfernt.'; exit 1; }
        # No --zap; user settings, templates and documents are never selected.
        HOMEBREW_NO_AUTOREMOVE=1 "$tex_brew" uninstall --cask mactex
        [ -z "$("$tex_brew" list --cask --versions mactex)" ] || exit 1
      elif tex_mac_existing; then
        tex_error 'MacTeX-Nachweis fehlt, aber TeX-Dateien sind noch vorhanden. Protokoll bleibt erhalten.'; exit 1
      fi
      ;;
    linux)
      [ "$(uname -s)" = Linux ] || exit 1
      tex_packages > "$tex_state/current.tmp"
      set --
      while IFS= read -r tex_pkg; do
        printf '%s\n' "$tex_pkg" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$' || { tex_error 'Ungueltiger Paketnachweis.'; exit 1; }
        # An entry that existed before setup can never be removed, even with
        # an inconsistent owned-list. No package-name globbing or options.
        ! awk -v p="$tex_pkg" '$1==p {found=1} END {exit !found}' "$tex_state/before" || exit 1
        if awk -v p="$tex_pkg" '$1==p && $2=="ii" {found=1} END {exit !found}' "$tex_state/current.tmp"; then
          tex_verified=$(sudo dpkg --verify "$tex_pkg") || exit 1
          [ -z "$tex_verified" ] || { tex_error "$tex_pkg wurde veraendert; Protokoll bleibt erhalten."; exit 1; }
          set -- "$@" "$tex_pkg"
        fi
      done < "$tex_state/owned"
      if [ "$#" -gt 0 ]; then
        LC_ALL=C apt-get --simulate remove "$@" > "$tex_state/plan"
        ! grep -q '^Inst ' "$tex_state/plan" || { tex_error 'Entfernung wuerde weitere Pakete installieren.'; exit 1; }
        awk 'FILENAME==ARGV[1] {own[$1]=1; next} /^Remv / && !own[$2] {exit 1}' "$tex_state/owned" "$tex_state/plan" || { tex_error 'Andere Programme benoetigen diese Pakete. Nichts entfernt.'; exit 1; }
        # dpkg removes ONLY this explicit list and refuses external dependants,
        # including changes since the simulation. No purge, force or autoremove.
        sudo dpkg --remove "$@"
        tex_packages > "$tex_state/current.tmp"
        for tex_pkg do
          ! awk -v p="$tex_pkg" '$1==p && $2=="ii" {found=1} END {exit !found}' "$tex_state/current.tmp" || exit 1
        done
      fi
      rm "$tex_state/current.tmp"
      ;;
    *) tex_error 'Unbekanntes Protokoll. Nichts entfernt.'; exit 1 ;;
  esac
  # Only our known record files, never recursively remove a user directory.
  for tex_name in baseline completed owned before plan after manager schema; do
    [ ! -f "$tex_state/$tex_name" ] || rm "$tex_state/$tex_name"
  done
  rmdir "$tex_state/lock"
  trap - EXIT
  rmdir "$tex_state" || { tex_error 'Zusaetzliche Dateien im Protokollordner bleiben erhalten.'; exit 1; }
  printf 'Entfernung abgeschlossen; lokales Protokoll geloescht.\n'
  printf 'Paketmanager, gemeinsam genutzte Hilfen und eigene Dokumente bleiben erhalten.\n'
)
