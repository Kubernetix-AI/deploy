#!/usr/bin/env bash
# Tests for scripts/publish-action.sh, in a scratch copy of this repository
# with a local bare "origin" and fake kx releases on disk (KX_RELEASE_DIR).
# Nothing here touches the network or this repository's own git state.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export GIT_AUTHOR_NAME="Publish Test" GIT_AUTHOR_EMAIL="publish-test@example.invalid"
export GIT_COMMITTER_NAME="Publish Test" GIT_COMMITTER_EMAIL="publish-test@example.invalid"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

ARCHIVES=(kx_linux_amd64.tar.gz kx_linux_arm64.tar.gz kx_darwin_amd64.tar.gz
  kx_darwin_arm64.tar.gz kx_windows_amd64.zip kx_windows_arm64.zip)

# make_release VERSION: a fake kx release folder; prints its path. The
# script never opens the archives, so any bytes will do.
make_release() {
  local dir="$TMP_ROOT/release-$1" a
  mkdir -p "$dir"
  for a in "${ARCHIVES[@]}"; do printf 'fake %s %s\n' "$a" "$1" >"$dir/$a"; done
  (cd "$dir" && sha256sum "${ARCHIVES[@]}" >checksums.txt)
  printf '%s' "$dir"
}

# A scratch copy of this repository on main, pushed to a local bare origin.
REPO="$TMP_ROOT/repo"
ORIGIN="$TMP_ROOT/origin.git"
mkdir -p "$REPO"
cp -R "$REPO_ROOT/action.yml" "$REPO_ROOT/README.md" "$REPO_ROOT/scripts" "$REPO_ROOT/checksums" "$REPO/"
rm -f "$REPO"/checksums/*.txt
git -C "$REPO" init --quiet -b main
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "initial"
git init --quiet --bare "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push --quiet origin main

# publish [NAME=VALUE]... -- ARG...: run the script in the scratch repo.
publish() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  OUT="$(cd "$REPO" && env "${envs[@]}" bash scripts/publish-action.sh "$@" 2>&1)"
  RC=$?
}

refused() {
  local name="$1" text="$2"
  if [ "$RC" -ne 0 ] && contains "$OUT" "$text"; then pass "$name"; else fail_test "$name" "rc=$RC" "output: $OUT"; fi
}

pinned_default() {
  python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["inputs"]["kx-version"]["default"])' "$REPO/action.yml"
}

R999="$(make_release 9.9.9)"
start="$(git -C "$REPO" rev-parse HEAD)"

echo "# dry run"
publish KX_RELEASE_DIR="$R999" -- --skip-attestations 9.9.9
if [ "$RC" -eq 0 ] && contains "$OUT" "Dry run: nothing changed" && contains "$OUT" "+    default: \"9.9.9\"" &&
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$start" ] && [ -z "$(git -C "$REPO" tag)" ] &&
  [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  pass "a dry run shows the changes and changes nothing"
else
  fail_test "a dry run shows the changes and changes nothing" "rc=$RC" "output: $OUT"
fi

echo "# --commit"
publish KX_RELEASE_DIR="$R999" -- --commit --skip-attestations 9.9.9
head="$(git -C "$REPO" rev-parse HEAD)"
if [ "$RC" -eq 0 ] && cmp -s "$REPO/checksums/9.9.9.txt" "$R999/checksums.txt" && [ "$(pinned_default)" = "9.9.9" ] &&
  grep -qF "\`9.9.9\` <!-- pinned-kx-version -->" "$REPO/README.md" &&
  [ "$(git -C "$REPO" log -1 --format=%s)" = "chore(release): pin kx 9.9.9" ] &&
  [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  pass "--commit writes checksums/9.9.9.txt, pins 9.9.9 in action.yml and README.md, and commits"
else
  fail_test "--commit writes the checksums, pins the version and commits" "rc=$RC" "output: $OUT"
fi
if [ "$(git -C "$REPO" cat-file -t v9.9.9)" = tag ] && [ "$(git -C "$REPO" rev-parse 'v9.9.9^{commit}')" = "$head" ] &&
  [ "$(git -C "$REPO" rev-parse 'v9^{commit}')" = "$head" ]; then
  pass "--commit creates the annotated tag v9.9.9 and points v9 at it"
else
  fail_test "--commit creates the annotated tag v9.9.9 and points v9 at it" "output: $OUT"
fi
if [ "$(git -C "$ORIGIN" rev-parse main)" = "$start" ] && [ -z "$(git -C "$ORIGIN" tag)" ]; then
  pass "--commit pushes nothing"
else
  fail_test "--commit pushes nothing"
fi

publish KX_RELEASE_DIR="$R999" -- --commit --skip-attestations 9.9.9
refused "a published tag is never reused" "tag v9.9.9 already exists"

echo "# --push to a local origin"
git -C "$REPO" push --quiet --atomic origin HEAD:refs/heads/main refs/tags/v9.9.9 +refs/tags/v9
R9910="$(make_release 9.9.10)"
publish KX_RELEASE_DIR="$R9910" -- --push --skip-attestations 9.9.10
head="$(git -C "$REPO" rev-parse HEAD)"
if [ "$RC" -eq 0 ] && [ "$(git -C "$ORIGIN" rev-parse main)" = "$head" ] &&
  [ "$(git -C "$ORIGIN" rev-parse 'v9.9.10^{commit}')" = "$head" ] && [ "$(git -C "$ORIGIN" rev-parse 'v9^{commit}')" = "$head" ] &&
  [ "$(git -C "$ORIGIN" rev-parse 'v9.9.9^{commit}')" != "$head" ]; then
  pass "--push pushes main and v9.9.10 and moves v9 on origin"
else
  fail_test "--push pushes main and v9.9.10 and moves v9 on origin" "rc=$RC" "output: $OUT"
fi

echo "# release candidates and older versions"
v9_before="$(git -C "$ORIGIN" rev-parse 'v9^{commit}')"
publish KX_RELEASE_DIR="$(make_release 9.10.0-rc.1)" -- --push --skip-attestations 9.10.0-rc.1
if [ "$RC" -eq 0 ] && git -C "$ORIGIN" rev-parse -q --verify refs/tags/v9.10.0-rc.1 >/dev/null &&
  [ "$(git -C "$ORIGIN" rev-parse 'v9^{commit}')" = "$v9_before" ]; then
  pass "a release candidate gets its own tag and doesn't move v9"
else
  fail_test "a release candidate gets its own tag and doesn't move v9" "rc=$RC" "output: $OUT"
fi

publish KX_RELEASE_DIR="$(make_release 9.8.0)" -- --push --skip-attestations 9.8.0
if [ "$RC" -eq 0 ] && git -C "$ORIGIN" rev-parse -q --verify refs/tags/v9.8.0 >/dev/null &&
  [ "$(git -C "$ORIGIN" rev-parse 'v9^{commit}')" = "$v9_before" ] && contains "$OUT" "v9 stays at v9.9.10"; then
  pass "an older version never moves v9 backwards"
else
  fail_test "an older version never moves v9 backwards" "rc=$RC" "output: $OUT"
fi

publish KX_RELEASE_DIR="$R9910" -- --push --skip-attestations --action-version 9.9.11 9.9.10
head="$(git -C "$REPO" rev-parse HEAD)"
if [ "$RC" -eq 0 ] && contains "$OUT" "already committed and identical" &&
  [ "$(git -C "$ORIGIN" rev-parse 'v9.9.11^{commit}')" = "$head" ] && [ "$(git -C "$ORIGIN" rev-parse 'v9^{commit}')" = "$head" ]; then
  pass "--action-version releases the Action again with an already pinned kx"
else
  fail_test "--action-version releases the Action again with an already pinned kx" "rc=$RC" "output: $OUT"
fi

echo "# bad release files"
BAD="$(make_release 9.9.12)"
printf 'x' >>"$BAD/kx_darwin_arm64.tar.gz"
publish KX_RELEASE_DIR="$BAD" -- --commit --skip-attestations 9.9.12
refused "refuses an archive that doesn't match checksums.txt" "an archive doesn't match checksums.txt"

BAD="$(make_release 9.9.13)"
sed -i '/windows_arm64/d' "$BAD/checksums.txt"
publish KX_RELEASE_DIR="$BAD" -- --commit --skip-attestations 9.9.13
refused "refuses a checksums.txt that misses an archive" "checksums.txt has 5 lines"

BAD="$(make_release 9.9.14)"
printf '%s  %s\n' "$(printf '0%.0s' {1..64})" kx_freebsd_amd64.tar.gz >>"$BAD/checksums.txt"
publish KX_RELEASE_DIR="$BAD" -- --commit --skip-attestations 9.9.14
refused "refuses a checksums.txt with an unknown file" "kx_freebsd_amd64.tar.gz, which is not a kx release archive"

BAD="$(make_release 9.9.15)"
sed -i '1p' "$BAD/checksums.txt"
sed -i '$d' "$BAD/checksums.txt"
publish KX_RELEASE_DIR="$BAD" -- --commit --skip-attestations 9.9.15
refused "refuses a checksums.txt that lists an archive twice" "lists kx_linux_amd64.tar.gz 2 times"

BAD="$(make_release 9.9.16)"
rm "$BAD/kx_windows_amd64.zip"
publish KX_RELEASE_DIR="$BAD" -- --commit --skip-attestations 9.9.16
refused "refuses a release with a missing archive" "has no kx_windows_amd64.zip"

DIFF="$(make_release 9.9.9-other)" # different files, presented as 9.9.9
publish KX_RELEASE_DIR="$DIFF" -- --commit --skip-attestations --action-version 9.9.17 9.9.9
refused "never rewrites committed checksums" "checksums/9.9.9.txt already exists with different checksums"

mkdir -p "$TMP_ROOT/fakebin-ok"
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/fakebin-ok/gh"
chmod 0755 "$TMP_ROOT/fakebin-ok/gh"

echo "# guards"
for bad in latest 1.0 "1.0.0;id" "../1.0.0" "1.0.0-beta"; do
  publish KX_RELEASE_DIR="$R999" -- --skip-attestations "$bad"
  refused "refuses kx version $(printf '%q' "$bad")" "isn't a kx release version"
done
publish KX_RELEASE_DIR="$R999" -- --skip-attestations --action-version 2.0 9.9.9
refused "refuses a malformed --action-version" "isn't a version"

echo dirty >>"$REPO/README.md"
publish KX_RELEASE_DIR="$(make_release 9.9.18)" -- --commit --skip-attestations 9.9.18
refused "--commit refuses a dirty working tree" "uncommitted changes"
git -C "$REPO" checkout --quiet -- README.md

git -C "$REPO" switch --quiet -c other
publish KX_RELEASE_DIR="$(make_release 9.9.19)" -- --commit --skip-attestations 9.9.19
refused "--commit refuses a branch other than main" "you are on other, not main"
git -C "$REPO" switch --quiet main

# A real (non-local) origin: unverified files must never get near it. The
# .invalid host never resolves, and every case below stops before the network.
git -C "$REPO" remote set-url origin https://example.invalid/deploy.git
head_before="$(git -C "$REPO" rev-parse HEAD)"
publish KX_RELEASE_DIR="$(make_release 9.9.20)" -- --push --skip-attestations 9.9.20
refused "test release files can't be pushed to a real remote" "only for dry runs and tests"
publish KX_RELEASE_DIR="$(make_release 9.9.22)" PATH="$TMP_ROOT/fakebin-ok:$PATH" -- --commit 9.9.22
refused "test release files can't be committed in a clone of a real remote" "only for dry runs and tests"
publish -- --push --skip-attestations 9.9.23
refused "--skip-attestations can't be used with --push to a real remote" "only for dry runs and tests"
publish -- --commit --skip-attestations 9.9.23
refused "--skip-attestations can't be used with --commit in a clone of a real remote" "only for dry runs and tests"
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$head_before" ] && ! git -C "$REPO" rev-parse -q --verify refs/tags/v9.9.22 >/dev/null; then
  pass "nothing was committed or tagged by the refused runs"
else
  fail_test "nothing was committed or tagged by the refused runs"
fi
publish KX_RELEASE_DIR="$(make_release 9.9.24)" -- --skip-attestations 9.9.24
if [ "$RC" -eq 0 ] && contains "$OUT" "Dry run: nothing changed"; then
  pass "a dry run in test mode still works against a real remote"
else
  fail_test "a dry run in test mode still works against a real remote" "rc=$RC" "output: $OUT"
fi
git -C "$REPO" remote set-url origin "$ORIGIN"

publish KX_RELEASE_DIR="$(make_release 9.9.25)" -- --commit --skip-attestations 9.9.25
if [ "$RC" -eq 0 ] && contains "$OUT" "test mode, so no push command is shown" && ! contains "$OUT" "To publish: git push"; then
  pass "test mode never prints a push command"
else
  fail_test "test mode never prints a push command" "rc=$RC" "output: $OUT"
fi

echo "# attestations"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
exit "${FAKE_GH_EXIT:-0}"
EOF
chmod 0755 "$FAKEBIN/gh"
R921="$(make_release 9.9.21)"
publish PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$TMP_ROOT/gh.log" FAKE_GH_EXIT=1 KX_RELEASE_DIR="$R921" -- 9.9.21
refused "refuses files without a valid attestation" "has no valid attestation"
: >"$TMP_ROOT/gh.log"
publish PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$TMP_ROOT/gh.log" KX_RELEASE_DIR="$R921" -- 9.9.21
calls="$(grep -c -- '--repo Kubernetix-AI/kx --signer-workflow Kubernetix-AI/kx/.github/workflows/release.yml --source-ref refs/tags/v9.9.21 --deny-self-hosted-runners' "$TMP_ROOT/gh.log")"
if [ "$RC" -eq 0 ] && [ "$calls" -eq 7 ]; then
  pass "verifies all seven files' provenance against the kx release workflow and tag"
else
  fail_test "verifies all seven files' provenance" "rc=$RC calls=$calls" "output: $OUT" "gh: $(cat "$TMP_ROOT/gh.log")"
fi

finish
