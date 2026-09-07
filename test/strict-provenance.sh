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
NODE_SHIMS="${SANDBOX}/bin-node"
mkdir -p "${FULL_SHIMS}" "${CURL_ONLY_SHIMS}" "${NODE_SHIMS}" "${SANDBOX}/release"

cat > "${SANDBOX}/release/pinprick" <<'PINPRICK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pinprick ${SHIM_BINARY_VERSION:-99.0.0}"
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
      "browser_download_url": "https://github.com/starhaven-io/pinprick/releases/download/v${version}/pinprick-${version}-x86_64-unknown-linux-gnu.tar.gz",
      "digest": "sha256:${ARCHIVE_SHA}"
    }
  ]
}
JSON
}
write_metadata 99.0.0 "${SANDBOX}/metadata.json"
write_metadata 0.6.0 "${SANDBOX}/metadata-old.json"
printf '{"tag_name":"v99.0.0-rc.1","assets":[]}\n' \
    > "${SANDBOX}/metadata-node-prerelease.json"
printf '{not-json\n' > "${SANDBOX}/metadata-node-invalid-json.json"
printf '{"tag_name":"v99.0.0","assets":{}}\n' \
    > "${SANDBOX}/metadata-node-invalid-assets.json"
printf '{"tag_name":"v99.0.0","assets":[{"name":"pinprick-99.0.0-x86_64-unknown-linux-gnu.tar.gz","browser_download_url":"https://github.com/starhaven-io/pinprick/releases/download/v99.0.0/pinprick-99.0.0-x86_64-unknown-linux-gnu.tar.gz"}]}\n' \
    > "${SANDBOX}/metadata-node-no-digest.json"
printf '{"tag_name":"v99.0.0","assets":[{"name":"pinprick-99.0.0-x86_64-unknown-linux-gnu.tar.gz","browser_download_url":"https://example.invalid/pinprick.tar.gz","digest":"sha256:%s"}]}\n' \
    "${ARCHIVE_SHA}" > "${SANDBOX}/metadata-node-wrong-url.json"

cat > "${FULL_SHIMS}/curl" <<'SHIM'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
    case "${arg}" in
        https://*) url="${arg}" ;;
    esac
done
if [[ -n "${SHIM_CURL_URL_LOG:-}" ]]; then
    printf '%s\n' "${url}" >> "${SHIM_CURL_URL_LOG}"
fi
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
for tool in bash env cat cp rm ln tar gzip gunzip sed awk grep od mkdir mktemp chmod \
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
    if [[ "${SHIM_GH_MODE:-success}" == "old" ]]; then
        exit 1
    fi
    if [[ "${SHIM_GH_MODE:-success}" != "no-signer" ]]; then
        echo "      --signer-workflow string"
    fi
    if [[ "${SHIM_GH_MODE:-success}" != "no-source-ref" ]]; then
        echo "      --source-ref string"
    fi
    if [[ "${SHIM_GH_MODE:-success}" != "no-runner-policy" ]]; then
        echo "      --deny-self-hosted-runners"
    fi
    exit 0
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
    if [[ -n "${SHIM_GH_ARGS_LOG:-}" ]]; then
        printf '%s\n' "$*" >> "${SHIM_GH_ARGS_LOG}"
    fi
    [[ "${SHIM_GH_MODE:-success}" != "verify-fail" ]]
    exit
fi
exit 1
SHIM
chmod +x "${FULL_SHIMS}/gh"

cp "${FULL_SHIMS}/curl" "${NODE_SHIMS}/curl"
cp "${FULL_SHIMS}/gh" "${NODE_SHIMS}/gh"
for tool in bash env cat cp rm ln tar gzip gunzip sed awk grep od mkdir mktemp chmod \
    sleep sha256sum shasum node; do
    tool_path="$(command -v "${tool}" 2>/dev/null)" || continue
    ln -sf "${tool_path}" "${NODE_SHIMS}/${tool}"
done
if PATH="${NODE_SHIMS}" command -v python3 >/dev/null 2>&1; then
    echo "FAIL harness setup: python3 is reachable from the node-only PATH" >&2
    exit 1
fi

