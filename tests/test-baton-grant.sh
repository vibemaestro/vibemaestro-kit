#!/bin/bash
# =============================================================================
# BatonRun: the owner's plan approvals (baton.py sign --by owner --approve, log --grants, grant revoke, log --digest)
# =============================================================================
# Run: bash tests/test-baton-grant.sh
#
# A plan approval (sign --by owner --approve) is the owner's record of plan rows' trust-layer touches, read at a pinned commit
# through a fake gh serving a scratch repository, signed through the same guard, dialog and record as `sign --by owner --seal`.
# It is in force only while its file is intact and its `grant signed` log line names its body; a revoke file or a revoke line
# ends it. The plan grants were removed: `go --grant` and `sign --by owner --grant` are usage errors, and a grant record left on
# disk is never in force. Each family runs on a copy of the real plugin (its baton isolated from the machine: baton_isolate).
# No network, nothing outside the scratch tree.
# =============================================================================
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT    # an input copy is read-only (0400 in a 0500 directory)
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
GHB="$TMP/ghbin"; mkdir -p "$GHB"                     # a fake gh: an approval's dialog reads plans through gh api (fam_approve)
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/merge_gh.py" > "$GHB/gh"; chmod +x "$GHB/gh"
PATH="$GHB:$PATH"; export PATH
BT_OUT="$TMP/bt.out"; ST=""; XD=""; W=""; BT_ENV=(); GID=""; SID=s-owner

