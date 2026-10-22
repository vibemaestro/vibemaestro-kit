---
applyWhen: "\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+(?:pr|issue|run|release|workflow|label|repo)(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+list\b|\b(?:[efz]?grep|rg)\b(?:[^|;&\n]|(?<=\\)\n)*\s(?:-[A-Za-z]*c[A-Za-z]*|--count)\b|\bgit(?:\s+(?:-[Cc]\s+(?:\x22[^\x22]*\x22|\x27[^\x27]*\x27|\S+)|--[\w-]+(?:=\S+)?))*\s+(?:log|rev-list|shortlog)\b(?:[^|;&\n]|(?<=\\)\n)*(?:\s(?!-)[\x22\x27]?(?:[^\s\x22\x27]*?[^\s\x22\x27/.][\x22\x27]?(?:\.\.\.?(?=[\x22\x27]?[^\s\x22\x27./])|\.\.(?=[\s|;&)\x22\x27]|$))|(?:HEAD|\$[^\s\x22\x27.]+|[^\s\x22\x27]*?/[^\s\x22\x27./]+)[\x22\x27]?\.\.\.(?=[\s|;&)\x22\x27]|$)|\.\.\.?[\x22\x27]?[^\s\x22\x27./])|[)\x60][\x22\x27]?(?:\.\.\.?[\x22\x27]?[^\s\x22\x27./]|\.\.\.?(?=[\s|;&)\x22\x27]|$)))|\bgit(?:\s+(?:-[Cc]\s+(?:\x22[^\x22]*\x22|\x27[^\x27]*\x27|\S+)|--[\w-]+(?:=\S+)?))*\s+rev-list\b(?:[^|;&\n]|(?<=\\)\n)*--count\b"
description: "Counting and listing commands answer a narrower question than they seem to: run a sure-positive control before you quote the number"
---

# Counting commands: the number is not the answer

A count or a list comes back with no sign that it was cut, is empty for the wrong reason, or counts something else. Before you quote a number, know which question the command really answered.

| Command | It answers | It is taken to answer |
|---|---|---|
| `gh pr list`, `gh issue list`, `gh run list`, ... | the first page only: `--limit` defaults to 30 (20 for `gh run list`, 50 for `gh workflow list`) | the total |
| `git log A..B`, `git rev-list --count A..B` | commits of B that A lacks: empty or 0 once B is merged into A | how many commits B had |
| `grep -c <string>`, `grep -w <term>` | lines holding that exact string on one line: a term broken over a line break of wrapped prose is missed | the concept the string stands for (code may build the string, or spell it differently), every place the term is written |

- A number from a `list` command that you will quote: pass `--limit` explicitly, above the count you expect.
- Commits of a merged branch: `gh pr view <n> --json commits`, not a range.
- A concept, not a string: read the function or block that does the work, or first run the command on one case that is certainly positive. A term scan of wrapped prose also runs over the text with whitespace collapsed, its control a planted name broken over two lines.
- A count with no control is unchecked: say so. A scan criterion that quotes its own pattern finds its own line: bracket one letter of each alternative (`A[I]O`), an optional suffix after the bracket (`templat[e]s?`: the text `template[s]?` itself holds "template").
