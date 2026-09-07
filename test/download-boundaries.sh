#!/usr/bin/env bash

# Assert curl transport controls and API-token scoping for release downloads.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
SANDBOX="$(mktemp -d "${TEMP_ROOT%/}/pinprick-action-download.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT

SHIMS="${SANDBOX}/bin"
mkdir -p "${SHIMS}" "${SANDBOX}/release" "${SANDBOX}/runner-temp"
# Prefer GNU tar when available so macOS development runs exercise Linux's
# exact archive-member matching.
if command -v gtar >/dev/null 2>&1; then
    ln -s "$(command -v gtar)" "${SHIMS}/tar"
fi

cat > "${SANDBOX}/release/pinprick" <<'PINPRICK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pinprick 99.0.0"
    exit 0
fi
if [[ "${1:-}" == "audit" ]]; then
    printf '%s\n' "${PPA_PATH}"
    exit 0
fi
exit 2
PINPRICK
chmod +x "${SANDBOX}/release/pinprick"
printf '%s\n' "pinprick license fixture" > "${SANDBOX}/release/LICENSE"
# Match the engine's release packaging command. GNU tar stores these members
# as ./pinprick and ./LICENSE rather than normalizing away the leading ./.
tar -czf "${SANDBOX}/archive.tar.gz" -C "${SANDBOX}/release" .
tar -tzf "${SANDBOX}/archive.tar.gz" | grep -qxF './pinprick' || {
    echo "FAIL download boundaries: fixture does not use the engine archive layout" >&2
    exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
    ARCHIVE_SHA="$(sha256sum "${SANDBOX}/archive.tar.gz" | awk '{ print $1 }')"
else
    ARCHIVE_SHA="$(shasum -a 256 "${SANDBOX}/archive.tar.gz" | awk '{ print $1 }')"
fi

cat > "${SANDBOX}/metadata.json" <<JSON
{
  "tag_name": "v99.0.0",
  "assets": [
    {
      "name": "pinprick-99.0.0-x86_64-unknown-linux-gnu.tar.gz",
      "browser_download_url": "https://github.com/starhaven-io/pinprick/releases/download/v99.0.0/pinprick-99.0.0-x86_64-unknown-linux-gnu.tar.gz",
      "digest": "sha256:${ARCHIVE_SHA}"
    }
  ]
}
JSON

cat > "${SHIMS}/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
    case "${arg}" in
        https://*) url="${arg}" ;;
    esac
done
if [[ "${url}" == https://api.github.com/* ]]; then
    printf '%s\n' "$@" > "${SHIM_API_LOG}"
    cat "${SHIM_METADATA}"
else
    printf '%s\n' "$@" > "${SHIM_ASSET_LOG}"
    cat "${SHIM_ARCHIVE}"
fi
SHIM
chmod +x "${SHIMS}/curl"

cat > "${SHIMS}/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" && "${3:-}" == "--help" ]]; then
    echo "      --signer-workflow string"
    echo "      --source-ref string"
    echo "      --deny-self-hosted-runners"
    exit 0
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
    exit 0
fi
exit 1
SHIM
chmod +x "${SHIMS}/gh"

run_action() {
    : > "${SANDBOX}/output"
    exitcode=0
    env -i \
        PATH="${SHIMS}:/usr/bin:/bin" \
        RUNNER_TEMP="${SANDBOX}/runner-temp" \
        RUNNER_OS="Linux" \
        RUNNER_ARCH="X64" \
        GITHUB_OUTPUT="${SANDBOX}/output" \
        GITHUB_TOKEN="test-token" \
        SHIM_METADATA="${SANDBOX}/metadata.json" \
        SHIM_ARCHIVE="${SANDBOX}/archive.tar.gz" \
        SHIM_API_LOG="${SANDBOX}/api.log" \
        SHIM_ASSET_LOG="${SANDBOX}/asset.log" \
        PPA_VERSION="99.0.0" \
        PPA_PATH="${1}" \
        PPA_ADVANCED_SECURITY="true" \
        PPA_FAIL_ON_FINDINGS="false" \
        PPA_STRICT_PROVENANCE="true" \
        PPA_NO_REPO_CONFIG="true" \
        bash "${REPO_ROOT}/action.sh" \
        > "${SANDBOX}/stdout.log" 2> "${SANDBOX}/stderr.log" \
        || exitcode="$?"
}

run_action first-audit

if [[ "${exitcode}" -ne 0 ]]; then
    echo "FAIL download boundaries: action exited ${exitcode}" >&2
    cat "${SANDBOX}/stdout.log" "${SANDBOX}/stderr.log" >&2
    exit 1
fi

install_dirs=("${SANDBOX}/runner-temp"/pinprick-action.*/99.0.0)
install_dir="${install_dirs[0]}"
if [[ ! -x "${install_dir}/pinprick" ]]; then
    echo "FAIL download boundaries: ./pinprick was not extracted" >&2
    exit 1
fi
if [[ -e "${install_dir}/LICENSE" ]]; then
    echo "FAIL download boundaries: unrelated archive content was extracted" >&2
    exit 1
fi
echo "ok: engine-layout archive extracts only ./pinprick"

for log in "${SANDBOX}/api.log" "${SANDBOX}/asset.log"; do
    grep -qxF -- "--proto" "${log}" || {
        echo "FAIL download boundaries: --proto is missing from ${log}" >&2
        exit 1
    }
    grep -qxF -- "--proto-redir" "${log}" || {
        echo "FAIL download boundaries: --proto-redir is missing from ${log}" >&2
        exit 1
    }
    if [[ "$(grep -cxF -- "=https" "${log}")" -ne 2 ]]; then
        echo "FAIL download boundaries: HTTPS-only transport is not enforced in ${log}" >&2
        exit 1
    fi
done
echo "ok: API and asset downloads require HTTPS, including redirects"

grep -qxF "Authorization: Bearer test-token" "${SANDBOX}/api.log" || {
    echo "FAIL download boundaries: API request did not receive the token" >&2
    exit 1
}
if grep -qF "Authorization:" "${SANDBOX}/asset.log"; then
    echo "FAIL download boundaries: asset request received an Authorization header" >&2
    exit 1
fi
if grep -qF "X-GitHub-Api-Version:" "${SANDBOX}/asset.log"; then
    echo "FAIL download boundaries: asset request received a GitHub API header" >&2
    exit 1
fi
echo "ok: the GitHub token and REST headers are scoped to api.github.com"

grep -qxF "https://api.github.com/repos/starhaven-io/pinprick/releases/tags/v99.0.0" \
    "${SANDBOX}/api.log" || {
        echo "FAIL download boundaries: exact release endpoint was not requested" >&2
        exit 1
    }
grep -qxF "https://github.com/starhaven-io/pinprick/releases/download/v99.0.0/pinprick-99.0.0-x86_64-unknown-linux-gnu.tar.gz" \
    "${SANDBOX}/asset.log" || {
        echo "FAIL download boundaries: canonical asset URL was not requested" >&2
        exit 1
    }
echo "ok: release metadata and archive requests use canonical endpoints"

first_sarif="$(sed -n 's/^sarif-file=//p' "${SANDBOX}/output")"
run_action second-audit
second_sarif="$(sed -n 's/^sarif-file=//p' "${SANDBOX}/output")"
if [[ "${exitcode}" -ne 0 || -z "${first_sarif}" || -z "${second_sarif}" \
    || "${first_sarif}" == "${second_sarif}" ]]; then
    echo "FAIL invocation isolation: separate audits did not produce separate outputs" >&2
    exit 1
fi
grep -qxF first-audit "${first_sarif}"
grep -qxF second-audit "${second_sarif}"
echo "ok: later invocations preserve earlier SARIF outputs"

echo "download boundary behavior holds"
