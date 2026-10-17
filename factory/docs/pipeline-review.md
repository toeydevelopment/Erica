# Pipeline review: determinism and speed

This review looks at the factory overlay and the firstmate flow it runs on.
The question is which rules a weaker model can skip without anyone noticing, and what a script could check instead.
Each proposal names the prose rule, the check that would replace it, the cost, and a recommendation.
Evidence was read on 2026-10-17 from this fork's `main`.

## Principle

A rule that lives only in a brief is a request, not a contract.
A capable model follows it; a weaker or rushed model skips it silently, and nothing fails.
A rule a script can decide belongs in a script that refuses, with the brief keeping one pointer to it.
Prose stays only for judgment a script cannot make.

## 1. Pull request rules: now enforced by `sf-pr-check`

`factory/bin/sf-pr-check.sh` checks a pull request, or a local body with `--body-file`, and the `sf-pr-check` workflow runs it on every pull request to `main`.
Running it against the fork's own merged factory pull requests shows the gap it closes: https://github.com/toeydevelopment/Erica/pull/8 and https://github.com/toeydevelopment/Erica/pull/9 used `### Local Verification` instead of `## Local Verification`, and https://github.com/toeydevelopment/Erica/pull/5 quoted the forbidden address word.
Each passed review because no check existed.

Rules from `factory/brief-include.md` that the check now enforces:

| Line | Prose rule | Rule in `sf-pr-check` |
|------|-----------|------------------------|
| 33, 40 | "add a "Local Verification" section ... A pull request without this section is not ready." | 2 `local-verification` |
| 34 | "List every command you ran with its exact result" | 2 requires a command and a result word or count |
| 37-38 | "For user-interface changes ... embed them in the description" | 4 `ui-evidence` (image required when a `ui_globs` file changed) |
| 44-45 | "Fill every `## ` heading it lists, in its order" | 1 `headings` |
| 46-58 | default `## Summary`, `## Evidence`, `## Merge Danger` | 1 `headings`, 3 `merge-danger` |
| 49-57 | `<...>` template placeholders | 5 `no-placeholders` |

Two rules come from outside `brief-include.md`: rule 6 (Conventional Commits title, the subject style every factory commit uses) and rule 7 (no direct address in non-chat artifacts, `AGENTS.md` line 14).

Rules that remain prose, because a script cannot decide them:

- Line 34 "exact result": the check proves a result word exists, not that it is true. Hosted CI is the truth for that.
- Line 36 "State plainly anything you did not run and why": needs knowledge of what should have run.
- Line 60 "Mark a change one-way when it cannot be undone": the check proves a door is named, not that it is the right door. A later rule could require `one-way` when changed paths match a configured list (migrations, deploy config). Cost: one table row and a config key. Recommendation: later, once a project lists its one-way paths.
- Lines 27-29 "Write for the next reader" and lines 65-66 test quality: judgment.

Pointer firstmate should add to `factory/brief-include.md` under "Pull request descriptions" (this task did not edit that file because the trunk task owns a section there):

```markdown
Before you open or edit a pull request, run `factory/bin/sf-pr-check.sh --body-file <body-file> --title "<title>"` and fix every FAIL line; the `sf-pr-check` workflow runs the same check on the pull request.
```

Once that line lands, lines 44-58 can shrink to the template block alone, because the check now owns the heading rules.

## 2. The guard hook is opt-in

`factory/hooks/sf-guard.sh` blocks secret reads, literal secret writes and `rm` outside the project root.
It runs only where someone ran `factory/bin/sf-hooks-install.sh --apply` on a settings file: `factory/docs/hooks.md` line 33 says "The installer never runs on its own and touches only the file you name".
Nothing in `factory/bin/sf-install.sh` or the spawn path installs it, so a new home or project runs unguarded and nobody is told.
Proposal: `sf-install.sh` prints `FAIL guard hook not installed in <settings>` for each project in the registry whose `.claude/settings.json` lacks the hook, and a test pins that.
Cost: about 20 lines and one test. Recommendation: do now.

## 3. Worker status-line discipline

