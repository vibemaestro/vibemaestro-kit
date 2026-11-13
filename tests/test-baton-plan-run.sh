#!/bin/bash
# =============================================================================
# BatonRun: plan-covered runs (baton.py go --row <plan line> <baton> <args>) and the digest by plan (log --digest --plan <id>)
# =============================================================================
# Run: bash tests/test-baton-plan-run.sh
#
# The owner signs a plan once (sign --by owner --approve, through the plugin's guard and dialog; the plan read at its commit, and
# at the default branch's tip, by a fake gh serving a scratch repository as acme/app). Where plain `go` stops for the owner (exit
# 8), `go --row` runs a baton that a row of that plan declares as `run <kit:name or project:name> Stops: <words> [runs: <n>]`,
# with no other dialog, under the signature plan:<approval>/<row>/<n> held in that process, when every condition holds; anything
# else is exit 8 naming the first condition that did not hold, and nothing runs. The kit batons come from a dependent plugin
# registered beside an installed copy of the real plugin (isolated from the machine: baton_isolate), built from
# tests/fixtures/dependent-plugin under the names the plan's runs need. Families:
#   [R] a declared run with no dialog; the spent record the passphrase holder reads; Q9 (c): kit:vault-put-text and kit:script-run run;
#       the plugin moved, then its bytes changed, between the signature and a run: still covered; a run count used up
#   [N] exit 8: an undeclared baton, Stops wider than the touch, a floor word (a marked touch, one a plugin update added, one an
#       approval record holds unmarked), Q9 (c) (kit:vault-kv-copy, a project: secrets baton, marked or not), an unreviewed
#       project: baton (origin not listed; bytes not origin's blob; unpinned too: rc 3, as plain go), a dropped row, a changed row
#       cell, intent or spec (a Link cell, a new row or a Decisions line changes nothing); mode manual covered too
#   [L] exit 8: an approval expired, revoked, or signed from another directory
#   [U] exit 64: a user: baton, a session file, a kind:, stdin, a sandbox session, a malformed plan line, --row with --by or --queue
#   [C] two processes at once for the last run: one runs; a baton file changed between go's match and its run phase: refused
#   [D] log --digest by plan: each run under its approval, each row's runs left, the owner's signatures by kind
#   [H] log --digest and the passphrase holder's holds.tsv: each approval's hold lines (a serve with its run, a close, a refuse, open, end),
#       a serve under the approval whose key it names; no file, or a broken line: one line, rc 0; nothing but the columns printed
#   [row-charter] no approval, a charter for the plan's focus: a declared run with no dialog, plan:<charter>/<row>/<n>, the spent
#       record naming the charter and the touch (the one the run phase's match used, when the row moved since go's); exit 8 for
#       Stops beyond max_stops, the floor (declared unmarked too), a marked touch, a dropped row, an undeclared baton, the runs used
#       up, the plan's repository outside the charter's repos, the plan's path written with a `.` or `..` part
#   [row-charter-ended] exit 8: the charter expired, revoked, its focus closed, signed from another directory, or only another
#       focus's in force
#   [row-charter-no-repo] a plan line that names no repository reads approvals only, its output as before charters
#   [digest-charter] log --digest: a charter's runs, merges and hold lines in its own section (charter <id>), never as an approval
# Every call that must be refused goes through `capped`. No network, nothing outside the scratch tree.
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
KD_FIX="$HERE/fixtures/dependent-plugin"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
GHB="$TMP/ghbin"; mkdir -p "$GHB"                     # a fake gh: the dialog and go --row read the plan through gh api
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/merge_gh.py" > "$GHB/gh"; chmod +x "$GHB/gh"
PATH="$GHB:$PATH"; export PATH
BT_OUT="$TMP/bt.out"; SID=s-owner; C=""; S=""; D=""; W=""; ST=""; XD=""; AC=""; GID=""; RC=""; BT_ENV=()
ROW=kb/plans/p.md

# bt <dir> <baton args...> — rc of the world's baton.py from <dir>, as session SID (plus BT_ENV); output in $BT_OUT
bt() {
  local d=$1; shift
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" CLAUDE_CODE_SESSION_ID="$SID" ${BT_ENV[@]+"${BT_ENV[@]}"} \
      python3 "$S/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
out() { cat "$BT_OUT"; }
bdir() { printf '%s' "$ST/vibemaestro/baton"; }
shaf() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
# jf <json file> <key> — the key's value: a list or object as JSON, else as Python prints it (None when absent)
jf() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1])).get(sys.argv[2]); print(json.dumps(v) if isinstance(v, (list, dict)) else v)' "$1" "$2"; }
# owner_acts — the log lines of an owner act: a dialog asked, or anything signed by the owner
owner_acts() { awk -F'\t' '$2 == "owner-ask" || $8 == "owner"' "$(bdir)/log.tsv" | wc -l | tr -d ' '; }
starts() { grep -c '	run-start	' "$(bdir)/log.tsv"; }
uses() { find "$(bdir)/touches" -type f 2>/dev/null | grep -c .; }
owner_mode() { mode_asked "$S" "$W" "$ST" "$SID" "$@" >/dev/null; bt "$W" mode "$@" >/dev/null; }

# mkkit <plugin dir> <name> <Stops> [<seconds its act sleeps>] — the fixture kit (kit:fixture-kit) under that name and Stops
mkkit() {
  python3 - "$KD_FIX/batons/fixture-kit.sh" "$1/batons/$2.sh" "$2" "$3" "${4:-}" <<'PY'   # new bytes from the fixture: an input, not a break
import sys
src, dst, name, stops, nap = sys.argv[1:6]
t = open(src).read()
for old, new in (("kit:fixture-kit", "kit:" + name), ("\n# Stops: none\n", "\n# Stops: %s\n" % stops),
                 ("\nact() {\n", "\nact() {\n  sleep %s\n" % nap if nap else "\nact() {\n")):
    if old not in t:
        sys.exit("mkkit: %r is not in the fixture" % old)
    t = t.replace(old, new)
open(dst, "w").write(t)
PY
}
# kits <dir> — the dependent fixture plugin at <dir>, with the kit batons the plan's runs name
kits() {
  mkdir -p "$1/batons"; cp -r "$KD_FIX/.claude-plugin" "$1/"
  mkkit "$1" vault-put-text secrets; mkkit "$1" script-run secrets; mkkit "$1" vault-kv-copy secrets
  mkkit "$1" plan-note publish; mkkit "$1" plan-wipe irreversible-delete; mkkit "$1" plan-free none; mkkit "$1" plan-slow publish 2
  mkkit "$1" script-run-upload secrets 2
}
# the brain a charter's dialog reads its focus from (`show <P> --json`), a fake built from scratch: P8 and P9, live, with done when
FB="$TMP/brain"; mkdir -p "$FB/scripts"   # its file written from inside the directory: a fake, not a path the planner reads as the brain plugin's
( cd "$FB/scripts" && cat > brain.py ) <<'PY'
import json, sys
src = {"type": "session", "quote": "q", "where": "chat"}
items = {p: {"kind": "focus", "status": "live", "text": "focus " + p, "goal": "G1", "source": src, "done": "it shipped"} for p in ("P8", "P9")}
if sys.argv[1:2] != ["show"] or sys.argv[3:] != ["--json"] or sys.argv[2] not in items:
    sys.exit("brain: no such item")
print(json.dumps(dict(items[sys.argv[2]], id=sys.argv[2])))
PY
# reg <kits dir> — the plugin registry: the sdlc copy S, the kits plugin at <kits dir> and the brain FB
reg() {
  python3 - "$C/plugins/installed_plugins.json" "$S" "$1" "$FB" <<'PY'
import json, sys
e = lambda p: [{"scope": "user", "installPath": p, "version": "1.0.0", "installedAt": "2026-11-08T00:00:00.000Z",
                "lastUpdated": "2026-11-08T00:00:00.000Z"}]
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": e(sys.argv[2]), "dependent-fixture@vibemaestro": e(sys.argv[3]),
                                     "vibemaestro-brain@vibemaestro": e(sys.argv[4])}}, open(sys.argv[1], "w"))
