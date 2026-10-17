#!/bin/bash
# Destructive fixture preparation, ONLY on disposable GitHub-hosted test VMs.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] &&
  [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] &&
  [ "${GITHUB_REPOSITORY:-}" = killu42/tex-setup ] &&
  [ "$(uname -s)" = Darwin ] || exit 90
[[ "${TEST_REF:-}" =~ ^[a-f0-9]{40}$ ]] || exit 91
tex_test_dir=$(mktemp -d "${RUNNER_TEMP:?}/tex-manager-native.XXXXXX")
tex_test_source="https://raw.githubusercontent.com/killu42/tex-setup/$TEST_REF"
tex_test_checks=0
check() {
  "$@" || { printf 'FAIL: %s\n' "$*"; exit 1; }
  tex_test_checks=$((tex_test_checks + 1))
  printf 'PASS: %s\n' "$*"
}
summary() {
  tex_test_result=$?
  printf '## Native missing Homebrew: %s\nCommit: `%s`\n\nChecks: %s; exit: %s\n' \
    "$(uname -m)" "$TEST_REF" "$tex_test_checks" "$tex_test_result" >> "${GITHUB_STEP_SUMMARY:?}"
}
trap summary EXIT
curl -fsSL --retry 3 "$tex_test_source/track.sh" -o "$tex_test_dir/track.sh"
sed "s@https://raw.githubusercontent.com/killu42/tex-setup/main/@$tex_test_source/@g" \
  "$tex_test_dir/track.sh" > "$tex_test_dir/candidate.sh"
source "$tex_test_dir/candidate.sh"
tex_manager_location
check test ! -e "$tex_manager_state"
check test ! -e "$tex_state"
tex_remove_manager

# The runner image contains Homebrew. Remove that disposable fixture using
# Homebrew's own uninstaller BEFORE defining the absent-manager baseline.
tex_test_prefix=$(tex_manager_default_prefix)
if tex_brew_path; then
  check test "$("$tex_brew" --prefix)" = "$tex_test_prefix"
  tex_test_uninstaller=$(curl -fsSL --retry 3 https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)
  NONINTERACTIVE=1 /bin/bash -c "$tex_test_uninstaller" -- --path "$tex_test_prefix"
fi
hash -r
# An empty ARM prefix is a footprint too. Only an empty directory may go.
if [ "$tex_test_prefix" = /opt/homebrew ] && [ -d /opt/homebrew ]; then
  sudo rmdir /opt/homebrew
fi
check test ! -e "$tex_test_prefix/bin/brew"
if tex_manager_existing; then printf 'Fixture still contains Homebrew.\n'; exit 1; fi
tex_test_git_hash=$(shasum -a 256 /usr/bin/git)
printf 'own document\n' > "$tex_test_dir/keep.tex"
tex_test_document=$(shasum -a 256 "$tex_test_dir/keep.tex")

tex_manager_prepare
check test "$(cat "$tex_manager_state/baseline")" = absent
check test "$(cat "$tex_manager_state/status")" = complete
check test -x "$tex_test_prefix/bin/brew"
tex_manager_prepare
check test "$(cat "$tex_manager_state/baseline")" = absent
check test "$(cat "$tex_manager_state/status")" = complete
tex_remove_manager
check test ! -e "$tex_test_prefix/bin/brew"
check test ! -e "$tex_manager_state"
tex_remove_manager
check test "$(shasum -a 256 /usr/bin/git)" = "$tex_test_git_hash"
check test "$(shasum -a 256 "$tex_test_dir/keep.tex")" = "$tex_test_document"
printf 'NATIVE MANAGER TEST COMPLETED SUCCESSFULLY\n'
