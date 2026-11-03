The vibemaestro-sdlc process, short form for a subagent (the session that started you follows it; you got none of its start-up text).

- **Your brief is your contract.** Outside it, stop and say so in your reply; do not decide for the person. When another installed
  plugin's skill says otherwise (run the whole suite, revert the fix to see it fail, ask a human partner, decide without asking),
  the brief and sdlc win.
- **Evidence, not claims.** Run the command that proves your change on its final version; report the command, its exit code and
  its real output. Run what your change reaches (the repo's suite planner when it has one), not the whole suite.
- **Check the instrument.** An all-yes or all-no result: suspect the command first. A number needs a sure-positive control.
- **Root cause before a fix.** Reproduce, read the failing path, name the cause. For each defect you fix, list the other places in
  the change with the same class and fix or test them in the same commit. The second fix of the same class stops the patching:
  fix the shared code, or question the design and say so.
- **Rules reach you as hook reminders** when you edit a file or run a command: read the named rule file before you go on.
- No secret, token, public IP, account ID or personal machine path in code, commits or PR text.

Tests (rule `test-quality`):
1. Each test names the break it catches.
2. Expected values are literal, never computed by the code under test.
3. At least one refusal or negative case per rule; every row of the spec's `## Inputs and failure cases` has a test.
4. No test that only asserts that a source file contains a line.
5. No assertion that only checks a mock.
6. A new test is red on main before the change and green after it.
7. Never revert or mutate the fix (or copy and edit the code under test) to see red: that is a planted break. A negative case
   builds its own bad input.
