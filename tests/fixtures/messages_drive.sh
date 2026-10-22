# shellcheck shell=bash
# =============================================================================
# The printing paths of the sdlc scripts, driven once per language (sourced by tests/test-messages-language.sh)
# =============================================================================
#   drive <plugin dir> <vi|en> <out dir>
#       runs every case below on throw-away repositories under <out dir>/s and writes <out dir>/<case>.txt: what the command
#       printed (stdout and stderr together), then `rc=N`. `en` gives each repository `"language": "en"`; `vi` gives it no
#       language key (a repository that needs other keys gets them without `language`). Paths of the scratch root and of the
#       plugin, and git SHAs, are normalised, so the output of two runs (and of two machines) compares byte for byte.
#       <out dir>/<case>.data, when present, holds input lines the messages of that case quote (the user's own words)
# Each case is one message path of `kb.py`, `intent-branch.sh` (and its core), `open-pr.sh` (and its core), the current-state
# check, the config loader's deprecation note and `pr_evidence.py`. Needs lib.sh and ports.sh (git_, cenv) sourced first.
# =============================================================================

# _dr_repo <name> [extra config fields] — a repository with the config of the mode, a seed commit and kb/intent/
_dr_repo() {
  local d="$DR_S/$1" extra=${2:-} cfg
  git_ init -q -b main "$d"
  mkdir -p "$d/kb/intent"; : > "$d/kb/intent/.keep"; echo seed > "$d/seed.txt"
  if [ -n "$DR_LANG" ] || [ -n "$extra" ]; then
    mkdir -p "$d/.vibemaestro"
    cfg="{\"schema\": 1"; [ -n "$DR_LANG" ] && cfg="$cfg, $DR_LANG"; [ -n "$extra" ] && cfg="$cfg, $extra"
    printf '%s}\n' "$cfg" > "$d/.vibemaestro/sdlc.json"
  fi
  git_ -C "$d" add -A; git_ -C "$d" commit -qm seed
  printf '%s' "$d"
}
# _dr_dir <name> — a directory that is no git repository, with the config of the mode
_dr_dir() {
  local d="$DR_S/$1"; mkdir -p "$d"
  [ -z "$DR_LANG" ] || { mkdir -p "$d/.vibemaestro"; printf '{"schema": 1, %s}\n' "$DR_LANG" > "$d/.vibemaestro/sdlc.json"; }
  printf '%s' "$d"
}
# _dr_intent <repo> <slug> [issue] — kb/intent/<slug>.md with a description (and an `issue:` line), committed
_dr_intent() {
  { printf -- '---\n'; [ -z "${3:-}" ] || printf 'issue: %s\n' "$3"; printf 'description: "A demo intent"\n---\n\n# Demo\n\nWords.\n'; } > "$1/kb/intent/$2.md"
  git_ -C "$1" add -A; git_ -C "$1" commit -qm "intent $2"
}
# _dr <case> <dir> <command…> — run under cenv from <dir>; the output and the rc land in <out>/<case>.raw
_dr() {
  local c=$1 d=$2; shift 2
  (cd "$d" && cenv "$@") > "$DR_OUT/$c.raw" 2>&1
  echo "rc=$?" >> "$DR_OUT/$c.raw"
}

drive() {
  local P=$1 mode=$2 R W O G NOGH f
  DR_OUT=$3; DR_S="$3/s"; mkdir -p "$DR_S"
  DR_LANG=""; [ "$mode" = en ] && DR_LANG='"language": "en"'
  local K="$P/scripts/kb.py" IB="$P/scripts/intent-branch.sh" IBC="$P/scripts/intent_branch.py" OP="$P/scripts/open-pr.sh"

  # a fake gh (FAKE_GH=fail: the issue call is refused; junk: it prints no URL; no case creates an issue) and a PATH with no gh
  G="$DR_S/ghbin"; mkdir -p "$G"
  cat > "$G/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "label create") exit 0;;
  "issue create") case "${FAKE_GH:-}" in
                    fail) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1;;
                    junk) echo "created"; exit 0;;
                  esac; exit 1;;
  *) exit 1;;
