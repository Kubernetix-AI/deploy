# shellcheck shell=bash
# Helpers shared by the tests. Source it; don't run it.

# shellcheck disable=SC2034 # used by the test files that source this
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASSED=0
FAILED=0

# A scratch folder for this test file, removed on exit.
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok   %s\n' "$1"
}

fail_test() {
  FAILED=$((FAILED + 1))
  printf 'FAIL %s\n' "$1"
  shift
  local line
  for line in "$@"; do printf '     %s\n' "$line"; done
}

# check NAME COMMAND...: pass when COMMAND succeeds.
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail_test "$name" "command failed: $*"; fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac }

finish() {
  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}
