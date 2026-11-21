#!/usr/bin/env bash
# Tests for scripts/version-tags.sh against local git repositories: an
# "origin" with tags, and checkouts made the way actions/checkout makes
# them (one commit, no tags). Nothing here uses the network.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/version-tags.sh"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test

g() { git -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

# The origin: three commits; the last has two version tags (one annotated),
# a tag that isn't a version and one that only looks like a version; an
# older commit has its own version.
SRC="$TMP_ROOT/src"
g init -q "$SRC"
for f in a b c; do
  echo "$f" >"$SRC/$f"
  g -C "$SRC" add "$f"
  g -C "$SRC" commit -q -m "$f"
  [ "$f" = a ] && g -C "$SRC" tag v0.9.0
done
g -C "$SRC" tag v1.2.0
g -C "$SRC" tag -a -m "release candidate" v1.3.0-rc.1
g -C "$SRC" tag nightly
g -C "$SRC" tag release-1.2.0
HEAD_SHA="$(g -C "$SRC" rev-parse HEAD)"
ORIGIN="file://$SRC"

# checkout NAME [CLONE FLAGS...]: a clone of origin without tags.
checkout() {
  local dir="$TMP_ROOT/$1"
  shift
  rm -rf "$dir"
  g clone -q --no-tags "$@" "$ORIGIN" "$dir"
  printf '%s' "$dir"
}

tags_at_head() { g -C "$1" tag --points-at HEAD | sort | tr '\n' ' '; }

echo "# a shallow checkout without tags"
CO="$(checkout shallow --depth 1)"
check "the checkout starts without tags" test -z "$(g -C "$CO" tag)"
OUT="$(bash "$SCRIPT" "$CO" 2>&1)"
RC=$?
check "exits 0" test "$RC" -eq 0
got="$(tags_at_head "$CO")"
if [ "$got" = "v1.2.0 v1.3.0-rc.1 " ]; then
  pass "fetches the version tags of HEAD, annotated or not, and nothing else"
else
  fail_test "fetches the version tags of HEAD, annotated or not, and nothing else" "got: $got" "output: $OUT"
fi
if [ -z "$(g -C "$CO" tag --list v0.9.0 nightly release-1.2.0)" ]; then
  pass "leaves other commits' tags and tags that aren't versions alone"
else
  fail_test "leaves other commits' tags and tags that aren't versions alone" "tags: $(g -C "$CO" tag)"
fi
if [ "$(g -C "$CO" cat-file -t v1.3.0-rc.1)" = tag ]; then
  pass "an annotated tag arrives as the same annotated tag"
else
  fail_test "an annotated tag arrives as the same annotated tag"
fi
if contains "$OUT" "v1.2.0" && contains "$OUT" "v1.3.0-rc.1"; then
  pass "says which tags it fetched"
else
  fail_test "says which tags it fetched" "output: $OUT"
fi
check "the checkout stays shallow at one commit" test "$(g -C "$CO" rev-list --count HEAD)" -eq 1

echo "# a full checkout without tags"
CO="$(checkout full)"
bash "$SCRIPT" "$CO" >/dev/null 2>&1
check "fetches the version tags" test "$(tags_at_head "$CO")" = "v1.2.0 v1.3.0-rc.1 "
check "doesn't make a full checkout shallow" test "$(g -C "$CO" rev-parse --is-shallow-repository)" = false

echo "# a checkout that already has one of the version tags"
CO="$(checkout tagged --depth 1)"
g -C "$CO" fetch -q --no-tags origin "+refs/tags/v1.2.0:refs/tags/v1.2.0"
OUT="$(bash "$SCRIPT" "$CO" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$(tags_at_head "$CO")" = "v1.2.0 v1.3.0-rc.1 " ] && [ "$OUT" = "Fetched this commit's version tags from origin: v1.3.0-rc.1" ]; then
  pass "still fetches the versions only origin has"
else
  fail_test "still fetches the versions only origin has" "rc=$RC tags=$(tags_at_head "$CO") output: $OUT"
fi
g -C "$CO" remote set-url origin "file://$TMP_ROOT/no-such-repository"
OUT="$(bash "$SCRIPT" "$CO" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "says nothing when origin can't be reached but the checkout has a version tag"
else
  fail_test "says nothing when origin can't be reached but the checkout has a version tag" "rc=$RC output: $OUT"
