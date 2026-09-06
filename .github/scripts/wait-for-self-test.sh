#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf '::error::%s\n' "${*}" >&2
    exit 1
}

repository="${REPOSITORY:-}"
commit_sha="${COMMIT_SHA:-}"
branch="${SELF_TEST_BRANCH:-main}"
max_attempts="${SELF_TEST_MAX_ATTEMPTS:-120}"
poll_seconds="${SELF_TEST_POLL_SECONDS:-10}"

[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || fail "REPOSITORY must be an owner/repository name"
[[ "${commit_sha}" =~ ^[0-9a-f]{40}$ ]] \
    || fail "COMMIT_SHA must be a full lowercase commit SHA"
[[ "${branch}" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || fail "SELF_TEST_BRANCH is invalid"
[[ "${max_attempts}" =~ ^[1-9][0-9]*$ ]] \
    || fail "SELF_TEST_MAX_ATTEMPTS must be a positive integer"
[[ "${poll_seconds}" =~ ^[0-9]+$ ]] \
    || fail "SELF_TEST_POLL_SECONDS must be a non-negative integer"

attempt=0
while (( attempt < max_attempts )); do
    (( attempt += 1 ))

    response=""
    if response="$(gh api --method GET \
        "repos/${repository}/actions/workflows/self-test.yml/runs" \
        -f "head_sha=${commit_sha}" \
        -f "branch=${branch}" \
        -f "event=push" \
        -f "per_page=100")"
    then
        run=""
        if ! run="$(jq -c \
            --arg branch "${branch}" \
            --arg sha "${commit_sha}" \
            '.workflow_runs
              | map(select(
                  .head_sha == $sha
                  and .head_branch == $branch
                  and .event == "push"
                ))
              | sort_by(.created_at)
              | last // empty' \
            <<< "${response}")"
        then
            fail "Could not parse the Self-test workflow runs response"
        fi

        if [[ -n "${run}" ]]; then
            run_id="$(jq -r '.id // ""' <<< "${run}")"
            run_status="$(jq -r '.status // "unknown"' <<< "${run}")"
            run_conclusion="$(jq -r '.conclusion // ""' <<< "${run}")"
            run_url="$(jq -r '.html_url // "unknown"' <<< "${run}")"
            [[ "${run_id}" =~ ^[1-9][0-9]*$ ]] \
                || fail "Self-test returned an invalid workflow run id"

            jobs_response=""
            if jobs_response="$(gh api --method GET \
                "repos/${repository}/actions/runs/${run_id}/jobs" \
                -f "filter=latest" \
                -f "per_page=100")"
            then
                conclusion_count="$(jq \
                    '[.jobs[] | select(.name == "conclusion")] | length' \
                    <<< "${jobs_response}")" \
                    || fail "Could not parse the Self-test jobs response"
                [[ "${conclusion_count}" == "0" || "${conclusion_count}" == "1" ]] \
                    || fail "Self-test returned multiple conclusion jobs"

                conclusion_job="$(jq -c \
                    '.jobs[] | select(.name == "conclusion")' \
                    <<< "${jobs_response}")" \
                    || fail "Could not parse the Self-test conclusion job"

                if [[ -n "${conclusion_job}" ]]; then
                    status="$(jq -r '.status // "unknown"' <<< "${conclusion_job}")"
                    conclusion="$(jq -r '.conclusion // ""' <<< "${conclusion_job}")"
                    url="$(jq -r '.html_url // "unknown"' <<< "${conclusion_job}")"

                    if [[ "${status}" == "completed" ]]; then
                        if [[ "${conclusion}" == "success" ]]; then
                            echo "Self-test conclusion succeeded for ${commit_sha}: ${url}"
                            exit 0
                        fi
                        fail "Self-test conclusion completed with '${conclusion:-no conclusion}' for ${commit_sha}: ${url}"
                    fi

                    echo "Waiting for the Self-test conclusion on ${commit_sha} (${status}, attempt ${attempt}/${max_attempts})"
                elif [[ "${run_status}" == "completed" ]]; then
                    fail "Self-test completed with '${run_conclusion:-no conclusion}' but no conclusion job for ${commit_sha}: ${run_url}"
                else
                    echo "Waiting for the Self-test conclusion job on ${commit_sha} (attempt ${attempt}/${max_attempts})"
                fi
            else
                echo "Waiting after a Self-test jobs API error for ${commit_sha} (attempt ${attempt}/${max_attempts})" >&2
            fi
        else
            echo "Waiting for the Self-test push run for ${commit_sha} (attempt ${attempt}/${max_attempts})"
        fi
    else
        echo "Waiting after a Self-test API error for ${commit_sha} (attempt ${attempt}/${max_attempts})" >&2
    fi

    if (( attempt < max_attempts )); then
        sleep "${poll_seconds}"
    fi
done

fail "Self-test did not succeed for ${commit_sha} after ${max_attempts} attempts"
