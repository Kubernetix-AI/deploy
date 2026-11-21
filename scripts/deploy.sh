#!/usr/bin/env bash
# deploy.sh: run `kx deploy --github` with the Action's inputs.
#
# action.yml passes every input through the environment, never by pasting
# it into this script, so an input is always data and never shell code:
#
#   KX_BIN              the kx that install-kx.sh installed
#   KX_TOKEN            token          (read by kx itself)
#   GITHUB_TOKEN        github-token   (read by kx itself, for the commit status)
#   DEPLOY_APP          app
#   DEPLOY_PATH         path
#   DEPLOY_DOCKERFILE   dockerfile
#   DEPLOY_IMAGE        image
#   DEPLOY_REPOSITORY   repository
#   DEPLOY_ENVIRONMENT  environment
#   DEPLOY_WAIT         wait
#   DEPLOY_TIMEOUT      timeout
#
# Each value becomes exactly one argument of the form --flag=value, so a
# value can't turn into another flag or a second argument.
#
# Before kx builds, version-tags.sh fetches the commit's version tags from
# origin that the checkout doesn't have, so kx can give the image the
# version too (kx 1.1.0 and later; kx 1.0 has no version tags).
set -euo pipefail

escape() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

fail() {
  printf '::error title=Kubernetix deploy::%s%%0A%s\n' "$(escape "$1")" "$(escape "$2")"
  exit 1
}

if [ -z "${KX_BIN:-}" ] || [ ! -x "$KX_BIN" ]; then
  fail "kx isn't installed, so there's nothing to deploy with." "Re-run the job; the Install kx step should have installed it."
fi

token="${KX_TOKEN:-}"
case "$token" in
  *$'\n'* | *$'\r'*)
    fail "The token input has more than one line." "Save only the kx_ token in the KX_TOKEN secret, with no extra lines."
    ;;
esac
if [ -n "$token" ]; then
  # GitHub already hides secrets in the log; this also covers a token that
  # reached the input some other way.
  echo "::add-mask::$token"
else
  case "${GITHUB_EVENT_NAME:-}" in
    # Pull request runs never deploy (and get no secrets from forks): kx
    # says so and exits 0. Without an event name kx explains the refusal.
    pull_request | pull_request_target | pull_request_review | pull_request_review_comment | merge_group | "") ;;
    *)
      fail "The token input is empty, so this workflow can't deploy." \
        "Save a deploy token as the KX_TOKEN secret of the production environment, and give the job environment: production."
      ;;
  esac
fi

args=(deploy --github)

if [ -n "${DEPLOY_APP:-}" ]; then
  args+=("--app=$DEPLOY_APP")
fi

path="${DEPLOY_PATH:-.}"
if [ -n "${DEPLOY_IMAGE:-}" ]; then
  args+=("--image=$DEPLOY_IMAGE")
  # Pass a non-default path too, so kx can say the two don't go together.
  if [ "$path" != "." ]; then
    args+=("--build=$path")
  fi
else
  args+=("--build=$path")
fi

if [ -n "${DEPLOY_DOCKERFILE:-}" ]; then
  args+=("--dockerfile=$DEPLOY_DOCKERFILE")
fi

# kx_has FLAG: whether this kx's deploy command has FLAG (kx 1.0 has
# neither --tag nor --repository).
kx_help=""
kx_has() {
  if [ -z "$kx_help" ]; then
    kx_help="$("$KX_BIN" deploy --help 2>/dev/null || true)"
  fi
  case "$kx_help" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# needs_flag FLAG INPUT: stop unless this kx has FLAG; say so instead of
# kx's unknown-flag error.
needs_flag() {
  kx_has "$1" || fail "The $2 input needs kx 1.1.0 or later, and this job runs an older kx." \
    "Use a release of Kubernetix-AI/deploy that pins kx 1.1.0 or later (or set kx-version to one), or remove the $2 input."
}

if [ -n "${DEPLOY_REPOSITORY:-}" ]; then
  needs_flag --repository repository
  args+=("--repository=$DEPLOY_REPOSITORY")
fi


args+=("--environment=${DEPLOY_ENVIRONMENT:-production}")

case "${DEPLOY_WAIT:-true}" in
  true | True | TRUE) ;;
  false | False | FALSE) args+=(--no-wait) ;;
  *) fail "The wait input must be true or false." "Set wait: true to wait until the deploy is live, or wait: false to stop once it has started." ;;
esac

if [ -n "${DEPLOY_TIMEOUT:-}" ]; then
  args+=("--timeout=$DEPLOY_TIMEOUT")
fi

# kx skips pull request runs, with an image it builds nothing, and kx 1.0
# gives no version tags.
case "${GITHUB_EVENT_NAME:-}" in
  pull_request | pull_request_target | pull_request_review | pull_request_review_comment | merge_group | "") ;;
  *)
    if [ -z "${DEPLOY_IMAGE:-}" ] && kx_has --tag; then
      bash "$(dirname "${BASH_SOURCE[0]}")/version-tags.sh" "$path" || true
    fi
    ;;
esac

exec "$KX_BIN" "${args[@]}"
