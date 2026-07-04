#!/usr/bin/env bash
#
# Install pinprick from its GitHub releases and run `pinprick audit`, mapping
# its exit status onto GitHub Actions results.
#
# Composite-action structure inspired by zizmor-action by William Woodruff
# (MIT): https://github.com/zizmorcore/zizmor-action

set -euo pipefail

# Emit a GitHub Actions workflow command: note <level> <message...>
note() {
    printf '::%s::%s\n' "${1}" "${*:2}"
}

# Report an error and abort the step.
die() {
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
    local headers=(
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    if [[ -n "${GITHUB_TOKEN:-}" && "${url}" == https://api.github.com/* ]]; then
        headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    curl --proto '=https' --retry 3 --retry-delay 1 -fsSL "${headers[@]}" "${url}"
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
import sys

metadata_path, target = sys.argv[1], sys.argv[2]
with open(metadata_path, encoding="utf-8") as handle:
    release = json.load(handle)

tag = release.get("tag_name", "")
version = tag[1:] if tag.startswith("v") else tag
if not version:
    print("release metadata did not include tag_name", file=sys.stderr)
    sys.exit(1)

asset_name = f"pinprick-{version}-{target}.tar.gz"
assets = release.get("assets", [])
for asset in assets:
    if asset.get("name") != asset_name:
        continue
    digest = asset.get("digest", "")
    if not digest.startswith("sha256:"):
        print(f"{asset_name} did not include a sha256 digest", file=sys.stderr)
        sys.exit(1)
    print(version)
    print(asset["browser_download_url"])
    print(digest.removeprefix("sha256:"))
    sys.exit(0)

available = ", ".join(asset.get("name", "<unnamed>") for asset in assets)
print(f"release does not contain {asset_name}; available assets: {available}", file=sys.stderr)
sys.exit(1)
PY
        return
    fi

    if have node; then
        node - "${metadata}" "${target}" <<'JS'
const fs = require("fs");

const [metadataPath, target] = process.argv.slice(2);
const release = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
const tag = release.tag_name || "";
const version = tag.startsWith("v") ? tag.slice(1) : tag;
if (!version) {
  console.error("release metadata did not include tag_name");
  process.exit(1);
}

const assetName = `pinprick-${version}-${target}.tar.gz`;
const assets = release.assets || [];
const asset = assets.find((entry) => entry.name === assetName);
if (!asset) {
  const available = assets.map((entry) => entry.name || "<unnamed>").join(", ");
  console.error(`release does not contain ${assetName}; available assets: ${available}`);
  process.exit(1);
}
if (!asset.digest || !asset.digest.startsWith("sha256:")) {
  console.error(`${assetName} did not include a sha256 digest`);
  process.exit(1);
}

console.log(version);
console.log(asset.browser_download_url);
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

verify_attestation() {
    local archive="${1}"
    local version="${2}"

    if ! version_requires_attestation "${version}"; then
        note warning "pinprick ${version} predates release attestations; skipping provenance verification"
        return
    fi

    if ! have gh; then
        note warning "gh is not installed; skipping pinprick archive provenance verification"
        return
    fi

    if ! gh attestation verify --help >/dev/null 2>&1; then
        note warning "installed gh does not support attestation verification; skipping pinprick archive provenance verification"
        return
    fi

    if [[ -z "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
        note warning "no GitHub token available; skipping pinprick archive provenance verification"
        return
    fi

    note debug "verifying pinprick archive provenance attestation"
    # Retry to ride out transient attestation-API errors; a real verification
    # failure (missing or mismatched attestation) fails every attempt and dies.
    local attempt
    for attempt in 1 2 3; do
        if gh attestation verify "${archive}" --repo starhaven-io/pinprick; then
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

install_pinprick() {
    local version="${1}"
    local target="${2}"
    local version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+$'
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

    github_curl "${api_url}" > "${metadata}"

    local release_info
    release_info="$(parse_release_metadata "${metadata}" "${target}")"

    local resolved_version download_url expected_sha actual_sha install_dir
    resolved_version="$(sed -n '1p' <<< "${release_info}")"
    download_url="$(sed -n '2p' <<< "${release_info}")"
    expected_sha="$(sed -n '3p' <<< "${release_info}")"
    install_dir="${workdir}/${resolved_version}"

    mkdir -p "${install_dir}"
    github_curl "${download_url}" > "${archive}"

    actual_sha="$(sha256_file "${archive}")"
    if [[ "${actual_sha}" != "${expected_sha}" ]]; then
        die "Downloaded pinprick archive checksum mismatch"
    fi

    # Keep stdout clean: install_pinprick's stdout is captured as the binary
    # path, so route verification progress to stderr.
    verify_attestation "${archive}" "${resolved_version}" >&2

    tar -xzf "${archive}" -C "${install_dir}"
    chmod +x "${install_dir}/pinprick"
    "${install_dir}/pinprick" --version >&2
    echo "${install_dir}/pinprick"
}

main() {
    validate_bool "advanced-security" "${PPA_ADVANCED_SECURITY}"
    validate_bool "fail-on-findings" "${PPA_FAIL_ON_FINDINGS}"

    have curl || die "Cannot install pinprick without curl"
    have tar || die "Cannot install pinprick without tar"

    local target pinprick sarif_file exitcode
    target="$(target_triple)"
    note debug "resolved runner target ${target}"

    pinprick="$(install_pinprick "${PPA_VERSION}" "${target}")"
    sarif_file="${RUNNER_TEMP}/pinprick.sarif"

    if [[ "${PPA_ADVANCED_SECURITY}" == "true" ]]; then
        set_output "sarif-file" "${sarif_file}"
        set +e
        "${pinprick}" audit --sarif "${PPA_PATH}" > "${sarif_file}"
        exitcode="${?}"
        set -e
    else
        set +e
        "${pinprick}" audit "${PPA_PATH}"
        exitcode="${?}"
        set -e
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
