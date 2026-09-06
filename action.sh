#!/usr/bin/env bash
#
# Install pinprick from its GitHub releases and run `pinprick audit`, mapping
# its exit status onto GitHub Actions results.
#
# Composite-action structure inspired by zizmor-action by William Woodruff
# (MIT): https://github.com/zizmorcore/zizmor-action

set -euo pipefail

# Emit a GitHub Actions workflow command: note <level> <message...>
# Writes to stderr, which the runner also scans for workflow commands, so
# messages stay visible inside command substitutions that capture stdout.
# Percent signs and newlines are escaped per the workflow-command data
# convention so a message cannot truncate itself or inject a second command.
note() {
    local message="${*:2}"
    message="${message//'%'/%25}"
    message="${message//$'\r'/%0D}"
    message="${message//$'\n'/%0A}"
    printf '::%s::%s\n' "${1}" "${message}" >&2
}

# Fence repository-controlled engine output from workflow-command parsing.
# Use an unpredictable token; stderr leaves stdout available for SARIF.
COMMAND_FENCE_TOKEN=""

fence_engine_output() {
    local token
    token="$(od -An -N16 -tx1 /dev/urandom)" || token=""
    token="${token//[[:space:]]/}"
    [[ "${token}" =~ ^[0-9a-f]{32}$ ]] || die "Could not generate a workflow-command fence token"
    COMMAND_FENCE_TOKEN="${token}"
    printf '::stop-commands::%s\n' "${COMMAND_FENCE_TOKEN}" >&2
}

unfence_engine_output() {
    [[ -n "${COMMAND_FENCE_TOKEN}" ]] || return 0
    printf '::%s::\n' "${COMMAND_FENCE_TOKEN}" >&2
    COMMAND_FENCE_TOKEN=""
}

# Restore workflow-command processing after unexpected exits.
trap unfence_engine_output EXIT

# Reopen workflow-command processing before annotating failures.
die() {
    unfence_engine_output
    note error "${@}"
    exit 1
}

# True when COMMAND resolves on PATH.
have() {
    command -v "${1}" >/dev/null 2>&1
}

# Append key=value to the step's outputs.
set_output() {
    printf '%s=%s\n' "${1}" "${2}" >> "${GITHUB_OUTPUT}"
}

validate_bool() {
    local name="${1}"
    local value="${2}"

    case "${value}" in
        true | false) ;;
        *) die "'${name}' must be 'true' or 'false'" ;;
    esac
}

github_curl() {
    local url="${1}"
    local args=(
        --proto '=https'
        --proto-redir '=https'
        --connect-timeout 10
        --max-time 300
        --retry 3
        --retry-delay 1
        -fsSL
    )

    # The REST headers and token belong to api.github.com only; the asset
    # download redirects to a CDN that must never see the Authorization
    # header and has no use for the API version.
    if [[ "${url}" == https://api.github.com/* ]]; then
        args+=(
            -H "Accept: application/vnd.github+json"
            -H "X-GitHub-Api-Version: 2022-11-28"
        )
        if [[ -n "${GITHUB_TOKEN:-}" ]]; then
            args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        fi
    fi

    curl "${args[@]}" "${url}"
}

target_triple() {
    case "${RUNNER_OS}:${RUNNER_ARCH}" in
        Linux:X64) echo "x86_64-unknown-linux-gnu" ;;
        Linux:ARM64) echo "aarch64-unknown-linux-gnu" ;;
        macOS:ARM64) echo "aarch64-apple-darwin" ;;
        macOS:X64) die "pinprick does not support x86_64 macOS" ;;
        Windows:*) die "pinprick does not support Windows" ;;
        *) die "Unsupported runner platform: ${RUNNER_OS}/${RUNNER_ARCH}" ;;
    esac
}