# bt <plugin> <dir> <baton args...> — rc of baton from <dir> as session SID (plus BT_ENV); output in $BT_OUT. No guard.
bt() {
  local p=$1 d=$2; shift 2
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" CLAUDE_CODE_SESSION_ID="$SID" ${BT_ENV[@]+"${BT_ENV[@]}"} \
      python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
out() { cat "$BT_OUT"; }
bdir() { printf '%s' "$ST/vibemaestro/baton"; }
asked_n() { find "$(bdir)/asked" -name '*.json' 2>/dev/null | grep -c .; }
grants_n() { find "$(bdir)/grants" -maxdepth 1 -name '*.json' 2>/dev/null | grep -c .; }
gfile() { printf '%s' "$(bdir)/grants/$GID.json"; }
shaf() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
owner_mode() { mode_asked "$1" "$W" "$ST" "$SID" "$2" >/dev/null; bt "$1" "$W" mode "$2" >/dev/null; }
# setup <plugin> — a fresh state, library and project directory W (a git repository), mode manual chosen by the owner
setup() {
  ST="$(fresh)/state"; XD="$(fresh)/data"; W=$(fresh); BT_ENV=(); GID=""
  git_ init -q -b main "$W"; W=$(cd "$W" && pwd -P); owner_mode "$1" manual
}
# ask <plugin> <spec> [session] [extra JSON] — the guard on the owner's literal `sign --by owner --approve <spec>` (or ASKCMD) from W, as
# Claude Code runs it; prints the decision, keeps the dialog text in $TMP/guard.reason
ask() {
  local pl
  pl=$(python3 -c 'import json, sys
d = {"session_id": sys.argv[1], "permission_mode": "default", "cwd": sys.argv[2], "hook_event_name": "PreToolUse",
     "tool_name": "Bash", "tool_input": {"command": sys.argv[3]}}
d.update(json.loads(sys.argv[4]))
print(json.dumps(d))' "${3:-$SID}" "$W" "${ASKCMD:-python3 $1/scripts/baton.py sign --by owner --approve $2}" "${4:-{\}}")
  printf '%s' "$pl" | ( cd "$W" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" ${BT_ENV[@]+"${BT_ENV[@]}"} \
      python3 "$1/scripts/baton-guard.py" ) 2>/dev/null | python3 -c 'import json, sys
t = sys.stdin.read().strip()
o = json.loads(t)["hookSpecificOutput"] if t else {}
open(sys.argv[1], "w").write(o.get("permissionDecisionReason", ""))
print(o.get("permissionDecision", "none"))' "$TMP/guard.reason"
}
reason() { cat "$TMP/guard.reason"; }
glist() { bt "$1" "$W" log --grants >/dev/null; out; }
# poke <python on g> [rehash] — change the grant file's bytes (a forgery); rehash computes the body digest and the signature's
# copy again, as a forger who knows the format would. Builds an input for the in-force check, not a break.
poke() {
  python3 - "$(gfile)" "$@" <<'PY'
import hashlib, json, sys
p, expr = sys.argv[1], sys.argv[2]
g = json.load(open(p))
exec(expr)
if len(sys.argv) > 3:
    body = {k: v for k, v in g.items() if k not in ("body_sha256", "signature")}
    g["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    g["signature"]["body_sha256"] = g["body_sha256"]
open(p, "w").write(json.dumps(g))
PY
}
# logline <event> <result> <signed_by> <output> — one forged log.tsv line (13 fields), an input for the log reader, not a break
logline() { printf '2026-11-04T00:00:00Z\t%s\t-\t-\t-\t-\t-\t%s\t-\t%s\t-\t%s\t-\n' "$1" "$3" "$2" "$4" >> "$(bdir)/log.tsv"; }

# oldgrant <id> [expires in seconds] — a plan grant record as the removed `sign --by owner --grant` wrote one (v 1, steps, its
# digest and the owner's signature computed as the record's own fields say), and its `grant signed` log line: state left on a
# machine from before the grants were removed, built from scratch here; an input, not a break
oldgrant() {
  mkdir -p "$(bdir)/grants"
  python3 - "$(bdir)/grants/$1.json" "$1" "$W" "${2:-86400}" <<'PY' > "$TMP/oldgrant.sha"
import hashlib, json, sys, time
p, gid, w, sec = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
plan = {"repo": "acme/app", "path": "kb/plans/2026-11-03-fleet.md", "commit": "a" * 40}
g = {"v": 1, "id": gid, "plan": [plan], "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + sec)),
     "dir": w, "dir_key": "k", "env": {}, "created": "2026-11-05T00:00:00Z", "session": "s-owner",
     "steps": [{"plan": plan, "word": "kit:grant-probe", "baton": "kit:grant-probe", "args": ["under:/tmp", "=x"], "stops": [],
                "runs": 2, "tree": "t", "path": "/x"}]}
g["body_sha256"] = hashlib.sha256(json.dumps(g, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
g["signature"] = {"by": "owner", "dialog": "0" * 32, "time": "2026-11-05T00:00:00Z", "body_sha256": g["body_sha256"]}
open(p, "w").write(json.dumps(g))
print(g["body_sha256"])
PY
  logline grant signed owner "$1 $(cat "$TMP/oldgrant.sha")"
}
# setup_a <plugin> — setup, W's plan committed (its commit in AC) and the fake gh serving it
setup_a() { setup "$1"; AC=$(aplan); afx; }
# approved <plugin> [rows] [expires in seconds] — an approval of W's plan rows (default B) signed through the dialog, from W
approved() { aspec "$W/a.json" "$AC" "${2:-B}" "${3:-86400}"; aask "$1" "$W/a.json" >/dev/null; asign "$1" "$W/a.json"; }

fam_store() {  # [T] an approval is in force only while its file is intact AND its signed log line names its body
  local P=$1 g0
  setup_a "$P"; approved "$P"; g0=$(cat "$(gfile)")
  has "$(glist "$P")" "$GID  in force  approval, signed " "[T] the approval signed through the dialog: in force"
  has "$(glist "$P")" "  row B of acme/app kb/plans/p.md @ ${AC:0:12}: not merged yet" "[T] …its row"
  poke 'g["rows"][0]["row"] = "A"'
  has "$(glist "$P")" "$GID  damaged  (grant $GID is damaged: its bytes changed since the owner signed it, so it is never in force)" \
      "[T] a row changed in the file: damaged"
  printf '%s' "$g0" > "$(gfile)"; poke 'g["expires"] = "2030-01-01T00:00:00Z"' rehash
  has "$(glist "$P")" "$GID  not in force  " "[T] the expiry moved, digest and signature computed again: not in force"
  has "$(glist "$P")" "no \`grant signed\` line in the log names its body" "[T] …no signed log line names the new body"
  printf '%s' "$g0" > "$(gfile)"; poke 'g["rows"].append(dict(g["rows"][0], row="A"))' rehash
  has "$(glist "$P")" "$GID  not in force  " "[T] a row added, digest computed again: not in force"
  printf '%s' "$g0" > "$(gfile)"; poke 'g["rows"] = [1]' rehash
  eq "$(bt "$P" "$W" log --grants)" 0 "[T] rows rewritten as garbage, digest computed again: log --grants still rc 0"
  has "$(out)" "$GID  not in force  " "[T] …the approval is not in force"
  has "$(out)" "  (its rows cannot be read)" "[T] …and its rows are named unreadable"
  printf '%s' "$g0" > "$(gfile)"; poke 'del g["kind"]' rehash
  has "$(glist "$P")" "$GID  not in force  (grant $GID is a plan grant: grants were removed, so it is never in force)" \
      "[T] its kind dropped, digest computed again: read as a plan grant, not in force"
  printf '%s' "$g0" > "$(gfile)"
  has "$(glist "$P")" "$GID  in force  " "[T] the bytes the owner signed back: in force again"
  # a file nobody signed: a copy under another id
  python3 -c 'import json, sys
g = json.loads(sys.argv[1]); g["id"] = "0123456789abcdef"
open(sys.argv[2], "w").write(json.dumps(g))' "$g0" "$(bdir)/grants/0123456789abcdef.json"   # a forged file, an input not a break
  has "$(glist "$P")" "0123456789abcdef  damaged" "[T] a copy of a signed approval under another id: damaged (its id is in the body)"
  # a forged log line alone
  logline grant signed owner "fedcba9876543210 $(printf 'b%.0s' $(seq 64))"
  has "$(glist "$P")" "fedcba9876543210  absent  (no grant fedcba9876543210)" "[T] a forged grant signed line with no file: listed, absent"
  # an approval hidden while it is revoked: the revoke still lands
  mv "$(gfile)" "$TMP/hidden.json"                                # hiding the file, an input not a break
  eq "$(bt "$P" "$W" grant revoke "$GID")" 0 "[T] grant revoke of an approval whose file was moved away: rc 0 (its signed line knows it)"
  mv "$TMP/hidden.json" "$(gfile)"
  has "$(glist "$P")" "$GID  revoked  " "[T] …the file moved back: still revoked"
  eq "$(grep -c "	grant	.*	revoked	.*	$GID	" "$(bdir)/log.tsv")" 1 "[T] …through the revoke line written while it was away"
  approved "$P"
  # revoke: the file and the line each end it
  eq "$(bt "$P" "$W" grant revoke "$GID")" 0 "[T] grant revoke: rc 0"
  has "$(out)" "grant $GID revoked: kit:merge-pr's guard no longer merges under it" "[T] …one line says so"
  has "$(glist "$P")" "$GID  revoked  " "[T] …log --grants shows it revoked"
  eq "$(tail -n 1 "$(bdir)/log.tsv" | cut -f2,10,12)" "$(printf 'grant\trevoked\t%s' "$GID")" "[T] …and a grant revoked log line"
  rm -f "$(bdir)/grants/$GID.revoked"   # an un-revoke attempt: the input, not a break
  has "$(glist "$P")" "$GID  revoked  " "[T] the revoke file deleted: still revoked (the log line)"
  eq "$(bt "$P" "$W" grant revoke "$GID")/$(grep -c "	grant	.*	revoked	.*	$GID	" "$(bdir)/log.tsv")" "0/1" \
     "[T] revoke again: rc 0, no second log line"
  approved "$P"; printf 'x\t' >> "$(bdir)/log.tsv"                                # a glued fragment, an input
  eq "$(bt "$P" "$W" grant revoke "$GID")/$(tail -n 1 "$(bdir)/log.tsv" | cut -f2,10)" "0/$(printf 'grant\trevoked')" \
     "[T] revoke after an unended log fragment: its line starts a line of its own"
  rm -f "$(bdir)/grants/$GID.revoked"
  has "$(glist "$P")" "$GID  revoked  " "[T] …the revoke file deleted: still revoked"
  approved "$P"; printf 'x\t' >> "$(bdir)/log.tsv"; logline grant revoked - "$GID"   # a line glued to a fragment, an input
  has "$(glist "$P")" "$GID  revoked  " "[T] a revoke line glued after an unended fragment: still read as revoked"
  approved "$P"
  logline grant revoked - "$GID"
  has "$(glist "$P")" "$GID  revoked  " "[T] a forged revoked line: revoked (a line alone only narrows)"
  # a revoke when one record cannot be written: the other still ends the approval; neither: refused, said loudly
  if [ "$(id -u)" != 0 ]; then                    # root writes whatever the mode
    approved "$P"; chmod 400 "$(bdir)/log.tsv"    # an unwritable log, an input not a break
    eq "$(bt "$P" "$W" grant revoke "$GID")" 0 "[T] revoke with the log unwritable: rc 0"
    has "$(out)" "grant $GID: the revoke line cannot be written to the log" "[T] …it names the line it could not write"
    has "$(glist "$P")" "$GID  revoked  " "[T] …the revoke file ends the approval"
    chmod 600 "$(bdir)/log.tsv"; approved "$P"; chmod 400 "$(bdir)/log.tsv"; chmod 500 "$(bdir)/grants"
    eq "$(bt "$P" "$W" grant revoke "$GID")" 2 "[T] revoke with neither record writable: rc 2"
    has "$(out)" "grant $GID is NOT revoked: neither the log line nor the revoke file could be written" "[T] …it says the approval is not revoked"
    chmod 700 "$(bdir)/grants"; chmod 600 "$(bdir)/log.tsv"
  else
    ok "[T] revoke with the log unwritable (root: not tested)"; ok "[T] revoke with neither record writable (root: not tested)"
  fi
  BT_ENV=()
}

fam_removed() {  # [X] the plan grants were removed: a record left from before is never in force, and nothing signs or runs one
  local P=$1 G=0123456789abcdef
  setup "$P"; oldgrant "$G"
  eq "$(bt "$P" "$W" log --grants)" 0 "[X] log --grants with a plan grant left from before: rc 0"
  has "$(out)" "$G  not in force  (grant $G is a plan grant: grants were removed, so it is never in force)" \
      "[X] …the grant, signed and unexpired, is listed not in force, the removal named"
  hasnt "$(out)" "Step 1" "[X] …none of its steps is shown"
  bt "$P" "$W" log --digest >/dev/null
  has "$(out)" "approvals in force: none" "[X] log --digest: it is not among the approvals in force"
  hasnt "$(out)" "$G" "[X] …nor named anywhere in the digest"
  eq "$(bt "$P" "$W" go --grant "$G" "$HERE/fixtures/baton-positional.sh" "$W/a.txt" hello)/$([ -e "$W/a.txt" ] && echo ran || echo none)" \
     "64/none" "[X] go --grant <its id> <baton> <args>: rc 64, nothing ran"
  has "$(out)" "go --grant: the plan grants were removed" "[X] …the removal named"
  eq "$(bt "$P" "$W" go --grant=$G "$HERE/fixtures/baton-positional.sh" "$W/a.txt" hello)" 64 "[X] go --grant=<id>: rc 64"
  eq "$(BT_ENV=(VIBEMAESTRO_ROLE=worker); bt "$P" "$W" go --grant "$G" "$HERE/fixtures/baton-positional.sh" "$W/a.txt" hello)" 64 \
     "[X] go --grant in a sandbox: rc 64"
  printf '{"plan": [], "expires": "2030-01-01T00:00:00Z", "steps": []}\n' > "$W/g.json"
  eq "$(bt "$P" "$W" sign --by owner --grant "$W/g.json")/$(grants_n)" "64/1" "[X] sign --by owner --grant <absolute spec>: rc 64, nothing signed"
  has "$(out)" "sign --grant: the plan grants were removed" "[X] …the removal named"
  eq "$(bt "$P" "$W" sign --by owner --grant=$W/g.json)" 64 "[X] sign --by owner --grant=<spec>: rc 64"
  eq "$(bt "$P" "$W" sign --by coordinator-auto --grant "$W/g.json")" 64 "[X] sign --by coordinator-auto --grant: rc 64"
  ASKCMD="python3 $P/scripts/baton.py sign --by owner --grant $W/g.json" ask "$P" "$W/g.json" >/dev/null
  eq "$(asked_n)" 0 "[X] the guard on the owner's literal sign --by owner --grant: no dialog record"
  has "$(reason)" "sign --by owner --approve <absolute spec path>" "[X] …it names the shapes it asks for, none of them --grant"
  eq "$(bt "$P" "$W" grant revoke "$G")" 0 "[X] grant revoke still ends the record: rc 0"
  # the merge guard's read (approvals_for): a signed approval of row B is found; a grant record listing that row never is
  setup_a "$P"; approved "$P"; x=$GID; oldgrant fedcba9876543210
  python3 - "$(bdir)/grants/fedcba9876543210.json" "$(cat "$(gfile)")" <<'PY'   # rows of the approval copied into the grant: an input, not a break
import hashlib, json, sys
g = json.load(open(sys.argv[1])); a = json.loads(sys.argv[2])
g.update(rows=a["rows"], dir=a["dir"], dir_key=a["dir_key"])
body = {k: v for k, v in g.items() if k not in ("body_sha256", "signature")}
g["body_sha256"] = g["signature"]["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
open(sys.argv[1], "w").write(json.dumps(g))
PY
  logline grant signed owner "fedcba9876543210 $(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["body_sha256"])' "$(bdir)/grants/fedcba9876543210.json")"
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 - "$P/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import baton
found, near = baton.approvals_for("acme/app", "kb/plans/p.md", "B")
print(" ".join(g["id"] for g, _r in found) or "-", " ".join(i for i, _w in near) or "-")
PY
) 2>&1)" "$x -" "[X] approvals_for row B: only the approval; the grant record listing row B is neither found nor near"
  BT_ENV=()
}

fam_usage() {  # [U] the spellings of revoke and log --grants; no new permission rule
  local P=$1
  setup "$P"
  eq "$(bt "$P" "$W" sign --by owner --approve a.json)" 64 "[U] a relative approval spec path: rc 64"
  eq "$(bt "$P" "$W" sign --by owner --approve "$W/a.json" extra)" 64 "[U] a word after the spec: rc 64"
  eq "$(bt "$P" "$W" sign --by coordinator-auto --approve "$W/a.json")" 64 "[U] sign --by coordinator-auto --approve: rc 64"
  eq "$(bt "$P" "$W" sign --by "grant:0123456789abcdef/1" --seal x kit:grant-probe)" 64 "[U] sign --by grant:<id>/<n>: rc 64"
  eq "$(bt "$P" "$W" grant revoke)" 64 "[U] grant revoke with no id: rc 64"
  eq "$(bt "$P" "$W" grant revoke XYZ)" 64 "[U] grant revoke of a malformed id: rc 64"
  eq "$(bt "$P" "$W" grant revoke 0123456789abcdef)" 66 "[U] grant revoke of no such approval: rc 66"
  eq "$(bt "$P" "$W" grant)" 64 "[U] grant alone: rc 64"
  eq "$(bt "$P" "$W" log --grants extra)" 64 "[U] log --grants with a word after it: rc 64"
  eq "$(bt "$P" "$W" log --grants)/$(out)" "0/grants: none" "[U] log --grants with no record: rc 0, grants: none"
  bt "$P" "$W" permissions --print >/dev/null
  hasnt "$(out)" "grant" "[U] permissions --print adds no rule for approvals: nobody is asked to upgrade"
  mkdir -p "$W/cc"; printf '{}\n' > "$W/cc/settings.json"; BT_ENV=(CLAUDE_CONFIG_DIR="$W/cc")
  bt "$P" "$W" permissions --check >/dev/null
  has "$(out)" "no ask rule for \`baton sign --by owner --approve /tmp/approval.json\`" \
      "[U] no rules in force: permissions --check names the --approve spelling among the owner's ask probes"
  hasnt "$(out)" "--grant" "[U] …and no --grant probe"
  ( cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CONFIG_DIR="$W/cc" python3 "$P/scripts/baton.py" permissions --print ) > "$W/cc/settings.json" 2>/dev/null
  bt "$P" "$W" permissions --check >/dev/null
  hasnt "$(out)" "--approve" "[U] the printed rules in force: permissions --check names no --approve probe (the ask rules cover it)"
  BT_ENV=()
}

# aplan — W's plans committed on main, with their intent and spec: kb/plans/p.md (a row per refusal; its config names a planner),
# c.md (signed whole: the card), and three plans the dialog refuses whole. Prints the commit.
aplan() {
  mkdir -p "$W/kb/plans" "$W/kb/intent" "$W/kb/specs" "$W/.vibemaestro" "$W/batons"
  printf '{"merge": {"deny_globs": [], "planner": {"script": "tests/plan.py", "inputs": []}}}\n' > "$W/.vibemaestro/sdlc.json"
  printf '#!/usr/bin/env bash\n# Purpose: b\n# Stops: none\n' > "$W/batons/b.sh"
  printf '#!/usr/bin/env bash\n# Purpose: q\n# Stops: no-way-back, publish\n' > "$W/batons/q.sh"
  printf '# Intent\n\nThe owner, verbatim: sign the plan once.\n' > "$W/kb/intent/i.md"
  printf '# Spec\n\n## Tiêu chí chấp nhận\n\n1. `bash tests/t.sh` gives 0 fail.\n2. The card shows\n   what signs again.\n\n## Thiết kế\n\n3. not a criterion\n' > "$W/kb/specs/s.md"
  printf '# Spec\n\n## Mục tiêu\n\n1. a goal, no criteria\n' > "$W/kb/specs/none.md"
  python3 -c 'import sys; open(sys.argv[1], "w").write("# Spec\n\n## Acceptance criteria\n\n" + "".join("%d. criterion %d\n" % (i, i) for i in range(1, 42)))' "$W/kb/specs/big.md"
  cat > "$W/kb/plans/p.md" <<'EOF'
# Plan

Intent: kb/intent/i.md · Spec: kb/specs/s.md · Issue: #1

## Rows

| Row | Must be true | Trust touches | Link |
|---|---|---|---|
| A | a | workflow .github/workflows/x.yml; baton `batons/b.sh` Stops: secrets | — |
| B | b | none | — |
| C | c | — | — |
| D | d | workflow .github/workflows/*.yml | — |
| E | e | config .vibemaestro/sdlc.json | — |
| F | f | script tests/plan.py | — |
| G | g | workflow .github/workflows/g.yml | dropped: not needed |
| H | h | other - | — |
| I | i | magic src/y | — |
| dup | k | none | — |
| DUP | K | none | — |
| J | j | config .vibemaestro/SDLC.json | — |
| P | p | other plugins/p/.claude-plugin/p.json | — |
| R1 | r | run kit:branch-delete Stops: irreversible-delete | — |
| R2 | r | run project:copy Stops: secrets | — |
| R3 | r | run user:x Stops: none | — |
| Q | q | baton batons/q.sh Stops: publish | — |
| T | t | test src/ | — |
| RM | rm | baton batons/q.sh Stops: removed | — |
EOF
  cat > "$W/kb/plans/c.md" <<'EOF'
# Plan C

Intent: kb/intent/i.md · Spec: kb/specs/s.md

## Rows

| Row | Must be true | Trust touches | Link |
|---|---|---|---|
| A | a | workflow .github/workflows/x.yml; PRs: 3 | — |
| B | b | baton batons/b.sh Stops: secrets | — |
| V | v | run kit:vault-put-text Stops: secrets runs: 5; run kit:script-run Stops: secrets | — |
| S | s | config .vibemaestro/sdlc.json (signs again); run kit:branch-delete Stops: irreversible-delete (signs again); workflow .github/workflows/d.yml (signs again) | — |
| O | o | other src/notes.txt; test tests/fixtures/ | — |
| G | g | workflow .github/workflows/g.yml | dropped: not needed |
EOF
  printf '# Plan\n\nIssue: #1\n\n## Rows\n\n| Row | Trust touches | Link |\n|---|---|---|\n| A | none | — |\n' > "$W/kb/plans/noref.md"
  printf '# Plan\n\nIntent: kb/intent/i.md · Spec: kb/specs/none.md\n\n## Rows\n\n| Row | Trust touches | Link |\n|---|---|---|\n| A | none | — |\n' > "$W/kb/plans/nocrit.md"
  printf '# Plan\n\nIntent: kb/intent/i.md · Spec: kb/specs/big.md\n\n## Rows\n\n| Row | Trust touches | Link |\n|---|---|---|\n| A | none | — |\n' > "$W/kb/plans/big.md"
  printf '# Plan\n\nIntent: [kb/intent/i.md](kb/intent/i.md) · Spec: kb/specs/s.md\n\n## Rows\n\n| Row | Trust touches | Link |\n|---|---|---|\n| A | none | — |\n' > "$W/kb/plans/link.md"
  printf '# Plan\n\nIntent: kb/intent/i.md · Spec: kb/specs/fence.md\n\n## Rows\n\n| Row | Trust touches | Link |\n|---|---|---|\n| A | none | — |\n' > "$W/kb/plans/fence.md"
  printf '# Spec\n\n## Context\n\nA spec shows its shape:\n\n```\n## Acceptance criteria\n1. an example, not a criterion\n```\n\n## Acceptance criteria\n\n1. the real one\n' > "$W/kb/specs/fence.md"
  git_ -C "$W" add -A >/dev/null; git_ -C "$W" commit -q -m plan; git_ -C "$W" rev-parse HEAD
}
# aspec <file> <commit> <row ids, space-separated; `*` for none: every row> [expires in seconds] [plan path] — an approval spec of
# W's plan (kb/plans/p.md, or <plan path>) at that commit
aspec() {
  python3 - "$@" <<'PY'
import json, sys, time
p, commit, rows = sys.argv[1], sys.argv[2], sys.argv[3].split()
sec = int(sys.argv[4]) if len(sys.argv) > 4 else 86400
plan = {"repo": "acme/app", "path": sys.argv[5] if len(sys.argv) > 5 else "kb/plans/p.md", "commit": commit}
spec = {"plan": [plan], "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + sec))}
if rows != ["*"]:
    spec["rows"] = [{"plan": plan, "row": r} for r in rows]
json.dump(spec, open(p, "w"))
PY
}
# afx — the fake gh's fixture for W as acme/app, through BT_ENV (the dialog reads the plan and the config with `gh api`)
afx() {
  printf '{"repo": "acme/app", "git": {"acme/app": "%s"}, "api": {}}\n' "$W" > "$W.fx.json"; : > "$W.gh.log"
  BT_ENV=(FAKE_GH_FX="$W.fx.json" FAKE_GH_LOG="$W.gh.log")
}
aask() { ask "$1" "$2"; }
asign() {
  local g; RC=$(bt "$1" "$W" sign --by owner --approve "$2")
  g=$(sed -n 's/^signed approval \([0-9a-f]\{16\}\) by owner: .*/\1/p' "$BT_OUT"); [ -z "$g" ] || GID=$g
}

fam_approve() {  # [A] the owner's plan approval: the rows' touches read at the pinned commit, one dialog, one record
  local P=$1 C r why
  setup "$P"; C=$(aplan); afx
  aspec "$W/a.json" "$C" "A B"
  asign "$P" "$W/a.json"; eq "$RC/$(grants_n)" "3/0" "[A] sign --by owner --approve with no dialog record: rc 3, nothing signed"
  eq "$(aask "$P" "$W/a.json")/$(asked_n)" "ask/1" "[A] the owner's literal --approve: the guard asks and writes one record"
  has "$(reason)" "baton: the owner signs a plan approval of 2 rows:" "[A] …the dialog says it is a plan approval"
  has "$(reason)" "  Plan:     acme/app kb/plans/p.md @ ${C:0:12}
  Intent:   kb/intent/i.md sha256 $(shaf "$W/kb/intent/i.md" | cut -c1-12)
  Spec:     kb/specs/s.md sha256 $(shaf "$W/kb/specs/s.md" | cut -c1-12)
  Criteria: 1. \`bash tests/t.sh\` gives 0 fail.
            2. The card shows what signs again." "[A] …the plan at its pinned commit, its intent and spec with their sha256, the spec's criteria"
  has "$(reason)" "  Row A:
            workflow acme/app:.github/workflows/x.yml
            baton acme/app:batons/b.sh Stops: secrets (default branch: none)
  Row B: none (it changes no trust layer)" "[A] …every row with its touches, read at that commit, a baton's Stops at the default branch"
  has "$(cat "$W.gh.log")" "repos/acme/app/contents/kb/plans/p.md?ref=$C" "[A] …the plan was read through gh api at the commit"
  asign "$P" "$W/a.json"; eq "$RC/$(grants_n)/$(asked_n)" "0/1/0" "[A] the click's command: rc 0, one record, the dialog used up"
  has "$(out)" "signed approval $GID by owner: 2 rows of acme/app kb/plans/p.md, until " "[A] …one line names the approval"
  eq "$(python3 -c 'import json, sys
g = json.load(open(sys.argv[1]))
print(g["kind"], g["v"], g["dir"], [r["row"] for r in g["rows"]], g["rows"][0]["touches"][1], g["rows"][0]["prs"], g["rows"][1]["cells"],
      g["plans"][0]["spec"]["path"], g["plans"][0]["criteria"], g["signature"]["by"])' "$(gfile)")" \
     "approval 2 $W ['A', 'B'] {'again': False, 'base': 'none', 'kind': 'baton', 'object': None, 'path': 'batons/b.sh', 'repo': 'acme/app', 'runs': None, 'stops': 'secrets'} 1 [['Row', 'B'], ['Must be true', 'b'], ['Trust touches', 'none']] kb/specs/s.md ['\`bash tests/t.sh\` gives 0 fail.', 'The card shows what signs again.'] owner" \
     "[A] …the record: kind approval v 2, the directory, the rows (cells but Link, parsed touches, PRs), the spec and its criteria, the owner's signature"
  eq "$(python3 -c 'import json, sys; g = json.load(open(sys.argv[1])); print(g["plans"][0]["intent"]["sha256"], g["plans"][0]["spec"]["sha256"])' "$(gfile)")" \
     "$(shaf "$W/kb/intent/i.md") $(shaf "$W/kb/specs/s.md")" "[A] …the intent's and the spec's sha256 at the commit"
  eq "$(tail -n 1 "$(bdir)/log.tsv" | cut -f2,8,10)" "$(printf 'grant\towner\tsigned')" "[A] …and a grant signed log line"
  glist "$P" >/dev/null
  has "$(out)" "$GID  in force  approval, signed " "[A] log --grants lists it as an approval in force"
  has "$(out)" "  row A of acme/app kb/plans/p.md @ ${C:0:12}: not merged yet" "[A] …each row and whether a merge used it"
  r=$(bt "$P" "$W" go --grant "$GID" "$HERE/fixtures/baton-positional.sh" "$W/a.txt" hello)
  eq "$r/$([ -e "$W/a.txt" ] && echo ran || echo none)" "64/none" "[A] go --grant with an approval's id: rc 64, nothing ran"
  has "$(out)" "go --grant: the plan grants were removed" "[A] …named: no run is signed under an approval or a grant"
  eq "$(bt "$P" "$W" grant revoke "$GID")" 0 "[A] grant revoke ends an approval: rc 0"
  glist "$P" >/dev/null; has "$(out)" "$GID  revoked  approval, signed " "[A] …listed revoked"
  # the dialog refuses each rule, naming it, and writes no record
  for r in "D|the path is exact and relative: no glob" "I|the kind is none of script, baton" "H|other -: the path is exact and relative: no glob, space, \`:\`, \`.\` or \`..\` part, never \`-\`" \
           "E|config .vibemaestro/sdlc.json is the floor, never covered by a plan signature: it judges every later PR in acme/app" \
           "F|script tests/plan.py is the floor, never covered by a plan signature: it judges every later PR in acme/app" \
           "C|no Trust touches cell" "G|dropped at that commit (not needed)" "Z|row Z of acme/app kb/plans/p.md @ ${C:0:12}: no such row" \
           "dup|rows dup, DUP have ids equal ignoring case" "J|config .vibemaestro/SDLC.json is the floor, never covered by a plan signature: it judges every later PR" \
           "P|other plugins/p/.claude-plugin/p.json: a .claude-plugin path is the floor (it chooses the code every machine installs): mark it (signs again)" \
           "R1|run kit:branch-delete is the floor, never covered by a plan signature: its Stops hold irreversible-delete, which sign again at every run; mark it (signs again)" \
           "R2|run project:copy is the floor, never covered by a plan signature: a secrets run of a baton outside the kit batons a plan covers (vault-put-text, vault-put-file, credential-import, credential-upload, kubeconfig-install, script-run, script-run-upload)" \
           "R3|run user:x Stops: none: a run touch names one kit: or project: baton, never a user: baton" \
           "Q|baton batons/q.sh is the floor, never covered by a plan signature: its Stops drop no-way-back, which the default branch holds" \
           "T|test src/: test names test data"; do
    aspec "$W/d.json" "$C" "${r%%|*}"
    eq "$(aask "$P" "$W/d.json")/$(asked_n)" "deny/0" "[A] row ${r%%|*}: the dialog is denied, no record"
    has "$(reason)" "${r#*|}" "[A] …named: ${r#*|}"
  done
  aspec "$W/d.json" "$C" "B" $((31 * 86400))
  eq "$(aask "$P" "$W/d.json")/$(asked_n)" "deny/0" "[A] an expiry 31 days ahead: denied (Q8: at most 30 days)"
  has "$(reason)" "at most 30 days ahead" "[A] …named"
  aspec "$W/d.json" "$C" "B" $((29 * 86400)); eq "$(aask "$P" "$W/d.json")" ask "[A] control: 29 days ahead is asked"
  aspec "$W/d.json" "$C" "D"; asign "$P" "$W/d.json"
  eq "$RC/$(grants_n)" "64/1" "[A] the spec rewritten after the dialog to a glob row: sign rc 64, no record"
  has "$(out)" "the path is exact and relative" "[A] …the rule named"
  aspec "$W/d.json" "$C" "B"; eq "$(aask "$P" "$W/d.json")" ask "[A] a row with Trust touches none is approvable"
  printf '{"repo": "acme/app", "api": {}}\n' > "$W.fx.json"
  eq "$(aask "$P" "$W/d.json")/$(asked_n)" "deny/0" "[A] a plan the API cannot serve: denied, no record (and the open one voided)"
  has "$(reason)" "acme/app kb/plans/p.md @ ${C:0:12} cannot be read at its commit: not found" "[A] …named"
  BT_ENV=()
}

# drow <time> <event> <name> <signed_by> <result> <undone> [output] — one forged log.tsv line (13 fields), an input for the log reader, not a break
drow() { printf '%s\t%s\t%s\t-\t-\t-\t-\t%s\t-\t%s\t%s\t%s\t-\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:--}" >> "$(bdir)/log.tsv"; }
ago() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$1"; }

fam_grant_digest() {  # [D] log --digest lists what anyone but the owner signed in the window, hiding none of it
  local P=$1 G=0123456789abcdef x t
  setup "$P"
  drow "$(ago 3600)" run kit:d1-grant "grant:$G/2" ok -
  drow "$(ago 1800)" run kit:d1-auto coordinator-auto ok -
  drow "$(ago 600)" run kit:d1-owner owner ok -
  drow "$(ago 90000)" run kit:d1-old coordinator-auto ok -
  eq "$(bt "$P" "$W" log --digest)" 0 "[D1] log --digest: rc 0"
  has "$(out)" "kit:d1-grant	grant:$G/2	ok	-" "[D1] …the grant run, with its time, signer, result and undone"
  has "$(out)" "kit:d1-auto	coordinator-auto	ok	-" "[D1] …the coordinator-auto run"
  eq "$(grep -c '	ok	' "$BT_OUT")" 2 "[D1] …exactly two run lines"
  hasnt "$(out)" "d1-owner" "[D1] …the owner's run is not listed"
  hasnt "$(out)" "d1-old" "[D1] …the run before the window is not listed"
  hasnt "$(out)" "	owner	" "[D1] …owner-signed runs are not listed as runs"
  has "$(out)" "signers: coordinator-auto 1, grant:$G/2 1" "[D1] …a count per signer, a run signed by a removed grant under its own signer"
  has "$(out)" "approvals in force: none" "[D1] …no approval in force"
  drow "$(ago 500)" sign kit:d1-signed owner signed -
  drow "$(ago 400)" grant - owner signed -
  drow "$(ago 300)" queue kit:d1-queued owner signed -
  bt "$P" "$W" log --digest >/dev/null
  has "$(out)" "owner signatures in the window, any act: plan dialogs 1, per-run 1 (merges through kit:merge-pr 0), queued 1" "[D1] …the owner's signatures appear by kind"
  hasnt "$(out)" "d1-signed" "[D1] …and are not listed as runs"
  eq "$(bt "$P" "$W" log --digest --since 30h)/$(grep -c '	ok	' "$BT_OUT")" "0/3" "[D1] --since 30h: the 25 h old run joins"
  eq "$(bt "$P" "$W" log --digest --since 2d)/$(grep -c '	ok	' "$BT_OUT")" "0/3" "[D1] --since 2d: the same three"
  eq "$(bt "$P" "$W" log --digest --since "$(ago 1000)")/$(grep -c '	ok	' "$BT_OUT")" "0/0" "[D1] --since a UTC time: only what came after"
  # refused attempts and markers are not runs
  drow "$(ago 100)" run kit:d2-refused coordinator-auto refused -
  drow "$(ago 100)" run kit:d2-cut coordinator-auto interrupted-before-run -
  drow "$(ago 100)" grant kit:d2-used "grant:$G/1" used -
  drow "$(ago 100)" sign kit:d2-sign coordinator-auto ok -
  bt "$P" "$W" log --digest >/dev/null
  hasnt "$(out)" "d2-" "[D2] a refused run, one cut before its run phase, a grant use marker and a sign line: none listed"
  has "$(out)" "signers: coordinator-auto 1, grant:$G/2 1" "[D2] …none counted"
  # a signer of an unknown shape is shown, not hidden
  drow "$(ago 100)" run kit:d3-near coordinator-auto2 ok -
  drow "$(ago 100)" run kit:d3-grant "grant:xyz/1" run-failed yes
  bt "$P" "$W" log --digest >/dev/null
  has "$(out)" "kit:d3-near	coordinator-auto2	ok	-" "[D3] a signer that is not owner or a known shape: listed as written"
  has "$(out)" "kit:d3-grant	grant:xyz/1	run-failed	yes" "[D3] …a malformed grant signer too, with its result and undone"
  has "$(out)" "signers: coordinator-auto 1, coordinator-auto2 1, grant:$G/2 1, grant:xyz/1 1" "[D3] …and counted"
  # a time the window cannot place
  drow "garbage" run kit:d4-time coordinator-auto ok -
  printf 'junk%s\trun\tkit:d4-glued\t-\t-\t-\t-\tcoordinator-auto\t-\tok\t-\t-\t-\n' "$(ago 5000000)" >> "$(bdir)/log.tsv"
  bt "$P" "$W" log --digest >/dev/null
  has "$(out)" "garbage	kit:d4-time	coordinator-auto" "[D4] a run line whose time cannot be read: listed with the time as written"
  has "$(out)" "kit:d4-glued	coordinator-auto" "[D4] a run line with a fragment glued before it: listed, its fields read from the end"
  # the window start is inclusive
  drow 2026-01-01T00:00:10Z run kit:d5-at coordinator-auto ok -
  drow 2026-01-01T00:00:09Z run kit:d5-before coordinator-auto ok -
  bt "$P" "$W" log --digest --since 2026-01-01T00:00:10Z >/dev/null
  has "$(out)" "kit:d5-at	" "[D5] a run at the start second: listed"
  hasnt "$(out)" "d5-before" "[D5] a run one second before: not listed"
  # control characters never redraw a line
  drow "$(ago 100)" run "$(printf 'kit:d6-\033[31mred\r\\u{1b}é')" coordinator-auto ok -
  bt "$P" "$W" log --digest >/dev/null
  eq "$(grep -c 'kit:d6-' "$BT_OUT")" 1 "[D6] a name with an escape and a carriage return: one output line"
  has "$(out)" 'kit:d6-\u{1b}[31mred\u{d}\u{1b}é' "[D6] …both written as \\u{…}, the non-ASCII letter kept"
  eq "$(grep -c "$(printf '\033')" "$BT_OUT")" 0 "[D6] …no raw escape in the output"
  # the spellings
  for x in "--since 0h" "--since 5m" "--since h" "--since 24" "--since -5h" "--since 10000h" "--since 2026-11-04" \
           "--since 2026-11-04T00:00:00+07:00" "--since 2026-11-04t00:00:00z" "--since 2026-1-4T0:0:0Z" "--since ２０２６-11-04T00:00:00Z" "--since 1h --since 2h" "--since" "extra" "--since 1h extra"; do
    # shellcheck disable=SC2086
    eq "$(bt "$P" "$W" log --digest $x)/$(grep -c 'digest since' "$BT_OUT")" "64/0" "[D7] log --digest $x: rc 64, nothing printed"
  done
  has "$(out)" "usage: baton.py log --digest [--since <N>h|<N>d|YYYY-MM-DDTHH:MM:SSZ]" "[D7] …the usage line"
  # nothing to list
  setup "$P"; drow "$(ago 100)" run kit:d8-now coordinator-auto ok -
  eq "$(bt "$P" "$W" log --digest --since 2999-01-01T00:00:00Z)/$(grep -c '	ok	' "$BT_OUT")" "0/0" "[D8] --since in the future: rc 0, no run line"
  has "$(out)" "signers: none" "[D8] …signers: none"
  rm -f "$(bdir)/log.tsv"                            # no log: an input, not a break
  eq "$(bt "$P" "$W" log --digest)" 0 "[D8] no log.tsv: rc 0"
  has "$(out)" "signers: none" "[D8] …signers: none"
  # the approvals in force
  setup_a "$P"; approved "$P"; x=$GID
  approved "$P"; eq "$(bt "$P" "$W" grant revoke "$GID")" 0 "[D9] a second approval, revoked"
  approved "$P" B 3; eq "$RC" 0 "[D9] a third approval, of 3 s"; sleep 4                                   # a third, expired
  oldgrant fedcba9876543210                                                                              # a plan grant left from before
  approved "$P"; poke 'g["rows"][0]["row"] = "A"'                                                         # a fifth, rewritten: damaged
  bt "$P" "$W" log --digest >/dev/null
  eq "$(grep -c '^approvals in force:' "$BT_OUT")/$(grep -c '^grants in force:' "$BT_OUT")" "1/0" "[D9] one approvals line, no grants line"
  has "$(out)" "approvals in force: $x until " "[D9] the approval in force is listed with its expiry"
  hasnt "$(out)" "$GID" "[D9] the damaged one is not listed"
  hasnt "$(out)" "fedcba9876543210" "[D9] …nor the plan grant left from before"
  eq "$(grep -c 'approvals in force: .* until .*, ' "$BT_OUT")" 0 "[D9] …nor the revoked or the expired one: only one approval is named"
  BT_ENV=()
  # a run killed after it started has a start line and no end line
  setup "$P"
  drow "$(ago 300)" run-start kit:d11-killed coordinator-auto - - "$W/runs/k.log"
  drow "$(ago 200)" run-start kit:d11-grant-killed "grant:$G/1" - - "$W/runs/g.log"
  drow "$(ago 100)" run-start kit:d11-done coordinator-auto - - "$W/runs/d.log"
  drow "$(ago 90)" run kit:d11-done coordinator-auto ok - "$W/runs/d.log"
  drow "$(ago 80)" run-start kit:d11-cut coordinator-auto - - "$W/runs/c.log"
  drow "$(ago 70)" run kit:d11-cut coordinator-auto interrupted-before-run - "$W/runs/c.log"
  drow "$(ago 60)" run-start kit:d11-owner owner - - "$W/runs/o.log"
  bt "$P" "$W" log --digest >/dev/null
  has "$(out)" "kit:d11-killed	coordinator-auto	unfinished	-" "[D11] a coordinator-auto start with no end line: listed as unfinished"
  has "$(out)" "kit:d11-grant-killed	grant:$G/1	unfinished	-" "[D11] …a grant start too"
  eq "$(grep -c 'kit:d11-done' "$BT_OUT")" 1 "[D11] a start that has its run line: listed once, by the run line"
  has "$(out)" "kit:d11-done	coordinator-auto	ok	-" "[D11] …as ok"
  hasnt "$(out)" "d11-cut" "[D11] a start whose end is a before-run refusal: not listed"
  hasnt "$(out)" "d11-owner" "[D11] the owner's start: not listed"
  has "$(out)" "signers: coordinator-auto 2, grant:$G/1 1" "[D11] …the unfinished runs are counted"
  # reading changes nothing
  printf 'no newline' >> "$(bdir)/log.tsv"; x=$(shaf "$(bdir)/log.tsv"); t=$(tree_hash "$ST")
  eq "$(bt "$P" "$W" log --digest)/$(bt "$P" "$W" log --digest)" "0/0" "[D10] twice, the log ending in an unended line: rc 0"
  eq "$(tail -c 10 "$(bdir)/log.tsv")" "no newline" "[D10] …the unended line is left as it was"
  eq "$(shaf "$(bdir)/log.tsv")/$(tree_hash "$ST")" "$x/$t" "[D10] …log.tsv and the whole state tree are byte-identical"
}
fam_card() {  # [K] one dialog signs every row of a plan: the card shows the intent and spec, the criteria, every row, what signs again and what the owner types
  local P=$1 C
  setup "$P"; C=$(aplan); afx
  aspec "$W/a.json" "$C" "*" 86400 kb/plans/c.md
  eq "$(aask "$P" "$W/a.json")/$(asked_n)" "ask/1" "[K] a spec with no rows: the guard asks once"
  has "$(reason)" "baton: the owner signs a plan approval of 5 rows:" "[K] …every row but the dropped one"
  has "$(reason)" "  Plan:     acme/app kb/plans/c.md @ ${C:0:12}
  Intent:   kb/intent/i.md sha256 $(shaf "$W/kb/intent/i.md" | cut -c1-12)
  Spec:     kb/specs/s.md sha256 $(shaf "$W/kb/specs/s.md" | cut -c1-12)
  Criteria: 1. \`bash tests/t.sh\` gives 0 fail.
            2. The card shows what signs again.
  Row A: PRs: 3
            workflow acme/app:.github/workflows/x.yml
  Row B:
            baton acme/app:batons/b.sh Stops: secrets (default branch: none)
  Row V:
            run kit:vault-put-text Stops: secrets runs: 5
            run kit:script-run Stops: secrets runs: 1
  Row S:
            config acme/app:.vibemaestro/sdlc.json (signs again)
            run kit:branch-delete Stops: irreversible-delete runs: 1 (signs again)
            workflow acme/app:.github/workflows/d.yml (signs again)
  Row O:
            other acme/app:src/notes.txt
            test acme/app:tests/fixtures/
  Signs again (an owner merge, or the owner's dialog at each run; never under this signature):
    row S: config acme/app:.vibemaestro/sdlc.json (signs again): it judges every later PR in acme/app (the config, an adapter, the planner, a touch check's input, .vibemaestro/gates/)
    row S: run kit:branch-delete Stops: irreversible-delete runs: 1 (signs again): its Stops hold irreversible-delete, which sign again at every run
    row S: workflow acme/app:.github/workflows/d.yml (signs again): the plan marks it
  The owner types, on the passphrase holder's page, what a baton asks (a value or a file); the GPG passphrase once per approval, held at most 24 h (a kit:script-run run is closed to the hold when its script starts, and the handover's token hold, after the script, asks the owner again); kit:script-run reads a Vault field with no ask:
    row V: kit:vault-put-text, 5 run(s)
    row V: kit:script-run, 1 run(s)" "[K] …the whole card: intent, spec, criteria, rows, PRs, runs, a baton's Stops at the default branch, what signs again and why, what the owner types"
  asign "$P" "$W/a.json"; eq "$RC/$(grants_n)" "0/1" "[K] the click's command: one record"
  has "$(out)" "signed approval $GID by owner: 5 rows of acme/app kb/plans/c.md" "[K] …of every row not dropped"
  eq "$(python3 -c 'import json, sys; g = json.load(open(sys.argv[1])); print([(r["row"], r["prs"]) for r in g["rows"]], [t["runs"] for t in g["rows"][2]["touches"]])' "$(gfile)")" \
     "[('A', 3), ('B', 1), ('V', 1), ('S', 1), ('O', 1)] [5, 1]" "[K] …its rows with their PRs and a run touch's runs"
  glist "$P" >/dev/null; has "$(out)" "  row A of acme/app kb/plans/c.md @ ${C:0:12}: not merged yet" "[K] log --grants lists each row"
  # a plan the dialog refuses whole: no intent or spec named, a spec with no criteria; a long criteria list shows its count
  for r in "noref|the plan's preamble names 0 kb/intent/ path(s) after \`Intent:\`, not one" \
           "nocrit|its spec kb/specs/none.md has no acceptance criteria (numbered items under"; do
    aspec "$W/d.json" "$C" "*" 86400 "kb/plans/${r%%|*}.md"
    eq "$(aask "$P" "$W/d.json")/$(asked_n)" "deny/0" "[K] plan ${r%%|*}: the dialog is denied, no record"
    has "$(reason)" "${r#*|}" "[K] …named: ${r#*|}"
  done
  aspec "$W/d.json" "$C" "*" 86400 kb/plans/link.md
  eq "$(aask "$P" "$W/d.json")" ask "[K] an Intent: path written as a link to itself: one intent, asked"
  aspec "$W/d.json" "$C" "*" 86400 kb/plans/fence.md
  eq "$(aask "$P" "$W/d.json")" ask "[K] a spec with a fenced example of a criteria section: asked"
  has "$(reason)" "  Criteria: 1. the real one
  Row A: none" "[K] …the criteria are the section's own: a heading inside a fenced example is not one"
  hasnt "$(reason)" "an example, not a criterion" "[K] …the fenced example is not shown"
  aspec "$W/d.json" "$C" "B" 86400 kb/plans/c.md; python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); s["rows"] = None; json.dump(s, open(sys.argv[1], "w"))' "$W/d.json"
  eq "$(aask "$P" "$W/d.json")/$(asked_n)" "deny/0" "[K] a spec of plan c.md whose rows is null: denied, never read as every row"
  has "$(reason)" "the approval spec is an object of exactly plan and expires (every row of each plan), or plan, expires and rows" "[K] …named"
  aspec "$W/d.json" "$C" "RM"
  eq "$(aask "$P" "$W/d.json")" ask "[K] a baton's deletion (Stops: removed) over a default branch whose Stops hold no-way-back: no floor word dropped, asked"
  aspec "$W/d.json" "$C" "*" 86400 kb/plans/big.md
  eq "$(aask "$P" "$W/d.json")" ask "[K] a spec of 41 criteria: asked"
  has "$(reason)" "  Criteria: 41, too many to show here: read them in the spec above" "[K] …the card shows their count, not the list"
  BT_ENV=()
}
FAMILIES="fam_store fam_removed fam_usage fam_grant_digest fam_approve fam_card"
echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