esac
GH
  chmod +x "$G/gh"
  NOGH="$DR_S/nogh"; mkdir -p "$NOGH"
  for f in bash sh env git python3 dirname sed grep head cat; do ln -s "$(command -v "$f")" "$NOGH/$f"; done

  # ── kb.py ──────────────────────────────────────────────────────────────────────────────────
  R=$(_dr_repo kb)
  _dr kb-usage "$R" python3 -B "$K"
  _dr kb-usage-word "$R" python3 -B "$K" frob
  _dr kb-date "$R" python3 -B "$K" new intent x --date 2026-1-1
  _dr kb-new-usage "$R" python3 -B "$K" new intent
  _dr kb-new-kind "$R" python3 -B "$K" new frob x
  _dr kb-new-slug "$R" python3 -B "$K" new intent Bad_Slug
  _dr kb-new-nodir "$R" python3 -B "$K" new spec x
  _dr kb-check-usage "$R" python3 -B "$K" check spec
  _dr kb-check-what "$R" python3 -B "$K" check frob x
  mkdir -p "$R/kb/specs"; printf '# Only a title\n' > "$R/kb/specs/2026-01-01-bad.md"
  _dr kb-check-spec-fail "$R" python3 -B "$K" check spec 2026-01-01-bad
  _dr kb-cs-missing "$R" python3 -B "$K" check current-state
  : > "$R/kb/current-state.md"
  _dr kb-cs-empty "$R" python3 -B "$K" check current-state
  O=$(_dr_dir kb-norepo)
  _dr kb-norepo "$O" python3 -B "$K" new intent x
  _dr kb-norepo-find "$O" python3 -B "$K" find x
  # the current-state check: the history signs (not a PR number: the public-tree check reads it as one), the size caps, a long
  # line, and the lines this branch added over origin/main
  R=$(_dr_repo cs); O="$DR_S/cs-origin.git"; git_ init -q --bare "$O"; git_ -C "$R" remote add origin "$O"
  printf '# State\n\nThe app runs.\n' > "$R/kb/current-state.md"; git_ -C "$R" add -A; git_ -C "$R" commit -qm cs; git_ -C "$R" push -q origin main
  git_ -C "$R" fetch -q origin
  { printf '# State\n\nThe app runs.\n'
    printf 'On 2026-10-11.\nSince 2026/10/11.\nOn 11/10.\nIn tháng 10 năm 2026.\nOn ngày 11 tháng 10.\nOn ngày 5/9.\n'
    printf 'At commit abcdef1.\ntrước đây it was slow; previously too.\nCập nhật lần cuối: now.\n'
    printf '## Lịch sử\n'
    printf 'x%.0s' $(seq 1 450); printf '\n'
    for f in $(seq 1 120); do printf 'Line %s.\n' "$f"; done
  } > "$R/kb/current-state.md"
  _dr kb-cs-fail "$R" python3 -B "$K" check current-state
  grep '[^ -~]' "$R/kb/current-state.md" > "$DR_OUT/kb-cs-fail.data"   # the file's own words, which the problems quote
  R=$(_dr_repo csbyte '"current_state": {"limits": {"bytes": 100}}')
  printf '# State\n\n%s\n' "$(printf 'word %.0s' $(seq 1 40))" > "$R/kb/current-state.md"
  _dr kb-cs-bytes "$R" python3 -B "$K" check current-state
  R=$(_dr_repo dep '"pr": {"tester_exempt": {"decision": "kb/decisions/x.md"}}')
  _dr config-deprecated "$R" python3 -B "$K" config check

  # ── intent-branch.sh and its core ──────────────────────────────────────────────────────────
  R=$(_dr_repo ib)
  _dr ib-nosub "$R" bash "$IB"
  _dr ib-help "$R" bash "$IB" --help
  _dr ib-noslug "$R" bash "$IB" create-intent --slug / --no-issue
  _dr ib-slash "$R" bash "$IB" create-intent --slug a/b --no-issue
  _dr ib-nodoc "$R" bash "$IB" create-intent --slug 2026-01-01-x --base main --no-issue
  : > "$R/kb/intent/2026-01-01-empty.md"
  _dr ib-emptydoc "$R" bash "$IB" create-intent --slug 2026-01-01-empty --base main --no-issue
  _dr_intent "$R" 2026-01-01-e; git_ -C "$R" branch intent/2026-01-01-e
  _dr ib-exists "$R" bash "$IB" create-intent --slug 2026-01-01-e --base main --no-issue
  _dr_intent "$R" 2026-01-01-b
  _dr ib-nobase "$R" bash "$IB" create-intent --slug 2026-01-01-b --base nope --no-issue
  _dr_intent "$R" 2026-01-01-g1
  _dr ib-issue-nogh "$R" PATH="$NOGH" bash "$IB" create-intent --slug 2026-01-01-g1 --base main
  git_ -C "$R" checkout -q main; _dr_intent "$R" 2026-01-01-g2
  _dr ib-issue-fail "$R" PATH="$G:$PATH" FAKE_GH=fail bash "$IB" create-intent --slug 2026-01-01-g2 --base main
  git_ -C "$R" checkout -q main; _dr_intent "$R" 2026-01-01-g3
  _dr ib-issue-junk "$R" PATH="$G:$PATH" FAKE_GH=junk bash "$IB" create-intent --slug 2026-01-01-g3 --base main
  git_ -C "$R" checkout -q main
  _dr ib-retry-noslug "$R" bash "$IB" retry-issue --slug /
  _dr ib-retry-nodoc "$R" bash "$IB" retry-issue --slug 2026-01-01-none
  _dr_intent "$R" 2026-01-01-has 5
  _dr ib-retry-has "$R" bash "$IB" retry-issue --slug 2026-01-01-has
  _dr ib-retry-fail "$R" PATH="$G:$PATH" FAKE_GH=fail bash "$IB" retry-issue --slug 2026-01-01-g2
  O=$(_dr_dir ib-norepo)
  _dr ib-norepo "$O" bash "$IB" create-intent --slug 2026-01-01-x --no-issue
  # the two adapters alone, without their core: the refusals printed before python3 and the table are known to run
  mkdir -p "$DR_S/alone"; cp "$IB" "$OP" "$DR_S/alone/"
  _dr ib-nocore "$R" bash "$DR_S/alone/intent-branch.sh" create-intent --slug x
  _dr op-nocore "$R" bash "$DR_S/alone/open-pr.sh" --title t
  # worker-branch
  _dr ib-wb-nointent "$R" bash "$IB" worker-branch --intent / --name w1
  _dr ib-wb-noname "$R" bash "$IB" worker-branch --intent 2026-01-01-e --name ""
  _dr ib-wb-prefix "$R" bash "$IB" worker-branch --intent 2026-01-01-e --name intent/w1
  _dr ib-wb-notip "$R" bash "$IB" worker-branch --intent 2026-01-01-nope --name w1
  git_ -C "$R" branch w-taken
  _dr ib-wb-exists "$R" bash "$IB" worker-branch --intent 2026-01-01-e --name w-taken
  _dr ib-wb-maintree "$R" bash "$IB" worker-branch --intent 2026-01-01-e --name w2
  _dr ib-wb-env "$R" GIT_DIR="$R/.git" bash "$IB" worker-branch --intent 2026-01-01-e --name w3
  # integrate: an origin, the intent branch on it, a worker's linked worktree on a branch cut from it
  R=$(_dr_repo int); O="$DR_S/int-origin.git"; git_ init -q --bare "$O"; git_ -C "$R" remote add origin "$O"
  _dr_intent "$R" 2026-01-01-i; git_ -C "$R" push -q origin main; git_ -C "$R" push -q origin main:refs/heads/intent/2026-01-01-i
  git_ -C "$R" fetch -q origin
  W="$R/.claude/worktrees/w"; git_ -C "$R" worktree add -q -b feat "$W" origin/intent/2026-01-01-i
  echo a > "$W/a.txt"; git_ -C "$W" add a.txt; git_ -C "$W" commit -qm "feat: a"
  _dr ib-int-env "$W" GIT_DIR="$R/.git" bash "$IB" integrate --intent 2026-01-01-i --to origin
  _dr ib-int-nointent "$W" bash "$IB" integrate --intent / --to origin
  _dr ib-int-maintree "$R" bash "$IB" integrate --intent 2026-01-01-i --to origin
  _dr ib-int-self "$W" bash "$IB" integrate --intent 2026-01-01-i --branch intent/2026-01-01-i --to origin --no-fetch
  _dr ib-int-protected "$W" bash "$IB" integrate --intent 2026-01-01-i --branch main --to origin --no-fetch
  _dr ib-int-nobranch "$W" bash "$IB" integrate --intent 2026-01-01-i --branch nope --to origin --no-fetch
  _dr ib-int-notip "$W" bash "$IB" integrate --intent 2026-01-01-zz --to origin --no-fetch
  # the tip moves (a conflicting change), so feat is behind it
  W2="$R/.claude/worktrees/w2"; git_ -C "$R" worktree add -q -b other "$W2" origin/intent/2026-01-01-i
  echo b > "$W2/a.txt"; git_ -C "$W2" add a.txt; git_ -C "$W2" commit -qm "feat: b"; git_ -C "$W2" push -q origin other:refs/heads/intent/2026-01-01-i
  git_ -C "$W" fetch -q origin
  _dr ib-int-norebase "$W" bash "$IB" integrate --intent 2026-01-01-i --to origin --no-fetch --no-rebase
  _dr ib-int-conflict "$W" bash "$IB" integrate --intent 2026-01-01-i --to origin --no-fetch
  # a branch with two commits over its cut point: the adapter's rc 8 text
  W3="$R/.claude/worktrees/w3"; git_ -C "$R" worktree add -q -b two "$W3" origin/intent/2026-01-01-i
  echo 1 > "$W3/c.txt"; git_ -C "$W3" add c.txt; git_ -C "$W3" commit -qm "feat: c1"
  echo 2 > "$W3/c.txt"; git_ -C "$W3" add c.txt; git_ -C "$W3" commit -qm "feat: c2"
  _dr ib-int-twocommits "$W3" bash "$IB" integrate --intent 2026-01-01-i --to origin --no-fetch
  # --to local while another worktree holds the intent branch; --to origin with a remote that refuses
  W4="$R/.claude/worktrees/w4"; git_ -C "$R" worktree add -q "$W4" -b intent/2026-01-01-i origin/intent/2026-01-01-i
  W5="$R/.claude/worktrees/w5"; git_ -C "$R" worktree add -q -b five "$W5" origin/intent/2026-01-01-i
  echo 5 > "$W5/e.txt"; git_ -C "$W5" add e.txt; git_ -C "$W5" commit -qm "feat: e"
  _dr ib-int-held "$W5" bash "$IB" integrate --intent 2026-01-01-i --to local --no-fetch
  git_ -C "$W5" remote set-url origin "$DR_S/no-such-origin.git"
  _dr ib-int-push "$W5" bash "$IB" integrate --intent 2026-01-01-i --to origin --no-fetch

  # ── open-pr.sh and its core ────────────────────────────────────────────────────────────────
  R=$(_dr_repo op); _dr_intent "$R" 2026-01-01-p 7
  W="$R/.claude/worktrees/p"; git_ -C "$R" worktree add -q -b intent/2026-01-01-p "$W" main
  printf 'What this does.\n' > "$DR_S/sum.md"; printf '$ make test\n0 fail\n' > "$DR_S/ev.md"; : > "$DR_S/empty.md"
  if [ "$mode" = en ]; then printf '## Summary\n' > "$DR_S/heading.md"; else printf '## Tóm tắt\n' > "$DR_S/heading.md"; fi
  _dr op-unknown "$W" bash "$OP" --frob
  _dr op-notitle "$W" bash "$OP"
  _dr op-nosum "$W" bash "$OP" --title t
  _dr op-noev "$W" bash "$OP" --title t --summary "$DR_S/sum.md"
  _dr op-closes "$W" bash "$OP" --title t --summary "$DR_S/sum.md" --evidence "$DR_S/ev.md" --dry-run
  _dr op-title-blank "$W" bash "$OP" --title " " --summary "$DR_S/sum.md" --evidence "$DR_S/ev.md" --dry-run
  _dr op-maintree "$R" bash "$OP" --title t --summary "$DR_S/sum.md" --evidence "$DR_S/ev.md" --dry-run
  O=$(_dr_dir op-norepo)
  _dr op-norepo "$O" bash "$OP" --title t --summary "$DR_S/sum.md" --evidence "$DR_S/ev.md" --dry-run
  _dr op-sum-missing "$W" bash "$OP" --title t --summary "$DR_S/none.md" --evidence "$DR_S/ev.md" --dry-run
  _dr op-sum-empty "$W" bash "$OP" --title t --summary "$DR_S/empty.md" --evidence "$DR_S/ev.md" --dry-run
  _dr op-sum-heading "$W" bash "$OP" --title t --summary "$DR_S/heading.md" --evidence "$DR_S/ev.md" --dry-run
  _dr op-ev-empty "$W" bash "$OP" --title t --summary "$DR_S/sum.md" --evidence "$DR_S/empty.md" --dry-run
  _dr op-head-main "$W" bash "$OP" --title t --summary "$DR_S/sum.md" --evidence "$DR_S/ev.md" --head main --dry-run
  _dr op-payload "$W" python3 -B "$P/scripts/open_pr.py" --title t --summary-file "$DR_S/sum.md" --evidence-file "$DR_S/ev.md" --dry-run --payload-out "$DR_S/no/dir/p.json"
  git_ -C "$W" checkout -q --detach
  _dr op-detached "$W" bash "$OP" --title t --summary "$DR_S/sum.md" --evidence "$DR_S/ev.md" --dry-run
  _dr op-nogh "$R" PATH="$NOGH" bash "$OP" --title t --summary "$DR_S/sum.md" --evidence "$DR_S/ev.md"

  # ── pr_evidence.py: a UI change, an E2E line with a short reason, and none at all ───────────────
  R=$(_dr_repo pe '"evidence": {"ui_paths": ["web/**"]}')
  local H; H=$(printf 'a%.0s' $(seq 40))
  printf '{"head": "%s", "files": [{"filename": "web/a.js"}], "capped": false, "base": "main", "comments": [{"url": "https://example.invalid/c/1", "author": "alice", "association": "MEMBER", "created_at": "2026-10-20T10:01:00Z", "id": 1, "body": "SHA: %s — review round 1\\nE2E không chạy: short"}]}' "$H" "$H" > "$DR_S/pe-short.json"
  printf '{"head": "%s", "files": [{"filename": "web/a.js"}], "capped": false, "base": "main", "comments": [{"url": "https://example.invalid/c/1", "author": "alice", "association": "MEMBER", "created_at": "2026-10-20T10:01:00Z", "id": 1, "body": "SHA: %s — review round 1"}]}' "$H" "$H" > "$DR_S/pe-none.json"
  _dr pe-e2e-short "$R" python3 -B "$P/gates/pr_evidence.py" --facts "$DR_S/pe-short.json" --cwd "$R"
  _dr pe-e2e-none "$R" python3 -B "$P/gates/pr_evidence.py" --facts "$DR_S/pe-none.json" --cwd "$R"

  # normalise: the plugin path, the scratch root, git SHAs (7 to 40 hex digits holding a letter and a digit), the lines git
  # itself prints after a refused rebase or push (they change with the git version), and of `--help` only the description
  # argparse wraps (its usage and option layout change with the Python version)
  for f in "$DR_OUT"/*.raw; do
    python3 - "$f" "${f%.raw}.txt" "$P" "$DR_S" <<'PY'
import re, sys
src, dst, plugin, scratch = sys.argv[1:5]
t = open(src, encoding="utf-8", errors="replace").read().replace(plugin, "<PLUGIN>").replace(scratch, "<S>")
t = re.sub(r"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}\b", "<SHA>", t)
t = "".join(ln for ln in t.splitlines(True)
            if not re.match(r"(Auto-merging |CONFLICT |Rebasing |error: could not apply |Could not apply |hint: |fatal: |Please make sure |and the repository exists\.)", ln))
if dst.endswith("/ib-help.txt"):
    blocks = t.split("\n\n")
    t = blocks[1] + "\n" + t.splitlines(True)[-1] if len(blocks) > 2 else t
open(dst, "w", encoding="utf-8").write(t)
PY
    rm -f "$f"
  done
}
