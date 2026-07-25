#!/usr/bin/env bash
#
# Assert that no-repo-config is validated and forwarded to pinprick.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
SANDBOX="$(mktemp -d "${TEMP_ROOT%/}/pinprick-action-no-config.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT

BIN_DIR="${SANDBOX}/bin"
mkdir -p "${BIN_DIR}" "${SANDBOX}/release"

cat > "${SANDBOX}/release/pinprick" <<'PINPRICK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    echo "pinprick 99.0.0"
    exit 0
fi
printf '%s\n' "$*" > "${SHIM_ARGS_LOG}"
exit 0
PINPRICK
chmod +x "${SANDBOX}/release/pinprick"
tar -czf "${SANDBOX}/archive.tar.gz" -C "${SANDBOX}/release" pinprick

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
      "browser_download_url": "https://example.invalid/pinprick.tar.gz",
      "digest": "sha256:${ARCHIVE_SHA}"
    }
  ]
}
JSON

cat > "${BIN_DIR}/curl" <<'SHIM'
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
chmod +x "${BIN_DIR}/curl"

run_action() {
    local no_repo_config="${1}"

    rm -rf "${SANDBOX}/runner-temp"
    mkdir -p "${SANDBOX}/runner-temp"
    : > "${SANDBOX}/output"
    : > "${SANDBOX}/args"

    local exitcode=0
    env -i \
        PATH="${BIN_DIR}:/usr/bin:/bin" \
        HOME="${SANDBOX}" \
        RUNNER_TEMP="${SANDBOX}/runner-temp" \
        RUNNER_OS="Linux" \
        RUNNER_ARCH="X64" \
        GITHUB_OUTPUT="${SANDBOX}/output" \
        SHIM_METADATA="${SANDBOX}/metadata.json" \
        SHIM_ARCHIVE="${SANDBOX}/archive.tar.gz" \
        SHIM_ARGS_LOG="${SANDBOX}/args" \
        PPA_VERSION="99.0.0" \
        PPA_PATH="." \
        PPA_ADVANCED_SECURITY="false" \
        PPA_FAIL_ON_FINDINGS="false" \
        PPA_STRICT_PROVENANCE="false" \
        PPA_NO_REPO_CONFIG="${no_repo_config}" \
        bash "${REPO_ROOT}/action.sh" \
        > "${SANDBOX}/stdout.log" 2> "${SANDBOX}/stderr.log" || exitcode="$?"
    echo "${exitcode}"
}

fail() {
    echo "FAIL $*" >&2
    cat "${SANDBOX}/stdout.log" "${SANDBOX}/stderr.log" >&2
    exit 1
}

exitcode="$(run_action true)"
[[ "${exitcode}" -eq 0 ]] || fail "enabled input exited ${exitcode}"
grep -qxF "audit --no-repo-config -- ." "${SANDBOX}/args" \
    || fail "no-repo-config was not forwarded"
echo "ok: enabled input is forwarded"

exitcode="$(run_action false)"
[[ "${exitcode}" -eq 0 ]] || fail "disabled input exited ${exitcode}"
grep -qxF "audit -- ." "${SANDBOX}/args" \
    || fail "disabled input changed the audit arguments"
echo "ok: disabled input is omitted"

exitcode="$(run_action sometimes)"
[[ "${exitcode}" -ne 0 ]] || fail "invalid input unexpectedly succeeded"
grep -qF "::error::'no-repo-config' must be 'true' or 'false'" \
    "${SANDBOX}/stdout.log" "${SANDBOX}/stderr.log" \
    || fail "invalid input did not emit the expected error"
echo "ok: invalid input is rejected"

echo "no-repo-config behavior holds"
