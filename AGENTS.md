# Agent Instructions for starhaven-io/pinprick-action

Most importantly, keep this action a thin, deterministic, supply-chain-safe
wrapper around the `pinprick` engine. It runs in other people's CI with their
`GITHUB_TOKEN`, so changes must stay small, auditable, and pinned.

## Project overview

`pinprick-action` is a composite GitHub Action that installs
[`pinprick`](https://github.com/starhaven-io/pinprick) from its GitHub releases
and runs `pinprick audit`, mapping the engine's exit codes onto GitHub Actions
results and optionally uploading SARIF to code scanning. `action.yml` defines the
composite steps; `action.sh` does the install-and-run work. The wrapper is MIT;
the pinprick engine it downloads is a separate AGPL-3.0 project. The composite
structure was inspired by zizmor-action (MIT, by William Woodruff); keep that
acknowledgement in `README.md` and `action.sh`.

## Required checks

- Run `just check` before pushing: diff hygiene (`git diff --check`), workflow
  audit (`zizmor`), action supply-chain audit (`pinprick audit .`), and the
  README link check (`lychee`).
- Run `just install-hooks` once per clone so DCO sign-off and the pre-push gate
  are active.
- After changing `action.sh`, keep it `shellcheck`-clean and re-check the
  exit-code mapping by hand: 0 stays success, 1 stays success unless
  `fail-on-findings`, and 2+ fails.
- Confirm `git status --short` shows only intended changes.

## Repository structure

- `action.yml`: composite action definition: inputs, outputs, and the run,
  SARIF-upload, and fail-on-findings steps.
- `action.sh`: installs pinprick from GitHub releases (checksum-verified) and
  runs `pinprick audit`, translating exit codes into step results.
- `README.md`: usage, inputs, outputs, permissions, and exit behavior.
- `LICENSE`: MIT, for this wrapper only.
- `lychee.toml`: README link-check configuration.
- `.github/workflows/self-test.yml`: runs the action against this repo and
  exposes the aggregate `conclusion` check the org ruleset requires.
- `.github/workflows/codeql.yml`: actions CodeQL analysis.
- `.github/workflows/link-check.yml`: weekly README link check.
- `.github/workflows/zizmor.yml`: GitHub Actions security audit.
- `.github/dependabot.yml`: `github-actions` version updates.
- `justfile`, `.githooks/`, `.editorconfig`, `.gitignore`: local tooling and
  hygiene shared across the estate.
- `CLAUDE.md`: compatibility pointer for Claude Code; keep it as `@AGENTS.md`.

## Safety / do-not-touch rules

1. Preserve the exit-code contract in `action.sh`: 0 = clean (succeed), 1 =
   findings (succeed with a warning unless `fail-on-findings: true`), 2+ = error
   (fail). Downstream workflows depend on it.
2. In Advanced Security mode, upload SARIF before any `fail-on-findings` failure
   so findings still reach code scanning.
3. Keep every action reference SHA-pinned with the version in a trailing comment;
   this action audits for exactly that. The
   `github/codeql-action/upload-sarif` pin in `action.yml` is one such reference.
4. Keep the `version` input pinned by default for deterministic installs; bump it
   deliberately per release rather than defaulting to `latest`.
5. Keep wrapper inputs namespaced as `PPA_*` in `action.yml` and `action.sh` so
   they never clash with pinprick's own environment variables.
6. Verify the downloaded archive checksum before use; never skip the sha256 check
   in `action.sh`.
7. Do not relicense. This wrapper is MIT; pinprick stays AGPL-3.0. Keep the
   distinction clear in `README.md`.
8. Keep `self-test.yml`'s `conclusion` job: the org-wide ruleset requires a
   `conclusion` status check on this repo.

<!-- fleet:block commit-and-pr-conventions -->

## Commit and PR conventions

- Conventional Commits: `type(scope): description`. Valid types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
- Sign off every commit with `git commit -s` for DCO (enforced by the
  `.githooks/commit-msg` hook; run `just install-hooks` once per clone to
  enable it).
- When authored with an AI coding agent, add a `Co-Authored-By` trailer after
  `Signed-off-by`, naming the agent and model. Current example:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Bump the model
  version as newer ones ship.
- Never commit directly to `main`; create a feature branch and open a PR.
- PR descriptions should contain only a concise summary of changes. Do not add
  test-plan sections, bot attribution, or generated-with footers.
- Comments must earn their keep: a comment states a constraint or rationale the
  code cannot express. Never add comments that narrate what the code does,
  restate names, or explain a change to its reviewer.

<!-- fleet:end -->
