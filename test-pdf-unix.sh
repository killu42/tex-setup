#!/bin/bash
# Exact published PDF commands, only on disposable hosted test machines.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}:${RUNNER_ENVIRONMENT:-}:${GITHUB_REPOSITORY:-}" = true:github-hosted:killu42/tex-setup ] || exit 90
[[ "${TEST_REF:-}" =~ ^[a-f0-9]{40}$ ]] || exit 91
tex_work=$(mktemp -d "$RUNNER_TEMP/pdf-lifecycle.XXXXXX")
curl -fsSL --retry 3 "https://raw.githubusercontent.com/killu42/tex-setup/$TEST_REF/pdf-commands.json" -o "$tex_work/commands.json"
# JSON parsing is test-only, not a dependency of the user commands.
read_command() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$tex_work/commands.json" "$1"; }
tex_install_block=$(read_command "$TEST_PLATFORM")
tex_remove_block=$(read_command "${TEST_PLATFORM}_remove")
printf '\\documentclass{article}\\begin{document}Test.\\end{document}\n' > "$tex_work/keep.tex"
tex_doc_hash=$(shasum -a 256 "$tex_work/keep.tex")
tex_git=$(command -v git)
tex_git_hash=$(shasum -a 256 "$tex_git")
if [ "$(uname -s)" = Darwin ]; then
  [ ! -x /Library/TeX/texbin/pdflatex ]
  if [ "$TEST_PLATFORM" = intel ]; then [ "$(uname -m)" = x86_64 ]; fi
else
  ! command -v pdflatex
fi
for tex_pass in 1 2; do
  printf 'STAGE install/update pass %s, %s\n' "$tex_pass" "$TEST_PLATFORM"
  if [ "$(uname -s)" = Darwin ]; then
    /bin/zsh -c "$tex_install_block"
    test -x /Applications/TeX/TeXShop.app/Contents/MacOS/TeXShop
    /Library/TeX/texbin/pdflatex -interaction=nonstopmode -halt-on-error -output-directory="$tex_work" "$tex_work/keep.tex"
  else
    /bin/bash -c "$tex_install_block" <<< Y
    command -v texstudio
    test -f /usr/share/applications/texstudio.desktop
    pdflatex -interaction=nonstopmode -halt-on-error -output-directory="$tex_work" "$tex_work/keep.tex"
  fi
  printf 'PASS install/update and actual PDF, pass %s\n' "$tex_pass"
done
if [ "$(uname -s)" = Darwin ]; then
  open -a /Applications/TeX/TeXShop.app
  for tex_wait in {1..30}; do pgrep -x TeXShop && break; sleep 1; done
  pgrep -x TeXShop
  pkill -x TeXShop
else
  xvfb-run -a texstudio "$tex_work/keep.tex" > "$tex_work/editor.txt" 2>&1 &
  tex_editor_pid=$!
  sleep 5
  pgrep -x texstudio
  kill "$tex_editor_pid" || true
  pkill -x texstudio
fi
printf 'PASS editor starts\n'
/bin/bash -c "$tex_remove_block" <<< Y
hash -r
if [ "$(uname -s)" = Darwin ]; then
  test ! -x /Library/TeX/texbin/pdflatex
  test ! -e /Applications/TeX/TeXShop.app
  if [ "$TEST_PLATFORM" = mac ]; then brew --version; fi
else
  if command -v pdflatex || command -v texstudio; then exit 1; fi
  apt-get --version
fi
printf 'PASS exact PDF removal: distribution and editor absent\n'
# Repeated package-manager removal may report "not installed"; it must not remove other programs.
set +e
/bin/bash -c "$tex_remove_block" <<< Y
tex_repeat_status=$?
set -e
printf 'Repeat removal exit: %s\n' "$tex_repeat_status"
test -s "$tex_work/keep.pdf"
[ "$(shasum -a 256 "$tex_work/keep.tex")" = "$tex_doc_hash" ]
[ "$(shasum -a 256 "$tex_git")" = "$tex_git_hash" ]
printf 'PASS own document and unrelated program unchanged\n'
