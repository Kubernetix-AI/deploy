#!/usr/bin/env bash
# Injection tests for action.yml: inputs must stay data.
#
# Runs the Action's Deploy step the way the runner does (tests/run_step.py)
# against a stub kx, with inputs holding $(...), backticks, quotes, line
# breaks and other shell syntax. Passes only if nothing was executed and the
# stub received each input as exactly one literal argument.
# The payloads and jq programs are single-quoted on purpose:
# shellcheck disable=SC2016
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WS="$TMP_ROOT/workspace"
mkdir -p "$WS" "$TMP_ROOT/stub"
STUB="$TMP_ROOT/stub/kx"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
# Stand-in kx: records its arguments (NUL-separated) and the tokens it got.
printf '%s\0' "$@" >"$STUB_ARGS"
printf '%s' "${KX_TOKEN-<unset>}" >"$STUB_TOKEN"
printf '%s' "${GITHUB_TOKEN-<unset>}" >"$STUB_GHTOKEN"
echo "url=https://shop-api.example.test" >>"$GITHUB_OUTPUT"
exit "${STUB_EXIT:-0}"
EOF
chmod 0755 "$STUB"

# Payloads that run a command if anything evaluates them.
P_DOLLAR='shop$(touch pwned-dollar)'
P_BACKTICK='api`touch pwned-backtick`'
P_QUOTE='"; touch pwned-quote; echo "'
P_SINGLE="'; touch pwned-single; '"
P_NEWLINE=$'web\n--api-url=https://attacker.example\ntouch pwned-newline'
P_IFS='15m${IFS}$(touch${IFS}pwned-ifs)'
P_SEMI='prod;touch pwned-semi&&touch pwned-and|touch pwned-pipe'
P_TOKEN='kx_$(touch pwned-token)`touch pwned-token2`'
P_GHTOKEN='ghs_$(touch pwned-ghtoken)'
P_IMAGE='registry.example/app@sha256:`touch pwned-image`$(touch pwned-image2)'

# run_deploy INPUTS_JSON [NAME=VALUE]...: run the Deploy step in $WS.
# Sets RC, OUT and ARGS (the stub's arguments; empty if it didn't run).
run_deploy() {
  local inputs="$1"
  shift
  rm -f "$TMP_ROOT/args" "$TMP_ROOT/token" "$TMP_ROOT/ghtoken"
  : >"$TMP_ROOT/output"
  OUT="$(cd "$WS" && env -i HOME="$HOME" PATH="$PATH" GITHUB_EVENT_NAME=push \
    GITHUB_OUTPUT="$TMP_ROOT/output" STUB_ARGS="$TMP_ROOT/args" STUB_TOKEN="$TMP_ROOT/token" \
    STUB_GHTOKEN="$TMP_ROOT/ghtoken" "$@" \
    python3 "$REPO_ROOT/tests/run_step.py" deploy "$inputs" "{\"install.kx-path\": \"$STUB\"}" 2>&1)"
  RC=$?
  ARGS=()
  if [ -f "$TMP_ROOT/args" ]; then
    mapfile -d '' -t ARGS <"$TMP_ROOT/args"
  fi
}

# expect_args NAME ARG...: the stub got exactly these arguments.
expect_args() {
  local name="$1"
  shift
  local want=("$@")
  if [ "$RC" -eq 0 ] && [ "${#ARGS[@]}" -eq "${#want[@]}" ] && [ "$(printf '%s\0' "${ARGS[@]}" | od -An -tx1)" = "$(printf '%s\0' "${want[@]}" | od -An -tx1)" ]; then
    pass "$name"
  else
    fail_test "$name" "rc=$RC" "got:  $(printf '[%q] ' "${ARGS[@]}")" "want: $(printf '[%q] ' "${want[@]}")" "output: $OUT"
  fi
}