PY
}
# pbaton <file> <Stops> — a kept project baton (dest=path: it creates <dest>/x), built from scratch by the params fixture
pbaton() {
  python3 "$HERE/fixtures/baton_params.py" make "$S" "$1" "dest=path" "{dest}/** — the file"
  sed -i "s/^# Stops: none\$/# Stops: $2/" "$1"   # its declared Stops: an input, not a break
}
# pmd [<X's Link>] [<Y's Must be true>] [<V's Link>] — the plan's text
pmd() {
  cat <<EOF
# Plan

Intent: kb/intent/i.md · Spec: kb/specs/s.md

## Rows

| Row | Must be true | Trust touches | Link |
|---|---|---|---|
| V | v | run kit:vault-put-text Stops: secrets runs: 3; run kit:script-run Stops: secrets | ${3:-—} |
| K | k | run kit:vault-kv-copy Stops: secrets (signs again) | — |
| N | n | run kit:plan-note Stops: none | — |
| F | f | run kit:plan-note Stops: publish; run kit:plan-wipe Stops: irreversible-delete (signs again); run kit:plan-free Stops: none | — |
| P | p | run project:pub Stops: publish; run project:sec Stops: secrets (signs again) | — |
| X | x | run kit:plan-note Stops: publish | ${1:-—} |
| Y | ${2:-y} | run kit:plan-note Stops: publish | — |
| L | l | run kit:plan-slow Stops: publish | — |
| M | m | run kit:plan-slow Stops: publish runs: 2 | — |
EOF
}
commit() { git_ -C "$W" add -A >/dev/null; git_ -C "$W" commit -q -m "${1:-c}"; }
# world [mode] — a fresh world: an installed copy of the real plugin (S) beside the kits plugin (D) in a registry; the project W, a
# git repository served as acme/app (origin a network URL whose refs hold main), with the plan, its intent and spec and two project:
# batons committed (AC); the fake gh serving W; the owner's mode (auto)
world() {
  local O
  C="$(fresh)/claude"; S="$C/plugins/cache/vibemaestro/vibemaestro-sdlc/1.0.0"; D="$C/plugins/cache/vibemaestro/dependent-fixture/1.0.0"
  mkdir -p "$(dirname "$S")"; mk_plugin_copy "$S"; kits "$D"; reg "$D"
  ST="$(fresh)/state"; XD="$(fresh)/data"; W=$(fresh); W=$(cd "$W" && pwd -P); BT_ENV=(); GID=""
  git_ init -q -b main "$W"; mkdir -p "$W/kb/plans" "$W/kb/intent" "$W/kb/specs" "$W/.vibemaestro/batons"
  printf '# Intent\n\nThe owner, verbatim: run the plan.\n' > "$W/kb/intent/i.md"
  printf '# Spec\n\n## Acceptance criteria\n\n1. `bash tests/t.sh` gives 0 fail.\n' > "$W/kb/specs/s.md"
  pmd > "$W/$ROW"
  pbaton "$W/.vibemaestro/batons/pub.sh" publish; pbaton "$W/.vibemaestro/batons/sec.sh" secrets
  commit plan; AC=$(git_ -C "$W" rev-parse HEAD)
  O="$(fresh)/origin.git"; git_ init -q --bare -b main "$O"; git_ -C "$W" remote add origin "$O"
  git_ -C "$W" push -q origin main 2>/dev/null; git_ -C "$W" fetch -q origin; git_ -C "$W" remote set-head origin main >/dev/null
  git_ -C "$W" remote set-url origin "https://example.invalid/acme/app.git"
  printf '{"repo": "acme/app", "git": {"acme/app": "%s"}, "api": {}}\n' "$W" > "$W.fx.json"; : > "$W.gh.log"
  BT_ENV=(FAKE_GH_FX="$W.fx.json" FAKE_GH_LOG="$W.gh.log")
  owner_mode "${1:-auto}"
}
# approve [life in seconds] — the owner's approval of every row of the plan at AC: the guard's dialog on the literal command
# (its decision in ASKED), then the sign; RC, and GID when it signed
approve() {
  python3 - "$W/a.json" "$AC" "${1:-86400}" <<'PY'
import json, sys, time
p, c, sec = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({"plan": [{"repo": "acme/app", "path": "kb/plans/p.md", "commit": c}],
           "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + sec))}, open(p, "w"))
PY
  ASKED=$(guard_cmd "$S" "$W" "$ST" "$SID" "python3 $S/scripts/baton.py sign --by owner --approve $W/a.json")
  RC=$(bt "$W" sign --by owner --approve "$W/a.json")
  GID=$(sed -n 's/^signed approval \([0-9a-f]\{16\}\) by owner: .*/\1/p' "$BT_OUT")
}
# unmark — the approval GID rewritten with no run touch marked or on the floor, its digest and signature computed again and a
# `grant signed` line for it: a record as a forger who knows the format writes it, so go --row's own floor check is what refuses
unmark() {
  python3 - "$(bdir)/grants/$GID.json" <<'PY' > "$TMP/unmark.sha"   # the approval record as a forger writes it: an input, not a break
import hashlib, json, sys
p = sys.argv[1]
g = json.load(open(p))
for r in g["rows"]:
    for t in r["touches"]:
        t["again"] = False
        t.pop("floor", None)
body = {k: v for k, v in g.items() if k not in ("body_sha256", "signature")}
g["body_sha256"] = g["signature"]["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
open(p, "w").write(json.dumps(g))
print(g["body_sha256"])
PY
  printf '%s\tgrant\t-\t-\t-\t-\t-\towner\t-\tsigned\t-\t%s %s\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GID" "$(cat "$TMP/unmark.sha")" \
    >> "$(bdir)/log.tsv"
}
# keep <place key> <seq> — a keep record of project:pub's bytes as they are now, built from scratch (as `pack` writes one)
keep() {
  mkdir -p "$(bdir)/kept/$1/pub"
  printf '{"sha256": "%s", "place": "project", "name": "pub", "kept_by": "local", "kept_at": "2026-11-08T00:00:00Z"}\n' \
    "$(shaf "$W/.vibemaestro/batons/pub.sh")" > "$(bdir)/kept/$1/pub/$2.json"
}
# r8 <label> <phrase> <go args...> — a call that must be refused: rc 8, the part that did not match named, nothing started
r8() {
  local label=$1 phrase=$2 n; shift 2
  n=$(starts)
  eq "$(capped bt "$W" "$@")" 8 "$label: rc 8"
  has "$(out)" "go --row: not covered by the owner's plan approval: $phrase" "$label: …named"
  eq "$(starts)" "$n" "$label: …nothing started"
}
# r64 <label> <phrase> <go args...> — a usage error: rc 64, named, nothing started
r64() {
  local label=$1 phrase=$2 n; shift 2
  n=$(starts)
  eq "$(capped bt "$W" "$@")" 64 "$label: rc 64"
  has "$(out)" "$phrase" "$label: …named"
  eq "$(starts)" "$n" "$label: …nothing started"
}

fam_run() {  # [R] one owner signature, then the declared runs with no dialog; the spent record; the plugin moved; the count
  local n rec D2
  world; approve
  eq "$ASKED/$RC" "ask/0" "[R] the owner signs every row of the plan once (the guard asks, sign --by owner --approve): rc 0"
  eq "$(capped bt "$W" go kit:vault-put-text "$W/v0" hi)" 8 "[R] control: plain go of kit:vault-put-text (Stops: secrets) stops for the owner, rc 8"
  n=$(owner_acts)
  eq "$(bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/v1" hi)" 0 "[R1] go --row V kit:vault-put-text: rc 0"
  eq "$(cat "$W/v1" 2>/dev/null)" hi "[R1] …it wrote its file"
  has "$(out)" "go: ok — 1 write — " "[R1] …one line"
  has "$(out)" " — plan:$GID/V/1" "[R1] …naming its signature plan:<approval>/V/1"
  eq "$(owner_acts)" "$n" "[R1] …no owner dialog asked and nothing signed by the owner since the plan's signature"
  eq "$(awk -F'\t' '$2 == "run" {print $8 "/" $10}' "$(bdir)/log.tsv")" "plan:$GID/V/1/ok" "[R1] …the log's run line: that signer, ok"
  eq "$(find "$(bdir)/used" -name '*.json' | grep -c .)" 1 "[R1] one spent record in used/"
  rec=$(find "$(bdir)/used" -name '*.json')
  eq "$(jf "$rec" signed_by)/$(jf "$rec" approval)/$(jf "$rec" dialog)" "plan:$GID/V/1/$GID/None" \
    "[R1] …signed_by plan:<approval>/V/1, the approval's id, no dialog id"
  eq "$(jf "$rec" v)/$(jf "$rec" stops)/$(jf "$rec" cwd)/$(jf "$rec" args)" "2/[\"secrets\"]/$W/[\"$W/v1\", \"hi\"]" \
    "[R1] …v 2, the Stops, the directory and the arguments, as an owner-signed run's record holds them"
  eq "$(jf "$rec" script_sha256)/$(jf "$rec" script_path)" "$(shaf "$D/batons/vault-put-text.sh")/$D/batons/vault-put-text.sh" \
    "[R1] …the script's sha256 and path at run time"
  case "$(basename "$rec")" in *"-$(jf "$rec" binding).json") ok "[R1] …named <stamp>-<pid>-<binding>.json, as the passphrase holder finds it";;
    *) bad "[R1] …named <stamp>-<pid>-<binding>.json, as the passphrase holder finds it ($(basename "$rec"))";; esac
  eq "$(bt "$W" go --row "$ROW#V" kit:script-run "$W/s1" hi)" 0 "[R2] Q9 (c): kit:script-run (Stops: secrets) under row V: rc 0"
  has "$(out)" " — plan:$GID/V/1" "[R2] …its own count: run 1 of kit:script-run"
  D2="$C/plugins/cache/vibemaestro/dependent-fixture/1.0.1"; cp -r "$D" "$D2"; reg "$D2"; rm -rf "$D"
  eq "$(bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/v2" hi)" 0 "[R3] the plugin moved to a new versioned directory, same bytes: covered, rc 0"
  has "$(out)" " — plan:$GID/V/2" "[R3] …run 2"
  printf '# a later release\n' >> "$D2/batons/vault-put-text.sh"
  eq "$(bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/v3" hi)" 0 "[R3] its bytes changed by an update, Stops the same: covered (no code is bound), rc 0"
  has "$(out)" " — plan:$GID/V/3" "[R3] …run 3"
  r8 "[R4] a fourth run of row V's runs: 3" "row V's runs of kit:vault-put-text are used up (3 of 3)" go --row "$ROW#V" kit:vault-put-text "$W/v4" hi
  [ ! -e "$W/v4" ] && ok "[R4] …nothing written" || bad "[R4] …nothing written"
  r8 "[R4] the second run of kit:script-run (runs 1)" "row V's runs of kit:script-run are used up (1 of 1)" go --row "$ROW#V" kit:script-run "$W/s2" hi
  BT_ENV=()
}

