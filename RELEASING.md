# Releasing

Every release is a plain `vX.Y.Z` tag on `main` plus a GitHub release whose
notes state the pinned engine version. There is deliberately no floating major
tag; consumers pin commit SHAs (see "Versioning" in `README.md`).

## Automated: engine bumps

When a starhaven-bot `chore/pin-pinprick-*` PR (bumping the `version` default
in `action.yml` and `README.md`) merges to `main`, `release.yml` validates the
bump contract, tags the next patch version, and creates the release. No manual
step is involved.

## Manual: wrapper changes

Changes to `action.sh`, workflows, or docs never trigger `release.yml`. To
release them:

1. Merge the change to `main` through a PR and wait for the `conclusion`
   check to succeed on the merge commit.
2. Run the "Release (manual)" workflow from `main` (Actions → Release
   (manual) → Run workflow) with:
   - `version`: the next tag, e.g. `v0.4.4` (must not exist and must sort
     above the latest tag; the release is refused when there are no new
     commits; wrapper releases bump the patch version unless inputs or outputs
     changed behavior).
   - `notes`: a one-line summary of the wrapper changes.
3. The workflow verifies the request, tags the head of `main`, and creates
   the release with the pinned engine version appended to the notes.

## After any release

Optionally refresh the SHA-pinned usage examples in `README.md` to the new
tag's commit in a follow-up PR. The self-test validates that each pinned
SHA/tag pair in the README stays consistent, so stale-but-consistent examples
do not fail CI; update them when recommending the new release.
