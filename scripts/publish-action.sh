#!/usr/bin/env bash
# publish-action.sh: release this Action with a new kx version.
#
# Usage: scripts/publish-action.sh [--commit | --push] [--action-version X.Y.Z]
#                                  [--skip-attestations] <kx-version>
#
#  1. Downloads checksums.txt and the six archives of kx <kx-version> from
#     https://github.com/Kubernetix-AI/kx/releases.
#  2. Checks that checksums.txt lists exactly the six release archives, once
#     each, and that every archive matches its checksum.
#  3. Verifies every file's build provenance with `gh attestation verify`:
#     built by the kx release workflow from tag v<kx-version> on a
#     GitHub-hosted runner. --skip-attestations skips this, but only for a
#     dry run or a repository whose origin is a local folder (tests).
#  4. Writes checksums/<kx-version>.txt and makes <kx-version> the default
#     kx-version in action.yml and README.md, and commits that on main.
#  5. Creates the annotated tag v<action-version> (default: the kx version)
#     and moves the major tag (v1 for 1.x.y) to it, unless the version is a
#     release candidate or older than the newest release with that major.
#
# Modes:
#   (default)  dry run: steps 1-3, then shows what 4-5 would change;
#              changes nothing
#   --commit   also does steps 4-5 locally, without pushing
#   --push     also pushes main and the tags to origin, in one atomic push
#
# Run it from a clean main branch that is up to date with origin.
# Tests only: KX_RELEASE_DIR=<folder> reads the release files from a local
# folder instead of downloading them. Like --skip-attestations, it is
# refused with --commit or --push unless origin is a local folder, so
# unverified checksums can never reach the real repository.
set -euo pipefail

RELEASES="https://github.com/Kubernetix-AI/kx/releases/download"
KX_REPO="Kubernetix-AI/kx"
SIGNER="Kubernetix-AI/kx/.github/workflows/release.yml"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$'
ARCHIVES=(
  kx_linux_amd64.tar.gz
  kx_linux_arm64.tar.gz
  kx_darwin_amd64.tar.gz
  kx_darwin_arm64.tar.gz
  kx_windows_amd64.zip
  kx_windows_arm64.zip
)
ACTION_MARKER='# pinned kx version: written by scripts/publish-action.sh'
README_MARKER='<!-- pinned-kx-version -->'

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
fail() {
  echo "publish-action: $*" >&2
  exit 1
}
warn() { echo "publish-action: warning: $*" >&2; }
say() { echo "==> $*"; }

mode=dry-run
action_version=""
skip_attestations=false
kx_version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) mode=commit ;;
    --push) mode=push ;;
    --action-version)
      [ $# -ge 2 ] || usage
      action_version="$2"
      shift
      ;;
    --skip-attestations) skip_attestations=true ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [ -z "$kx_version" ] || usage
      kx_version="$1"
      ;;
  esac
  shift
done
[ -n "$kx_version" ] || usage

kx_version="${kx_version#v}"
[[ "$kx_version" =~ $SEMVER ]] || fail "\"$kx_version\" isn't a kx release version (X.Y.Z or X.Y.Z-rc.N)"
action_version="${action_version:-$kx_version}"
action_version="${action_version#v}"
[[ "$action_version" =~ $SEMVER ]] || fail "\"$action_version\" isn't a version (X.Y.Z or X.Y.Z-rc.N)"
major="${action_version%%.*}"
prerelease=false
case "$action_version" in *-rc.*) prerelease=true ;; esac
tag="v$action_version"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

for tool in git curl jq sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done

# --- Preconditions --------------------------------------------------------------

