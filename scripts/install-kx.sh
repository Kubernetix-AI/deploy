#!/usr/bin/env bash
# install-kx.sh: install a pinned, checksum-verified kx for this Action.
#
# Environment:
#   KX_VERSION     the kx version, for example 1.0.0. It must have a
#                  checksums/<version>.txt committed in this repository.
#   RUNNER_TEMP    where kx is installed (set by GitHub Actions)
#   RUNNER_OS      must be Linux (set by GitHub Actions; uname otherwise)
#   RUNNER_ARCH    X64 or ARM64 (set by GitHub Actions; uname otherwise)
#   GITHUB_PATH    kx's folder is added to it, so later steps can run kx
#   GITHUB_OUTPUT  receives kx-path, the full path of the installed kx
#
# The archive is downloaded from the kx release on GitHub over HTTPS and
# installed only if its SHA-256 matches the checksum committed in this
# repository. There is no way to skip that check.
#
# Tests only: KX_INSTALL_BASE_URL=file:///<dir> copies the archive from
# <dir>/v<version>/ instead of downloading it. It is honoured only for a
# file:// folder inside GITHUB_WORKSPACE, the checksum is still checked
# against checksums/, and action.yml always clears it.

# Kept to plain sh syntax until the OS check, so that on a macOS (bash 3.2)
# or Windows runner the user still gets a clear message.
os="${RUNNER_OS:-$(uname -s 2>/dev/null || echo unknown)}"
case "$os" in
  Linux | linux) ;;
  *)
    echo "::error title=Kubernetix deploy::Kubernetix-AI/deploy runs on Linux runners only, and this job runs on $os.%0AUse runs-on: ubuntu-latest for the job that deploys."
    exit 1
    ;;
esac

set -euo pipefail

RELEASES="https://github.com/Kubernetix-AI/kx/releases/download"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$'

# escape VALUE: make VALUE safe inside a workflow command.
escape() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

