# Reviewer brief

The brief a fresh-context reviewer gets (skill `ship` step 5, rule `before-ready` items 5 and 9); the reviewer runs on
`agents.review_model`, or on `agents.worker_model` for a small fix's re-review. Fill the angle brackets; give facts and paths,
not your conclusion. The reviewer has none of your context: what is not in the brief, it does not know.

```markdown
You review <PR link> at head <full SHA>, with fresh context. Read the code at that SHA, not a summary of it.

## What it must do
Spec: <kb/specs/<date>-<slug>.md>. Its goals, in one line each:
- <goal 1>
- <goal 2>

## Risks to cover
The risks the author worked from (copied from the spec's `## Risks to cover`; an older spec: the rows of its `## Inputs and failure
cases`). For each: does the code handle it, and does a test prove it (red without the change, green with it)?
- <risk>

## Files
- Expected to change (from the spec): <list>
- Changed (`git diff --name-only <base>...<SHA>`): <list>
Say why any changed file is not expected, and which expected file did not change.

## The author's report: claims to check
Each line is a claim, not a fact. Check it against the code or by running the command; do not repeat it as your finding.
- <claim, with the command the author ran and the exit code it reported>

## What to return
1. **Spec verdict first**: for each goal, criterion and risk, met / not met / partly, with the file and line that shows it.
   Something the spec did not ask for is a finding too.
2. **Then the quality verdict**: defects, each with id, severity (high / medium / low), file:line, the input that breaks it and
   what happens. Read each changed function whole, with its callers and its tests, not only the diff lines. For each defect, name
   its class and the other places in the change where the same class may hide.
3. **Declined to judge**: what you did not check or could not decide, and why (no access, needs a live system, outside your
   knowledge). An empty list is a claim too.
```

A re-review after a fix round (rule `before-ready` item 9) uses the same brief with the round's head SHA, the defects the round
fixed, and the functions they touched; the reviewer reads those functions whole, not only the fix diff.