run_action() {
    rm -rf "${SANDBOX}/runner-temp"
    mkdir -p "${SANDBOX}/runner-temp"
    : > "${SANDBOX}/output"
    : > "${SANDBOX}/gh-args"
    : > "${SANDBOX}/curl-urls"

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
        SHIM_GH_ARGS_LOG="${SANDBOX}/gh-args" \
        SHIM_CURL_URL_LOG="${SANDBOX}/curl-urls" \
        SHIM_BINARY_VERSION="99.0.0" \
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

expect_error "gh without signer-workflow support fails closed" \
    "installed gh does not support signer-workflow attestation verification; failing because strict-provenance is enabled" \
    SHIM_GH_MODE="no-signer" \
    PPA_STRICT_PROVENANCE="true"

expect_error "gh without source-ref support fails closed" \
    "installed gh does not support source-ref attestation verification; failing because strict-provenance is enabled" \
    SHIM_GH_MODE="no-source-ref" \
    PPA_STRICT_PROVENANCE="true"

expect_error "gh without runner policy support fails closed" \
    "installed gh cannot reject self-hosted attestation signers; failing because strict-provenance is enabled" \
    SHIM_GH_MODE="no-runner-policy" \
    PPA_STRICT_PROVENANCE="true"

expect_error "missing token fails closed" \
    "no GitHub token available; failing because strict-provenance is enabled" \
    PPA_STRICT_PROVENANCE="true"

expect_success "explicit pre-attestation release retains non-strict compatibility" \
    PATH="${CURL_ONLY_SHIMS}" \
    SHIM_METADATA="${SANDBOX}/metadata-old.json" \
    SHIM_BINARY_VERSION="0.6.0" \
    PPA_VERSION="0.6.0"

expect_error "explicit pre-attestation release fails closed" \
    "pinprick 0.6.0 predates release attestations; failing because strict-provenance is enabled" \
    PATH="${CURL_ONLY_SHIMS}" \
    SHIM_METADATA="${SANDBOX}/metadata-old.json" \
    PPA_VERSION="0.6.0" \
    PPA_STRICT_PROVENANCE="true"

expect_error "latest cannot select a pre-attestation release" \
    "Latest pinprick release 0.6.0 predates release attestations" \
    PATH="${CURL_ONLY_SHIMS}" \
    SHIM_METADATA="${SANDBOX}/metadata-old.json" \
    PPA_VERSION="latest"

grep -qxF "https://api.github.com/repos/starhaven-io/pinprick/releases/latest" \
    "${SANDBOX}/curl-urls" || {
        echo "FAIL latest endpoint: floating resolution did not use releases/latest" >&2
        cat "${SANDBOX}/curl-urls" >&2
        exit 1
    }
echo "ok: latest resolution uses the dedicated floating-release endpoint"

expect_success "verified provenance succeeds under strict mode" \
    GITHUB_TOKEN="shim-token" \
    PPA_STRICT_PROVENANCE="true"

grep -qF -- "--repo starhaven-io/pinprick --signer-workflow starhaven-io/pinprick/.github/workflows/release.yml" \
    "${SANDBOX}/gh-args" || {
        echo "FAIL signer-workflow: attestation verification was not bound to the release workflow" >&2
        cat "${SANDBOX}/gh-args" >&2
        exit 1
    }
echo "ok: attestation verification is bound to the release workflow"
grep -qF -- "--source-ref refs/heads/main --deny-self-hosted-runners" \
    "${SANDBOX}/gh-args" || {
        echo "FAIL attestation policy: source ref or runner policy was not enforced" >&2
        cat "${SANDBOX}/gh-args" >&2
        exit 1
    }
echo "ok: attestation verification requires main and GitHub-hosted signing"

expect_success "node metadata parser fallback succeeds" \
    PATH="${NODE_SHIMS}" \
    GITHUB_TOKEN="shim-token" \
    PPA_STRICT_PROVENANCE="true"

for metadata_case in invalid-json invalid-assets prerelease no-digest wrong-url; do
    expect_error "node metadata parser rejects ${metadata_case}" \
        "Could not resolve a pinprick 99.0.0 release asset for x86_64-unknown-linux-gnu" \
        PATH="${NODE_SHIMS}" \
        SHIM_METADATA="${SANDBOX}/metadata-node-${metadata_case}.json" \
        GITHUB_TOKEN="shim-token" \
        PPA_STRICT_PROVENANCE="true"
done

expect_error "invalid strict value is rejected" \
    "'strict-provenance' must be 'true' or 'false'" \
    PPA_STRICT_PROVENANCE="sometimes"

echo "strict provenance behavior holds"
