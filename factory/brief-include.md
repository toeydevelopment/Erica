# Standing instructions for every lane in this home

These rules are shared by every worker in every project.
Private, project-specific additions belong in `config/brief-include.private.md`, which the installer appends after this file.

## Never end a turn idle on your own background work

If you start a background command (a test run, a build, a lint pass, a gate), do not end your turn while waiting for it.
Nothing will wake you and the supervisor will see a stopped worker.
Read the output in the same turn, or append a `paused` status line that names exactly what you wait for.

## Keep your deliverable somewhere that survives you

A path under `/tmp` or `/var/folders` is not a deliverable.
Anything the next person needs (a report, a handover, evidence) belongs under the home's `data/<your-task-id>/` before you report it.
Assume your worktree and any temporary directory disappear when you finish.

## Hosted CI is a signal, not a formality

Local verification is always required: run the repository's own commands in your worktree and record the exact commands, commit SHAs and results in the pull request.
Also report the hosted check results for your pull request head.
A red hosted check is a real signal: investigate it and fix it or explain it, and never dismiss it as unavailable CI.
For local failures in untouched paths, record the command, failing test or tooling error, paths and available base-branch evidence in the pull request, then continue to hosted CI without asking your lead.
Treat these as baseline failures unless evidence links them to your change; an unchanged test can still expose your regression.
A flaky or tooling-only local failure gets one retry, then hosted CI is the gate; record both attempts, and never claim an unrun suite passed.

## Write for the next reader, not for the ticket

Commit messages, pull request bodies, issue comments and reports are read by people who were not here.
State what changed and why, name what you verified and how, and say plainly what you deliberately did not do.
If you deviated from your instructions, say so and give the reason.

## Every pull request carries its test evidence

Before reporting a pull request ready, add a "Local Verification" section.
List every command you ran with its exact result: pass and fail counts, error counts, and duration where useful.
Name the test files you added or changed.
State plainly anything you did not run and why.
For user-interface changes, include real-browser evidence of the changed screens, such as screenshots or a recorded journey.
Reviewers must see screenshots in the pull request itself, so embed them in the description rather than naming files, and keep existing embeds intact when you edit it.
If your delivery path cannot embed images, say so plainly in the pull request and in your done report.
A pull request without this section is not ready.

## Pull request descriptions

Read the repository's `.github/pull_request_template.md` before you open or edit a pull request.
Fill every `## ` heading it lists, in its order, in one edit, because a workflow check that rejects the body reports one missing section at a time.
Before you open or edit a pull request, run `factory/bin/sf-pr-check.sh --body-file <body-file> --title "<title>"` and fix every FAIL line; the `sf-pr-check` workflow runs the same check on the pull request.
When the repository has no template, use these headings:

```markdown
## Summary
<diagram, pseudocode, call tree, or diff-sketch>

## Evidence
- **Before:** <output or failing test>  **After:** <output or passing test>

## Merge Danger
**Door:** <one-way, two-way or mixed>
**Blast Radius:** <one word> - <what can go wrong and how bad>
```

Mark a change one-way when it cannot be undone by reverting the pull request, such as a database migration, an encryption schema change, deploy or runtime configuration, payments, customer notifications, or auth behaviour.
Your home may list further one-way doors in its private additions below.

## Tests

Write tests through public interfaces.
Do not write tests that only restate constants, read source files as text, or mock away a dependency's real failure modes.

## Your lead manages you

Your supervising lead decides; you execute the one job in your instructions.
Never approve your own review finding or question, never widen scope, and never start a next task on your own.
Apply the standing answers below before escalating; stop and report unresolved blockers or uncertainty, not a local failure covered above.
If your work overlaps an open human pull request, stop and report its URL and the overlap instead of competing.

## Keep the feedback loop short

Do not re-verify what the pipeline or CI already proved; run the narrowest check that answers the question.
Do not repeat an optional evidence probe after the first good result; record it once.
After two failures, do not try a third variant; use the local-failure rule above or report an unresolved blocker.
For a test-only or docs-only delta after review, refresh the review note with the reviewed SHA, current SHA, delta and relevant verification instead of commissioning another review.
Do not claim the reviewer reviewed the new SHA or bypass a required gate.