fam_refuse() {  # [N] what a row does not declare, or does not cover, is exit 8
  local key
  world; approve
  r8 "[N1] a baton no run touch of the row names (kit:plan-note under row V)" "row V declares no run of kit:plan-note" \
    go --row "$ROW#V" kit:plan-note "$W/n1" hi
  r8 "[N1] a row the approval does not hold (row Z)" "no approval in force signed from this directory holds row Z of kb/plans/p.md" \
    go --row "$ROW#Z" kit:plan-note "$W/n1" hi
  r8 "[N1] the row of another repository's plan" "no approval in force signed from this directory holds row V of other/repo kb/plans/p.md" \
    go --row "other/repo:$ROW#V" kit:vault-put-text "$W/n1" hi
  r8 "[N2] Stops wider than the touch (kit:plan-note, Stops publish, under row N's Stops: none)" \
    "the Stops of kit:plan-note (publish) go beyond the row's (none)" go --row "$ROW#N" kit:plan-note "$W/n2" hi
  r8 "[N3] a floor word, the touch marked: kit:plan-wipe (irreversible-delete) under row F" "row F marks the run of kit:plan-wipe (signs again)" \
    go --row "$ROW#F" kit:plan-wipe "$W/n3" hi
  r8 "[N3] Q9 (c): kit:vault-kv-copy (Stops: secrets), marked" "row K marks the run of kit:vault-kv-copy (signs again)" \
    go --row "$ROW#K" kit:vault-kv-copy "$W/n3" hi
  eq "$(bt "$W" go --row "$ROW#F" kit:plan-note "$W/f1" hi)" 0 "[N4] control: kit:plan-note (Stops publish) under row F: rc 0"
  mkkit "$D" plan-note "publish, irreversible-delete"
  r8 "[N4] a plugin update adds irreversible-delete to kit:plan-note's Stops" \
    "kit:plan-note: its Stops hold irreversible-delete, which sign again at every run" go --row "$ROW#F" kit:plan-note "$W/f2" hi
  mkkit "$D" plan-note publish
  unmark
  r8 "[N5] Q9 (c): kit:vault-kv-copy under a record that holds its touch unmarked" \
    "kit:vault-kv-copy: a secrets run of a baton outside the kit batons a plan covers" go --row "$ROW#K" kit:vault-kv-copy "$W/n5" hi
  r8 "[N5] kit:plan-wipe under a record that holds its touch unmarked" \
    "kit:plan-wipe: its Stops hold irreversible-delete, which sign again at every run" go --row "$ROW#F" kit:plan-wipe "$W/n5" hi
  bt "$W" grant revoke "$GID" >/dev/null; approve   # the forged record ends first: the next cases read one approval
  # an unreviewed project: baton: pinned by a keep record on this machine (built from scratch), origin not on the owner's list
  key=$( (cd "$W" && python3 -c 'import hashlib, os, subprocess
p = os.path.realpath(subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True).stdout.strip())
print("project-" + hashlib.sha256(p.encode()).hexdigest()[:16])') )
  keep "$key" 000001
  eq "$(capped bt "$W" go project:pub "dest=$W")" 8 "[N6] control: plain go of project:pub (pinned, Stops publish): rc 8"
  r8 "[N6] project:pub pinned, origin not on the owner's list" "project:pub is not reviewed on origin's default branch: " \
    go --row "$ROW#P" project:pub "dest=$W"
  owner_mode trust example.invalid/acme/app
  eq "$(bt "$W" go --row "$ROW#P" project:pub "dest=$W")" 0 "[N6] …origin on the owner's list, its bytes the blob of origin's main: rc 0"
  printf '# edited here\n' >> "$W/.vibemaestro/batons/pub.sh"; keep "$key" 000002
  r8 "[N6] project:pub edited here, its new bytes pinned, origin listed" \
    "project:pub is not reviewed on origin's default branch: these bytes are not the blob at .vibemaestro/batons/pub.sh on origin main" \
    go --row "$ROW#P" project:pub "dest=$W"
  printf '# edited again\n' >> "$W/.vibemaestro/batons/pub.sh"
  eq "$(capped bt "$W" go --row "$ROW#P" project:pub "dest=$W")" 3 "[N6] …edited again, these bytes neither pinned nor reviewed: rc 3, as plain go"
  has "$(out)" "project:pub: no keep record pins these bytes on this machine" "[N6] …named"
  git_ -C "$W" checkout -q -- .vibemaestro/batons/pub.sh
  r8 "[N6] Q9 (c): project:sec (Stops: secrets), reviewed, marked" "row P marks the run of project:sec (signs again)" \
    go --row "$ROW#P" project:sec "dest=$W"
  unmark
  r8 "[N6] Q9 (c): project:sec under a record that holds its touch unmarked" \
    "project:sec: a secrets run of a baton outside the kit batons a plan covers" go --row "$ROW#P" project:sec "dest=$W"
  bt "$W" grant revoke "$GID" >/dev/null; approve   # the forged record ends first: the next cases read one approval
  pmd "dropped: not needed" > "$W/$ROW"; commit drop
  r8 "[N7] row X dropped at the default branch's tip" "row X is dropped at the default branch's tip (not needed)" \
    go --row "$ROW#X" kit:plan-note "$W/x1" hi
  pmd "dropped: not needed" "y, now wider" "merged" > "$W/$ROW"
  printf '| Z9 | a new row | none | — |\n\n## Decisions\n\n- the owner: go on.\n' >> "$W/$ROW"; commit cells
  r8 "[N8] a cell of row Y changed at the tip" "the plan changed since the owner signed it (row Y's cells, at the default branch's tip): sign it again" \
    go --row "$ROW#Y" kit:plan-note "$W/y1" hi
  eq "$(bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/v1" hi)" 0 \
    "[N8] control: row V's Link cell, another row's cell, a new row and a Decisions line changed: V still covered, rc 0"
  printf '# Intent\n\nThe owner, verbatim: run the plan, now twice.\n' > "$W/kb/intent/i.md"; commit intent
  r8 "[N9] the intent changed at the tip" "the plan changed since the owner signed it (its intent kb/intent/i.md, at the default branch's tip): sign it again" \
    go --row "$ROW#V" kit:vault-put-text "$W/v2" hi
  printf '# Intent\n\nThe owner, verbatim: run the plan.\n' > "$W/kb/intent/i.md"; commit intent-back
  eq "$(bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/v2" hi)" 0 "[N9] control: the intent's bytes as signed again: rc 0"
  printf '# Spec\n\n## Acceptance criteria\n\n1. `bash tests/t.sh` gives 0 fail.\n2. a new criterion.\n' > "$W/kb/specs/s.md"; commit spec
  r8 "[N9] the spec changed at the tip" "the plan changed since the owner signed it (its spec kb/specs/s.md, at the default branch's tip): sign it again" \
    go --row "$ROW#V" kit:vault-put-text "$W/v3" hi
  BT_ENV=()
  world manual; approve
  eq "$(capped bt "$W" go kit:plan-free "$W/m0" hi)" 8 "[N10] control: mode manual, plain go of kit:plan-free (Stops: none): rc 8"
  eq "$(bt "$W" go --row "$ROW#F" kit:plan-free "$W/m1" hi)" 0 "[N10] …go --row F kit:plan-free, declared Stops: none: rc 0"
  BT_ENV=()
}

