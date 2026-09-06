# Releasing

Every release is a plain `vX.Y.Z` tag on `main` plus a GitHub release whose
notes state the pinned engine version. There is deliberately no floating major
tag; consumers pin commit SHAs (see "Versioning" in `README.md`).

## Automated: engine bumps

When a starhaven-bot `chore/pin-pinprick-*` PR (bumping the `version` default
in `action.yml` and `README.md`) merges to `main`, `release.yml` validates the
bump contract, waits for the exact merge commit's push-triggered `Self-test`
`conclusion` job to succeed, tags the next patch version, and creates the
release. A failed, cancelled, missing, or timed-out conclusion blocks
publication. Non-gating preview jobs do not block a release. No manual step is
involved.

## Manual: wrapper changes

Changes to `action.sh`, workflows, or docs never trigger `release.yml`. To
release them:

1. Merge the change to `main` through a PR and wait for the `conclusion`
   check to succeed on the merge commit.
2. Run the "Release (manual)" workflow from `main` (Actions → Release
   (manual) → Run workflow) with:
   - `version`: the next tag, e.g. `v0.6.0` (must not exist and must sort
     above the latest published stable release; the release is refused when
     there are no new commits; wrapper releases bump the patch version unless
     inputs or outputs changed behavior). Before v1, observable behavior changes
     such as changing an input default require a minor-version bump.
   - `notes`: a one-line summary of the wrapper changes.
3. The workflow verifies the request, independently rechecks the exact
   `conclusion` job in the push-triggered `Self-test` run for the head of `main`,
   then tags that commit and creates the release with the pinned engine version
   appended to the notes.

## After any release

Refresh every SHA-pinned usage example in `README.md` to the new tag's commit in
an immediate follow-up PR. This is required because `SECURITY.md` supports only
the latest release. The self-test validates that every documented SHA resolves
to its trailing tag, but it cannot update a release SHA that does not exist
until after publication.
