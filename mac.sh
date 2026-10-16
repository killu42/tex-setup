# Source this script in the current shell so Homebrew is available immediately.
# Only Homebrew is installed/updated here, never a TeX distribution.
tex_setup_homebrew() {
  local tex_brew tex_installer tex_env
  if [ "$(uname -s)" != Darwin ]; then
    printf 'Dieses Skript ist nur fuer macOS.\n' >&2
    return 1
  fi
  tex_brew=$(command -v brew 2>/dev/null) || tex_brew=
  if [ -z "$tex_brew" ] && [ -x /opt/homebrew/bin/brew ]; then
    tex_brew=/opt/homebrew/bin/brew
  elif [ -z "$tex_brew" ] && [ -x /usr/local/bin/brew ]; then
    tex_brew=/usr/local/bin/brew
  fi
  if [ -z "$tex_brew" ]; then
    tex_installer=$(curl --fail --silent --show-error --location --retry 3 \
      https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh) || return
    /bin/bash -c "$tex_installer" || return
    if [ -x /opt/homebrew/bin/brew ]; then
      tex_brew=/opt/homebrew/bin/brew
    elif [ -x /usr/local/bin/brew ]; then
      tex_brew=/usr/local/bin/brew
    else
      printf 'Homebrew konnte nicht eingerichtet werden.\n' >&2
      return 1
    fi
  fi
  "$tex_brew" update || return
  tex_env=$("$tex_brew" shellenv) || return
  eval "$tex_env"
}
tex_setup_homebrew