fam_life() {  # [L] an approval expired, revoked or signed from another directory covers nothing
  local W2 g1
  world; approve 30; g1=$GID
  eq "$(bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/l0" hi)" 0 "[L] control: within its life, rc 0"
  until [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \> "$(jf "$(bdir)/grants/$g1.json" expires)" ]; do sleep 1; done
  r8 "[L1] the approval expired" "no approval in force signed from this directory holds row V of kb/plans/p.md; grant $g1 expired at" go --row "$ROW#V" kit:vault-put-text "$W/l1" hi
  approve; eq "$(bt "$W" grant revoke "$GID")" 0 "[L2] a new approval, revoked: rc 0"
  r8 "[L2] the approval revoked" "no approval in force signed from this directory holds row V of kb/plans/p.md; grant " \
    go --row "$ROW#V" kit:vault-put-text "$W/l2" hi
  has "$(out)" "; grant $GID was revoked" "[L2] …the revoked one named, beside the expired one"
  approve; W2=$(fresh); W2=$(cd "$W2" && pwd -P); git_ init -q -b main "$W2"
  eq "$(capped bt "$W2" go --row "acme/app:$ROW#V" kit:vault-put-text "$W2/l3" hi)" 8 "[L3] in force, run from another directory: rc 8"
  has "$(out)" "approval $GID was signed from $W, not from $W2" "[L3] …named"
  [ ! -e "$W2/l3" ] && ok "[L3] …nothing written" || bad "[L3] …nothing written"
  BT_ENV=()
}

fam_usage() {  # [U] what go --row never runs, and its spellings: exit 64 before anything is read or run
  local B="go --row runs a kit: or project: baton that a row declares, never a user: baton, a session file or a kind:"
  world; approve
  printf '#!/usr/bin/env bash\n' > "$W/s.sh"
  r64 "[U1] a user: baton" "$B" go --row "$ROW#V" user:x
  r64 "[U1] a session file" "$B" go --row "$ROW#V" "$W/s.sh"
  r64 "[U1] a kind:" "$B" go --row "$ROW#V" kind:install-file a b
  r64 "[U1] a script from stdin" "$B" go --row "$ROW#V" -
  BT_ENV+=(VIBEMAESTRO_ROLE=worker)
  r64 "[U2] a sandbox session" "go --row in a sandbox session" go --row "$ROW#V" kit:vault-put-text "$W/u2" hi
  BT_ENV=("${BT_ENV[@]:0:2}")
  r64 "[U3] a plan line with no row" "go --row takes a plan line [<owner/repo>:]kb/plans/<file>.md#<row>" go --row "$ROW" kit:vault-put-text "$W/u3" hi
  r64 "[U3] a plan line outside kb/plans" "go --row takes a plan line" go --row "docs/p.md#V" kit:vault-put-text "$W/u3" hi
  r64 "[U3] --row=<line>" "go --row takes a plan line" go "--row=$ROW#V" kit:vault-put-text "$W/u3" hi
  r64 "[U3] --row and nothing after it" "go --row takes a plan line" go --row
  r64 "[U4] --row then --by" "--row goes first and alone (then --reuse); never with --by or --queue" go --row "$ROW#V" --by coordinator-auto kit:vault-put-text "$W/u4" hi
  r64 "[U4] --by then --row" "--row goes first and alone (then --reuse); never with --by or --queue" go --by coordinator-auto --row "$ROW#V" kit:vault-put-text "$W/u4" hi
  r64 "[U4] --queue then --row" "--row goes first and alone (then --reuse); never with --by or --queue" go --queue --row "$ROW#V" kit:vault-put-text "$W/u4" hi
  [ ! -e "$W/u2" ] && [ ! -e "$W/u3" ] && [ ! -e "$W/u4" ] && ok "[U] …nothing written" || bad "[U] …nothing written"
  BT_ENV=()
}

# race — two go --row at once for the last run of row L (kit:plan-slow: each phase sleeps 2 s, so both match before either
# takes the use); their exit codes, sorted
race() {
  ( BT_OUT="$TMP/race1.out"; bt "$W" go --row "$ROW#L" kit:plan-slow "$W/r1" hi > "$TMP/race1.rc" ) &
  ( BT_OUT="$TMP/race2.out"; bt "$W" go --row "$ROW#L" kit:plan-slow "$W/r2" hi > "$TMP/race2.rc" ) &
  wait
  sort "$TMP/race1.rc" "$TMP/race2.rc" | tr '\n' ' '
}
# swap_in_rehearse — once a phase of kit:plan-slow runs (go's rehearse, after go read the bytes), a line appended to its file
swap_in_rehearse() {
  local i=0
  while [ $i -lt 150 ] && ! ps -eo args= | grep -q 'baton-[^ ]*/plan-slow\.sh'; do sleep 0.1; i=$((i+1)); done
  printf '# swapped\n' >> "$D/batons/plan-slow.sh"
}
fam_race() {  # [C] what goes on between go's match and its run phase
  local rcs n
  world; approve
  rcs=$(capped race)
  case "$rcs" in "0 3 "|"0 8 ") ok "[C1] two go --row at once for row L's one run: one runs, the other is refused ($rcs)";;
    *) bad "[C1] two go --row at once for row L's one run: one runs, the other is refused (rcs $rcs)";; esac
  eq "$(ls "$W"/r1 "$W"/r2 2>/dev/null | grep -c .)" 1 "[C1] …exactly one wrote its file"
  eq "$(awk -F'\t' '$2 == "touches" && $10 == "used" && $3 == "kit:plan-slow"' "$(bdir)/log.tsv" | grep -c .)" 1 "[C1] …one use taken in the log"
  n=$(uses)
  swap_in_rehearse &
  eq "$(capped bt "$W" go --row "$ROW#M" kit:plan-slow "$W/m1" hi)" 3 "[C2] the baton's file changed after go matched it, before its run phase: refused, rc 3"
  wait
  has "$(out)" "run refused, nothing ran: the signature record does not match the script" "[C2] …named"
  [ ! -e "$W/m1" ] && ok "[C2] …nothing written" || bad "[C2] …nothing written"
  eq "$(uses)" "$n" "[C2] …no use taken"
  eq "$(bt "$W" go --row "$ROW#M" kit:plan-slow "$W/m2" hi)" 0 "[C2] …the same call again, the file now as read: rc 0"
  has "$(out)" " — plan:$GID/M/1" "[C2] …use 1 of row M: the refused call spent none"
  BT_ENV=()
}

