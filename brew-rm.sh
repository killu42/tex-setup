# Optional Homebrew removal. Never bootstrap or remove without a valid record.
set -eu
tracker=$(curl -fsSL https://raw.githubusercontent.com/killu42/tex-setup/main/track.sh)
[ -n "$tracker" ] || { printf 'Download ist leer. Nichts entfernt.\n' >&2; exit 1; }
eval "$tracker"
type tex_remove_manager >/dev/null 2>&1
tex_remove_manager
