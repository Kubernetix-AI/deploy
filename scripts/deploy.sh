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
#   DEPLOY_ENVIRONMENT  environment
#   DEPLOY_WAIT         wait
#   DEPLOY_TIMEOUT      timeout
#
# Each value becomes exactly one argument of the form --flag=value, so a
# value can't turn into another flag or a second argument.
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
    push | workflow_dispatch)
      fail "The token input is empty, so this workflow can't deploy." \
        "Save a deploy token as the KX_TOKEN secret of the production environment, and give the job environment: production."
      ;;
    *) ;; # kx explains that it only deploys on push and exits 0.
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

args+=("--environment=${DEPLOY_ENVIRONMENT:-production}")

case "${DEPLOY_WAIT:-true}" in
  true | True | TRUE) ;;
  false | False | FALSE) args+=(--no-wait) ;;
  *) fail "The wait input must be true or false." "Set wait: true to wait until the deploy is live, or wait: false to stop once it has started." ;;
esac

if [ -n "${DEPLOY_TIMEOUT:-}" ]; then
  args+=("--timeout=$DEPLOY_TIMEOUT")
fi

exec "$KX_BIN" "${args[@]}"