## Repository workflow profile

If the repository has `docs/agents/workflow.md`, read it first and use its `quick-check`, `affected-check` and `delivery-check` commands.
Report `incomplete` or `NOT RUN` honestly, and never write `pass` for a skipped lane.
A task whose delivery path is no-mistakes does not run a separate review of its own.

## After your implementation commit, keep going

When your delivery path is no-mistakes, committing is not the end.
Right after the implementation commit, start the pipeline yourself with `no-mistakes axi run` and drive it to a pull request with green CI.
Do not report `done` and do not exit before the pull request exists.

## Review base for non-default-branch work

When the task's base branch is not the default branch, the reviewer can compare against the wrong branch and report findings about files outside your diff.
`factory/bin/sf-review-base.sh` always passes the task's base branch and scope sentence when it starts validation, so use it instead of calling `no-mistakes axi run` by hand.
`factory/bin/sf-review-scope-check.sh` lists the findings that cite files outside `git diff origin/<base>...HEAD`, so you can raise them as one decision for your lead.
Never edit files outside your own diff to satisfy such a finding.
After the pipeline's document step, run `git diff --stat origin/<base>...HEAD` and restore any file the document step rewrote that your change does not need documented.

## Findings you can decide yourself

These answers are already given, so respond through the gate right away instead of stopping for your lead:

- A finding about the pull request description only (missing or wrong section, door, approver, provenance table): fix the description and rerun only the affected check.
- A test-only change that makes a racy or flaky test deterministic and is needed for this pull request's CI to pass is in scope: keep it and say why under scope and limitations.
- A CI job cancelled without a verdict, or one that failed on runner capacity: rerun the affected run once and record it in the pull request.
  A cancelled leftover matrix placeholder can still block the guarded merge; rerun that run instead of asking your lead (rerun the whole run if `--failed` selects no jobs).
- A CI failure that also fails on the base branch without your change is not yours: do not fix it in this pull request, record the evidence, and report `paused` while you wait for the base-branch fix.
- If `gh-axi` does not work in your worktree, use plain `gh` for the same action.

Still stop for your lead on anything that widens scope, changes product behaviour beyond the instructions, or is destructive.

## Review rounds have a budget

Count your own `no-mistakes axi respond --action fix` answers to the review step, keeping the count across reruns on the same branch; a fix command your lead dictates exactly does not count, so send it as given.
After the third, never send a fourth or approve your way out: that gate is a genuinely new escalation, so write the round trail (per round the finding count and severities, and whether `git blame` puts each current finding's file:line in pipeline fix commits or your own code) to the home's `data/<your-task-id>/nm-<run>-rounds.txt`, append `needs-decision [at=<epoch>] [key=nm-<run>-review-rounds]: review round <n> of run <run> still has <k> findings file=<that file>` and stop.
Re-decline only an auto-fix finding your lead's recorded decision already declined, citing that decision; an ask-user finding always goes to your lead, even when it looks like a repeat.

## Trunk-based delivery

- Branch from the default branch and target it; never an `epic/*`, `release/*` or other long-lived branch.
- Keep the pull request under the configured size (default 400 added lines and 20 files, test fixtures and lock files excluded).
- Open the pull request within 48 hours of your first commit.
- When the task belongs to an epic, put `Part of #<epic issue>` in the pull request body.
- Hide unfinished behavior behind a feature flag and name it on a `Flag: <name>` line in the pull request body.
- After base-branch merges, catch up with the latest base once, immediately before ready, using the project's configured method: rebase or fast-forward when `forbid_merge_commits` is true, a true merge otherwise.
- Mark ready together with the last push, because ready transitions can rerun checks; collect results for that final head.
- If the base advances again, let the merge queue handle it or report the remaining branch-protection blocker instead of starting another catch-up loop.
- Run `factory/bin/sf-trunk-check.sh --local` before reporting ready.

## Shared host: never kill by name

Never run `pkill`, `killall` or similar by process name.
Stop only processes you started, by their recorded PID or process group.
