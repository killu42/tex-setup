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
tex_manager_location() {
  [ "$(uname -s)" = Darwin ] || { tex_error 'Homebrew-Entfernung nur unter macOS.'; return 1; }
  tex_location || return
  tex_manager_state="$tex_state-manager"
  [ ! -L "$tex_manager_state" ] || { tex_error 'Paketmanager-Nachweis ist ein Link.'; return 1; }
}
tex_manager_lock() {
  tex_manager_location || return
  umask 077
  mkdir -p "$tex_manager_state" || return
  [ -O "$tex_manager_state" ] || { tex_error 'Falscher Besitzer des Paketmanager-Nachweises.'; return 1; }
  mkdir "$tex_manager_state/lock" 2>/dev/null || { tex_error 'Paketmanager-Vorgang gesperrt.'; return 1; }
  tex_manager_lock_held=1
  for tex_name in schema user baseline prefix after status transaction; do
    [ ! -L "$tex_manager_state/$tex_name" ] || return 1
    [ ! -e "$tex_manager_state/$tex_name" ] || [ -f "$tex_manager_state/$tex_name" ] || return 1
  done
  if [ -e "$tex_manager_state/schema" ]; then
    [ "$(cat "$tex_manager_state/schema")" = tex-manager-1 ] &&
      [ "$(cat "$tex_manager_state/user")" = "$(id -u)" ] || return 1
    case "$(cat "$tex_manager_state/baseline")" in present|absent|protected) ;; *) return 1 ;; esac
    case "$(cat "$tex_manager_state/status")" in pending|complete) ;; *) return 1 ;; esac
  else
    [ "$(ls -A "$tex_manager_state")" = lock ] || { tex_error 'Unvollstaendiger Paketmanager-Nachweis.'; return 1; }
  fi
}
tex_manager_default_prefix() {
  if [ "$(uname -m)" = arm64 ]; then printf '/opt/homebrew\n'; else printf '/usr/local\n'; fi
}
tex_manager_existing() {
  tex_brew_path && return 0
  # Broken installations and a second architecture must also be preserved.
  for tex_path in /opt/homebrew /usr/local/Homebrew /usr/local/Cellar /usr/local/Caskroom /usr/local/.git /usr/local/Library/Homebrew; do
    if [ -e "$tex_path" ] || [ -L "$tex_path" ]; then return 0; fi
  done
  return 1
}
tex_manager_prefix() {
  tex_prefix=$(cat "$tex_manager_state/prefix") || return
  case "$tex_prefix" in /opt/homebrew|/usr/local) ;; *) tex_error 'Unbekannter Homebrew-Pfad.'; return 1 ;; esac
  [ ! -L "$tex_prefix" ] && [ -d "$tex_prefix" ] || return 1
}
tex_manager_fingerprint() (
  set -o pipefail
  tex_manager_prefix || exit 1
  # Include additions and changes anywhere in the prefix, including non-brew
  # files in /usr/local. Directory timestamps are excluded; file metadata is not.
  { find "$tex_prefix" -type d -exec stat -f '%N|%HT|%i' {} + &&
    find "$tex_prefix" ! -type d -exec stat -f '%N|%HT|%z|%m|%i|%Y' {} +; } |
    LC_ALL=C sort | shasum -a 256
)
tex_manager_preserve_changes() {
  if [ "$(cat "$tex_manager_state/baseline")" = absent ]; then
    tex_observed=$(tex_manager_fingerprint) || tex_observed=
    if [ -z "$tex_observed" ] || [ "$tex_observed" != "$(cat "$tex_manager_state/after")" ]; then
      printf 'protected\n' > "$tex_manager_state/baseline"
    fi
  fi
}
tex_manager_prepare() (
  set -eu
  tex_manager_lock_held=0
  trap '[ "$tex_manager_lock_held" != 1 ] || rmdir "$tex_manager_state/lock" 2>/dev/null || :' EXIT
  tex_manager_lock || exit 1
  if [ ! -f "$tex_manager_state/schema" ]; then
    if tex_manager_existing; then tex_before=present; else tex_before=absent; fi
    printf '%s\n' "$tex_before" > "$tex_manager_state/baseline" || exit 1
    id -u > "$tex_manager_state/user" || exit 1
    tex_manager_default_prefix > "$tex_manager_state/prefix" || exit 1
    printf 'tex-manager-1\n' > "$tex_manager_state/schema" || exit 1
  else
    [ "$(cat "$tex_manager_state/status")" = complete ] || { tex_error 'Fruehere Einrichtung unvollstaendig.' || :; exit 1; }
    tex_manager_preserve_changes || exit 1
  fi
  printf 'pending\n' > "$tex_manager_state/status" || exit 1
  tex_bootstrap=$(curl -fsSL https://raw.githubusercontent.com/killu42/tex-setup/main/mac.sh) || exit 1
  [ -n "$tex_bootstrap" ] || exit 1
  # A separate shell retains errexit even when the caller uses && or ||.
  /bin/bash -eu -c "$tex_bootstrap" || exit 1
  if [ "$(cat "$tex_manager_state/baseline")" = absent ]; then
    tex_brew_path || exit 1
    [ "$("$tex_brew" --prefix)" = "$(cat "$tex_manager_state/prefix")" ] || exit 1
    tex_manager_fingerprint > "$tex_manager_state/after" || exit 1
  fi
  printf 'complete\n' > "$tex_manager_state/status"
)
tex_manager_begin() {
  tex_manager_token=
  tex_manager_location || return
  [ -d "$tex_manager_state" ] || return 0
  tex_manager_token="$$-$(date +%s)-$RANDOM"
  (set -eu
   tex_manager_lock_held=0
   trap '[ "$tex_manager_lock_held" != 1 ] || rmdir "$tex_manager_state/lock" 2>/dev/null || :' EXIT
   tex_manager_lock || exit 1
   [ "$(cat "$tex_manager_state/status")" = complete ] || exit 1
   tex_manager_preserve_changes || exit 1
   printf 'pending\n' > "$tex_manager_state/status"
   printf '%s\n' "$tex_manager_token" > "$tex_manager_state/transaction")
}
tex_manager_finish() (
  set -eu
  [ -n "${tex_manager_token:-}" ] || exit 0
  tex_manager_lock_held=0
  trap '[ "$tex_manager_lock_held" != 1 ] || rmdir "$tex_manager_state/lock" 2>/dev/null || :' EXIT
  tex_manager_lock || exit 1
  [ "$(cat "$tex_manager_state/status")" = pending ] &&
    [ "$(cat "$tex_manager_state/transaction")" = "$tex_manager_token" ] || exit 1
  if [ "$(cat "$tex_manager_state/baseline")" = absent ]; then
    tex_manager_fingerprint > "$tex_manager_state/after"
  fi
  rm "$tex_manager_state/transaction"
  printf 'complete\n' > "$tex_manager_state/status"
)
tex_manager_uninstall() {
  tex_uninstaller=$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh) || return
  [ -n "$tex_uninstaller" ] || return 1
  /bin/bash -c "$tex_uninstaller" -- --path "$tex_prefix"
}
tex_remove_manager() (
  set -eu
  tex_manager_lock_held=0
  trap '[ "$tex_manager_lock_held" != 1 ] || rmdir "$tex_manager_state/lock" 2>/dev/null || :' EXIT
  tex_manager_location || exit 1
  [ -d "$tex_manager_state" ] || { printf 'Kein eindeutiger Homebrew-Nachweis. Nichts entfernt.\n'; exit 0; }
  tex_manager_lock || exit 1
  [ "$(cat "$tex_manager_state/status")" = complete ] || { tex_error 'Einrichtung unvollstaendig. Homebrew bleibt erhalten.' || :; exit 1; }
  [ "$(cat "$tex_manager_state/baseline")" = absent ] || { printf 'Vorhandenes oder inzwischen veraendertes Homebrew bleibt erhalten.\n'; exit 0; }
  [ ! -e "$tex_state" ] || { tex_error 'Zuerst die TeX-Entfernung abschliessen.' || :; exit 1; }
  tex_manager_prefix || exit 1
  tex_observed=$(tex_manager_fingerprint) || exit 1
  [ -n "$tex_observed" ] && [ "$tex_observed" = "$(cat "$tex_manager_state/after")" ] || { tex_error 'Homebrew wurde inzwischen veraendert oder anderweitig genutzt. Nichts entfernt.' || :; exit 1; }
  tex_manager_uninstall || exit 1
  [ ! -e "$tex_prefix/bin/brew" ] && [ ! -L "$tex_prefix/bin/brew" ] || { tex_error 'Homebrew-Entfernung nicht abgeschlossen.' || :; exit 1; }
  for tex_name in schema user baseline prefix after status; do
    [ ! -f "$tex_manager_state/$tex_name" ] || rm "$tex_manager_state/$tex_name"
  done
  rmdir "$tex_manager_state/lock"
  trap - EXIT
  rmdir "$tex_manager_state"
  printf 'Neu eingerichtetes Homebrew entfernt.\n'
)
tex_prepare() {
  # Bootstrap remains separate from the visible TeX installation command.
  if [ "$(uname -s)" = Darwin ]; then
    tex_manager_prepare || return
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
tex_linux_new_packages() {
  # APT often omits :amd64 while dpkg reports it. Resolve only unambiguous
  # installed identities; never treat an existing multiarch package as new.
  awk '
    FILENAME==ARGV[1] {old[$1]=1; next}
    FILENAME==ARGV[2] {
      if ($2=="ii") {installed[$1]=1; b=$1; sub(/:[^:]+$/,"",b); count[b]++; name[b]=$1}
      next
    }
    /^Inst / {
      p=$2
      if (!installed[p]) {if (count[p]!=1) {exit 1}; p=name[p]}
      if (!old[p]) print p
    }
  ' "$tex_state/after" "$tex_state/completed.tmp" "$tex_state/plan"
}
tex_linux_removal_plan_safe() {
  awk '
    FILENAME==ARGV[1] {own[$1]=1; next}
    FILENAME==ARGV[2] {
      if ($2=="ii") {installed[$1]=1; b=$1; sub(/:[^:]+$/,"",b); count[b]++; name[b]=$1}
      next
    }
    /^Remv / {
      p=$2
      if (!installed[p]) {if (count[p]!=1) {exit 1}; p=name[p]}
      if (!own[p]) exit 1
    }
  ' "$tex_state/owned" "$tex_state/current.tmp" "$tex_state/plan"
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
      tex_manager_begin
      HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 "$tex_brew" install --cask mactex
      "$tex_brew" list --cask --versions mactex > "$tex_state/owned"
      [ -s "$tex_state/owned" ] || exit 1
      tex_mac_fingerprint > "$tex_state/after"
      tex_manager_finish
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
      tex_linux_new_packages > "$tex_state/new.tmp"
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
        tex_manager_begin
        HOMEBREW_NO_AUTOREMOVE=1 "$tex_brew" uninstall --cask mactex
        [ -z "$("$tex_brew" list --cask --versions mactex)" ] || exit 1
        tex_manager_finish
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
        tex_linux_removal_plan_safe || { tex_error 'Andere Programme benoetigen diese Pakete. Nichts entfernt.'; exit 1; }
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