fam_digest() {  # [D] log --digest by plan: each act under its approval, each row's runs left, the owner's signatures by kind
  local seal g1
  world; approve; g1=$GID
  bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/d1" hi >/dev/null
  bt "$W" go --row "$ROW#V" kit:vault-put-text "$W/d2" hi >/dev/null
  bt "$W" go --row "$ROW#V" kit:script-run "$W/d3" hi >/dev/null
  bt "$W" go --by coordinator-auto kit:plan-free "$W/d4" hi >/dev/null
  # the owner's own per-run signature, through the dialog
  bt "$W" rehearse kit:plan-note "$W/d5" hi >/dev/null; seal=$(sed -n 's/^seal \([0-9a-f.]*\) .*/\1/p' "$BT_OUT")
  owner_asked "$S" "$W" "$ST" "$SID" --by owner --seal "$seal" kit:plan-note "$W/d5" hi >/dev/null
  eq "$(bt "$W" sign --by owner --seal "$seal" kit:plan-note "$W/d5" hi)" 0 "[D] the owner signs one run of kit:plan-note: rc 0"
  # a queued item signed by the owner and a merge under the approval: log lines as they write them, inputs of the reader
  printf '%s\tqueue\tx.sh\t-\t-\t-\t-\towner\t-\tsigned\t-\tq1\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$(bdir)/log.tsv"
  printf '%s\ttouches\tkit:merge-pr\t-\t-\t["acme/app change 7 head 1234567"]\t-\tapproval:%s\t-\tused\t-\tacme/app:kb/plans/p.md@%s#v\t-\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$g1" "$AC" >> "$(bdir)/log.tsv"
  eq "$(bt "$W" log --digest --plan "$g1")" 0 "[D1] log --digest --plan <id>: rc 0"
  has "$(out)" "approval $g1: in force until " "[D1] …the approval, in force"
  has "$(out)" "  row V of acme/app kb/plans/p.md @ ${AC:0:12}: 1 of 1 PR(s) merged; run kit:vault-put-text 2 of 3 used; run kit:script-run 1 of 1 used" \
    "[D1] …row V: its PRs and each run touch's uses"
  has "$(out)" "  row K of acme/app kb/plans/p.md @ ${AC:0:12}: 0 of 1 PR(s) merged; run kit:vault-kv-copy (signs again)" "[D1] …row K: its run signs again"
  eq "$(grep -c "	plan:$g1/V/[12]	ok	-\$" "$BT_OUT")/$(grep -c "	plan:$g1/V/1	ok	-\$" "$BT_OUT")" "3/2" \
    "[D1] …its three runs, each with its signer plan:<id>/V/<n>, ok, not undone"
  has "$(out)" "	kit:merge-pr	approval:$g1	touches acme/app:kb/plans/p.md@$AC#v	-	acme/app change 7 head 1234567" \
    "[D1] …the merge under it, with the row it used and its pull request"
  hasnt "$(out)" "plan-free.sh	coordinator-auto" "[D1] …a run not under the approval is not in its digest"
  has "$(out)" "owner signatures in the window, any act: plan dialogs 1, per-run 1 (merges through kit:merge-pr 0), queued 1" "[D1] …the owner's signatures by kind"
  eq "$(bt "$W" log --digest)" 0 "[D2] log --digest: rc 0"
  has "$(out)" "plan-free.sh	coordinator-auto	ok	-" "[D2] …a run outside any plan, at the top"
  eq "$(grep -c "	plan:$g1/" "$BT_OUT")" 3 "[D2] …the plan's runs once each, under their approval"
  has "$(out)" "signers: approval 1, coordinator-auto 1, plan 3" "[D2] …a count per signer kind"
  has "$(out)" "approval $g1: in force until " "[D2] …the approval's section"
  has "$(out)" "owner signatures in the window, any act: plan dialogs 1, per-run 1 (merges through kit:merge-pr 0), queued 1" "[D2] …the owner's signatures by kind"
  eq "$(capped bt "$W" log --digest --plan 0123456789abcdef)" 66 "[D3] --plan of no approval: rc 66"
  eq "$(capped bt "$W" log --digest --plan xyz)" 64 "[D3] --plan with a malformed id: rc 64"
  has "$(out)" "usage: baton.py log --digest [--since <N>h|<N>d|YYYY-MM-DDTHH:MM:SSZ] [--plan <id>]" "[D3] …the usage line"
  BT_ENV=()
}

