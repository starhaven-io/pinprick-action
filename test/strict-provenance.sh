#!/usr/bin/env bash
#
# Assert strict-provenance fail-open and fail-closed behavior.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
SANDBOX="$(mktemp -d "${TEMP_ROOT%/}/pinprick-action-strict.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT

FULL_SHIMS="${SANDBOX}/bin"
CURL_ONLY_SHIMS="${SANDBOX}/bin-nogh"
mkdir -p "${FULL_SHIMS}" "${CURL_ONLY_SHIMS}" "${SANDBOX}/release"

cat > "${SANDBOX}/release/pinprick" <<'PINPRICK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pinprick 99.0.0"
fi
exit 0
PINPRICK
chmod +x "${SANDBOX}/release/pinprick"
tar -czf "${SANDBOX}/archive.tar.gz" -C "${SANDBOX}/release" pinprick

if command -v sha256sum >/dev/null 2>&1; then
    ARCHIVE_SHA="$(sha256sum "${SANDBOX}/archive.tar.gz" | awk '{ print $1 }')"
else
    ARCHIVE_SHA="$(shasum -a 256 "${SANDBOX}/archive.tar.gz" | awk '{ print $1 }')"
fi

write_metadata() {
    local version="${1}"
    local file="${2}"
    cat > "${file}" <<JSON
{
  "tag_name": "v${version}",
  "assets": [
    {
      "name": "pinprick-${version}-x86_64-unknown-linux-gnu.tar.gz",
      "browser_download_url": "https://example.invalid/pinprick.tar.gz",
      "digest": "sha256:${ARCHIVE_SHA}"
    }
  ]
}
JSON
}
write_metadata 99.0.0 "${SANDBOX}/metadata.json"
write_metadata 0.6.0 "${SANDBOX}/metadata-old.json"

cat > "${FULL_SHIMS}/curl" <<'SHIM'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
    case "${arg}" in
        https://*) url="${arg}" ;;
    esac
done
if [[ "${url}" == https://api.github.com/* ]]; then
    cat "${SHIM_METADATA}"
else
    cat "${SHIM_ARCHIVE}"
fi
SHIM
chmod +x "${FULL_SHIMS}/curl"

# The gh-missing cases need a PATH that provably lacks gh. Omitting the shim
# from a PATH that still carries /usr/bin is not enough: hosted runners ship
# /usr/bin/gh, so action.sh would find the real one and report a different
# provenance gap. Link in only the tools action.sh shells out to.
cp "${FULL_SHIMS}/curl" "${CURL_ONLY_SHIMS}/curl"
for tool in bash env cat cp rm ln tar gzip gunzip sed awk grep mkdir chmod \
    sleep sha256sum shasum python3 node; do
    tool_path="$(command -v "${tool}" 2>/dev/null)" || continue
    ln -sf "${tool_path}" "${CURL_ONLY_SHIMS}/${tool}"
done
if PATH="${CURL_ONLY_SHIMS}" command -v gh >/dev/null 2>&1; then
    echo "FAIL harness setup: gh is reachable from the gh-missing PATH" >&2
    exit 1
fi

cat > "${FULL_SHIMS}/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" && "${3:-}" == "--help" ]]; then
    [[ "${SHIM_GH_MODE:-success}" != "old" ]]
    exit
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
    [[ "${SHIM_GH_MODE:-success}" == "success" ]]
    exit
fi
exit 1
SHIM
chmod +x "${FULL_SHIMS}/gh"

run_action() {
    rm -rf "${SANDBOX}/runner-temp"
    mkdir -p "${SANDBOX}/runner-temp"
    : > "${SANDBOX}/output"

    local exitcode=0
    env -i \
        PATH="${FULL_SHIMS}:/usr/bin:/bin" \
        HOME="${SANDBOX}" \
        RUNNER_TEMP="${SANDBOX}/runner-temp" \
        RUNNER_OS="Linux" \
        RUNNER_ARCH="X64" \
        GITHUB_OUTPUT="${SANDBOX}/output" \
        SHIM_METADATA="${SANDBOX}/metadata.json" \
        SHIM_ARCHIVE="${SANDBOX}/archive.tar.gz" \
        SHIM_GH_MODE="success" \
        PPA_VERSION="99.0.0" \
        PPA_PATH="." \
        PPA_ADVANCED_SECURITY="false" \
        PPA_FAIL_ON_FINDINGS="false" \
        PPA_STRICT_PROVENANCE="false" \
        PPA_NO_REPO_CONFIG="false" \
        "$@" \
        bash "${REPO_ROOT}/action.sh" \
        > "${SANDBOX}/stdout.log" 2> "${SANDBOX}/stderr.log" || exitcode="$?"
    echo "${exitcode}"
}

expect_success() {
    local label="${1}"
    shift
    local exitcode
    exitcode="$(run_action "$@")"
    if [[ "${exitcode}" -ne 0 ]]; then
        echo "FAIL ${label}: expected success, got ${exitcode}" >&2
        cat "${SANDBOX}/stderr.log" >&2
        exit 1
    fi
    echo "ok: ${label}"
}

expect_error() {
    local label="${1}"
    local annotation="${2}"
    shift 2
    local exitcode
    exitcode="$(run_action "$@")"
    if [[ "${exitcode}" -eq 0 ]]; then
        echo "FAIL ${label}: expected failure" >&2
        exit 1
    fi
    if ! grep -qF "::error::${annotation}" \
        "${SANDBOX}/stdout.log" "${SANDBOX}/stderr.log"; then
        echo "FAIL ${label}: expected annotation not found" >&2
        cat "${SANDBOX}/stderr.log" >&2
        exit 1
    fi
    echo "ok: ${label}"
}

expect_success "missing gh fails open by default" \
    PATH="${CURL_ONLY_SHIMS}"

expect_error "missing gh fails closed" \
    "gh is not installed; failing because strict-provenance is enabled" \
    PATH="${CURL_ONLY_SHIMS}" \
    PPA_STRICT_PROVENANCE="true"

expect_error "old gh fails closed" \
    "installed gh does not support attestation verification; failing because strict-provenance is enabled" \
    SHIM_GH_MODE="old" \
    PPA_STRICT_PROVENANCE="true"

expect_error "missing token fails closed" \
    "no GitHub token available; failing because strict-provenance is enabled" \
    PPA_STRICT_PROVENANCE="true"

expect_error "pre-attestation release fails closed" \
    "pinprick 0.6.0 predates release attestations; failing because strict-provenance is enabled" \
    PATH="${CURL_ONLY_SHIMS}" \
    SHIM_METADATA="${SANDBOX}/metadata-old.json" \
    PPA_VERSION="0.6.0" \
    PPA_STRICT_PROVENANCE="true"

expect_success "verified provenance succeeds under strict mode" \
    GITHUB_TOKEN="shim-token" \
    PPA_STRICT_PROVENANCE="true"

expect_error "invalid strict value is rejected" \
    "'strict-provenance' must be 'true' or 'false'" \
    PPA_STRICT_PROVENANCE="sometimes"

echo "strict provenance behavior holds"
