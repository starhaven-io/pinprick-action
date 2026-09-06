#!/usr/bin/env bash

# Assert that releases wait for the exact main-branch Self-test workflow run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
SANDBOX="$(mktemp -d "${TEMP_ROOT%/}/pinprick-action-release.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT

SHIMS="${SANDBOX}/bin"
mkdir -p "${SHIMS}"

cat > "${SHIMS}/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
if [[ "${args}" == *"repos/example/project/actions/workflows/self-test.yml/runs"* ]]; then
    for expected in \
        "head_sha=${SHIM_SHA}" \
        "branch=main" \
        "event=push"; do
        if [[ "${args}" != *"${expected}"* ]]; then
            echo "shim: missing workflow-run constraint ${expected}" >&2
            exit 2
        fi
    done

    count=0
    if [[ -s "${SHIM_STATE}" ]]; then
        read -r count < "${SHIM_STATE}"
    fi
    (( count += 1 ))
    printf '%s\n' "${count}" > "${SHIM_STATE}"

    emit_run() {
        local status="${1}"
        local conclusion="${2}"
        local sha="${3:-${SHIM_SHA}}"
        printf '{"workflow_runs":[{"id":123,"head_sha":"%s","head_branch":"main","event":"push","status":"%s","conclusion":%s,"created_at":"2026-09-06T00:00:00Z","html_url":"https://github.com/example/project/actions/runs/123"}]}\n' \
            "${sha}" "${status}" "${conclusion}"
    }

    case "${SHIM_MODE}" in
        success)
            emit_run completed '"success"'
            ;;
        queued-then-success)
            if (( count == 1 )); then
                emit_run queued null
            else
                emit_run completed '"success"'
            fi
            ;;
        api-then-success)
            if (( count == 1 )); then
                exit 1
            fi
            emit_run completed '"success"'
            ;;
        failure | missing-conclusion | preview-failure)
            emit_run completed '"failure"'
            ;;
        missing)
            printf '{"workflow_runs":[]}\n'
            ;;
        wrong-sha)
            emit_run completed '"success"' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            ;;
        *)
            echo "shim: unknown mode ${SHIM_MODE}" >&2
            exit 2
            ;;
    esac
elif [[ "${args}" == *"repos/example/project/actions/runs/123/jobs"* ]]; then
    for expected in "filter=latest" "per_page=100"; do
        if [[ "${args}" != *"${expected}"* ]]; then
            echo "shim: missing jobs constraint ${expected}" >&2
            exit 2
        fi
    done

    read -r count < "${SHIM_STATE}"
    emit_job() {
        local status="${1}"
        local conclusion="${2}"
        printf '{"jobs":[{"name":"conclusion","status":"%s","conclusion":%s,"html_url":"https://github.com/example/project/actions/runs/123/job/456"}]}\n' \
            "${status}" "${conclusion}"
    }

    case "${SHIM_MODE}" in
        success | api-then-success | preview-failure)
            emit_job completed '"success"'
            ;;
        queued-then-success)
            if (( count == 1 )); then
                emit_job queued null
            else
                emit_job completed '"success"'
            fi
            ;;
        failure)
            emit_job completed '"failure"'
            ;;
        missing-conclusion)
            printf '{"jobs":[]}\n'
            ;;
        *)
            echo "shim: unexpected jobs request for ${SHIM_MODE}" >&2
            exit 2
            ;;
    esac
else
    echo "shim: unexpected API route: ${args}" >&2
    exit 2
fi
SHIM
chmod +x "${SHIMS}/gh"

COMMIT_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

run_wait() {
    local mode="${1}"
    local attempts="${2:-3}"
    : > "${SANDBOX}/state"

    WAIT_EXITCODE=0
    env -i \
        PATH="${SHIMS}:${PATH}" \
        REPOSITORY="example/project" \
        COMMIT_SHA="${COMMIT_SHA}" \
        SELF_TEST_MAX_ATTEMPTS="${attempts}" \
        SELF_TEST_POLL_SECONDS="0" \
        SHIM_MODE="${mode}" \
        SHIM_SHA="${COMMIT_SHA}" \
        SHIM_STATE="${SANDBOX}/state" \
        bash "${REPO_ROOT}/.github/scripts/wait-for-self-test.sh" \
        > "${SANDBOX}/stdout.log" 2> "${SANDBOX}/stderr.log" \
        || WAIT_EXITCODE="$?"
}

