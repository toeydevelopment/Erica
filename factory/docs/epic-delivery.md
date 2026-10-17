# Epic delivery

Every change ships trunk-based: a short-lived branch, one small pull request to the default branch, merged as soon as it is ready.
An epic does not change that.
An epic is only a way to group and track related tickets on GitHub.

## The rule

- An epic is a GitHub issue that carries the `epic` label.
  The label name is `epic_label` in `config/epics.json`; the template is `factory/config-templates/epics.json`.
- A ticket of the epic is a sub-issue of the epic issue, or any issue whose body has a `Part of #<epic>` line.
- Each ticket ships as a short-lived branch from the default branch and a pull request back to it.
  There is no `epic/<slug>` branch and no big epic pull request.
- The ticket pull request body says `Part of #<epic>`, and `Closes #<ticket>` when it finishes a ticket issue.
- Ticket pull requests merge as they finish.
- Behavior that is not ready for users stays behind a feature flag.
  Name the flag on a `Flag: <name>` line in the pull request body, so the tracker can list it.
- `factory/bin/sf-trunk-check.sh` checks each ticket pull request against the trunk rules.
  Its header comment owns the rules, the `config/trunk.json` keys and the exit codes.
  Workers run `sf-trunk-check.sh --local` before reporting ready, and `.github/workflows/sf-trunk-check.yml` runs it on every pull request to this fork.

## Tracking progress

Run `factory/bin/sf-epic-track.sh <owner/repo> <epic-issue-number>`.
It prints one row per child: the issue number, title, pull request URL or `no PR`, pull request state (`merged`, `open`, `closed` or `none`) and the flag from the `Flag:` line, or `-`.
The last line is `progress: merged X/N`.

Children are the epic's GitHub sub-issues, plus every issue and pull request whose body says `Part of #<epic>`.
A child issue is matched to the child pull request that closes it.
A child pull request that closes no child issue gets its own row.
The `Part of` search uses GitHub issue search, so a pull request opened seconds ago can be missing until the search index catches up.

Two options make the progress visible on GitHub:

- `--comment` keeps one checklist comment on the epic issue, marked `<!-- sf-epic-track -->`.
  A rerun edits that comment instead of adding a new one.
- `--label` makes sure label `epic:<slug>` exists and every child carries it.
  The slug is the `Slug:` line of the epic body, else the epic title in lower-case words joined by dashes.
  Filter on that label in issue search, pull request lists or a GitHub Project view to see the whole epic.

Without either option the script only reads.
Exit codes: 0 done, 2 bad arguments, missing config, an issue without the epic label, or a GitHub error.

## Finishing an epic

The epic is done when `progress` shows every child merged and every flag it introduced is either removed or switched on for everyone.
Close the epic issue by hand then; nothing closes it automatically.

## Tests

`factory/tests/sf-epic-track.test.sh` and `factory/tests/sf-trunk-check.test.sh` replay recorded JSON from `factory/tests/fixtures/` through a fake `gh` and need no network.