# expect_nothing_ran NAME: no payload created a file anywhere in the scratch folder.
expect_nothing_ran() {
  local found
  found="$(find "$TMP_ROOT" -name 'pwned*' -print)"
  if [ -z "$found" ]; then pass "$1"; else fail_test "$1" "payload ran: $found"; fi
}

json() { jq -cn "$@"; }

echo "# the payloads are live (control)"
(cd "$TMP_ROOT" && mkdir control && cd control && eval "echo $P_DOLLAR $P_BACKTICK" >/dev/null 2>&1)
if [ -e "$TMP_ROOT/control/pwned-dollar" ] && [ -e "$TMP_ROOT/control/pwned-backtick" ]; then
  pass "the payloads do run when a shell evaluates them"
else
  fail_test "the payloads do run when a shell evaluates them"
fi
rm -rf "$TMP_ROOT/control"

echo "# build mode, every input hostile"
inputs="$(json --arg app "$P_DOLLAR$P_BACKTICK" --arg path "$P_QUOTE" --arg df "$P_NEWLINE" \
  --arg env "$P_SINGLE" --arg to "$P_IFS" --arg tok "$P_TOKEN" --arg gh "$P_GHTOKEN" \
  '{app: $app, path: $path, dockerfile: $df, environment: $env, timeout: $to, token: $tok, "github-token": $gh}')"
run_deploy "$inputs"
expect_args "each input reaches kx as one literal --flag=value argument" \
  deploy --github "--app=$P_DOLLAR$P_BACKTICK" "--build=$P_QUOTE" "--dockerfile=$P_NEWLINE" \
  "--environment=$P_SINGLE" "--timeout=$P_IFS"
expect_nothing_ran "no input was executed (build mode)"
if [ "$(cat "$TMP_ROOT/token" 2>/dev/null)" = "$P_TOKEN" ] && [ "$(cat "$TMP_ROOT/ghtoken" 2>/dev/null)" = "$P_GHTOKEN" ]; then
  pass "the tokens reach kx literally, through the environment"
else
  fail_test "the tokens reach kx literally, through the environment" "output: $OUT"
fi
if ! contains "$(printf '%s ' "${ARGS[@]}")" "kx_"; then pass "the token is never a command-line argument"; else fail_test "the token is never a command-line argument"; fi
if contains "$OUT" "::add-mask::$P_TOKEN"; then pass "the token is masked in the log"; else fail_test "the token is masked in the log" "output: $OUT"; fi

echo "# image mode"
inputs="$(json --arg img "$P_IMAGE" --arg env "$P_SEMI" '{image: $img, environment: $env, token: "kx_test"}')"
run_deploy "$inputs"
expect_args "image mode passes --image and no --build for the default path" \
  deploy --github "--image=$P_IMAGE" "--environment=$P_SEMI" "--timeout=15m"
expect_nothing_ran "no input was executed (image mode)"

inputs="$(json --arg img "$P_IMAGE" '{image: $img, path: "services/api", token: "kx_test"}')"
run_deploy "$inputs"
expect_args "image mode with a path passes both, for kx to explain" \
  deploy --github "--image=$P_IMAGE" "--build=services/api" "--environment=production" "--timeout=15m"

echo "# defaults and simple inputs"
run_deploy '{"token": "kx_test"}'
expect_args "defaults: build the repository root for production, 15 minute timeout" \
  deploy --github "--build=." "--environment=production" "--timeout=15m"

run_deploy '{"token": "kx_test", "app": "shop-api", "wait": "false", "timeout": "30m"}'
expect_args "wait: false adds --no-wait" \
  deploy --github "--app=shop-api" "--build=." "--environment=production" "--no-wait" "--timeout=30m"

run_deploy "$(json --arg w "true\$(touch pwned-wait)" '{token: "kx_test", wait: $w}')"
if [ "$RC" -ne 0 ] && [ "${#ARGS[@]}" -eq 0 ] && contains "$OUT" "The wait input must be true or false."; then
  pass "a wait value other than true or false is refused before kx runs"