`bin/fm-brief.sh` line 777 lists the six states and the next line asks the worker to "Substitute `<epoch>` with the current Unix time ... a stamp that is not plain digits records no time at all."
The worker writes the line with a raw `echo`, so a wrong verb or a literal `<epoch>` is accepted and only shows up later as an unclassified or untimed event.
`bin/fm-classify-lib.sh` already owns the grammar (`status_stamp_line`, line 471, adds a stamp when one is missing) but no writer-side tool uses it.
Proposal: a `factory/bin/sf-status.sh <state> <text>` that refuses an unknown state, stamps the time itself and appends, so the brief rule becomes one command.
Cost: small, but the generated brief text lives in upstream `bin/fm-brief.sh`; the overlay can only add a `brief-include.md` line saying "prefer `sf-status.sh`".
Recommendation: later; the classifier already tolerates a missing stamp, so the damage today is lost timing, not lost events.

## 4. Briefs grow with every rule

The launch brief for this task was 246 lines and 23 KB before any code was read.
`factory/brief-include.md` adds 115 lines to every worker, and `AGENTS.md` (433 lines, 50 KB) loads into every session of this repository.
Each new prose rule taxes every worker on every task, and a long brief is exactly where a weaker model drops rules.
Proposals:

- Every rule moved into a check leaves one pointer line behind (section 1 shows the shape). Cost: none beyond the check. Recommendation: do now, as each check lands.
- Add a size budget test: `factory/tests/sf-brief-budget.test.sh` fails when `brief-include.md` grows past a set line count, so growth is a reviewed decision. Cost: about 10 lines. Recommendation: do now.
- Split rules that apply only on one delivery path (lines 86-98 are no-mistakes only) into the private additions of homes that use that path. Cost: moves text, no code. Recommendation: later, after the trunk task settles its section.

## 5. Default delivery path for this fork

The fork inherits `.github/workflows/no-mistakes-required.yml`, which checks that a pull request to `main` was raised by no-mistakes and exempts only the upstream author.
That workflow is `disabled_manually` on this fork (`gh api repos/toeydevelopment/erica/actions/workflows`), and no such check ran on https://github.com/toeydevelopment/Erica/pull/9 or https://github.com/toeydevelopment/Erica/pull/10, so this fork ships direct-PR in practice.
The factory overlay is shell scripts with plain-bash tests and a ten-second overlay workflow (`sf-overlay-check.yml`); the full upstream CI also runs on each pull request.
For changes limited to the overlay, the review step of no-mistakes adds minutes per round and its document step can rewrite files outside the add-only allowlist (`brief-include.md` lines 92-98 exist to undo that).
Recommendation: keep direct-PR as the default for overlay-only work now that `sf-pr-check` and `sf-overlay-check` gate the body and layout; use no-mistakes for work that changes behaviour other homes run, such as hooks wired into spawns.

## 6. Trunk-based delivery

No prose rule covers branch shape today: `brief-include.md` says nothing about branch age, size or base. A separate task adds `factory/bin/sf-trunk-check.sh`; this review does not build or describe its rules.
The two checks compose: `sf-trunk-check` judges the branch and `sf-pr-check` judges the description, and both run as required workflows.
Recommendation: once both exist, make both required status checks in branch protection (`factory/docs/fork-remotes.md` already covers that setup).

## 7. What the fleet dashboard still lacks

No prose rule covers overall progress today; the brief only asks workers for sparse status lines (`bin/fm-brief.sh` line 779, "Each append wakes firstmate, so report sparingly"). The dashboard task is not on any branch of this fork yet (`git branch -r` lists none), so this compares against what it would read: `bin/fm-fleet-snapshot.sh` schema `fm-fleet-snapshot.v1`.
That snapshot carries backlog rows, per-task current state, open decisions and secondmate summaries.
For overall progress it has no field for:

- Pull request check state per task (CI green, red or pending, and the `sf-pr-check` result). Today that needs a separate `gh` read per PR.
- Epic roll-up: done and total child tickets per epic. `factory/bin/sf-epic-gate.sh --ledger` already prints this per epic and could feed it.
- Time per stage: dispatch, first PR, merge. Status lines carry `[at=]` stamps, so this is derivable once stamps are reliable (section 3).

Recommendation: later; add the PR check column first, because it answers "what is blocked on red CI" without opening each PR.

## Summary of recommendations

| Proposal | Recommendation |
|----------|----------------|
| `sf-pr-check` plus workflow | done in this change |
| Brief pointer line for `sf-pr-check` | do now (firstmate edits `brief-include.md`) |
| Guard hook presence check in `sf-install.sh` | do now |
| Brief size budget test | do now |
| `sf-status.sh` writer | later |
| One-way door by changed path | later |
| Split no-mistakes-only rules out of the shared brief | later |
| Direct-PR default for overlay-only work | keep |
| Dashboard PR check column, epic roll-up, stage times | later |
