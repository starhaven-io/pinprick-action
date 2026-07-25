# pinprick-action

Run [pinprick](https://github.com/starhaven-io/pinprick) from GitHub Actions.

pinprick audits GitHub Actions supply chain security by finding runtime fetch
patterns that bypass pinning, checking action references, and reporting results
through an explainable, open scoring rubric.

This wrapper installs pinprick from GitHub releases, verifies the downloaded
archive's sha256 digest, and verifies GitHub provenance attestations before
extracting attested release assets.

## Quickstart

### Usage with GitHub Advanced Security

This is the default mode. The action emits SARIF and uploads findings to GitHub
code scanning so they appear in the repository's Security tab.

In this mode, the action does not fail the workflow when pinprick reports
findings unless `fail-on-findings: true` is set. Use GitHub rulesets if you want
code scanning alerts to block merges.

Run SARIF upload on trusted events such as `push` or `workflow_dispatch`. Pull
requests from forks receive a read-only token, so SARIF upload can fail there;
use console mode for pull request feedback.

```yaml
name: GitHub Actions supply chain audit

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions: {}

jobs:
  pinprick:
    runs-on: ubuntu-24.04
    permissions:
      security-events: write
      contents: read # needed for checkout and private/internal repositories
      actions: read # needed for private/internal repositories
    steps:
      - name: Checkout repository
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false

      - name: Run pinprick
        uses: starhaven-io/pinprick-action@c247aaa3a3f4a994e03c200d070aab378727c5c0 # v0.5.0
```

### Usage without GitHub Advanced Security

Set `advanced-security: false` to print results to the workflow log instead of
uploading SARIF. This mode is suitable for pull requests from forks.

```yaml
name: GitHub Actions supply chain audit

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - "**"

permissions: {}

jobs:
  pinprick:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false

      - name: Run pinprick
        uses: starhaven-io/pinprick-action@c247aaa3a3f4a994e03c200d070aab378727c5c0 # v0.5.0
        with:
          advanced-security: false
```

Each example pins pinprick-action to a full commit SHA with the release tag in a
trailing comment, not a mutable tag. That is exactly the pinning pinprick itself
checks for; bump the SHA when you adopt a newer release.

### Fail on findings

```yaml
- name: Run pinprick
  uses: starhaven-io/pinprick-action@c247aaa3a3f4a994e03c200d070aab378727c5c0 # v0.5.0
  with:
    fail-on-findings: true
```

## Supported runners

| Runner | Architecture |
| --- | --- |
| `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04`, `ubuntu-slim` | Linux x64 |
| `ubuntu-24.04-arm`, `ubuntu-26.04-arm` | Linux ARM64 |
| `macos-latest`, `macos-15`, `macos-26` | macOS ARM64 |

Support is limited to the labels above. The 26.04 preview labels report through
a self-test job excluded from the required `conclusion` check. Everything else
is unsupported, including self-hosted runners, containers, and any environment
with glibc older than 2.39. pinprick publishes no x86_64 macOS or Windows
build.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | `0.22.0` | pinprick version to install, pinned by default for deterministic runs. Use `latest` for the newest, or an exact version like `v0.22.0`. |
| `path` | `.` | Repository path to scan. |
| `advanced-security` | `true` | Emit SARIF and upload it to GitHub code scanning. |
| `fail-on-findings` | `false` | Fail the workflow when pinprick reports findings. Internal errors always fail. |
| `strict-provenance` | `false` | Require provenance verification to run: fail instead of warn when the attestation cannot be checked. |
| `no-repo-config` | `false` | Ignore the scanned repository's `.pinprick.toml` and audit with the global config or defaults. Recommended when auditing repositories you don't control, so their config cannot suppress findings. |

pinprick currently supports severity filtering through `.pinprick.toml`, not an
audit CLI flag, so this action does not expose a `min-severity` input.

## Outputs

| Output | Description |
| --- | --- |
| `exit-code` | pinprick audit exit code. |
| `sarif-file` | Filepath to usable SARIF results when `advanced-security: true` and the audit exits 0 or 1. |

## Permissions

Start workflows with `permissions: {}` and grant permissions only at the job
that runs pinprick.

| Permission | Required when |
| --- | --- |
| `security-events: write` | `advanced-security: true` uploads SARIF to code scanning. |
| `contents: read` | Checking out the repository, and Advanced Security on private/internal repositories. |
| `actions: read` | Advanced Security on private/internal repositories. |

The action passes the workflow's `GITHUB_TOKEN` to pinprick so it can fetch and
audit external action source when the job permissions allow it. Without a token,
pinprick still scans local workflow `run:` blocks and local actions.

## Provenance verification

Every install verifies the downloaded archive's sha256 digest against the
GitHub release metadata, then attempts to verify the release's provenance
attestation with `gh attestation verify`.

Verification fails open by default: when `gh` is missing or too old, or no
GitHub token is available, the action warns and continues on the strength of
the checksum alone. Set `strict-provenance: true` to require that verification
actually ran, turning every unverifiable condition, including engine releases
that predate attestations, into a hard failure:

```yaml
- name: Run pinprick
  uses: starhaven-io/pinprick-action@c247aaa3a3f4a994e03c200d070aab378727c5c0 # v0.5.0
  with:
    strict-provenance: true
```

## Exit Behavior

pinprick uses these exit codes:

| Code | Meaning | Action behavior |
| --- | --- | --- |
| `0` | Clean | Succeeds. |
| `1` | Findings present | Succeeds by default; fails only with `fail-on-findings: true`. |
| `2+` | Error | Fails. |

In Advanced Security mode, SARIF upload happens before optional
`fail-on-findings` failure so findings are still available in code scanning.

## Versioning

Each release of this action pins a specific pinprick version through the
`version` default, so a workflow pinned to a given action ref installs the same
pinprick build on every run. To move to a newer pinprick, bump the action to a
release whose default targets it, or set `version` yourself (including
`latest`, if you accept non-deterministic installs).

There is deliberately no floating major tag such as `@v1`: a mutable tag
resolved at run time is exactly the pattern pinprick audits workflows for.
Pin a full commit SHA with the release tag in a trailing comment, as every
example above does, and bump it deliberately when adopting a new release.

<!-- fleet:block license-section -->

## License

This action wrapper is licensed under the MIT License. See [LICENSE](LICENSE).

The pinprick engine downloaded and run by this action is a separate project
licensed under the [GNU Affero General Public License v3.0 only](https://github.com/starhaven-io/pinprick/blob/main/LICENSE).
Using this wrapper does not relicense pinprick or change pinprick's license
terms.

<!-- fleet:end -->

## Acknowledgements

This action's composite structure was inspired by
[zizmor-action](https://github.com/zizmorcore/zizmor-action) (MIT, © William Woodruff).
