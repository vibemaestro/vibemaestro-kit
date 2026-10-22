---
applyTo: "README*.md,DEVELOPMENT*.md,CONTRIBUTING*.md,SECURITY*.md,CODE_OF_CONDUCT*.md,docs/**,**/README.md,**/README.*.md"
description: "READMEs, root docs and docs/ are the final public description of what the thing is and how to use it now: no dates, history, decisions or private names; kb/ keeps those"
---

A root doc, a README and everything under `docs/` is public documentation, read by people who were not there. `kb/` is the private side: history, decisions, measurements. A README under `kb/` or a test fixture is not covered, nor are `CLAUDE.md` and `AGENTS.md` (instructions for the model) or a CHANGELOG (release notes, history by nature; nothing private in it still holds).
1. Describe the current behaviour in the present tense. What is not built yet is said once as not available yet, with no plan id and no date.
2. No dates and no diary: no calendar date, no "since", "was changed", "retired", "as of commit". When order matters, write first, second.
3. No decision talk: not who decided, asked or approved, no rule named after the person who set it, no quote of someone's words. A role the product has (the owner who signs a baton) is behaviour and stays.
4. No working notes: no issue, PR or plan-row number, no TODO, no round or session history.
5. A result is a property with its conditions ("tested with Claude Code 2.1.290", "a run costs about N tokens"), not a log of runs, dates or who measured.
6. No pointer into `kb/`: a doc stands on its own. A plugin text that tells a repo how to use its own `kb/` is behaviour, not a pointer.
7. Nothing private: no person's name, host, IP, org, account, internal repository or machine path.
8. A `*.vi.md` twin says what its English file says.
