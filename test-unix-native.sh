#!/bin/bash
# Real applications on disposable GitHub-hosted VMs only. Never run on a PC.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] &&
  [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] &&
  [ "${GITHUB_REPOSITORY:-}" = killu42/tex-setup ] || exit 90
[[ "${TEST_REF:-}" =~ ^[a-f0-9]{40}$ ]] || exit 91
case "${TEST_SCENARIO:-}" in fresh|existing) ;; *) exit 92 ;; esac
tex_test_dir=$(mktemp -d "${RUNNER_TEMP:?}/tex-native.XXXXXX")
tex_test_source="https://raw.githubusercontent.com/killu42/tex-setup/$TEST_REF"
tex_test_checks=0
check() {
  "$@" || { printf 'FAIL: %s\n' "$*"; exit 1; }
  tex_test_checks=$((tex_test_checks + 1))
  printf 'PASS: %s\n' "$*"
}
summary() {
  tex_test_result=$?
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '## Native %s / %s\nCommit: `%s`\n\nChecks passed: %s; exit: %s\n' \
      "$(uname -sm)" "$TEST_SCENARIO" "$TEST_REF" "$tex_test_checks" "$tex_test_result" >> "$GITHUB_STEP_SUMMARY"
  fi
}
trap summary EXIT
uname -a
df -h
curl -fsSL --retry 3 "$tex_test_source/track.sh" -o "$tex_test_dir/track.sh"
# Pin nested repository downloads to the same candidate, not production main.
sed "s@https://raw.githubusercontent.com/killu42/tex-setup/main/@$tex_test_source/@g" \
  "$tex_test_dir/track.sh" > "$tex_test_dir/candidate.sh"
source "$tex_test_dir/candidate.sh"
tex_location
check test ! -e "$tex_state"
tex_remove
printf '\\documentclass{article}\\begin{document}Native test.\\end{document}\n' > "$tex_test_dir/keep.tex"
tex_test_document=$(shasum -a 256 "$tex_test_dir/keep.tex")
case "$(uname -s)" in
  Darwin)
    check test ! -e /Library/TeX
    check test ! -e /Applications/TeX
    tex_test_git=$(command -v git)
    tex_test_git_hash=$(shasum -a 256 "$tex_test_git")
    brew list --formula | LC_ALL=C sort > "$tex_test_dir/preexisting-packages"
    if [ "$TEST_SCENARIO" = existing ]; then
      brew install --cask mactex
    fi
    tex_install brew install --cask mactex
    check test -x /Library/TeX/texbin/pdflatex
    check test -d /Applications/TeX/TeXShop.app
    /Library/TeX/texbin/pdflatex -interaction=nonstopmode -halt-on-error \
      -output-directory="$tex_test_dir" "$tex_test_dir/keep.tex"
    check test -s "$tex_test_dir/keep.pdf"
    open /Applications/TeX/TeXShop.app
    tex_test_editor_found=0
    for tex_test_attempt in {1..30}; do
      if pgrep -x TeXShop >/dev/null; then tex_test_editor_found=1; break; fi
      sleep 1
    done
    check test "$tex_test_editor_found" = 1
    osascript -e 'tell application "TeXShop" to quit'
    tex_install brew install --cask mactex
    tex_install brew install --cask mactex
    tex_remove
    if [ "$TEST_SCENARIO" = existing ]; then
      check test -x /Library/TeX/texbin/pdflatex
      check test -d /Applications/TeX/TeXShop.app
    else
      check test ! -e /Applications/TeX/TeXShop.app
      check test ! -x /Library/TeX/texbin/pdflatex
    fi
    tex_remove
    tex_remove_manager
    check command -v brew
    check test "$(shasum -a 256 "$tex_test_git")" = "$tex_test_git_hash"
    brew list --formula | LC_ALL=C sort > "$tex_test_dir/after-packages"
    check test -z "$(comm -23 "$tex_test_dir/preexisting-packages" "$tex_test_dir/after-packages")"
    ;;
  Linux)
    tex_packages | awk '$2=="ii" {print $1}' | LC_ALL=C sort > "$tex_test_dir/preexisting-packages"
    if [ "$TEST_SCENARIO" = existing ]; then
      sudo apt-get update
      sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio
    fi
    tex_install sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio
    check command -v pdflatex
    check command -v texstudio
    check test -f /usr/share/applications/texstudio.desktop
    pdflatex -interaction=nonstopmode -halt-on-error -output-directory="$tex_test_dir" "$tex_test_dir/keep.tex"
    check test -s "$tex_test_dir/keep.pdf"
    xvfb-run -a bash -c 'texstudio & editor_pid=$!; sleep 8; kill -0 "$editor_pid" && kill "$editor_pid"; wait "$editor_pid" || [ "$?" = 143 ]'
    tex_install sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio
    tex_install sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio
    tex_remove
    if [ "$TEST_SCENARIO" = existing ]; then
      check command -v pdflatex
      check command -v texstudio
    else
      check test ! -x /usr/bin/texstudio
    fi
    tex_remove
    tex_packages | awk '$2=="ii" {print $1}' | LC_ALL=C sort > "$tex_test_dir/after-packages"
    check test -z "$(comm -23 "$tex_test_dir/preexisting-packages" "$tex_test_dir/after-packages")"
    ;;
  *) exit 93 ;;
esac
check test "$(shasum -a 256 "$tex_test_dir/keep.tex")" = "$tex_test_document"
check test ! -e "$tex_state"
printf 'NATIVE TEST COMPLETED SUCCESSFULLY\n'
