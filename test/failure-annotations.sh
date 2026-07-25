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
    echo "pinprick 99.0.0"
    exit 0
fi
if [[ "${1:-}" == "audit" ]]; then
    echo "audit ok"
    exit 0
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
    grep -qF "audit ok" "${SANDBOX}/stdout.log" \
        || {
            echo "FAIL success path: installed pinprick was not executed" >&2
            exit 1
        }

    echo "ok: successful install and audit"
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

expect_error "attestation verification failure" \
    "pinprick archive provenance attestation verification failed" \
    SHIM_METADATA="${SANDBOX}/metadata-match.json" \
    GITHUB_TOKEN="shim-token"

expect_success

echo "all failure paths annotate and the success path holds"