expect_success() {
    local label="${1}"
    local mode="${2}"
    local expected_calls="${3}"
    run_wait "${mode}"
    if [[ "${WAIT_EXITCODE}" -ne 0 ]]; then
        echo "FAIL ${label}: wait exited ${WAIT_EXITCODE}" >&2
        cat "${SANDBOX}/stdout.log" "${SANDBOX}/stderr.log" >&2
        exit 1
    fi
    [[ "$(< "${SANDBOX}/state")" == "${expected_calls}" ]] || {
        echo "FAIL ${label}: expected ${expected_calls} API calls" >&2
        exit 1
    }
    echo "ok: ${label}"
}

expect_failure() {
    local label="${1}"
    local mode="${2}"
    local annotation="${3}"
    local attempts="${4:-3}"
    run_wait "${mode}" "${attempts}"
    if [[ "${WAIT_EXITCODE}" -eq 0 ]]; then
        echo "FAIL ${label}: wait unexpectedly succeeded" >&2
        exit 1
    fi
    grep -qF "::error::${annotation}" "${SANDBOX}/stderr.log" || {
        echo "FAIL ${label}: expected annotation not found" >&2
        cat "${SANDBOX}/stdout.log" "${SANDBOX}/stderr.log" >&2
        exit 1
    }
    echo "ok: ${label}"
}

expect_success "completed Self-test succeeds" success 1
expect_success "queued Self-test is polled to success" queued-then-success 2
expect_success "transient API failure is retried" api-then-success 2
expect_success "non-gating preview failure does not block release" preview-failure 1
expect_failure "failed Self-test blocks release" failure \
    "Self-test conclusion completed with 'failure' for ${COMMIT_SHA}"
expect_failure "a missing conclusion job blocks release" missing-conclusion \
    "Self-test completed with 'failure' but no conclusion job for ${COMMIT_SHA}"
expect_failure "missing Self-test times out" missing \
    "Self-test did not succeed for ${COMMIT_SHA} after 2 attempts" 2
expect_failure "a different commit cannot satisfy the gate" wrong-sha \
    "Self-test did not succeed for ${COMMIT_SHA} after 2 attempts" 2

write_version_fixture() {
    local directory="${1}"
    local version="${2}"
    mkdir -p "${directory}"
    cat > "${directory}/action.yml" <<YAML
inputs:
  version:
    description: Install ${version}; the pinned release is ${version}.
    default: "${version}"
YAML
    printf 'Default %s; example %s.\n' "${version}" "${version}" \
        > "${directory}/README.md"
}

OLD_FIXTURE="${SANDBOX}/old"
NEW_FIXTURE="${SANDBOX}/new"
write_version_fixture "${OLD_FIXTURE}" "1.2.3"
write_version_fixture "${NEW_FIXTURE}" "1.2.4"

version="$("${REPO_ROOT}/.github/scripts/validate-engine-bump.py" \
    "${OLD_FIXTURE}/action.yml" "${OLD_FIXTURE}/README.md" \
    "${NEW_FIXTURE}/action.yml" "${NEW_FIXTURE}/README.md")"
[[ "${version}" == "1.2.4" ]] || {
    echo "FAIL engine bump contract: stable version was not accepted" >&2
    exit 1
}
echo "ok: canonical stable engine bump is accepted"