parse_release_metadata() {
    local metadata="${1}"
    local target="${2}"

    if have python3; then
        python3 - "${metadata}" "${target}" <<'PY'
import json
import re
import sys

metadata_path, target = sys.argv[1], sys.argv[2]
try:
    with open(metadata_path, encoding="utf-8") as handle:
        release = json.load(handle)
except (OSError, json.JSONDecodeError):
    print("release metadata was not valid JSON", file=sys.stderr)
    sys.exit(1)
if not isinstance(release, dict):
    print("release metadata must be an object", file=sys.stderr)
    sys.exit(1)

tag = release.get("tag_name", "")
match = re.fullmatch(
    r"v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))",
    tag if isinstance(tag, str) else "",
)
if not match:
    print("release metadata tag_name must be a canonical vX.Y.Z version", file=sys.stderr)
    sys.exit(1)
version = match.group(1)

asset_name = f"pinprick-{version}-{target}.tar.gz"
expected_url = f"https://github.com/starhaven-io/pinprick/releases/download/v{version}/{asset_name}"
assets = release.get("assets", [])
if not isinstance(assets, list):
    print("release metadata assets must be an array", file=sys.stderr)
    sys.exit(1)
for asset in assets:
    if not isinstance(asset, dict):
        continue
    if asset.get("name") != asset_name:
        continue
    digest = asset.get("digest", "")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        print(f"{asset_name} did not include a sha256 digest", file=sys.stderr)
        sys.exit(1)
    if asset.get("browser_download_url") != expected_url:
        print(f"{asset_name} did not use the canonical GitHub release URL", file=sys.stderr)
        sys.exit(1)
    print(version)
    print(expected_url)
    # Slicing rather than str.removeprefix keeps old self-hosted
    # python3 (< 3.9) working.
    print(digest[len("sha256:"):])
    sys.exit(0)

print(f"release does not contain {asset_name}", file=sys.stderr)
sys.exit(1)
PY
        return
    fi

    if have node; then
        node - "${metadata}" "${target}" <<'JS'
const fs = require("fs");

const [metadataPath, target] = process.argv.slice(2);
let release;
try {
  release = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
} catch {
  console.error("release metadata was not valid JSON");
  process.exit(1);
}
if (!release || Array.isArray(release) || typeof release !== "object") {
  console.error("release metadata must be an object");
  process.exit(1);
}
const tag = release.tag_name || "";
const match = /^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$/.exec(tag);
if (!match) {
  console.error("release metadata tag_name must be a canonical vX.Y.Z version");
  process.exit(1);
}
const version = match[1];

const assetName = `pinprick-${version}-${target}.tar.gz`;
const expectedUrl = `https://github.com/starhaven-io/pinprick/releases/download/v${version}/${assetName}`;
const assets = release.assets === undefined ? [] : release.assets;
if (!Array.isArray(assets)) {
  console.error("release metadata assets must be an array");
  process.exit(1);
}
const asset = assets.find(
  (entry) => entry && typeof entry === "object" && entry.name === assetName,
);
if (!asset) {
  console.error(`release does not contain ${assetName}`);
  process.exit(1);
}
if (typeof asset.digest !== "string" || !/^sha256:[0-9a-f]{64}$/.test(asset.digest)) {
  console.error(`${assetName} did not include a sha256 digest`);
  process.exit(1);
}
if (asset.browser_download_url !== expectedUrl) {
  console.error(`${assetName} did not use the canonical GitHub release URL`);
  process.exit(1);
}

console.log(version);
console.log(expectedUrl);
console.log(asset.digest.replace(/^sha256:/, ""));
JS
        return
    fi

    die "Installing pinprick requires python3 or node to parse GitHub release metadata"
}

sha256_file() {
    local file="${1}"

    if have sha256sum; then
        sha256sum "${file}" | awk '{ print $1 }'
        return
    fi

    if have shasum; then
        shasum -a 256 "${file}" | awk '{ print $1 }'
        return
    fi

    die "Cannot verify pinprick archive without sha256sum or shasum"
}

