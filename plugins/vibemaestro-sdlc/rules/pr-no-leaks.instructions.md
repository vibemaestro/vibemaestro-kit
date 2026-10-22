---
applyWhen: "\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+pr(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+(?:create|edit|comment|review|merge|close|reopen)\b|\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+issue(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+(?:create|edit|comment|close|reopen)\b|\bgh\s+api\b(?=[^|;&\n]*(?:/(?:comments|pulls|issues)(?:/|\s|$)|graphql[^|;&\n]*(?i:mutation)))(?=[^|;&\n]*\s(?:-X\s*(?i:POST|PATCH|PUT)|--method[\s=]+(?i:POST|PATCH|PUT)|-[fF]|--(?:raw-)?field\b|--input\b))|open-pr\.sh|\b(?:review[-_]post|pr[-_]comment)(?:[-_][a-z]+)?\.(?:sh|py)\b|\bgit(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+commit(?![-\w])"
description: "Writing a PR body, an issue body, a PR comment, a commit message: no secret, public IP, account ID, e-mail or personal machine path; do not paste the output of a command that reads secrets; keep the PR body short"
---

# PRs and commits leak no information

A PR body, a PR comment and a commit message live long and many people read them. Before you send, check every line:

- **No** secret, token, password or private key; do not paste the output of a command that reads secrets (even trimmed).
- **No** public IP, cloud account ID, personal e-mail or anyone's machine path (`/home/<name>/…`, `/Users/<name>/…`).
- Output pasted as evidence is filtered first: keep only the lines that prove what needs proving.
- A short PR body: **what changed, why, evidence** (command + exit code + real output). Do not narrate the trial and error.
- A commit message follows the shape in rule `git-process`: subject ≤ 72 characters, body ≤ 3 sentences.

If you pushed something sensitive by mistake: treat it as leaked — revoke/rotate it first, and only then worry about removing it from history.

## Why this is checked before you type

Three kinds of text outlive the edit: GitHub keeps the edit history of a body or comment (the "edited" menu shows the old version), a commit message on the main branch cannot be rewritten, and commit messages travel with the provenance of whatever the repo publishes. Masking afterwards is late. A scanner, if the repo runs one, fires after the text is public: it is a net, not a licence to be sloppy.

| What | Why it hurts | Write instead |
|---|---|---|
| secret value, key, token | a pasted token is leaked: rotate it, and the old text stays in the edit history | the secret's name and key, or `***` |
| output of a command that reads secrets (`env`, `cat .env`, `gh auth token`, a `set -x` log) | the evidence is the secret | the conclusion only: `rc=0`, `3/3 keys present` |
| public IP of infrastructure, of a person's workstation, of a partner | a map to attack, a person's location, a third party's data | the node's name, or `<node ip>` |
| account, tenant or zone ID; a personal or service-account email | ID plus email is the first half of an account takeover | `<account_id>`, a role name |

**Safe shapes.** Judge a value by its own shape, never by nearby words such as "example" or "assume" (a scanner, if there is one, should do the same). Safe: non-global IPs (private ranges, `100.64.0.0/10`, the documentation ranges `192.0.2.x`, `198.51.100.x`, `203.0.113.x`), public DNS resolvers; a version number glued to its prefix (`tool/3.10.0.18`, `v1.25.3.1`; `version 1.25.3.1` is not); git SHAs and `sha256:` digests; `noreply` addresses and `@example.com|org|net`; placeholders (`<…>`, `${VAR}`, `***`, `xxx`); a name standing in for a value, if it has no digit (`API_KEY_FROM_STORE`); an ID with fewer than 6 distinct characters or a repeated chunk. Write examples in those shapes, not a real-looking value followed by "for example".

**Scan it yourself, and the allowlist.** Before you post a body, a comment or a commit message, write it to a file and run `python3 "${CLAUDE_PLUGIN_ROOT}/gates/pr_sensitive.py" --text < body.md`: rc 1 names each hit masked (its first 4 characters and its length), so rewrite it in a safe shape and scan again until rc 0. Only a value that is really not sensitive goes into the allowlist: the file that `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get sensitive.allowlist` prints, one line `<sha256 of the exact value>  # reason` (the scan prints the sha256 outside CI), never the value. The CI gate reads the allowlist of the base branch, so a line added in the pull request it should exempt does not count there: land it first, in its own pull request.
