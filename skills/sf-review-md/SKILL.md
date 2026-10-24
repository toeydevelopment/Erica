---
name: sf-review-md
description: >
  Help a project owner draft or update a REVIEW.md that tells code reviewers,
  human or agent, what failure looks like in their repository, how many nits
  to allow, which paths to skip, what evidence a finding needs, and how to
  open the review summary. Grounds every rule in the repository's own history
  (review comments, reverts, fix commits), then explains how to point a
  reviewer at the file. Use when someone says "write a REVIEW.md", "set up
  review instructions", "the reviewer keeps nitpicking", "make the AI reviewer
  follow our rules", or asks why reviews miss real problems. Writes the file
  only in the user's current project and only when the user asks.
---

# sf-review-md

A `REVIEW.md` lets the people who own an area of code tell every reviewer what matters there.
The useful ones are short and concrete: they say what failure looks like in each area, cap nits, list paths to skip, demand file and line evidence, and make the summary open with a count.
This skill drafts one from evidence in the repository rather than from general review advice.

## Boundaries

- Work read-only until the user asks you to write the file.
- Write `REVIEW.md` only in the project the user is working in, and only after the user approves the draft.
- Never commit, push, open a pull request, or edit reviewer or CI configuration unless the user asks for that exact change.
- Do not copy secrets, customer data, or private names from review comments into the file.

## The template

Start from the factory template at <https://github.com/toeydevelopment/firstmate/blob/main/factory/config-templates/REVIEW.md>, or `factory/config-templates/REVIEW.md` when you are inside the firstmate fork.
If neither is reachable, keep its six sections in this order: what failure looks like here, severity and nits, skip these paths, evidence rule, summary format, keeping this file current.
If the project already has a `REVIEW.md`, update it in place instead of starting over.

## Workflow

### 1. Find the areas

List the top-level directories and the files that own behavior, such as `README`, `CONTRIBUTING`, `CODEOWNERS`, and any existing agent instructions.
Pick the few areas where a mistake is expensive.
Ask the owner to confirm or correct the list before going further.

### 2. Gather evidence of real failures

Use whatever the repository and its forge allow, and say which sources you could not reach:

```bash
git log --oneline -n 200 --grep='^Revert' --grep='^fix' -i
git log --oneline -n 200 --diff-filter=M --stat -- <area>
```

With the GitHub CLI, read recent review comments:

```bash
gh pr list --state merged --limit 30 --json number,title
gh api repos/{owner}/{repo}/pulls/comments --paginate -q '.[].body' | head -200
```

Use the equivalent `glab` or web views on other forges.
From this, note for each area what actually broke, which review comments repeat, and which comments were only style.

### 3. Draft each section from that evidence

- **What failure looks like here:** one row per area, written as the failure ("it lies", "it misroutes", "it double-charges"), not as a topic.
  Every row should trace to a fix, revert, or repeated comment you found, or to the owner's own words.
- **Severity and nits:** keep the three levels and set a nit cap, three or fewer unless the owner wants otherwise.
- **Skip these paths:** generated code, vendored code, lock files, and anything the owner says reviewers waste time on.
- **Evidence rule:** keep it as written; it is what stops findings guessed from names.
- **Summary format:** keep the count-first opening and the plain "Nothing needs fixing." line.
- **Keeping this file current:** fill in the repeat threshold, the check cadence, and the owner.

Keep the whole file short, because the reviewer reads it on every review.
Show the draft to the user with a one-line source for each rule, then write it only when they say so.

### 4. Point the reviewer at it

A `REVIEW.md` does nothing until the reviewer reads it.
Tell the user how to wire it for the reviewer they use:

- **A reviewer agent or subagent:** add one line to its instructions, such as "Before reviewing, read `REVIEW.md` at the repository root and follow it over general habits."
- **A review command** (any slash command or script that runs a review): pass the file or that same line as part of the review prompt.
- **A review pipeline step that accepts instructions or a prompt file:** point that setting at `REVIEW.md`.
  If the tool has no such setting, say so plainly and note it as a follow-up instead of editing the tool's configuration.
- **Human reviewers:** link `REVIEW.md` from `CONTRIBUTING` or the pull request template.

### 5. Check that the reviewer follows it

After a few reviews, compare them with the file: is each finding tied to a listed failure, does it cite a file and line, does the summary open with the count, and are skipped paths left alone?
When a rule is ignored, make it shorter or more concrete rather than longer.
When the same comment keeps coming back, add it to the matching section, as the file's last section says.

## Required response

When you hand a draft back, give:

1. the draft `REVIEW.md`;
2. the evidence behind each rule, as commit SHAs, pull request links, or the owner's words;
3. the sources you could not check;
4. how to point the user's reviewer at the file.
