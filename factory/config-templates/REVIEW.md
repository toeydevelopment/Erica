# REVIEW.md

<!--
Fill-in template for a project's code review instructions.
Copy it to the project root, replace every <...> placeholder, and delete sections that do not apply.
Keep the result short: a reviewer reads this file on every review.
-->

Instructions for anyone, human or agent, who reviews a change in this repository.
Follow them over general review habits.

## What failure looks like here

Report a finding only when the change can cause one of these failures.

| Area (paths) | It fails when |
| --- | --- |
| `<docs/>` | it lies: the text no longer matches what the code does |
| `<config/>` | it misroutes: a value sends traffic, jobs or users to the wrong place |
| `<src/payments/>` | `<money is charged, refunded or rounded wrong>` |
| `<area>` | `<the concrete failure in that area>` |

## Severity and nits

- **Blocking:** one of the failures above, a security or data-loss risk, or a broken build or test.
- **Should fix:** a real defect with limited impact.
- **Nit:** style or naming only.
  Report at most `<3>` nits per review, and never block on a nit.

## Skip these paths

Do not review or comment on:

- `<generated/>`
- `<vendor/>`
- `<*.lock>`

## Evidence rule

Every finding names the file and line it is about and the code or behavior that proves the problem.
Do not report a problem guessed from a name, a comment or a file path alone.
If you cannot point at the evidence, leave the finding out.

## Summary format

Open the review summary with the count, for example `2 blocking, 1 should fix, 0 nits`.
When nothing needs fixing, say so in one plain sentence, such as `Nothing needs fixing.`, and stop.

## Keeping this file current

When the same review comment appears on `<2>` or more changes, add it to the matching section above in the same pull request that repeats it.
Every `<month>`, check `<3>` recent reviews against this file and fix any rule the reviewer ignored or that no longer matches the code.
Owner: `<team or person>`.