fi

echo "# origin can't be reached"
CO="$(checkout unreachable --depth 1)"
g -C "$CO" remote set-url origin "file://$TMP_ROOT/no-such-repository"
OUT="$(bash "$SCRIPT" "$CO" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && contains "$OUT" "couldn't get this commit's tags from origin" && contains "$OUT" "fetch-depth: 0"; then
  pass "says so in one line with the fix, and doesn't fail the job"
else
  fail_test "says so in one line with the fix, and doesn't fail the job" "rc=$RC output: $OUT"
fi
if ! contains "$OUT" "::error" && ! contains "$OUT" "fatal:"; then
  pass "no error annotation and no raw git error"
else
  fail_test "no error annotation and no raw git error" "output: $OUT"
fi

echo "# HEAD has no tags on origin"
SRC2="$TMP_ROOT/src2"
g init -q "$SRC2"
echo x >"$SRC2/x"
g -C "$SRC2" add x
g -C "$SRC2" commit -q -m x
CO="$TMP_ROOT/untagged"
g clone -q --no-tags --depth 1 "file://$SRC2" "$CO"
OUT="$(bash "$SCRIPT" "$CO" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$(g -C "$CO" tag)" ]; then
  pass "prints nothing and fetches nothing"
else
  fail_test "prints nothing and fetches nothing" "rc=$RC output: $OUT"
fi

echo "# not a git checkout"
mkdir -p "$TMP_ROOT/plain"
OUT="$(bash "$SCRIPT" "$TMP_ROOT/plain" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "a folder that isn't a checkout is left alone"; else fail_test "a folder that isn't a checkout is left alone" "rc=$RC output: $OUT"; fi
OUT="$(bash "$SCRIPT" "$TMP_ROOT/no-such-folder" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "a folder that doesn't exist is left alone"; else fail_test "a folder that doesn't exist is left alone" "rc=$RC output: $OUT"; fi

echo "# a subfolder of the checkout (the path input)"
CO="$(checkout subfolder --depth 1)"
mkdir -p "$CO/services/api"
bash "$SCRIPT" "$CO/services/api" >/dev/null 2>&1
check "works from a subfolder" test "$(tags_at_head "$CO")" = "v1.2.0 v1.3.0-rc.1 "

echo "# tag names on origin that aren't versions never reach git"
SRC3="$TMP_ROOT/src3"
g init -q "$SRC3"
echo x >"$SRC3/x"
g -C "$SRC3" add x
g -C "$SRC3" commit -q -m x
# shellcheck disable=SC2016 # the payloads are meant literally
for hostile in 'v9.9.9-$(touch${IFS}pwned-dollar)' 'v9.9.8;touch${IFS}pwned-semi' 'v9.9.7-`touch${IFS}pwned-tick`' 'v9.9.6--upload-pack=touch${IFS}pwned-flag'; do
  if g check-ref-format "refs/tags/$hostile"; then
    g -C "$SRC3" tag "$hostile"
  fi
done
g -C "$SRC3" tag v9.9.5
HOSTILE="$TMP_ROOT/hostile"
g clone -q --no-tags --depth 1 "file://$SRC3" "$HOSTILE"
OUT="$(cd "$TMP_ROOT" && bash "$SCRIPT" "$HOSTILE" 2>&1)"
if [ "$(tags_at_head "$HOSTILE")" = "v9.9.5 " ] && [ -z "$(find "$TMP_ROOT" -name 'pwned*' -print)" ] && [ "$(g -C "$SRC3" tag | wc -l)" -ge 3 ]; then
  pass "only the real version is fetched, and nothing runs"
else
  fail_test "only the real version is fetched, and nothing runs" "tags: $(tags_at_head "$HOSTILE")" "origin tags: $(g -C "$SRC3" tag | tr '\n' ' ')" "output: $OUT" "pwned: $(find "$TMP_ROOT" -name 'pwned*' -print)"
fi

echo "# HEAD is the commit origin's tags point at"
check "the fetched tags point at HEAD" test "$(g -C "$CO" rev-parse 'v1.3.0-rc.1^{commit}')" = "$HEAD_SHA"

finish
