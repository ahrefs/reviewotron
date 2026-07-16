#!/bin/sh
set -eu

if [ -n "${REVIEWOTRON_BIN:-}" ]; then
  run_reviewotron() {
    "$REVIEWOTRON_BIN" "$@"
  }
else
  run_reviewotron() {
    dune exec -- src/reviewotron.exe "$@"
  }
fi

run_reviewotron --help >/dev/null
run_reviewotron --version >/dev/null
run_reviewotron -version >/dev/null
run_reviewotron review-diff --help >/dev/null
run_reviewotron review-diff --help=plain 2>&1 | rg -- --commit >/dev/null
run_reviewotron --commit HEAD --help=plain 2>&1 | rg -- --commit >/dev/null
run_reviewotron review-path --help >/dev/null
run_reviewotron config-help >/dev/null