else
  fail_test "a wait value other than true or false is refused before kx runs" "rc=$RC output: $OUT"
fi
expect_nothing_ran "no input was executed (wait)"

echo "# the token"
run_deploy '{"token": ""}'
if [ "$RC" -ne 0 ] && [ "${#ARGS[@]}" -eq 0 ] && contains "$OUT" "The token input is empty"; then
  pass "an empty token on push stops with the two-line fix"
else
  fail_test "an empty token on push stops with the two-line fix" "rc=$RC output: $OUT"
fi

run_deploy '{"token": ""}' GITHUB_EVENT_NAME=pull_request
expect_args "an empty token on pull_request still runs kx, which explains it only deploys on push" \
  deploy --github "--build=." "--environment=production" "--timeout=15m"

run_deploy "$(json --arg t $'kx_secretpart\n::warning::injected' '{token: $t}')"
if [ "$RC" -ne 0 ] && [ "${#ARGS[@]}" -eq 0 ] && contains "$OUT" "more than one line" && ! contains "$OUT" "secretpart"; then
  pass "a token with a line break is refused without printing it"
else
  fail_test "a token with a line break is refused without printing it" "rc=$RC output: $OUT"
fi

echo "# kx's result"
run_deploy '{"token": "kx_test"}' STUB_EXIT=8
if [ "$RC" -eq 8 ]; then pass "kx's exit code is the step's exit code"; else fail_test "kx's exit code is the step's exit code" "rc=$RC"; fi
if grep -qx 'url=https://shop-api.example.test' "$TMP_ROOT/output"; then
  pass "kx writes its outputs to the step's GITHUB_OUTPUT"
else
  fail_test "kx writes its outputs to the step's GITHUB_OUTPUT"
fi

echo "# action.yml wiring"
if python3 - "$REPO_ROOT/action.yml" <<'EOF'; then
import re, sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
steps = {s["id"]: s for s in a["runs"]["steps"]}
assert a["runs"]["using"] == "composite"
for s in a["runs"]["steps"]:
    assert "${{" not in s["run"], "expression in run: of " + s["id"]
used = set()
for s in a["runs"]["steps"]:
    for k, v in (s.get("env") or {}).items():
        m = re.fullmatch(r"\$\{\{ inputs\.([a-z-]+) \}\}", str(v))
        if m:
            used.add(m.group(1))
assert used == set(a["inputs"]), "inputs not passed through env: %s" % (set(a["inputs"]) ^ used)
for out in ("url", "deployment-id", "version", "image"):
    assert a["outputs"][out]["value"] == "${{ steps.deploy.outputs.%s }}" % out, out
assert set(a["outputs"]) == {"url", "deployment-id", "version", "image"}
assert steps["install"]["env"]["KX_INSTALL_BASE_URL"] == ""
EOF
  pass "every input goes through env:, no run: has an expression, outputs come from kx"
else
  fail_test "every input goes through env:, no run: has an expression, outputs come from kx"
fi

# The harness itself refuses an action that pastes an input into run:.
BAD="$TMP_ROOT/bad-action"
mkdir -p "$BAD/scripts"
cp "$REPO_ROOT"/scripts/*.sh "$BAD/scripts/"
sed 's|run: bash "$GITHUB_ACTION_PATH/scripts/deploy.sh"|run: echo "${{ inputs.app }}"|' "$REPO_ROOT/action.yml" >"$BAD/action.yml"
OUT="$(ACTION_ROOT="$BAD" python3 "$REPO_ROOT/tests/run_step.py" deploy '{"app": "x"}' 2>&1)"
RC=$?
if [ "$RC" -eq 97 ] && contains "$OUT" "expression inside run:"; then
  pass "the harness rejects an action.yml with \${{ }} inside run:"
else
  fail_test "the harness rejects an action.yml with \${{ }} inside run:" "rc=$RC output: $OUT"
fi

finish
