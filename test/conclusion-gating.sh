#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$(ruby -ryaml -e '
  workflow = YAML.load_file(ARGV.fetch(0))
  step = workflow.fetch("jobs").fetch("conclusion").fetch("steps").find { |item| item["name"] == "Result" }
  puts step.fetch("run")
' "${REPO_ROOT}/.github/workflows/self-test.yml")

concludes() {
    env -i PATH="${PATH}" \
        VALIDATE="${1}" CONSOLE="${2}" CONTRACT="${3}" SARIF="${4}" EVENT_NAME="${5}" \
        bash -euo pipefail -c "${SCRIPT}" >/dev/null 2>&1
}

rejects() {
    if concludes "$@"; then
        echo "unexpected conclusion success: $*" >&2
        return 1
    fi
}

concludes success success success skipped pull_request
concludes success success success success push
concludes success success success success workflow_dispatch

for result in failure cancelled skipped; do
    rejects "${result}" success success skipped pull_request
    rejects success "${result}" success skipped pull_request
    rejects success success "${result}" skipped pull_request
done

rejects success success success success pull_request
rejects success success success skipped push
rejects success success success skipped unknown

echo "ok: conclusion distinguishes required SARIF from the pull-request skip"