CROW=kb/plans/c.md
# cworld [mode] — a fresh world with c.md on W's main (its frontmatter `focus: P8`), the fake gh serving W as acme/app and acme/plans
cworld() {
  world "${1:-auto}"
  cat > "$W/$CROW" <<'EOF'
---
focus: P8
---

# Plan C

Intent: kb/intent/i.md · Spec: kb/specs/s.md

## Rows

| Row | Must be true | Trust touches | Link |
|---|---|---|---|
| V | v | run kit:vault-put-text Stops: secrets runs: 2; run kit:plan-note Stops: publish | — |
| K | k | run kit:vault-kv-copy Stops: secrets | — |
| F | f | run kit:plan-wipe Stops: irreversible-delete (signs again) | — |
| D | d | run kit:plan-note Stops: publish | dropped: not needed |
| G | g | run kit:plan-free Stops: irreversible-delete | — |
| L | l | run kit:script-run-upload Stops: secrets runs: 2 | — |
EOF
  commit "a plan of focus P8"
  printf '{"repo": "acme/app", "git": {"acme/app": "%s", "acme/plans": "%s"}, "api": {}}\n' "$W" "$W" > "$W.fx.json"
}
# csign [focus] [life in s] [dir] — the owner's charter for <focus> (P8): repos acme/app, kind baton, Stops at most secrets, a day
# (or <life>) ahead, through the guard's dialog then the click's command, from <dir> (W); ASKED, RC, and CID when it signed
csign() {
  python3 - "$W/c.json" "${1:-P8}" "${2:-86400}" <<'PY'
import json, sys, time
p, focus, life = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({"focus": focus, "repos": ["acme/app"], "kinds": ["baton"], "max_stops": ["secrets"],
           "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + life))}, open(p, "w"))
PY
  ASKED=$(owner_asked "$S" "${3:-$W}" "$ST" "$SID" --by owner --charter "$W/c.json")
  RC=$(bt "${3:-$W}" sign --by owner --charter "$W/c.json")
  CID=$(sed -n 's/^signed charter \([0-9a-f]\{16\}\) by owner: .*/\1/p' "$BT_OUT")
}
tagged() { [ "$FAIL" = "$2" ] && echo "[$1] ok" || echo "[$1] FAIL"; }   # tagged <tag> <FAIL before its checks>
NOAP="no approval in force signed from this directory holds row"

row_charter() {  # [row-charter] a run a row of a plan of the charter's focus declares, inside its envelope, with no dialog
  local T=row-charter n rec
  cworld; csign
  eq "$ASKED/$RC" "ask/0" "[$T] the owner signs one charter for P8 (acme/app, kind baton, Stops at most secrets): the guard asks, rc 0"
  n=$(owner_acts)
  eq "$(bt "$W" go --row "acme/app:$CROW#V" kit:vault-put-text "$W/c1" hi)" 0 "[$T] go --row acme/app:kb/plans/c.md#V kit:vault-put-text, no approval: rc 0"
  eq "$(cat "$W/c1" 2>/dev/null)" hi "[$T] …it wrote its file"
  has "$(out)" "go: ok — 1 write — " "[$T] …one line"
  has "$(out)" " — plan:$CID/V/1" "[$T] …naming its signature plan:<charter>/V/1"
  eq "$(owner_acts)" "$n" "[$T] …no owner dialog asked and nothing signed by the owner since the charter"
  rec=$(find "$(bdir)/used" -name '*.json')
  eq "$(jf "$rec" signed_by)/$(jf "$rec" charter)/$(jf "$rec" approval)/$(jf "$rec" dialog)" "plan:$CID/V/1/$CID/None/None" \
    "[$T] the spent record: signed_by plan:<charter>/V/1, the charter's id, no approval, no dialog"
  eq "$(jf "$rec" touch)" '{"again": false, "kind": "run", "object": null, "path": "kit:vault-put-text", "plan": "kb/plans/c.md", "repo": "acme/app", "row": "V", "runs": 2, "stops": "secrets"}' \
    "[$T] …the run touch it matched, with the plan and row that declare it (the passphrase holder reads no plan)"
  eq "$(awk -F'\t' '$2 == "touches" && $10 == "used" {print $8 "|" $12}' "$(bdir)/log.tsv")" "plan:$CID/V/1|acme/app:kb/plans/c.md#v run kit:vault-put-text" \
    "[$T] …its use logged, keyed by the plan's repository and path, the row and the baton (no commit)"
  eq "$(bt "$W" go --row "acme/app:$CROW#V" kit:vault-put-text "$W/c2" hi)" 0 "[$T] the second run: rc 0"
  has "$(out)" " — plan:$CID/V/2" "[$T] …run 2"
  r8 "[$T] a third run of the row's runs: 2" "$NOAP V of acme/app kb/plans/c.md; charter $CID for P8: row V's runs of kit:vault-put-text are used up (2 of 2)" \
    go --row "acme/app:$CROW#V" kit:vault-put-text "$W/c3" hi
  r8 "[$T] Stops publish, as the row declares, beyond max_stops" \
    "$NOAP V of acme/app kb/plans/c.md; charter $CID for P8: the run of kit:plan-note: Stops publish go beyond charter $CID's max_stops (secrets)" \
    go --row "acme/app:$CROW#V" kit:plan-note "$W/c4" hi
  r8 "[$T] a declared secrets run of a kit baton outside PLAN_SECRETS_KITS (kit:vault-kv-copy)" \
    "$NOAP K of acme/app kb/plans/c.md; charter $CID for P8: the run of kit:vault-kv-copy is the floor: a secrets run of a baton outside the kit batons a plan covers" \
    go --row "acme/app:$CROW#K" kit:vault-kv-copy "$W/c5" hi
  r8 "[$T] a run the row marks (signs again)" "$NOAP F of acme/app kb/plans/c.md; charter $CID for P8: row F marks the run of kit:plan-wipe (signs again)" \
    go --row "acme/app:$CROW#F" kit:plan-wipe "$W/c6" hi
  r8 "[$T] a row dropped at the tip" "$NOAP D of acme/app kb/plans/c.md; charter $CID for P8: row D is dropped at the default branch's tip (not needed)" \
    go --row "acme/app:$CROW#D" kit:plan-note "$W/c7" hi
  r8 "[$T] a baton no run touch of the row names" "$NOAP V of acme/app kb/plans/c.md; charter $CID for P8: row V declares no run of kit:plan-slow" \
    go --row "acme/app:$CROW#V" kit:plan-slow "$W/c8" hi
  r8 "[$T] the plan read in acme/plans, a repository the charter does not list (decision 09/11)" \
    "$NOAP V of acme/plans kb/plans/c.md; charter $CID for P8: the plan's repository acme/plans is outside its repos (acme/app)" \
    go --row "acme/plans:$CROW#V" kit:vault-put-text "$W/c9" hi
  r8 "[$T] the used-up row V named as kb/plans/./c.md (GitHub serves the same file under another use key)" \
    "$NOAP V of acme/app kb/plans/./c.md; charter $CID for P8: the plan's path kb/plans/./c.md is not written plainly (kb/plans/c.md)" \
    go --row "acme/app:kb/plans/./c.md#V" kit:vault-put-text "$W/c10" hi
  r8 "[$T] …or kb/plans/x/../c.md" \
    "$NOAP V of acme/app kb/plans/x/../c.md; charter $CID for P8: the plan's path kb/plans/x/../c.md is not written plainly (kb/plans/c.md)" \
    go --row "acme/app:kb/plans/x/../c.md#V" kit:vault-put-text "$W/c11" hi
  [ ! -e "$W/c3" ] && [ ! -e "$W/c9" ] && [ ! -e "$W/c10" ] && [ ! -e "$W/c11" ] && ok "[$T] …nothing written" || bad "[$T] …nothing written"
  BT_ENV=()
  cworld manual; csign
  eq "$(capped bt "$W" go kit:plan-free "$W/g0" hi)" 8 "[$T] control: mode manual, plain go of kit:plan-free (Stops: none): rc 8"
  r8 "[$T] a run touch the row declares on the floor, unmarked (Stops: irreversible-delete), over a baton whose Stops are none" \
    "$NOAP G of acme/app kb/plans/c.md; charter $CID for P8: the run of kit:plan-free is the floor: its Stops hold irreversible-delete, which sign again at every run" \
    go --row "acme/app:$CROW#G" kit:plan-free "$W/g1" hi
  BT_ENV=()
  cworld; csign
  move_l &
  eq "$(bt "$W" go --row "acme/app:$CROW#L" kit:script-run-upload "$W/l1" hi)" 0 \
    "[$T] row L moved at the tip (runs: 2, then 3) between go's match and its run phase's, still covering the call: rc 0"
  wait
  rec=$(find "$(bdir)/used" -name '*.json')
  eq "$(jf "$rec" touch)" '{"again": false, "kind": "run", "object": null, "path": "kit:script-run-upload", "plan": "kb/plans/c.md", "repo": "acme/app", "row": "L", "runs": 3, "stops": "secrets"}' \
    "[$T] …the spent record holds the touch the run phase's own match used (runs: 3), not go's"
  BT_ENV=()
}
# move_l — once go signed its match (its `sign` line, signer plan:…), row L of c.md at the tip says runs: 3, while the run phase's
# rehearse sleeps (kit:script-run-upload: 2 s a phase), before its own match: the plan moving under a run, an input, not a break
move_l() {
  local i=0
  while [ $i -lt 150 ] && ! awk -F'\t' '$2 == "sign" && $8 ~ /^plan:/' "$(bdir)/log.tsv" 2>/dev/null | grep -q .; do sleep 0.1; i=$((i+1)); done
  sed -i 's/^| L | l | run kit:script-run-upload Stops: secrets runs: 2 |/| L | l | run kit:script-run-upload Stops: secrets runs: 3 |/' "$W/$CROW"
  commit "row L moved"
}

row_charter_ended() {  # [row-charter-ended] a charter not in force here covers nothing
  local T=row-charter-ended a p9 W2
  cworld; csign P8 20; a=$CID                         # 20 s: the control's run ends within it on a loaded runner
  eq "$(bt "$W" go --row "acme/app:$CROW#V" kit:vault-put-text "$W/e0" hi)" 0 "[$T] control: a charter of 20 s, within its life: rc 0"
  until [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \> "$(jf "$(bdir)/grants/$a.json" expires)" ]; do sleep 1; done
  r8 "[$T] past its expiry" "$NOAP V of acme/app kb/plans/c.md; no charter in force for P8 signed from this directory; grant $a expired at " \
    go --row "acme/app:$CROW#V" kit:vault-put-text "$W/e1" hi
  csign; a=$CID; eq "$(bt "$W" grant revoke "$a")" 0 "[$T] a new charter, revoked: rc 0"
  r8 "[$T] revoked" "$NOAP V of acme/app kb/plans/c.md; no charter in force for P8 signed from this directory; grant " \
    go --row "acme/app:$CROW#V" kit:vault-put-text "$W/e2" hi
  has "$(out)" "; grant $a was revoked" "[$T] …the revoked one named"
  csign; a=$CID; eq "$(bt "$W" grant revoke --focus P8)" 0 "[$T] a new charter, then its focus closed (what the brain's op close runs: grant revoke --focus P8): rc 0"
  r8 "[$T] its focus closed" "$NOAP V of acme/app kb/plans/c.md; no charter in force for P8 signed from this directory; grant " \
    go --row "acme/app:$CROW#V" kit:vault-put-text "$W/e3" hi
  has "$(out)" "; grant $a was revoked" "[$T] …named"
  csign P9; p9=$CID; eq "$RC" 0 "[$T] a charter for another focus, P9, in force from W"
  r8 "[$T] only P9's charter in force; the plan says focus: P8" "$NOAP V of acme/app kb/plans/c.md; no charter in force for P8 signed from this directory; " \
    go --row "acme/app:$CROW#V" kit:vault-put-text "$W/e4" hi
  hasnt "$(out)" "$p9" "[$T] …P9's charter is not read"
  W2=$(fresh); git_ init -q -b main "$W2"; W2=$(cd "$W2" && pwd -P); csign P8 86400 "$W2"; a=$CID
  eq "$ASKED/$RC" "ask/0" "[$T] a charter for P8 signed from another project directory"
  r8 "[$T] in force, signed from another directory" "$NOAP V of acme/app kb/plans/c.md; no charter in force for P8 signed from this directory; " \
    go --row "acme/app:$CROW#V" kit:vault-put-text "$W/e5" hi
  has "$(out)" "charter $a was signed from $W2, not from $W" "[$T] …named"
  [ ! -e "$W/e1" ] && [ ! -e "$W/e5" ] && ok "[$T] …nothing written" || bad "[$T] …nothing written"
  BT_ENV=()
}

row_charter_no_repo() {  # [row-charter-no-repo] a charter pins no plan: a line with no repository reads approvals only (decision 09/11)
  local T=row-charter-no-repo n
  cworld; csign
  eq "$(bt "$W" go --row "acme/app:$CROW#V" kit:vault-put-text "$W/n0" hi)" 0 "[$T] control: the line names acme/app: the charter covers it, rc 0"
  has "$(out)" " — plan:$CID/V/1" "[$T] …plan:<charter>/V/1"
  n=$(starts)
  eq "$(capped bt "$W" go --row "$CROW#V" kit:vault-put-text "$W/n1" hi)" 8 "[$T] the same row, the line naming no repository: rc 8"
  eq "$(grep '^go --row: ' "$BT_OUT")" "go --row: not covered by the owner's plan approval: $NOAP V of kb/plans/c.md" \
    "[$T] …the approvals' line as before charters, no charter read"
  eq "$(starts)" "$n" "[$T] …nothing started"
  BT_ENV=()
}

digest_charter() {  # [digest-charter] log --digest lists a charter's run, merge and hold lines under the charter, never as an approval
  local T=digest-charter exp sec h a t=$'\t'
  cworld; csign; exp=$(jf "$(bdir)/grants/$CID.json" expires)
  eq "$(bt "$W" go --row "acme/app:$CROW#V" kit:vault-put-text "$W/d1" hi)" 0 "[$T] instrument: a run under the charter: rc 0"
  # a merge the guard took under the charter and a hold line the passphrase holder wrote for it: lines as they write them, inputs of the reader
  printf '%s\ttouches\tkit:merge-pr\t-\t-\t["acme/app#9 head 1234567"]\t-\tcharter:%s\t-\tused\t-\tacme/app:kb/plans/c.md#k\t-\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CID" >> "$(bdir)/log.tsv"
  h="$ST/vibemaestro/holder/holds.tsv"; mkdir -p "$(dirname "$h")"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)${t}charter-$CID${t}AAAA1111${t}serve${t}20261109T100100Z-4242" > "$h"
  eq "$(bt "$W" log --digest)" 0 "[$T] log --digest: rc 0"
  sec=$(awk -v h="charter $CID: " 'index($0, h) == 1 {on = 1; print; next} on && /^(approval |charter |owner signatures)/ {on = 0} on' "$BT_OUT")
  has "$sec" "charter $CID: in force until $exp, focus P8, signed " "[$T] …the charter's own section: its state, expiry and focus"
  has "$sec" "${t}plan:$CID/V/1${t}ok${t}-" "[$T] …its run in that section, signed plan:<charter>/V/1"
  has "$sec" "${t}kit:merge-pr${t}charter:$CID${t}touches acme/app:kb/plans/c.md#k${t}-${t}acme/app#9 head 1234567" "[$T] …its merge, with the PR"
  has "$sec" "  hold${t}" "[$T] …its hold line"
  has "$sec" "${t}serve${t}20261109T100100Z-4242" "[$T] …the run the hold served"
  hasnt "$(out)" "approval $CID" "[$T] …never listed as an approval"
  has "$(out)" "signers: charter 1, plan 1" "[$T] …a count per signer kind, the charter's merge as charter"
  eq "$(sed -n '1,/^signers: /p' "$BT_OUT" | grep -c "$CID")" 0 "[$T] …none of its acts at the top, under no record"
  eq "$(bt "$W" log --digest --plan "$CID")" 0 "[$T] log --digest --plan <charter id>: rc 0"
  eq "$(grep -c "^digest since .*, charter $CID\$" "$BT_OUT")" 1 "[$T] …its header names the charter"
  has "$(out)" "charter $CID: in force until $exp, focus P8, signed " "[$T] …and its section"
  a=$CID; csign P9; exp=$(jf "$(bdir)/grants/$CID.json" expires)
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)${t}charter-$CID${t}BBBB2222${t}open${t}until 2026-11-10T10:00:00Z" >> "$h"
  eq "$(bt "$W" log --digest)" 0 "[$T] a charter (P9) with a hold line and no act in the window: rc 0"
  has "$(out)" "charter $CID: in force until $exp, focus P9, signed " "[$T] …its own section"
  has "$(out)" "${t}open${t}until 2026-11-10T10:00:00Z" "[$T] …its hold line"
  rm "$(bdir)/grants/$a.json"                        # the P8 charter's file gone (deleted by hand): an input, not a break
  eq "$(bt "$W" log --digest)" 0 "[$T] the P8 charter's file gone, its log lines and hold line left: rc 0"
  sec=$(awk -v h="charter $a: " 'index($0, h) == 1 {on = 1; print; next} on && /^(approval |charter |owner signatures)/ {on = 0} on' "$BT_OUT")
  has "$sec" "charter $a: absent (no grant $a)" "[$T] …a section that names it a charter, absent"
  has "$sec" "${t}plan:$a/V/1${t}ok${t}-" "[$T] …its run under it"
  has "$sec" "${t}serve${t}20261109T100100Z-4242" "[$T] …its hold line under it"
  hasnt "$(out)" "approval $a" "[$T] …never an approval"
  BT_ENV=()
}

