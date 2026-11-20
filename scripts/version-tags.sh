#!/usr/bin/env bash
# version-tags.sh DIR: let kx see the version tags of the commit it builds.
#
# kx pushes the image under the commit's version too (1.4.0 for a tag
# v1.4.0), but actions/checkout fetches one commit and no tags by default.
# When the checkout holding DIR (the path input) has no version tag on
# HEAD, this asks origin which tags point at HEAD and fetches the ones that
# look like versions (v1.2.3 or 1.2.3, optionally with a pre-release such
# as -rc.1; kx makes the final choice). It uses the checkout's own
# credentials and never fails the job: without an answer from origin, kx
# pushes the image under the commit's tag only.
#
# Tag names come from the repository, so only names made of the characters
# a version uses are ever passed to git, and each one as part of a single
# refs/tags/ refspec.
set -uo pipefail

dir="${1:-.}"
no_tags="The Action couldn't get this commit's tags from origin, so the image gets no version tag; to include them, set fetch-depth: 0 in actions/checkout."
version_re='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

# git in the checkout, never asking for a password.
git_in() { GIT_TERMINAL_PROMPT=0 git -C "$dir" "$@"; }

# Talking to origin is bounded, where timeout exists.
remote() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 env GIT_TERMINAL_PROMPT=0 git -C "$dir" "$@"
  else
    git_in "$@"
  fi
}

head="$(git_in rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || exit 0
[ -n "$head" ] || exit 0

while IFS= read -r t; do
  if [[ "$t" =~ $version_re ]]; then
    exit 0 # the checkout already has one; kx reads it
  fi
done < <(git_in tag --list --points-at "$head" 2>/dev/null)

if ! listing="$(remote ls-remote --tags origin 2>/dev/null)"; then
  echo "$no_tags"
  exit 0
fi

# Lines are "<object>\trefs/tags/<name>", plus "<commit>\trefs/tags/<name>^{}"
# for an annotated tag: the commit it points at.
names=()
while IFS=$'\t' read -r sha ref; do
  [ "$sha" = "$head" ] || continue
  name="${ref#refs/tags/}"
  name="${name%^\{\}}"
  [[ "$name" =~ $version_re ]] || continue
  case " ${names[*]-} " in *" $name "*) continue ;; esac
  names+=("$name")
done <<<"$listing"

fetched=()
for name in "${names[@]+"${names[@]}"}"; do
  if remote fetch --quiet --no-tags origin "+refs/tags/$name:refs/tags/$name" >/dev/null 2>&1; then
    fetched+=("$name")
  fi
done
if [ "${#fetched[@]}" -gt 0 ]; then
  echo "Fetched this commit's version tags from origin: ${fetched[*]}"
elif [ "${#names[@]}" -gt 0 ]; then
  echo "$no_tags"
fi
exit 0
