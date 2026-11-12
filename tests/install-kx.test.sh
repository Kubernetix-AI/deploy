#!/usr/bin/env bash
# Tests for scripts/install-kx.sh against fake kx releases on disk.
#
# Nothing here touches the network: downloads either go through the
# file:// test hook or through a fake curl on PATH. The fake releases use
# versions that will never be released (9.9.x), and their checksums exist
# only in the test's own copy of the Action, never in checksums/.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V=9.9.9
WS="$TMP_ROOT/workspace" # plays GITHUB_WORKSPACE
RELEASES="$WS/fake/releases/download"
mkdir -p "$WS" "$RELEASES"
SYSTEM_PATH="$PATH"

# make_release VERSION: fake kx archives for linux/amd64 and linux/arm64,
# plus their checksums in $TMP_ROOT/sums-VERSION.txt.
make_release() {
  local ver="$1" arch dir
  dir="$RELEASES/v$ver"
  mkdir -p "$dir"
  : >"$TMP_ROOT/sums-$ver.txt"
  for arch in amd64 arm64; do
    mkdir -p "$TMP_ROOT/build-$ver-$arch"
    printf '#!/bin/sh\necho "kx %s (fakecommit, 2026-01-01T00:00:00Z, linux/%s)"\n' "$ver" "$arch" >"$TMP_ROOT/build-$ver-$arch/kx"
    chmod 0755 "$TMP_ROOT/build-$ver-$arch/kx"
    tar -czf "$dir/kx_linux_$arch.tar.gz" -C "$TMP_ROOT/build-$ver-$arch" kx
    (cd "$dir" && sha256sum "kx_linux_$arch.tar.gz") >>"$TMP_ROOT/sums-$ver.txt"
  done
}