fam_charter() {  # [row-*] go --row under a focus charter, after the approvals; [digest-charter] the digest
  local f0
  f0=$FAIL; row_charter; tagged row-charter "$f0"
  f0=$FAIL; row_charter_ended; tagged row-charter-ended "$f0"
  f0=$FAIL; row_charter_no_repo; tagged row-charter-no-repo "$f0"
  f0=$FAIL; digest_charter; tagged digest-charter "$f0"
}

fam_holds() {  # [H] log --digest lists each approval's hold lines from holds.tsv, a file the passphrase holder writes (never a value)
  local g1 g2 h t=$'\t' T1=2026-11-09T10:0
  world; approve; g1=$GID; approve 3600; g2=$GID
  ne "$g1" "$g2" "[digest-holds] control: two approvals in force"
  h="$ST/vibemaestro/holder/holds.tsv"; mkdir -p "$(dirname "$h")"
  mkdir "$ST/vibemaestro/empty"                      # a sibling directory with no holds.tsv is not a second log
  printf '%s\n' "${T1}1:30Z${t}approval-$g1${t}AAAA1111${t}serve${t}run-in-state" > "$(bdir)/holds.tsv"   # inside the baton state: not beside it
  { printf '%s\n' "${T1}0:00Z${t}approval-$g1${t}AAAA1111${t}open${t}until 2026-11-10T10:00:00Z"
    printf '%s\n' "${T1}1:00Z${t}approval-$g1${t}AAAA1111${t}serve${t}20261109T100100Z-4242"
    printf '%s\n' "${T1}2:00Z${t}approval-$g2${t}BBBB2222${t}serve${t}20261109T100200Z-4343"
    printf '%s\n' "${T1}3:00Z${t}approval-$g1${t}AAAA1111${t}close${t}20261109T100300Z-4444"
    printf '%s\n' "${T1}4:00Z${t}approval-$g1${t}AAAA1111${t}refuse${t}pid 4545 runs below the script of a run step (pid 4444)"
    printf '%s\n' "${T1}5:00Z${t}approval-$g1${t}AAAA1111${t}end${t}the deadline"
    printf '%s\n' "${T1}6:00Z${t}approval-$g1${t}AAAA1111${t}take${t}hunter2"
    printf '%s\n' "${T1}7:00Z${t}approval-$g1${t}AAAA1111${t}serve${t}run-9${t}hunter3"
    printf 'half a line\n'; } > "$h"
  eq "$(bt "$W" log --digest --plan "$g1" --since 9999d)" 0 "[digest-holds] approval 1: rc 0"
  has "$(out)" "  hold${t}${T1}0:00Z${t}open${t}until 2026-11-10T10:00:00Z" "[digest-holds] …its hold's open line"
  hasnt "$(out)" "run-in-state" "[digest-holds] …a holds.tsv inside the baton state directory is not read"
  has "$(out)" "  hold${t}${T1}1:00Z${t}serve${t}20261109T100100Z-4242" "[digest-holds] …the run it served"
  has "$(out)" "  hold${t}${T1}3:00Z${t}close${t}20261109T100300Z-4444" "[digest-holds] …a closed run"
  has "$(out)" "  hold${t}${T1}4:00Z${t}refuse${t}pid 4545 runs below the script of a run step (pid 4444)" "[digest-holds] …a refusal"
  has "$(out)" "  hold${t}${T1}5:00Z${t}end${t}the deadline" "[digest-holds] …its end line"
  hasnt "$(out)" "4343" "[digest-holds] …a serve of approval 2 is not under approval 1"
  hasnt "$(out)" "AAAA1111" "[digest-holds] …the key's fingerprint is not printed"
  hasnt "$(out)" "hunter" "[digest-holds] …a line with an unknown event or an extra column is not printed"
  has "$(out)" "passphrase holds: 3 line(s) of holds.tsv unreadable, not listed" "[digest-holds] …the broken lines counted in one line"
  eq "$(bt "$W" log --digest --plan "$g2" --since 9999d)" 0 "[digest-holds] approval 2: rc 0"
  has "$(out)" "  hold${t}${T1}2:00Z${t}serve${t}20261109T100200Z-4343" "[digest-holds] …its own serve"
  hasnt "$(out)" "4242" "[digest-holds] …nothing of approval 1"
  eq "$(bt "$W" log --digest --since 9999d)" 0 "[digest-holds] every approval: rc 0"
  eq "$(grep -c "^  hold${t}" "$BT_OUT")" 6 "[digest-holds] …the six hold lines of the two approvals, once each"
  eq "$(bt "$W" log --digest --plan "$g1" --since 2026-11-09T11:00:00Z)" 0 "[digest-holds] a window that starts after all of them: rc 0"
  hasnt "$(out)" "  hold${t}" "[digest-holds] …no hold line outside the window"
  eq "$(bt "$W" log --digest --plan "$g1" --since 2026-11-09T10:03:30Z)" 0 "[digest-holds] a window that cuts the file in two: rc 0"
  has "$(out)" "  hold${t}${T1}4:00Z${t}refuse${t}" "[digest-holds] …a line after its start is listed"
  hasnt "$(out)" "  hold${t}${T1}1:00Z${t}serve${t}" "[digest-holds] …a line before its start is not"
  # a second file: an approval that ended (no act in the window, not in force), CRLF, a time that is not one, a long detail, an escape
  { printf '%s\n' "${T1}9:00Z${t}approval-0123456789abcdef${t}CCCC3333${t}end${t}the deadline"
    printf '%s\r\n' "${T1}8:00Z${t}approval-$g2${t}BBBB2222${t}end${t}the deadline"
    printf '%s\n' "not-a-time-hunter4${t}approval-$g2${t}BBBB2222${t}serve${t}run-1"
    printf '%s\n' "${T1}5:30Z${t}approval-$g2${t}-${t}unclosed${t}$(printf '%0300d' 0 | tr 0 a)"
    printf '%s\n' "${T1}5:40Z${t}approval-$g2${t}BBBB2222${t}refuse${t}$(printf 'pid 1\033[31m red')"; } > "$h"
  eq "$(bt "$W" log --digest --since 9999d)" 0 "[digest-holds] a second file: rc 0"
  has "$(out)" "  hold${t}${T1}9:00Z${t}end${t}the deadline" "[digest-holds] …the end line of an approval that is not in force, with no act in the window"
  has "$(out)" "approval 0123456789abcdef: absent" "[digest-holds] …under its own approval line"
  has "$(out)" "  hold${t}${T1}8:00Z${t}end${t}the deadline
" "[digest-holds] …a CRLF line without its carriage return"
  has "$(out)" "  hold${t}-${t}serve${t}run-1" "[digest-holds] …a time that is not one shown as -"
  hasnt "$(out)" "hunter4" "[digest-holds] …and not printed"
  eq "$(awk -F"$t" '$3 == "unclosed" { print $1 "/" length($4) }' "$BT_OUT")" "  hold/200" "[digest-holds] …an unclosed line, its 300-character detail cut to 200"
  has "$(out)" "pid 1\\u{1b}[31m red" "[digest-holds] …an escape in a detail written as \\u{1b}"
  rm "$h"
  eq "$(bt "$W" log --digest --plan "$g1")" 0 "[digest-holds] no holds.tsv: rc 0"
  eq "$(grep -c "passphrase holds:" "$BT_OUT")/$(grep -c "^passphrase holds: no holds.tsv to read (absent or unreadable)\$" "$BT_OUT")" "1/1" \
    "[digest-holds] …one line says so"
  mkdir "$h"
  eq "$(bt "$W" log --digest --plan "$g1")" 0 "[digest-holds] holds.tsv a directory: rc 0"
  has "$(out)" "passphrase holds: no holds.tsv to read (absent or unreadable)" "[digest-holds] …the same one line"
  rm -r "$ST/vibemaestro/holder" "$ST/vibemaestro/empty" "$(bdir)/holds.tsv"   # no directory beside the baton state holds a log at all
  eq "$(bt "$W" log --digest --plan "$g1")" 0 "[digest-holds] no directory beside the baton state: rc 0"
  eq "$(grep -c "passphrase holds:" "$BT_OUT")/$(grep -c "^passphrase holds: no holds.tsv to read (absent or unreadable)\$" "$BT_OUT")" "1/1" \
    "[digest-holds] …one line says so"
  mkdir "$ST/vibemaestro/holder" "$ST/vibemaestro/other"   # two directories each hold one: neither is read
  printf '%s\n' "${T1}1:00Z${t}approval-$g1${t}AAAA1111${t}serve${t}run-in-holder" > "$ST/vibemaestro/holder/holds.tsv"
  printf '%s\n' "${T1}2:00Z${t}approval-$g1${t}BBBB2222${t}serve${t}run-in-other" > "$ST/vibemaestro/other/holds.tsv"
  eq "$(bt "$W" log --digest --plan "$g1")" 0 "[digest-holds] two directories beside the baton state each hold a holds.tsv: rc 0"
  eq "$(grep -c "passphrase holds:" "$BT_OUT")/$(grep -c "^passphrase holds: 2 holds.tsv files beside the baton state, none read\$" "$BT_OUT")" "1/1" \
    "[digest-holds] …one line says so"
  hasnt "$(out)" "run-in-" "[digest-holds] …neither file's lines are listed"
  hasnt "$(out)" "  hold${t}" "[digest-holds] …no hold line at all"
  rm -r "$ST/vibemaestro/other"; ln -s holder "$ST/vibemaestro/alias"   # a link to the holder's directory: one file, read once
  eq "$(bt "$W" log --digest --plan "$g1" --since 9999d)" 0 "[digest-holds] a link beside the baton state to the holder's directory: rc 0"
  has "$(out)" "  hold${t}${T1}1:00Z${t}serve${t}run-in-holder" "[digest-holds] …the one file is read, once"
  rm "$ST/vibemaestro/alias"; ln -s "$(bdir)" "$ST/vibemaestro/alias"   # a link to the baton state: its holds.tsv is not beside it
  printf '%s\n' "${T1}1:30Z${t}approval-$g1${t}AAAA1111${t}serve${t}run-in-state" > "$(bdir)/holds.tsv"
  eq "$(bt "$W" log --digest --plan "$g1" --since 9999d)" 0 "[digest-holds] a link beside the baton state to the baton state: rc 0"
  has "$(out)" "  hold${t}${T1}1:00Z${t}serve${t}run-in-holder" "[digest-holds] …the holder's file is read"
  hasnt "$(out)" "run-in-state" "[digest-holds] …the baton state's own holds.tsv is not"
  rm "$ST/vibemaestro/alias"
  # the baton state's holds.tsv a link to a file outside it: still the state's, not beside it; the holder's file is read
  mv "$(bdir)/holds.tsv" "$ST/outside.tsv"; ln -s "$ST/outside.tsv" "$(bdir)/holds.tsv"
  eq "$(bt "$W" log --digest --plan "$g1" --since 9999d)" 0 "[digest-holds] the baton state's holds.tsv a link to a file outside: rc 0"
  has "$(out)" "  hold${t}${T1}1:00Z${t}serve${t}run-in-holder" "[digest-holds] …the holder's file is read"
  hasnt "$(out)" "run-in-state" "[digest-holds] …the linked file in the state is not"
  # the holder's holds.tsv a link to a file in the baton state: the holder's directory is beside it, so its log is read
  rm "$(bdir)/holds.tsv" "$ST/vibemaestro/holder/holds.tsv"; mv "$ST/outside.tsv" "$(bdir)/kept.tsv"
  ln -s "$(bdir)/kept.tsv" "$ST/vibemaestro/holder/holds.tsv"
  eq "$(bt "$W" log --digest --plan "$g1" --since 9999d)" 0 "[digest-holds] the holder's holds.tsv a link into the baton state: rc 0"
  has "$(out)" "  hold${t}${T1}1:30Z${t}serve${t}run-in-state" "[digest-holds] …the log it links to is read, as the holder's"
  rm "$ST/vibemaestro/holder/holds.tsv" "$(bdir)/kept.tsv"
  BT_ENV=()
}

FAMILIES="fam_run fam_refuse fam_life fam_usage fam_race fam_digest fam_holds fam_charter"
for f in ${ONLY:-$FAMILIES}; do echo "-- $f"; "$f"; done

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
