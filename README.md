# pinprick-action

Run [pinprick](https://github.com/starhaven-io/pinprick) from GitHub Actions.

pinprick audits GitHub Actions supply chain security by finding runtime fetch
patterns that bypass pinning, checking action references, and reporting results
through an explainable, open scoring rubric.

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
        uses: starhaven-io/pinprick-action@b711e85aacbd9cf73e0285b16b0f3d0b35b3ae60 # v0.2.0
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
        uses: starhaven-io/pinprick-action@b711e85aacbd9cf73e0285b16b0f3d0b35b3ae60 # v0.2.0
        with:
          advanced-security: false
```

Each example pins pinprick-action to a full commit SHA with the release tag in a
trailing comment, not a mutable tag. That is exactly the pinning pinprick itself
checks for; bump the SHA when you adopt a newer release.

### Fail on findings

```yaml
- name: Run pinprick
  uses: starhaven-io/pinprick-action@b711e85aacbd9cf73e0285b16b0f3d0b35b3ae60 # v0.2.0
  with:
    fail-on-findings: true
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | `0.19.0` | pinprick version to install, pinned by default for deterministic runs. Use `latest` for the newest, or an exact version like `v0.19.0`. |
| `path` | `.` | Repository path to scan. |
| `advanced-security` | `true` | Emit SARIF and upload it to GitHub code scanning. |
| `fail-on-findings` | `false` | Fail the workflow when pinprick reports findings. Internal errors always fail. |

pinprick currently supports severity filtering through `.pinprick.toml`, not an
audit CLI flag, so this action does not expose a `min-severity` input.

## Outputs

| Output | Description |
| --- | --- |
| `sarif-file` | Filepath to the SARIF results when `advanced-security: true`. |

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

## License

This action wrapper is licensed under the MIT License. See [LICENSE](LICENSE).

The pinprick engine downloaded and run by this action is a separate project
licensed under the [GNU Affero General Public License v3.0 only](https://github.com/starhaven-io/pinprick/blob/main/LICENSE).
Using this wrapper does not relicense pinprick or change pinprick's license
terms.

## Acknowledgements

This action's composite structure was inspired by
[zizmor-action](https://github.com/zizmorcore/zizmor-action) (MIT, © William Woodruff).