# make_action NAME [VERSION SUMSFILE]...: a copy of the Action whose
# checksums/ holds the given files. Prints its path.
make_action() {
  local dir="$TMP_ROOT/$1"
  shift
  mkdir -p "$dir/scripts" "$dir/checksums"
  cp "$REPO_ROOT/action.yml" "$dir/"
  cp "$REPO_ROOT"/scripts/*.sh "$dir/scripts/"
  while [ $# -ge 2 ]; do
    cp "$2" "$dir/checksums/$1.txt"
    shift 2
  done
  printf '%s' "$dir"
}

# run_install ACTION [NAME=VALUE]...: run the Action's install-kx.sh with a
# clean environment plus the given variables. Sets RC, OUT, KX_PATH and
# GH_PATH_FILE_CONTENT.
run_install() {
  local action="$1" rt
  shift
  rt="$(mktemp -d "$TMP_ROOT/runner-temp.XXXXXX")"
  : >"$rt.path"
  : >"$rt.output"
  RUNNER_TEMP_DIR="$rt"
  OUT="$(cd "$WS" && env -i HOME="$HOME" PATH="${TEST_PATH:-$SYSTEM_PATH}" \
    RUNNER_OS=Linux RUNNER_TEMP="$rt" GITHUB_PATH="$rt.path" GITHUB_OUTPUT="$rt.output" \
    GITHUB_WORKSPACE="$WS" "$@" bash "$action/scripts/install-kx.sh" 2>&1)"
  RC=$?
  KX_PATH="$(sed -n 's/^kx-path=//p' "$rt.output")"
  GH_PATH_FILE_CONTENT="$(cat "$rt.path")"
}

# expect_refused NAME TEXT: the last run failed, said TEXT and installed nothing.
expect_refused() {
  local name="$1" text="$2"
  if [ "$RC" -ne 0 ] && contains "$OUT" "$text" && [ -z "$KX_PATH" ] && [ -z "$GH_PATH_FILE_CONTENT" ] &&
    ! compgen -G "$RUNNER_TEMP_DIR/kx-9*" >/dev/null; then
    pass "$name"
  else
    fail_test "$name" "rc=$RC kx-path=$KX_PATH" "output: $OUT"
  fi
}

# expect_installed NAME ARCH VERSION: the last run installed a working kx.
expect_installed() {
  local name="$1" arch="$2" ver="$3" ran
  ran="$([ -n "$KX_PATH" ] && "$KX_PATH" version 2>&1)"
  if [ "$RC" -eq 0 ] && [ "$ran" = "kx $ver (fakecommit, 2026-01-01T00:00:00Z, linux/$arch)" ] &&
    [ "$GH_PATH_FILE_CONTENT" = "$(dirname "$KX_PATH")" ] &&
    contains "$KX_PATH" "$RUNNER_TEMP_DIR/kx-$ver." && contains "$OUT" "Checksum OK"; then
    pass "$name"
  else
    fail_test "$name" "rc=$RC kx-path=$KX_PATH ran=$ran" "output: $OUT"
  fi
}

# A fake curl: records its arguments. With FAKE_CURL_CODE it answers that
# HTTP error (exit 22, like curl -f); with an empty FAKE_CURL_SRC it can't
# connect (exit 7); otherwise it writes FAKE_CURL_SRC to the -o file. Like
# curl, it prints the HTTP code when given -w.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_CURL_LOG"
out=""
w=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) w="$2"; shift ;;
  esac
  shift
done
code() { if [ -n "$w" ]; then printf '%s' "$1"; fi; }
if [ -n "${FAKE_CURL_CODE:-}" ]; then code "$FAKE_CURL_CODE"; exit 22; fi
if [ -z "${FAKE_CURL_SRC:-}" ]; then code 000; exit 7; fi
cp "$FAKE_CURL_SRC" "$out"
code 200
EOF
chmod 0755 "$FAKEBIN/curl"

make_release "$V"
make_release 9.9.8
GOOD="$(make_action good "$V" "$TMP_ROOT/sums-$V.txt")"
HOOK="file://$RELEASES"

echo "# install with a good checksum"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_installed "installs kx when the checksum matches (X64 runner gets amd64)" amd64 "$V"

run_install "$GOOD" KX_VERSION="v$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_installed "accepts a version written with a leading v" amd64 "$V"

echo "# architecture selection"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=ARM64 KX_INSTALL_BASE_URL="$HOOK"
expect_installed "an ARM64 runner gets the arm64 archive" arm64 "$V"

UNAME_BIN="$TMP_ROOT/uname-bin"
mkdir -p "$UNAME_BIN"
for m in aarch64 x86_64 riscv64; do
  # shellcheck disable=SC2016 # $1 belongs to the fake uname
  printf '#!/bin/sh\ncase "$1" in -m) echo %s ;; *) echo Linux ;; esac\n' "$m" >"$UNAME_BIN/uname"
  chmod 0755 "$UNAME_BIN/uname"
  TEST_PATH="$UNAME_BIN:$SYSTEM_PATH" run_install "$GOOD" KX_VERSION="$V" KX_INSTALL_BASE_URL="$HOOK"
  case "$m" in
    aarch64) expect_installed "without RUNNER_ARCH, uname -m aarch64 gives arm64" arm64 "$V" ;;
    x86_64) expect_installed "without RUNNER_ARCH, uname -m x86_64 gives amd64" amd64 "$V" ;;
    riscv64) expect_refused "without RUNNER_ARCH, an unknown uname -m is refused" "no build for this runner's processor (riscv64)" ;;
  esac
done

for a in X86 ARM; do
  run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH="$a" KX_INSTALL_BASE_URL="$HOOK"
  expect_refused "a $a runner is refused" "no build for this runner's processor ($a)"
done

echo "# bad checksums"
sed "s/^[0-9a-f]\{64\}  kx_linux_amd64/$(printf '0%.0s' {1..64})  kx_linux_amd64/" "$TMP_ROOT/sums-$V.txt" >"$TMP_ROOT/sums-wrong.txt"
WRONG="$(make_action wrong "$V" "$TMP_ROOT/sums-wrong.txt")"
run_install "$WRONG" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_refused "refuses an archive whose checksum doesn't match checksums/" "doesn't match the checksum committed"
run_install "$WRONG" KX_VERSION="$V" RUNNER_ARCH=ARM64 KX_INSTALL_BASE_URL="$HOOK"
expect_installed "the other architecture's line is unaffected" arm64 "$V"

TAMPERED_WS_DIR="$WS/tampered/releases/download"
mkdir -p "$TAMPERED_WS_DIR/v$V"
cp "$RELEASES/v$V"/*.tar.gz "$TAMPERED_WS_DIR/v$V/"
printf 'x' >>"$TAMPERED_WS_DIR/v$V/kx_linux_amd64.tar.gz"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="file://$TAMPERED_WS_DIR"
expect_refused "refuses an archive changed after its checksum was published" "doesn't match the checksum committed"

head -n 1 "$TMP_ROOT/sums-$V.txt" >"$TMP_ROOT/sums-dup.txt"
cat "$TMP_ROOT/sums-$V.txt" >>"$TMP_ROOT/sums-dup.txt"
DUP="$(make_action dup "$V" "$TMP_ROOT/sums-dup.txt")"
run_install "$DUP" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_refused "refuses a checksums file that lists the archive twice" "no valid checksum for kx_linux_amd64.tar.gz"

sed 's/  kx_/ *kx_/' "$TMP_ROOT/sums-$V.txt" >"$TMP_ROOT/sums-star.txt"
STAR="$(make_action star "$V" "$TMP_ROOT/sums-star.txt")"
run_install "$STAR" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_refused "refuses a checksums line in another format" "no valid checksum"

awk '{ print toupper($1) "  " $2 }' "$TMP_ROOT/sums-$V.txt" >"$TMP_ROOT/sums-upper.txt"
UPPER="$(make_action upper "$V" "$TMP_ROOT/sums-upper.txt")"
run_install "$UPPER" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_refused "refuses a checksum that isn't 64 lowercase hex digits" "no valid checksum"

echo "# versions without committed checksums"
run_install "$GOOD" KX_VERSION=9.9.8 RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_refused "refuses a version with no checksums/<version>.txt, even when it can be downloaded" "can't install kx 9.9.8, because it has no checksums"
if contains "$OUT" "Test mode: copying"; then
  fail_test "nothing is downloaded for an unknown version" "output: $OUT"
else
  pass "nothing is downloaded for an unknown version"
fi
if contains "$OUT" "($V)"; then pass "the error lists the versions this Action can install"; else fail_test "the error lists the versions this Action can install" "output: $OUT"; fi

for bad in latest 1.0 9.9 "../../$V" "$V/../$V" "$V;touch pwned" "$V -rc.1" "$V-beta.1" "09.9.9" "$V"$'\n'; do
  run_install "$GOOD" KX_VERSION="$bad" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
  expect_refused "refuses kx-version $(printf '%q' "$bad")" "isn't a kx version"
done
run_install "$GOOD" KX_VERSION="" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_refused "refuses an empty kx-version" "No kx version was given"
if [ ! -e "$WS/pwned" ]; then pass "a version string never runs as a command"; else fail_test "a version string never runs as a command"; fi

echo "# Linux only"
for os in macOS Windows; do
  run_install "$GOOD" KX_VERSION="$V" RUNNER_OS="$os" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
  expect_refused "a $os runner gets a clear error" "runs on Linux runners only, and this job runs on $os"
done

echo "# archive contents"
mkdir -p "$TMP_ROOT/symlink-build" "$WS/symlink/v$V"
ln -s /bin/sh "$TMP_ROOT/symlink-build/kx"
tar -czf "$WS/symlink/v$V/kx_linux_amd64.tar.gz" -C "$TMP_ROOT/symlink-build" kx
(cd "$WS/symlink/v$V" && sha256sum kx_linux_amd64.tar.gz) >"$TMP_ROOT/sums-symlink.txt"
SYMLINK="$(make_action symlink "$V" "$TMP_ROOT/sums-symlink.txt")"
run_install "$SYMLINK" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="file://$WS/symlink"
expect_refused "refuses an archive whose kx is a symlink" "holds something other than the kx program"

make_release 9.9.6
mkdir -p "$RELEASES/v9.9.7"
cp "$RELEASES/v9.9.6"/*.tar.gz "$RELEASES/v9.9.7/"
MISLABELED="$(make_action mislabeled 9.9.7 "$TMP_ROOT/sums-9.9.6.txt")"
run_install "$MISLABELED" KX_VERSION=9.9.7 RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="$HOOK"
expect_refused "refuses an archive whose kx reports another version" "holds a different kx version"

echo "# the real download path (fake curl, no network)"
export FAKE_CURL_LOG="$TMP_ROOT/curl.log"
cp "$RELEASES/v$V/kx_linux_amd64.tar.gz" "$TMP_ROOT/tampered-download.tar.gz"
printf 'x' >>"$TMP_ROOT/tampered-download.tar.gz"
TEST_PATH="$FAKEBIN:$SYSTEM_PATH" run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 \
  FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_SRC="$TMP_ROOT/tampered-download.tar.gz"
expect_refused "a real download is checked against checksums/ too" "doesn't match the checksum committed"
curl_args="$(cat "$FAKE_CURL_LOG")"
if contains "$curl_args" "https://github.com/Kubernetix-AI/kx/releases/download/v$V/kx_linux_amd64.tar.gz" &&
  contains "$curl_args" "=https" && contains "$curl_args" "--tlsv1.2" && contains "$curl_args" "--proto-redir"; then
  pass "downloads the pinned release URL over HTTPS only"
else
  fail_test "downloads the pinned release URL over HTTPS only" "curl args: $curl_args"
fi

TEST_PATH="$FAKEBIN:$SYSTEM_PATH" run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 \
  FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_SRC="$RELEASES/v$V/kx_linux_amd64.tar.gz"
expect_installed "a real download with the right checksum installs" amd64 "$V"

TEST_PATH="$FAKEBIN:$SYSTEM_PATH" run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 \
  FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_SRC=""
expect_refused "a failed download stops the install" "Couldn't download kx $V from GitHub"

TEST_PATH="$FAKEBIN:$SYSTEM_PATH" run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 \
  FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_CODE=404
expect_refused "a kx version whose release files are gone says so" "kx $V is no longer available from GitHub"
if contains "$OUT" "Use a newer release of the Action"; then pass "and points to a newer release of the Action"; else fail_test "and points to a newer release of the Action" "output: $OUT"; fi

TEST_PATH="$FAKEBIN:$SYSTEM_PATH" run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 \
  FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_CODE=503
expect_refused "other HTTP errors keep the retry advice" "Couldn't download kx $V from GitHub"

echo "# the test hook can't be used to skip anything"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="https://example.com/releases/download"
expect_refused "the hook refuses https:// URLs" "must be a file:// URL"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="http://example.com/releases/download"
expect_refused "the hook refuses http:// URLs" "must be a file:// URL"

mkdir -p "$TMP_ROOT/outside/v$V"
cp "$RELEASES/v$V"/*.tar.gz "$TMP_ROOT/outside/v$V/"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="file://$TMP_ROOT/outside"
expect_refused "the hook refuses a folder outside the workspace" "must be inside the workspace"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="file://$WS/../outside"
expect_refused "the hook refuses .. out of the workspace" "must be inside the workspace"
ln -s "$TMP_ROOT/outside" "$WS/link-out"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="file://$WS/link-out"
expect_refused "the hook refuses a symlink that leads out of the workspace" "must be inside the workspace"
run_install "$GOOD" KX_VERSION="$V" RUNNER_ARCH=X64 KX_INSTALL_BASE_URL="file://$WS"
expect_refused "the hook refuses the workspace root itself" "must be inside the workspace"
OUT="$(cd "$WS" && env -i HOME="$HOME" PATH="$SYSTEM_PATH" RUNNER_OS=Linux RUNNER_TEMP="$TMP_ROOT" \
  GITHUB_PATH=/dev/null GITHUB_OUTPUT=/dev/null KX_VERSION="$V" RUNNER_ARCH=X64 \
  KX_INSTALL_BASE_URL="$HOOK" bash "$GOOD/scripts/install-kx.sh" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ] && contains "$OUT" "needs GITHUB_WORKSPACE"; then
  pass "the hook needs GITHUB_WORKSPACE"
else
  fail_test "the hook needs GITHUB_WORKSPACE" "rc=$RC output: $OUT"
fi

echo "# through action.yml"
# A job-level KX_INSTALL_BASE_URL must not reach the script: the Install
# step sets it to "". With the hook cleared, the fake curl is used.
OUT="$(cd "$WS" && env -i HOME="$HOME" PATH="$FAKEBIN:$SYSTEM_PATH" ACTION_ROOT="$GOOD" \
  RUNNER_OS=Linux RUNNER_ARCH=X64 RUNNER_TEMP="$TMP_ROOT" GITHUB_WORKSPACE="$WS" \
  GITHUB_PATH="$TMP_ROOT/through.path" GITHUB_OUTPUT="$TMP_ROOT/through.output" \
  KX_INSTALL_BASE_URL="$HOOK" FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_SRC="$RELEASES/v$V/kx_linux_amd64.tar.gz" \
  python3 "$REPO_ROOT/tests/run_step.py" install "{\"kx-version\": \"$V\"}" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && ! contains "$OUT" "Test mode" && contains "$(cat "$FAKE_CURL_LOG")" "/v$V/kx_linux_amd64.tar.gz" &&
  grep -q "^kx-path=$TMP_ROOT/kx-$V\." "$TMP_ROOT/through.output"; then
  pass "the Install step ignores a KX_INSTALL_BASE_URL set on the job"
else
  fail_test "the Install step ignores a KX_INSTALL_BASE_URL set on the job" "rc=$RC output: $OUT"
fi

default_version="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["inputs"]["kx-version"]["default"])' "$REPO_ROOT/action.yml")"
if [ -f "$REPO_ROOT/checksums/$default_version.txt" ]; then
  pass "the pinned kx-version ($default_version) has committed checksums"
else
  # Not published yet: the Action must refuse it (and so never download).
  OUT="$(cd "$WS" && env -i HOME="$HOME" PATH="$FAKEBIN:$SYSTEM_PATH" RUNNER_OS=Linux RUNNER_ARCH=X64 \
    RUNNER_TEMP="$TMP_ROOT" GITHUB_PATH=/dev/null GITHUB_OUTPUT=/dev/null FAKE_CURL_LOG="$TMP_ROOT/default.log" \
    python3 "$REPO_ROOT/tests/run_step.py" install '{}' 2>&1)"
  RC=$?
  if [ "$RC" -ne 0 ] && contains "$OUT" "can't install kx $default_version, because it has no checksums" && [ ! -e "$TMP_ROOT/default.log" ]; then
    pass "the pinned kx-version ($default_version) is refused until its checksums are published"
  else
    fail_test "the pinned kx-version is refused until its checksums are published" "rc=$RC output: $OUT"
  fi
fi

finish
