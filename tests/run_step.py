#!/usr/bin/env python3
"""Run one step of action.yml the way the GitHub Actions runner does.

Usage: run_step.py STEP_ID INPUTS_JSON [STEP_OUTPUTS_JSON]

INPUTS_JSON maps input names to the values a workflow would pass; inputs it
leaves out get their defaults from action.yml. STEP_OUTPUTS_JSON maps
"<step id>.<output>" to values for ${{ steps.<id>.outputs.<name> }}.

Like the runner, it evaluates the step's env: expressions to plain strings
(no shell involved), writes run: to a file and runs it with
`bash --noprofile --norc -eo pipefail FILE` in the current directory, with
GITHUB_ACTION_PATH set to the repository root. It refuses any run: that
contains an expression and any env: value other than a plain string or a
single ${{ inputs.<name> }} / ${{ steps.<id>.outputs.<name> }} expression,
so a test can't pass while the action pastes inputs into shell code.

ACTION_ROOT, if set, is the folder holding the action.yml to run (tests use
a copy of this repository with their own checksums/).

Exits with the step's exit code.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

import yaml

# The action to run: this repository, or ACTION_ROOT (a copy made by a test).
ROOT = os.environ.get("ACTION_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INPUT_RE = re.compile(r"^\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}$")
STEP_RE = re.compile(r"^\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}$")


def die(msg):
    print("run_step: " + msg, file=sys.stderr)
    sys.exit(97)


def main():
    if len(sys.argv) not in (3, 4):
        die(__doc__.strip().splitlines()[2])
    step_id = sys.argv[1]
    inputs = json.loads(sys.argv[2])
    step_outputs = json.loads(sys.argv[3]) if len(sys.argv) == 4 else {}

    with open(os.path.join(ROOT, "action.yml"), encoding="utf-8") as f:
        action = yaml.safe_load(f)

    declared = action.get("inputs") or {}
    for name in inputs:
        if name not in declared:
            die("action.yml has no input named " + name)

    steps = [s for s in action["runs"]["steps"] if s.get("id") == step_id]
    if len(steps) != 1:
        die("action.yml has no single step with id " + step_id)
    step = steps[0]

    for s in action["runs"]["steps"]:
        if "${{" in str(s.get("run", "")):
            die("step %r has an expression inside run:" % s.get("id"))
    if step.get("shell") != "bash":
        die("step %s must use shell: bash" % step_id)

    env = dict(os.environ)
    env["GITHUB_ACTION_PATH"] = ROOT
    for key, raw in (step.get("env") or {}).items():
        value = "" if raw is None else str(raw)
        if "${{" not in value:
            env[key] = value
            continue
        m = INPUT_RE.match(value)
        if m:
            name = m.group(1)
            if name not in declared:
                die("env %s uses unknown input %s" % (key, name))
            if name in inputs:
                env[key] = str(inputs[name])
            else:
                default = declared[name].get("default", "")
                if "${{" in str(default):
                    default = ""  # e.g. github.token: tests pass it explicitly
                env[key] = str(default)
            continue
        m = STEP_RE.match(value)
        if m:
            env[key] = str(step_outputs.get(m.group(1) + "." + m.group(2), ""))
            continue
        die("env %s=%r is not a plain input or step output" % (key, value))

    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as script:
        script.write(step["run"])
        path = script.name
    try:
        rc = subprocess.call(["bash", "--noprofile", "--norc", "-eo", "pipefail", path], env=env)
    finally:
        os.unlink(path)
    sys.exit(rc)


if __name__ == "__main__":
    main()
