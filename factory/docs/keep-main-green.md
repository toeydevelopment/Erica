# Keep main green and shorten delivery

Idle machines do not rule out a delivery bottleneck: incomplete PR checks, repeated branch updates and metadata gates can dominate elapsed time.
Project owners should fix those gates before adding workers.
The [shared worker rules](../brief-include.md) own failure handling, review-note refreshes and catch-up timing; the [normal factory install](../README.md#install-for-a-new-user) includes them for every project in that home.

## New-project onboarding checklist

- [ ] Map every release or deploy test gate to a required PR check, including its command, flags, environment, services and test selection.
  Run DB-backed unit tests with the database available; a short-test flag that skips them cannot prove the release gate.
  Include the deploy smoke subset of E2E tests before merge, and include any broader suite that blocks release.
  Use shared test entry points so PR and release commands cannot drift independently.
- [ ] Verify those checks actually execute and fail for a known failing test on a disposable branch.
  A green skipped job, absent service or missing required context is not coverage.
- [ ] Prefer a merge queue to validate changes with the latest base without repeated author catch-ups.
  Required GitHub Actions workflows must also handle `merge_group`; see [GitHub's merge queue setup](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue).
  If a queue is unavailable, require branches to be up to date and serialize the final update-and-merge window.
  That fallback protects main but does not eliminate retesting when another merge wins the race.
- [ ] Check workflow triggers, required check names and review-note validation together.
  Avoid duplicate expensive runs for the same final head, accept the worker review-note refresh where policy permits, and use the validator's exact status values.
  Keep required approvals intact and identify workflow code owners before scheduling a workflow change.
- [ ] Set an artifact storage budget, an owner and a retention period appropriate to the evidence needed.
  Upload only necessary outputs, retain failures long enough to debug, and monitor storage before uploads stop CI.
  Follow [GitHub's artifact retention and removal guidance](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/remove-workflow-artifacts); cleanup must preserve evidence still needed for active work.
- [ ] Confirm the installed home includes the shared worker rules before dispatch, including each secondmate home under the normal install procedure.
  Assign an owner to fix a red base branch separately instead of making every worker repair it.

## Proposed coverage-drift check

A warning-only `sf-*` check could compare explicit PR and release test invocations and report flags or suite selections present only in release.
For example, a PR command with a short-test flag and a release command without it should prompt a coverage review.
The check would need to report unknown coverage for reusable workflows, matrix expressions, environment-dependent skips and shell wrappers rather than report a false pass.
No checker is shipped here: reliably resolving those inputs is not a generic check of about 80 lines, and raw workflow text cannot prove which tests ran.
For now, use the onboarding command map and shared test entry points; add a small deterministic comparison only when a project exposes explicit comparable suite lists.
