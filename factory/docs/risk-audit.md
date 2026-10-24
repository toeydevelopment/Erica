# Risk audit

`factory/bin/sf-risk-audit.sh` answers one question with a reproducible number: how many merged high-risk pull requests in a date window did not go through no-mistakes?
It is read-only: it only issues GET requests through `gh api` and writes nothing to the audited repository.
Its header comment owns the options, the output format, the status meanings and the exit codes.

## Path list

High risk is defined per repository by a path list, one shell glob per line with `#` comments.
A pull request is high-risk when any changed file, or the old name of a renamed file, matches a glob.
`factory/config-templates/risk-paths.example` is a generic starting point.
Keep the real list for each repository in the home's private `data/`, never in this fork, and give each glob a one-line reason.
A list counts as the rule only after the owner of the standing preference confirms it; until then every count it produces is a draft.

## No-mistakes status

The status comes from the upstream `require-no-mistakes` verifier, `verify.py`, at the commit pinned in `.github/workflows/no-mistakes-required.yml`.
The audit runs that file offline with the pull request body and final head SHA, so it applies the same rules as the required check.
`compliant` means the verifier accepted the body; `marker` means a no-mistakes marker is present but the verifier rejected it; `none` means no marker at all.
`compliant` is a structural check of author-editable text, not a cryptographic signature: a hand-written body in the right format also passes.

## Reproducing a result

Run once online to fill the cache, then rerun with `--offline`.
The offline run makes no GitHub call and prints byte-identical output for the same cache, so a checksum of the output proves the result.
The window uses UTC dates of `merged_at`, inclusive at both ends.

## Blind spots

- Risk in a file the path list does not name is reported as low.
- A pull request merged without a pull request, such as a direct push, is not seen.
- The verifier proves the body format, not that the pipeline actually ran.