version_requires_attestation() {
    local version="${1}"

    # pinprick release assets have published provenance attestations since v0.7.0.
    if [[ "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"

        (( major > 0 || minor >= 7 ))
        return
    fi

    return 0
}

# Report an unverifiable provenance attestation: fatal under
# strict-provenance, otherwise a fail-open warning.
provenance_gap() {
    if [[ "${PPA_STRICT_PROVENANCE}" == "true" ]]; then
        die "${*}; failing because strict-provenance is enabled"
    fi
    note warning "${*}; skipping pinprick archive provenance verification"
}

verify_attestation() {
    local archive="${1}"
    local requested_version="${2}"
    local resolved_version="${3}"

    if ! version_requires_attestation "${resolved_version}"; then
        if [[ "${requested_version}" == "latest" ]]; then
            die "Latest pinprick release ${resolved_version} predates release attestations"
        fi
        provenance_gap "pinprick ${resolved_version} predates release attestations"
        return
    fi

    if ! have gh; then
        provenance_gap "gh is not installed"
        return
    fi

    local attestation_help
    if ! attestation_help="$(gh attestation verify --help 2>/dev/null)"; then
        provenance_gap "installed gh does not support attestation verification"
        return
    fi
    if [[ "${attestation_help}" != *"--signer-workflow"* ]]; then
        provenance_gap "installed gh does not support signer-workflow attestation verification"
        return
    fi
    if [[ "${attestation_help}" != *"--source-ref"* ]]; then
        provenance_gap "installed gh does not support source-ref attestation verification"
        return
    fi
    if [[ "${attestation_help}" != *"--deny-self-hosted-runners"* ]]; then
        provenance_gap "installed gh cannot reject self-hosted attestation signers"
        return
    fi

    if [[ -z "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
        provenance_gap "no GitHub token available"
        return
    fi

    note debug "verifying pinprick archive provenance attestation"
    # Retry to ride out transient attestation-API errors; a real verification
    # failure (missing or mismatched attestation) fails every attempt and dies.
    local attempt
    for attempt in 1 2 3; do
        if gh attestation verify "${archive}" \
            --repo starhaven-io/pinprick \
            --signer-workflow starhaven-io/pinprick/.github/workflows/release.yml \
            --source-ref refs/heads/main \
            --deny-self-hosted-runners
        then
            note debug "pinprick archive provenance attestation verified"
            return
        fi
        if (( attempt < 3 )); then
            note debug "attestation verification attempt ${attempt} failed; retrying"
            sleep "${attempt}"
        fi
    done
    die "pinprick archive provenance attestation verification failed"
}

# Install the requested pinprick release and set PINPRICK_BIN to the verified
# binary path. A stdout return would put every note/die in this call tree
# inside a captured stream, so the result travels through a global instead.
install_pinprick() {
    local version="${1}"
    local target="${2}"
    local version_regex='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    local api_url

    if [[ "${version}" == "latest" ]]; then
        api_url="https://api.github.com/repos/starhaven-io/pinprick/releases/latest"
    elif [[ "${version}" =~ ${version_regex} ]]; then
        api_url="https://api.github.com/repos/starhaven-io/pinprick/releases/tags/v${version#v}"
    else
        die "'version' must be 'latest' or an exact X.Y.Z version"
    fi

    local workdir="${RUNNER_TEMP}/pinprick-action"
    local metadata="${workdir}/release.json"
    local archive="${workdir}/pinprick.tar.gz"
    mkdir -p "${workdir}"

    if ! github_curl "${api_url}" > "${metadata}"; then
        die "Could not fetch pinprick release metadata for '${version}'"
    fi

    local release_info
    if ! release_info="$(parse_release_metadata "${metadata}" "${target}")"; then
        die "Could not resolve a pinprick ${version} release asset for ${target}"
    fi

    local resolved_version download_url expected_sha actual_sha install_dir
    resolved_version="$(sed -n '1p' <<< "${release_info}")"
    download_url="$(sed -n '2p' <<< "${release_info}")"
    expected_sha="$(sed -n '3p' <<< "${release_info}")"
    if [[ ! "${resolved_version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        die "Resolved pinprick version '${resolved_version}' is not a canonical X.Y.Z version"
    fi
    if [[ "${version}" != "latest" && "${resolved_version}" != "${version#v}" ]]; then
        die "Resolved pinprick version ${resolved_version} does not match requested version ${version#v}"
    fi
    install_dir="${workdir}/${resolved_version}"

    mkdir -p "${install_dir}"
    if ! github_curl "${download_url}" > "${archive}"; then
        die "Could not download the pinprick release archive"
    fi

    actual_sha="$(sha256_file "${archive}")"
    if [[ "${actual_sha}" != "${expected_sha}" ]]; then
        die "Downloaded pinprick archive checksum mismatch"
    fi

    verify_attestation "${archive}" "${version}" "${resolved_version}"

    # Engine release archives use ./pinprick, while older or third-party tar
    # producers may store the same root member as pinprick. Accept only those
    # two exact spellings so unrelated archive contents are never extracted.
    if ! tar -xzf "${archive}" -C "${install_dir}" ./pinprick 2>/dev/null \
        && ! tar -xzf "${archive}" -C "${install_dir}" pinprick
    then
        die "Could not extract pinprick from the release archive"
    fi
    if ! chmod +x "${install_dir}/pinprick"; then
        die "Could not make the installed pinprick executable"
    fi
    local reported_version
    if ! reported_version="$("${install_dir}/pinprick" --version)"; then
        die "Installed pinprick ${resolved_version} could not run on this ${target} runner; see the action's supported runners"
    fi
    if [[ "${reported_version}" != "pinprick ${resolved_version}" ]]; then
        die "Installed pinprick reported '${reported_version}', expected 'pinprick ${resolved_version}'"
    fi
    note debug "installed pinprick ${resolved_version}"
    PINPRICK_BIN="${install_dir}/pinprick"
}

main() {
    validate_bool "advanced-security" "${PPA_ADVANCED_SECURITY}"
    validate_bool "fail-on-findings" "${PPA_FAIL_ON_FINDINGS}"
    validate_bool "strict-provenance" "${PPA_STRICT_PROVENANCE}"
    validate_bool "no-repo-config" "${PPA_NO_REPO_CONFIG}"

    have curl || die "Cannot install pinprick without curl"
    have tar || die "Cannot install pinprick without tar"

    local target sarif_file exitcode
    target="$(target_triple)"
    note debug "resolved runner target ${target}"

    install_pinprick "${PPA_VERSION}" "${target}"
    sarif_file="${RUNNER_TEMP}/pinprick.sarif"

    local audit_args=(audit)
    if [[ "${PPA_NO_REPO_CONFIG}" == "true" ]]; then
        audit_args+=(--no-repo-config)
    fi

    if [[ "${PPA_ADVANCED_SECURITY}" == "true" ]]; then
        fence_engine_output
        set +e
        "${PINPRICK_BIN}" "${audit_args[@]}" --sarif -- "${PPA_PATH}" > "${sarif_file}"
        exitcode="${?}"
        set -e
        unfence_engine_output
        # Publish the SARIF path only for clean/findings runs; on an engine
        # error the file holds whatever partial output preceded the failure,
        # and a caller using continue-on-error must not upload it.
        if (( exitcode <= 1 )); then
            set_output "sarif-file" "${sarif_file}"
        fi
    else
        fence_engine_output
        set +e
        # Keep the fence and repository-controlled output on one ordered stream.
        "${PINPRICK_BIN}" "${audit_args[@]}" -- "${PPA_PATH}" >&2
        exitcode="${?}"
        set -e
        unfence_engine_output
    fi

    set_output "exit-code" "${exitcode}"
    note debug "pinprick exited with code ${exitcode}"

    case "${exitcode}" in
        0)
            exit 0
            ;;
        1)
            note warning "pinprick audit reported findings"
            exit 0
            ;;
        *)
            die "pinprick audit errored with exit code ${exitcode}"
            ;;
    esac
}

main "$@"