problems=()
branch="$(git symbolic-ref --quiet --short HEAD || echo "(detached)")"
[ "$branch" = main ] || problems+=("you are on $branch, not main")
[ -z "$(git status --porcelain)" ] || problems+=("the working tree has uncommitted changes")
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && problems+=("tag $tag already exists; published tags are never moved or reused")
if [ ${#problems[@]} -gt 0 ]; then
  if [ "$mode" = dry-run ]; then
    for p in "${problems[@]}"; do warn "$p (--commit and --push will refuse)"; done
  else
    fail "$(printf '%s; ' "${problems[@]}")fix that first"
  fi
fi

origin_is_local=false
case "$(git remote get-url origin 2>/dev/null || true)" in
  /* | file://*) origin_is_local=true ;;
esac

test_mode=false
if [ -n "${KX_RELEASE_DIR:-}" ]; then
  warn "test mode: reading the kx release from $KX_RELEASE_DIR instead of GitHub"
  test_mode=true
fi
if $skip_attestations; then
  test_mode=true
fi
if $test_mode && [ "$mode" != dry-run ] && ! $origin_is_local; then
  fail "KX_RELEASE_DIR and --skip-attestations are only for dry runs and tests; --commit and --push need verified release files and provenance"
fi

if [ "$mode" = push ]; then
  say "Checking that main is up to date with origin"
  git fetch --quiet origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse FETCH_HEAD)" ] ||
    fail "main is not the same as origin/main; pull (or push) first"
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    fail "tag $tag already exists on origin; published tags are never moved or reused"
  fi
fi

# --- 1. Download ----------------------------------------------------------------

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
files=(checksums.txt "${ARCHIVES[@]}")
say "Fetching kx $kx_version release files"
for f in "${files[@]}"; do
  if [ -n "${KX_RELEASE_DIR:-}" ]; then
    cp "$KX_RELEASE_DIR/$f" "$work/$f" 2>/dev/null || fail "$KX_RELEASE_DIR has no $f"
  else
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
      -o "$work/$f" "$RELEASES/v$kx_version/$f" ||
      fail "couldn't download $f of kx $kx_version; is v$kx_version released?"
  fi
done

# --- 2. Check checksums.txt and the archives ----------------------------------------

say "Checking checksums.txt against the release contract"
lines=0
while IFS= read -r line || [ -n "$line" ]; do
  lines=$((lines + 1))
  [[ "$line" =~ ^([0-9a-f]{64})\ \ ([A-Za-z0-9._-]+)$ ]] ||
    fail "checksums.txt line $lines is not '<sha256>  <file>'"
  name="${BASH_REMATCH[2]}"
  known=false
  for a in "${ARCHIVES[@]}"; do [ "$a" = "$name" ] && known=true; done
  $known || fail "checksums.txt lists $name, which is not a kx release archive"
done <"$work/checksums.txt"
[ "$lines" -eq "${#ARCHIVES[@]}" ] || fail "checksums.txt has $lines lines; it must list the ${#ARCHIVES[@]} archives"
for a in "${ARCHIVES[@]}"; do
  n="$(awk -v f="$a" '$2 == f' "$work/checksums.txt" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] || fail "checksums.txt lists $a $n times; it must list it once"
done
(cd "$work" && sha256sum --quiet --strict -c checksums.txt) || fail "an archive doesn't match checksums.txt"
echo "    all ${#ARCHIVES[@]} archives are listed once and match"

# --- 3. Attestations ---------------------------------------------------------------

if $skip_attestations; then
  warn "skipping build provenance checks (--skip-attestations)"
else
  command -v gh >/dev/null 2>&1 || fail "gh is needed to verify attestations (or pass --skip-attestations)"
  say "Verifying build provenance"
  for f in "${files[@]}"; do
    gh attestation verify "$work/$f" --repo "$KX_REPO" --signer-workflow "$SIGNER" \
      --source-ref "refs/tags/v$kx_version" --deny-self-hosted-runners >/dev/null ||
      fail "$f has no valid attestation from $SIGNER for v$kx_version"
    echo "    $f: attested"
  done
fi

# --- 4. The changes -------------------------------------------------------------------

sums="checksums/$kx_version.txt"
if [ -e "$sums" ] && ! cmp -s "$sums" "$work/checksums.txt"; then
  fail "$sums already exists with different checksums; committed checksums are never rewritten"
fi

[ "$(grep -cF -- "$ACTION_MARKER" action.yml)" -eq 1 ] || fail "action.yml must have exactly one line ending in: $ACTION_MARKER"
[ "$(grep -cF -- "$README_MARKER" README.md)" -eq 1 ] || fail "README.md must have exactly one line with: $README_MARKER"

# edit_files DIR: apply the version bump to DIR/action.yml and DIR/README.md.
edit_files() {
  local d="$1"
  sed -i.bak -E "s|^(    default: )\"[^\"]*\"( $ACTION_MARKER)\$|\\1\"$kx_version\"\\2|" "$d/action.yml"
  sed -i.bak -E "s|\`[^\`]*\`( $README_MARKER)|\`$kx_version\`\\1|" "$d/README.md"
  rm -f "$d/action.yml.bak" "$d/README.md.bak"
  grep -qF "default: \"$kx_version\" $ACTION_MARKER" "$d/action.yml" || fail "couldn't update action.yml"
  grep -qF "\`$kx_version\` $README_MARKER" "$d/README.md" || fail "couldn't update README.md"
}

mkdir "$work/preview"
cp action.yml README.md "$work/preview/"
edit_files "$work/preview"

say "Changes"
if [ -e "$sums" ]; then
  echo "    $sums is already committed and identical"
else
  echo "    new file $sums:"
  sed 's/^/      /' "$work/checksums.txt"
fi
diff -u action.yml "$work/preview/action.yml" | sed 's/^/    /' || true
diff -u README.md "$work/preview/README.md" | sed 's/^/    /' || true

# The major tag moves only for the newest stable release of that major.
move_major=false
if ! $prerelease; then
  newest="$( (git tag -l "v$major.*"; echo "$tag") | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)"
  if [ "$newest" = "$tag" ]; then
    move_major=true
  else
    warn "v$major stays at $newest, which is newer than $tag"
  fi
fi

say "Plan"
echo "    commit \"chore(release): pin kx $kx_version\" on main (if anything changed)"
echo "    tag $tag (annotated)"
if $move_major; then echo "    move v$major to $tag"; fi
if [ "$mode" = push ]; then echo "    push main, $tag$($move_major && echo " and v$major") to origin"; fi

if [ "$mode" = dry-run ]; then
  echo
  echo "Dry run: nothing changed. Run again with --commit (local only) or --push."
  exit 0
fi

# --- 5. Commit, tag, push -------------------------------------------------------------

cp "$work/checksums.txt" "$sums"
cp "$work/preview/action.yml" action.yml
cp "$work/preview/README.md" README.md
git add -- "$sums" action.yml README.md
if git diff --cached --quiet; then
  say "Nothing to commit; tagging the current main"
else
  git commit --quiet -m "chore(release): pin kx $kx_version" \
    -m "checksums/$kx_version.txt is the checksums.txt of the kx v$kx_version release, verified by scripts/publish-action.sh."
  say "Committed $(git rev-parse --short HEAD)"
fi

git tag -a "$tag" -m "Kubernetix-AI/deploy $action_version (kx $kx_version)"
say "Tagged $tag"
refs=("HEAD:refs/heads/main" "refs/tags/$tag")
if $move_major; then
  git tag -f -a "v$major" -m "Kubernetix-AI/deploy $action_version (kx $kx_version)" "$tag^{commit}" >/dev/null
  say "Moved v$major to $tag"
  refs+=("+refs/tags/v$major")
fi

if [ "$mode" = push ]; then
  git push --atomic origin "${refs[@]}"
  say "Pushed ${refs[*]}"
  echo "Done. Workflows can now use Kubernetix-AI/deploy@$tag$($move_major && echo " or @v$major")."
else
  echo
  if $test_mode; then
    echo "Done locally (test mode, so no push command is shown)."
  else
    echo "Done locally. To publish: git push --atomic origin ${refs[*]}"
  fi
fi
