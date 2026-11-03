---
applyTo: "**/tests/**,**/test/**,**/__tests__/**,**/spec/**,**/test_*.*,**/*_test.*,**/*.test.*,**/*_spec.*,**/*.spec.*,**/*Test.*,**/*Tests.*"
description: "A test proves a break it names: literal expected values, a refusal case per rule, red on main and green after; no source-text or mock-only assertion, no planted break; root cause before a fix"
---

# Test quality: a test proves one break it can name

A test that passes on broken code costs more than no test: it is read as proof. These hold in any language and test framework.

1. **Each test names the break it catches**, in its name or its message: "an empty list is refused with rc 65", not "test 3" or "works". If you cannot name the break, the test has no job.
2. **Expected values are literal**: `65`, `"section ## X is missing"`, a fixed list. An expected value computed by the code under test, or by a copy of its logic, agrees with the bug.
3. **At least one refusal or negative case per rule**: for every input the code must accept, one it must refuse (the empty, the hostile, the oversized, the one that fails half way), with the exit code or error it must give. Each row of the spec's `## Inputs and failure cases` has a test.
4. **No test that only asserts a source file contains a line.** Run the code and check what it does; reading text is a test only when the text is the product (a document, a generated file, a message a person reads).
5. **No assertion that only checks a mock.** "The mock was called" proves the test's own wiring: assert on an output, a state or a file the real code produced; mock only what you cannot run (the network, a clock, a paid service).
6. **A new test is red on main before the change and green after it.** Run it against the code before your change (a worktree of the base) and keep both results as evidence. A test that was never red proves nothing.
7. **Never revert or mutate the fix to see red.** Editing, reverting or copying the code under test (or the repository's own files) to make a check fail is a planted break: it proves the edited copy, not the code. A negative case builds its own bad input.

**Root cause before a fix.** Reproduce the failure with a command that shows it, read the failing path end to end and name the cause. A fix that repairs only the instance is not done: sweep the change for the same class (rule `before-ready`). The same class failing twice means the shared code or the design is wrong: fix it there, or ask.