# fail WHAT FIX: print the two-line error as an annotation and stop.
fail() {
  printf '::error title=Kubernetix deploy::%s%%0A%s\n' "$(escape "$1")" "$(escape "$2")"
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# available: the kx versions this copy of the Action has checksums for.
available() {
  local f list=""
  for f in "$root"/checksums/*.txt; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    list="${list:+$list, }${f%.txt}"
  done
  printf '%s' "${list:-none}"
}

# --- Inputs -----------------------------------------------------------------

version="${KX_VERSION:-}"
version="${version#v}"
if [ -z "$version" ]; then
  fail "No kx version was given." "Remove kx-version from the workflow to use the version this Action pins."
fi
if ! [[ "$version" =~ $SEMVER ]]; then
  fail "\"${KX_VERSION}\" isn't a kx version." "Use a version such as 1.0.0, or remove kx-version to use the one this Action pins."
fi

sums="$root/checksums/$version.txt"
if [ ! -f "$sums" ] || [ -L "$sums" ]; then
  fail "This release of Kubernetix-AI/deploy can't install kx $version, because it has no checksums for it." \
    "Use a kx version it has checksums for ($(available)), or a newer release of the Action."
fi

case "${RUNNER_ARCH:-}" in
  X64) arch=amd64 ;;
  ARM64) arch=arm64 ;;
  "")
    case "$(uname -m)" in
      x86_64 | amd64) arch=amd64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *) fail "kx has no build for this runner's processor ($(uname -m))." "Use a runner with an x64 or ARM64 processor, such as ubuntu-latest." ;;
    esac
    ;;
  *) fail "kx has no build for this runner's processor (${RUNNER_ARCH})." "Use a runner with an x64 or ARM64 processor, such as ubuntu-latest." ;;
esac

[ -n "${RUNNER_TEMP:-}" ] && [ -d "$RUNNER_TEMP" ] ||
  fail "RUNNER_TEMP isn't set to a folder, so there's nowhere to install kx." "Run this Action in a GitHub Actions job."
[ -n "${GITHUB_PATH:-}" ] && [ -n "${GITHUB_OUTPUT:-}" ] ||
  fail "GITHUB_PATH or GITHUB_OUTPUT isn't set." "Run this Action in a GitHub Actions job."

asset="kx_linux_${arch}.tar.gz"

# The expected checksum: exactly one well-formed line for this archive.
expected="$(awk -v f="$asset" '$2 == f { print $1 }' "$sums")"
if [ "$(printf '%s\n' "$expected" | grep -c .)" -ne 1 ] || ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  fail "checksums/$version.txt has no valid checksum for $asset." "Use a release of Kubernetix-AI/deploy whose checksums were written by its publish script."
fi

# --- Download -----------------------------------------------------------------

work="$(mktemp -d "$RUNNER_TEMP/kx-download.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/$asset"

if [ -n "${KX_INSTALL_BASE_URL:-}" ]; then
  # Test hook. Only a file:// folder inside the workspace is accepted.
  case "$KX_INSTALL_BASE_URL" in
    file:///*) ;;
    *) fail "KX_INSTALL_BASE_URL must be a file:// URL." "Unset KX_INSTALL_BASE_URL; it is only for this Action's own tests." ;;
  esac
  [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ] ||
    fail "KX_INSTALL_BASE_URL needs GITHUB_WORKSPACE." "Unset KX_INSTALL_BASE_URL; it is only for this Action's own tests."
  ws="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
  base="${KX_INSTALL_BASE_URL#file://}"
  [ -d "$base" ] || fail "KX_INSTALL_BASE_URL isn't a folder." "Unset KX_INSTALL_BASE_URL; it is only for this Action's own tests."
  base="$(cd "$base" && pwd -P)"
  case "$base/" in
    "$ws"/?*) ;;
    *) fail "KX_INSTALL_BASE_URL must be inside the workspace." "Unset KX_INSTALL_BASE_URL; it is only for this Action's own tests." ;;
  esac
  [ "$ws" != "/" ] || fail "The workspace can't be /." "Unset KX_INSTALL_BASE_URL; it is only for this Action's own tests."
  echo "Test mode: copying $asset from $base/v$version"
  cp "$base/v$version/$asset" "$archive" ||
    fail "Couldn't copy $asset for kx $version." "Check the test's fake release folder."
else
  command -v curl >/dev/null 2>&1 ||
    fail "This runner has no curl, which is needed to download kx." "Install curl on the runner, or use runs-on: ubuntu-latest."
  url="$RELEASES/v$version/$asset"
  echo "Downloading kx $version for linux/$arch"
  status=0
  code="$(curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
    -w '%{http_code}' -o "$archive" "$url")" || status=$?
  if [ "$status" -ne 0 ]; then
    case "$code" in
      404 | 410)
        fail "kx $version is no longer available from GitHub, so this release of Kubernetix-AI/deploy can't install it." \
          "Use a newer release of the Action, such as Kubernetix-AI/deploy@v1, or remove kx-version."
        ;;
      *) fail "Couldn't download kx $version from GitHub." "Re-run the job. If it keeps failing, check https://www.githubstatus.com." ;;
    esac
  fi
fi

# --- Verify -------------------------------------------------------------------

actual="$(sha256sum "$archive" | awk '{ print $1 }')"
if [ "$actual" != "$expected" ]; then
  rm -f "$archive"
  fail "The kx $version download doesn't match the checksum committed in Kubernetix-AI/deploy, so it wasn't installed." \
    "Re-run the job. If it happens again, report it: https://github.com/Kubernetix-AI/deploy/security/advisories/new"
fi
echo "Checksum OK: $asset sha256:$actual"

# --- Install ------------------------------------------------------------------

mkdir "$work/x"
tar -xzf "$archive" -C "$work/x" --no-same-owner --no-same-permissions kx 2>/dev/null ||
  fail "The kx $version archive has no kx in it." "Report it: https://github.com/Kubernetix-AI/deploy/issues"
if [ ! -f "$work/x/kx" ] || [ -L "$work/x/kx" ]; then
  fail "The kx $version archive holds something other than the kx program." "Report it: https://github.com/Kubernetix-AI/deploy/security/advisories/new"
fi

chmod 0755 "$work/x/kx"
if ! out="$("$work/x/kx" version 2>/dev/null)"; then
  fail "kx $version doesn't run on this runner." "Use a runner with an x64 or ARM64 processor, such as ubuntu-latest."
fi
case "$out" in
  "kx $version ("*) ;;
  *) fail "The kx $version archive holds a different kx version." "Report it: https://github.com/Kubernetix-AI/deploy/security/advisories/new" ;;
esac

dest="$(mktemp -d "$RUNNER_TEMP/kx-$version.XXXXXX")"
case "$dest" in
  *$'\n'* | *$'\r'*) fail "RUNNER_TEMP contains a line break." "Run this Action in a GitHub Actions job." ;;
esac
mv "$work/x/kx" "$dest/kx"
echo "Installed $out"

echo "$dest" >>"$GITHUB_PATH"
echo "kx-path=$dest/kx" >>"$GITHUB_OUTPUT"