expect_invalid_bump() {
    local label="${1}"
    local new_version="${2}"
    local expected="${3}"
    rm -rf "${NEW_FIXTURE}"
    write_version_fixture "${NEW_FIXTURE}" "${new_version}"
    if "${REPO_ROOT}/.github/scripts/validate-engine-bump.py" \
        "${OLD_FIXTURE}/action.yml" "${OLD_FIXTURE}/README.md" \
        "${NEW_FIXTURE}/action.yml" "${NEW_FIXTURE}/README.md" \
        > "${SANDBOX}/validator.stdout" 2> "${SANDBOX}/validator.stderr"; then
        echo "FAIL engine bump contract: ${label} was accepted" >&2
        exit 1
    fi
    grep -qF "${expected}" "${SANDBOX}/validator.stderr" || {
        echo "FAIL engine bump contract: ${label} gave the wrong diagnostic" >&2
        cat "${SANDBOX}/validator.stderr" >&2
        exit 1
    }
    echo "ok: ${label} is rejected"
}

expect_invalid_bump "prerelease default" "1.2.4-rc.1" \
    "could not find a canonical stable version default"
expect_invalid_bump "build-qualified default" "1.2.4+build.1" \
    "could not find a canonical stable version default"
expect_invalid_bump "leading-zero default" "01.2.4" \
    "could not find a canonical stable version default"
expect_invalid_bump "engine rollback" "1.2.2" \
    "the pinprick default version must increase"

rm -rf "${NEW_FIXTURE}"
write_version_fixture "${NEW_FIXTURE}" "1.2.4"
printf '%s\n' "unrelated change" >> "${NEW_FIXTURE}/README.md"
if "${REPO_ROOT}/.github/scripts/validate-engine-bump.py" \
    "${OLD_FIXTURE}/action.yml" "${OLD_FIXTURE}/README.md" \
    "${NEW_FIXTURE}/action.yml" "${NEW_FIXTURE}/README.md" \
    > "${SANDBOX}/validator.stdout" 2> "${SANDBOX}/validator.stderr"; then
    echo "FAIL engine bump contract: unrelated changes were accepted" >&2
    exit 1
fi
grep -qF "README.md contains changes beyond the version replacement" \
    "${SANDBOX}/validator.stderr" || {
        echo "FAIL engine bump contract: unrelated change diagnostic was missing" >&2
        exit 1
    }
echo "ok: engine bump rejects unrelated changes"

for workflow in release.yml release-manual.yml; do
    grep -qF 'run: .github/scripts/wait-for-self-test.sh' \
        "${REPO_ROOT}/.github/workflows/${workflow}" || {
            echo "FAIL workflow contract: ${workflow} does not invoke the Self-test gate" >&2
            exit 1
        }
    grep -qF "repos/\${REPOSITORY}/releases?per_page=100" \
        "${REPO_ROOT}/.github/workflows/${workflow}" || {
            echo "FAIL workflow contract: ${workflow} derives versions from unvalidated tags" >&2
            exit 1
        }
done

assert_waits_before_publication() {
    local workflow="${1}"
    local publication_step="${2}"
    local wait_line publication_line

    wait_line="$(grep -n -m1 -F 'run: .github/scripts/wait-for-self-test.sh' \
        "${REPO_ROOT}/.github/workflows/${workflow}" | cut -d: -f1)"
    publication_line="$(grep -n -m1 -F "name: ${publication_step}" \
        "${REPO_ROOT}/.github/workflows/${workflow}" | cut -d: -f1)"
    if [[ -z "${wait_line}" || -z "${publication_line}" ]] \
        || (( wait_line >= publication_line )); then
        echo "FAIL workflow contract: ${workflow} does not wait before publication" >&2
        exit 1
    fi
}

assert_waits_before_publication release.yml "Create action release tag"
assert_waits_before_publication release-manual.yml "Create action tag and release"
echo "ok: both release paths gate publication on the exact Self-test conclusion"

python3 - "${REPO_ROOT}/.github/workflows/self-test.yml" <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
contract = """concurrency:
  group: "self-test-${{ github.event_name }}-${{ github.event_name == 'pull_request' && github.event.pull_request.number || github.sha }}"
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
"""
if contract not in workflow:
    raise SystemExit(
        "FAIL workflow contract: Self-test push runs are not isolated by SHA "
        "and protected from cancellation"
    )
PY
echo "ok: Self-test push runs are SHA-scoped and cannot be cancelled"

echo "release gating behavior holds"
