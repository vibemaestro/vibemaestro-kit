#!/bin/bash
# =============================================================================
# The consumer contract: plugins/vibemaestro-sdlc/CONTRACT.md against the real tree
# =============================================================================
# Run: bash tests/test-contract.sh [<item id>]
#   no id: every item, the exactness checks, the change rule of the surface against the base branch (a change file when the base
#   has .changes/, a version bump before), and the planted breaks
#   an id (marketplace, layout, fetch-action, sandbox-env, seedable, cli, config-schema, rule-packs, dependents, local-state): that item only,
#   on the real tree
#   CONTRACT_BASE=<ref>: the base of the version-bump rule (default: merge-base of HEAD and origin/main, else the origin/main tip)
#
# The contract file is the list; this suite is its proof. Every item is a FAMILY `fam_<id> <repo copy>` that reads the values the
# contract states (facts, exit codes, config keys) and checks them against a scratch copy of this repository, behaviourally where it
# can: the fetch action's own `run` block copies, the hook output shows the sandbox, the plugin directory alone runs its hooks and
# entry points, every exit code row is produced by one trigger through the public entry point. The list is exact both ways: a row
# with no check and a check with no row are both red. Then each check is shown to go red on a copy with one planted break
# (expect_red, tests/fixtures/ports.sh), so a check that cannot fail is caught. Real git on throw-away repositories, a fake `gh`,
# the network shims of netguard.sh; no hub, no network, no `sleep`. Assertions read exit codes, files, JSON fields and outputs
# compared with each other; prose is never asserted.
#
# The version-bump rule needs the base branch. Where it does not resolve the suite prints `base check not run` and stays green
# (it is not counted as ok); CI fetches main at depth 1 so the rule runs there.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

ITEMS="marketplace layout fetch-action sandbox-env seedable cli config-schema rule-packs dependents local-state"
ONLY=${1:-}
if [ -n "$ONLY" ]; then
  case " $ITEMS " in *" $ONLY "*) ;; *) echo "usage: bash tests/test-contract.sh [$(echo "$ITEMS" | tr ' ' '|')]" >&2; exit 64;; esac
fi
CBASE=${CONTRACT_BASE:-}
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
GHB="$TMP/ghbin"; mk_gh "$GHB"
CT="$HERE/fixtures/contract.py"
PLREL=plugins/vibemaestro-sdlc

# mk_repo_copy <dir> — the files of this checkout (tracked and untracked, not ignored), without .git
mk_repo_copy() {
  mkdir -p "$1"
  git -C "$SRC_ROOT" ls-files -z -c -o --exclude-standard | (cd "$SRC_ROOT" && tar --null -T - -cf -) | tar -C "$1" -xf -
}
# cj <repo copy> <python expression on d> — a value of the contract of that copy, as JSON
cj() { python3 "$CT" json "$1/$PLREL/CONTRACT.md" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1])))' "$2"; }
# fact <repo copy> <id> <fact> — the value of one fact row (empty when absent)
fact() { python3 "$CT" json "$1/$PLREL/CONTRACT.md" | python3 -c '
import json,sys
v=[r[2] for r in json.load(sys.stdin)["facts"] if r[0]==sys.argv[1] and r[1]==sys.argv[2]]
print(v[0] if len(v)==1 else "")' "$2" "$3"; }
# facts_exact <repo copy> <id> <fact|fact|...> — the facts the contract states for <id> are exactly the ones the family checks
facts_exact() {
  local got; got=$(python3 "$CT" json "$1/$PLREL/CONTRACT.md" | python3 -c '
import json,sys
print("|".join(sorted(r[1] for r in json.load(sys.stdin)["facts"] if r[0]==sys.argv[1])))' "$2")
  eq "$got" "$(printf '%s' "$3" | tr '|' '\n' | sort | paste -sd'|' -)" "[$2] facts: the contract rows are exactly the facts this family checks"
}
# jget <file> <python expression on d> — a value of a JSON file
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
# src_of <repo copy> <plugin name> — the `source` of that plugin in the marketplace file
src_of() { jget "$1/.claude-plugin/marketplace.json" '[p["source"] for p in d["plugins"] if p["name"]=="'"$2"'"][0]'; }

# ── marketplace ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_marketplace() {
  local R=$1 name id mname pname
  facts_exact "$R" marketplace "marketplace name|plugin id"
  name=$(fact "$R" marketplace "marketplace name"); id=$(fact "$R" marketplace "plugin id")
  mname=$(jget "$R/.claude-plugin/marketplace.json" 'd["name"]')
  eq "$mname" "$name" "[marketplace] marketplace name: the marketplace file says '$name'"
  pname=$(jget "$R/$PLREL/.claude-plugin/plugin.json" 'd["name"]')
  eq "$pname@$mname" "$id" "[marketplace] plugin id: <manifest name>@<marketplace name> is '$id'"
  eq "$(jget "$R/.claude-plugin/marketplace.json" 'len([p for p in d["plugins"] if p["name"]=="'"${id%@*}"'"])')" 1 \
     "[marketplace] plugin id: the marketplace lists '${id%@*}' once"
}

# ── layout ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_layout() {
  local R=$1 mf src man
  facts_exact "$R" layout "marketplace file|plugin source|plugin manifest"
  mf=$(fact "$R" layout "marketplace file"); src=$(fact "$R" layout "plugin source"); man=$(fact "$R" layout "plugin manifest")
  [ -n "$mf" ] && [ -f "$R/$mf" ] && ok "[layout] marketplace file: '$mf' is at the repository root" || bad "[layout] marketplace file: '$mf' is missing"
  eq "$(jget "$R/.claude-plugin/marketplace.json" 'type([p["source"] for p in d["plugins"] if p["name"]=="vibemaestro-sdlc"][0]).__name__')" str \
     "[layout] plugin source: a plain string (not an object form)"
  eq "$(src_of "$R" vibemaestro-sdlc)" "$src" "[layout] plugin source: '$src'"
  eq "${src#./}/.claude-plugin/plugin.json" "$man" "[layout] plugin manifest: '<source>/.claude-plugin/plugin.json'"
  [ -n "$man" ] && [ -f "$R/$man" ] && ok "[layout] plugin manifest: present" || bad "[layout] plugin manifest: '$man' is missing"
}

# ── fetch-action ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# act <repo copy> <action file> <dest or ""> — run the action's one `run` step the way the runner does: its `env:` with
# `${{ inputs.<name> }}` replaced by the inputs given (dest=<dest>), GITHUB_ACTION_PATH the action's directory.
act() {
  local R=$1 A=$2 dest=$3
  python3 - "$A" "$dest" > "$TMP/act.env" <<'PY' || return 99
import sys, yaml, re, shlex
d = yaml.safe_load(open(sys.argv[1]))
steps = d["runs"]["steps"]; s = [x for x in steps if "run" in x][0]
inputs = {"dest": sys.argv[2]}
for k, v in (s.get("env") or {}).items():
    v = re.sub(r"\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}", lambda m: inputs.get(m.group(1), ""), str(v))
    print("export %s=%s" % (k, shlex.quote(v)))
print("RUN=%s" % shlex.quote(s["run"]))
PY
  ( . "$TMP/act.env"; cd "$TMP" && GITHUB_ACTION_PATH="$(dirname "$A")" bash -c "$RUN" ) >/dev/null 2>&1
}
fam_fetch_action() {
  local R=$1 af A D man
  facts_exact "$R" fetch-action "action file|runs|inputs|required inputs|copies"
  af=$(fact "$R" fetch-action "action file"); A="$R/$af"; man=$(fact "$R" layout "plugin manifest")
  [ -n "$af" ] && [ -f "$A" ] && ok "[fetch-action] action file: '$af' exists" || { bad "[fetch-action] action file: '$af' is missing"; return; }
  ayaml() { python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$A" "$1" 2>/dev/null; }
  eq "$(ayaml 'd["runs"]["using"]')" "$(fact "$R" fetch-action runs)" "[fetch-action] runs: '$(fact "$R" fetch-action runs)'"
  eq "$(ayaml '" ".join(sorted((d.get("inputs") or {}).keys()))')" "$(fact "$R" fetch-action inputs)" "[fetch-action] inputs: exactly '$(fact "$R" fetch-action inputs)'"
  eq "$(ayaml '" ".join(sorted(k for k,v in (d.get("inputs") or {}).items() if v.get("required") is True))')" "$(fact "$R" fetch-action "required inputs")" \
     "[fetch-action] required inputs: '$(fact "$R" fetch-action "required inputs")'"
  mkdir -p "$R/.git"; echo probe > "$R/.git/probe"
  D=$(fresh)
  act "$R" "$A" "$D/out"; eq "$?" 0 "[fetch-action] copies: the run step with dest set exits 0"
  [ -f "$D/out/.claude-plugin/marketplace.json" ] && [ -f "$D/out/$man" ] && [ -f "$D/out/$af" ] \
    && ok "[fetch-action] copies: the marketplace file, the plugin and the action land in dest" || bad "[fetch-action] copies: dest lacks the tree"
  [ ! -e "$D/out/.git" ] && ok "[fetch-action] copies: without .git" || bad "[fetch-action] copies: .git was copied"
  act "$R" "$A" ""; ne "$?" 0 "[fetch-action] required inputs: an empty dest is refused"
  rm -rf "$R/.git"
}

# ── sandbox-env ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# sess <plugin> <app> <VAR=value...> — the SessionStart hooks' output (both commands of hooks.json), session id fixed per call set
sess() {
  local P=$1 A=$2; shift 2
  ( cd "$A" && p_start s-contract | cenv CLAUDE_PROJECT_DIR="$A" CLAUDE_PLUGIN_ROOT="$P" "$@" python3 "$P/scripts/session-start.py" loi
    p_start s-contract | cenv CLAUDE_PROJECT_DIR="$A" CLAUDE_PLUGIN_ROOT="$P" "$@" python3 "$P/scripts/session-start.py" boi-canh ) 2>&1
}
fam_sandbox_env() {
  local R=$1 P="$1/$PLREL" A v1 v2 none both only1 only2 empty1 empty2
  facts_exact "$R" sandbox-env "variables"
  read -r v1 v2 <<<"$(fact "$R" sandbox-env variables)"
  A=$(mk_origin)
  none=$(sess "$P" "$A" X_UNRELATED=1)
  both=$(sess "$P" "$A" "$v1=2026-01-01-example" "$v2=example-seat")
  only1=$(sess "$P" "$A" "$v1=2026-01-01-example"); only2=$(sess "$P" "$A" "$v2=example-seat")
  empty1=$(sess "$P" "$A" "$v1=" "$v2=example-seat"); empty2=$(sess "$P" "$A" "$v1=2026-01-01-example" "$v2=")
  nonempty "$none" "[sandbox-env] instrument: the SessionStart hooks print something outside a sandbox"
  ne "$both" "$none" "[sandbox-env] variables: $v1 and $v2 both set: the hooks speak as in a sandbox"
  eq "$only1" "$none" "[sandbox-env] variables: only $v1 set: not a sandbox"
  eq "$only2" "$none" "[sandbox-env] variables: only $v2 set: not a sandbox"
  eq "$empty1" "$none" "[sandbox-env] variables: $v1 empty: not a sandbox"
  eq "$empty2" "$none" "[sandbox-env] variables: $v2 empty: not a sandbox"
}

# ── seedable ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# hook_cmds_of <plugin> — the hook commands of hooks.json, `${CLAUDE_PLUGIN_ROOT}` left in place, one per line
hook_cmds_of() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for ev, ms in d["hooks"].items():
    for m in ms:
        for h in m["hooks"]: print(ev + "\t" + h["command"])' "$1/hooks/hooks.json"
}
# payload <event> — a payload the hook would get
payload() {
  case "$1" in
    SessionStart) p_start s-contract;;
    *) p_bash s-contract "git status";;
  esac
}
# run_hook <plugin> <app> <event> <command> [stdin] — rc on the first line, then the output with the plugin path replaced by @P@
run_hook() {
  local P=$1 A=$2 ev=$3 c=$4 in=${5:-} out rc
  [ -n "$in" ] || in=$(payload "$ev")
  out=$(cd "$A" && printf '%s' "$in" | cenv CLAUDE_PROJECT_DIR="$A" CLAUDE_PLUGIN_ROOT="$P" bash -c "$c" 2>&1); rc=$?
  printf '%s\n%s' "$rc" "${out//$P/@P@}"
}
# smokes <plugin> <app> — one call per entry point, each line "<entry> <rc>"
smokes() {
  local P=$1 A=$2
  echo "scripts/intent-branch.sh $(cd "$A" && cenv PATH="$GHB:$PATH" bash "$P/scripts/intent-branch.sh" --cwd "$A" create-intent --slug 2026-01-01-none --no-issue >/dev/null 2>&1; echo $?)"
  echo "scripts/open-pr.sh $(cd "$A" && cenv PATH="$GHB:$PATH" bash "$P/scripts/open-pr.sh" --title t --summary "$A/README.md" --evidence "$A/README.md" --dry-run >/dev/null 2>&1; echo $?)"
  echo "scripts/kb.py $(cenv python3 "$P/scripts/kb.py" config check --root "$A" >/dev/null 2>&1; echo $?)"
  echo "scripts/sdlc_config.py $(cenv python3 "$P/scripts/sdlc_config.py" get schema --root "$A" >/dev/null 2>&1; echo $?)"
  echo "scripts/install_gates.py $(cenv python3 "$P/scripts/install_gates.py" --root "$A" --dry-run >/dev/null 2>&1; echo $?)"
  echo "scripts/baton.py $(cenv python3 "$P/scripts/baton.py" new smoke --dir "$(fresh)" >/dev/null 2>&1; echo $?)"
  echo "gates/commit_discipline.py $(cenv python3 "$P/gates/commit_discipline.py" origin/main HEAD --cwd "$A" >/dev/null 2>&1; echo $?)"
  echo "gates/pr_sensitive.py $(echo hello | cenv python3 "$P/gates/pr_sensitive.py" --text --cwd "$A" >/dev/null 2>&1; echo $?)"
  echo "gates/pr_title.py $(echo '{"title":"feat: x","draft":true,"files":["a"],"head":"feat/x"}' | cenv python3 "$P/gates/pr_title.py" --cwd "$A" >/dev/null 2>&1; echo $?)"
  echo "gates/dead_branches.sh $(cenv bash "$P/gates/dead_branches.sh" --repo "$A" >/dev/null 2>&1; echo $?)"
  echo "gates/merge_guard.py $(cenv python3 "$P/gates/merge_guard.py" --help >/dev/null 2>&1; echo $?)"
  echo "gates/gh_write.py $(cenv python3 "$P/gates/gh_write.py" --help >/dev/null 2>&1; echo $?)"
}
fam_seedable() {
  local R=$1 src PIN S SP A ev c inplace seeded n=0 e
  facts_exact "$R" seedable "copied directory"
  src=$(src_of "$R" vibemaestro-sdlc)
  [ -n "$src" ] && [ -d "$R/$src" ] || { bad "[seedable] copied directory: the source '$src' is not a directory"; return; }
  # the seed: only the source directory, in a tree with nothing else (no marketplace, no tests, no repository around it)
  PIN="$R/${src#./}"; S=$(fresh); cp -R "$PIN" "$S/vibemaestro-sdlc"; SP="$S/vibemaestro-sdlc"
  eq "$(find "$PIN" -type l | wc -l | tr -d ' ')" 0 "[seedable] copied directory: no symlink (a cache copy drops links that leave the directory)"
  # the app repository it serves, outside the seed; one commit on a branch so the gates have a range
  A=$(mk_origin); git_ -C "$A" checkout -q -b feat/x; commit_in "$A" a.txt a "feat: x"
  while IFS=$'\t' read -r ev c; do
    n=$((n+1))
    inplace=$(run_hook "$PIN" "$A" "$ev" "$c"); seeded=$(run_hook "$SP" "$A" "$ev" "$c")
    eq "$(printf '%s\n' "$seeded" | head -1)" 0 "[seedable] hook $n ($ev) from the seed: rc 0"
    eq "$seeded" "$inplace" "[seedable] hook $n ($ev) from the seed: the same output as from the plugin in place"
  done <<<"$(hook_cmds_of "$SP")"
  [ "$n" -gt 0 ] && ok "[seedable] instrument: $n hook commands ran" || bad "[seedable] instrument: no hook command found"
  inplace=$(smokes "$PIN" "$A"); seeded=$(smokes "$SP" "$A")
  while read -r e c; do
    eq "$(printf '%s\n' "$seeded" | grep -F "$e " | cut -d' ' -f2)" "$c" "[seedable] $e from the seed: rc $c, as from the plugin in place"
  done <<<"$inplace"
  eq "$(printf '%s\n' "$inplace" | cut -d' ' -f2 | sort -u | paste -sd' ' -)" "0 3 5" "[seedable] instrument: the in-place smokes end as expected (3 intent missing, 5 main tree, 0 the rest)"
}

# ── cli ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# One trigger per (entry point, rc): `trig <plugin> <entry> <rc>` prints the rc the entry point actually returned. The triggers are
# the smallest setups that reach each documented exit; TRIGGERS lists them, and the family compares that list with the contract.
TRIGGERS="
scripts/intent-branch.sh 0
scripts/intent-branch.sh 1
scripts/intent-branch.sh 2
scripts/intent-branch.sh 3
scripts/intent-branch.sh 4
scripts/intent-branch.sh 5
scripts/intent-branch.sh 6
scripts/intent-branch.sh 7
scripts/intent-branch.sh 8
scripts/intent-branch.sh 64
scripts/open-pr.sh 0
scripts/open-pr.sh 1
scripts/open-pr.sh 2
scripts/open-pr.sh 3
scripts/open-pr.sh 4
scripts/open-pr.sh 5
scripts/open-pr.sh 64
scripts/open-pr.sh 66
scripts/kb.py 0
scripts/kb.py 2
scripts/kb.py 6
scripts/kb.py 64
scripts/kb.py 65
scripts/kb.py 66
scripts/sdlc_config.py 0
scripts/sdlc_config.py 64
scripts/install_gates.py 0
scripts/install_gates.py 64
scripts/install_gates.py 65
scripts/baton.py 0
scripts/baton.py 1
scripts/baton.py 2
scripts/baton.py 3
scripts/baton.py 4
scripts/baton.py 5
scripts/baton.py 6
scripts/baton.py 7
scripts/baton.py 8
scripts/baton.py 9
scripts/baton.py 10
scripts/baton.py 64
scripts/baton.py 66
gates/commit_discipline.py 0
gates/commit_discipline.py 1
gates/commit_discipline.py 2
gates/commit_discipline.py 64
gates/commit_discipline.py 65
gates/pr_sensitive.py 0
gates/pr_sensitive.py 1
gates/pr_sensitive.py 2
gates/pr_sensitive.py 64
gates/pr_sensitive.py 65
gates/pr_title.py 0
gates/pr_title.py 1
gates/pr_title.py 2
gates/pr_title.py 64
gates/pr_title.py 65
gates/merge_guard.py 0
gates/merge_guard.py 1
gates/merge_guard.py 2
gates/merge_guard.py 64
gates/merge_guard.py 65
gates/gh_write.py 0
gates/gh_write.py 1
gates/gh_write.py 2
gates/gh_write.py 64
gates/dead_branches.sh 0
gates/dead_branches.sh 1
gates/dead_branches.sh 2
gates/dead_branches.sh 64
gates/dead_branches.sh 65
hooks/hooks.json 0
"
P=""; R=""; IBENV=()
# ib <cwd> <args...> — the intent-branch adapter; op <cwd> <args...> — the open-pr adapter; both with the fake gh first in PATH
ib() { local d=$1; shift; ( cd "$d" && cenv PATH="$GHB:$PATH" ${IBENV[@]+"${IBENV[@]}"} bash "$P/scripts/intent-branch.sh" "$@" ) >/dev/null 2>&1; echo $?; }
op() { local d=$1 g=$2; shift 2; ( cd "$d" && cenv PATH="$g:$PATH" bash "$P/scripts/open-pr.sh" "$@" ) >/dev/null 2>&1; echo $?; }
py() { local f=$1; shift; cenv python3 "$P/$f" "$@" >/dev/null 2>&1; echo $?; }
pyin() { local in=$1 f=$2; shift 2; printf '%s' "$in" | cenv python3 "$P/$f" "$@" >/dev/null 2>&1; echo $?; }
BADCFG='{"schema": 1, "hooks": 1}'   # a wrong-typed key: an unknown key is only a warning (rule config-compat)
put_cfg() { mkdir -p "$1/.vibemaestro"; printf '%s' "$2" > "$1/.vibemaestro/sdlc.json"; }
# gate_repo <subject> — a repo with main and a branch feat/x holding one commit with that subject; prints its path
gate_repo() {
  local r; r=$(fresh)/r; git_ init -q -b main "$r"; commit_in "$r" seed.txt seed seed
  git_ -C "$r" checkout -q -b feat/x; commit_in "$r" a.txt a "$1"; printf '%s' "$r"
}
# mg [fixture mutation ...] -- <guard args...> — the guarded merge on a fixture of tests/fixtures/merge_fx.py, served by the fake gh
# tests/fixtures/merge_gh.py; the case directory holds brief.txt (src/**, docs/**); prints the rc
MGB="$TMP/mgbin"; mkdir -p "$MGB"; printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/merge_gh.py" > "$MGB/gh"; chmod +x "$MGB/gh"
mg() {
  local d m=(); d=$(fresh)
  while [ $# -gt 0 ] && [ "$1" != -- ]; do m+=("$1"); shift; done; shift
  python3 -B "$HERE/fixtures/merge_fx.py" "$d/fx.json" --skill "$P/skills/init-kb/SKILL.md" ${m[@]+"${m[@]}"}
  printf 'src/**\ndocs/**\n' > "$d/brief.txt"; mkdir -p "$d/state"; [ -z "${MG_NOLOG:-}" ] || printf x > "$d/state/vibemaestro"
  ( cd "$d" && cenv PATH="$MGB:$PATH" XDG_STATE_HOME="$d/state" FAKE_GH_FX="$d/fx.json" FAKE_GH_LOG="$d/gh.log" \
      FAKE_GH_STATE="$d/merged.json" python3 "$P/gates/merge_guard.py" "$@" ) >/dev/null 2>&1; echo $?
}
# gw [python statements on W] -- <engine args...> — gates/gh_write.py from a case directory holding spec.json (one comment on
# an issue of acme/app) and a world served by the fake gh tests/fixtures/gh_write_gh.py; GW_SPEC replaces the ops; prints the rc
GW_ONE='[{"op": "issue-comment", "repo": "acme/app", "issue": 5, "body": "hi <!-- m -->", "marker": "<!-- m -->"}]'
GWB="$TMP/gwbin"; mkdir -p "$GWB"; printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/gh_write_gh.py" > "$GWB/gh"; chmod +x "$GWB/gh"
gw() {
  local d st=""; d=$(fresh)
  while [ $# -gt 0 ] && [ "$1" != -- ]; do st="$st$1"$'\n'; shift; done; shift
  printf '{"gh-write": 1, "ops": %s}\n' "${GW_SPEC:-$GW_ONE}" > "$d/spec.json"
  python3 - "$d" "$st" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
W = {"viewer": "bot", "next_issue": 10, "next_comment": 100, "faults": {},
     "repos": {"acme/app": {"private": True, "visibility": "private", "labels": [], "comments": {},
                            "issues": {"5": {"title": "t", "body": "b", "state": "open", "user": "bot"}}}}}
SHA = hashlib.sha256(open(os.path.join(d, "spec.json"), "rb").read()).hexdigest()
def journal(entries):
    p = os.path.join(d, "state", "vibemaestro", "gh-write")
    os.makedirs(p)
    json.dump({"spec": SHA, "paths": [os.path.realpath(os.path.join(d, "spec.json"))], "n": 1, "state": "open", "run": "0123456789abcdef",
               "entries": entries}, open(os.path.join(p, SHA + ".json"), "w"))
exec(sys.argv[2])
json.dump(W, open(os.path.join(d, "world.json"), "w"))
PY
  ( cd "$d" && cenv PATH="${GW_PATH:-$GWB:$PATH}" XDG_STATE_HOME="$d/state" FAKE_GH_STATE="$d/world.json" FAKE_GH_LOG="$d/gh.log" \
      python3 "$P/gates/gh_write.py" "$@" ) >/dev/null 2>&1; echo $?
}
# a gh that fails (HTTP 500) and one that prints something that is not JSON
GWFAIL="$TMP/gwfail"; mkdir -p "$GWFAIL"; printf '#!/bin/sh\necho "HTTP 500" >&2\nexit 1\n' > "$GWFAIL/gh"; chmod +x "$GWFAIL/gh"
GWJUNK="$TMP/gwjunk"; mkdir -p "$GWJUNK"; printf '#!/bin/sh\necho "<html>not json</html>"\n' > "$GWJUNK/gh"; chmod +x "$GWJUNK/gh"
GW_DONE='journal({"1": {"op": 1, "kind": "issue-comment", "repo": "acme/app", "number": 5, "comment": 100, "posted": "hi <!-- m -->", "status": "done"}})'
MG_HEAD=a1b2c3d4e5f60718293a4b5c6d7e8f9001122334
MG=(--repo acme/app --pr 7 --head "$MG_HEAD" --brief brief.txt)
# bat <dir> <state dir> <args...> — the baton runner from <dir> with its own state directory; prints the rc
# (a `sign --by owner` first goes through the plugin's guard hook, owner_asked, as in a session whose owner clicks the dialog; the
# repo copy's baton is isolated from the machine then, baton_isolate)
bat() {
  local d=$1 s=$2; shift 2
  if [ "${1:-} ${2:-} ${3:-}" = "sign --by owner" ]; then
    [ -d "${P%/}.isolate" ] || baton_isolate "$P"
    owner_asked "$P" "$d" "$s" s-owner "${@:2}" >/dev/null
  elif [ "${1:-}" = mode ] && [ $# -gt 1 ]; then
    [ -d "${P%/}.isolate" ] || baton_isolate "$P"
    mode_asked "$P" "$d" "$s" s-owner "${@:2}" >/dev/null
  fi
  ( cd "$d" && cenv XDG_STATE_HOME="$s" CLAUDE_CODE_SESSION_ID=s-owner python3 "$P/scripts/baton.py" "$@" ) >/dev/null 2>&1; echo $?
}
# bat_sign <dir> <state dir> <signer> <script> [args...] — rehearse to read the seal it prints, then sign with it; prints the rc
bat_sign() {
  local d=$1 s=$2 by=$3 seal; shift 3
  seal=$( (cd "$d" && cenv XDG_STATE_HOME="$s" python3 "$P/scripts/baton.py" rehearse "$@") 2>/dev/null | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  bat "$d" "$s" sign --by "$by" --seal "${seal:-none}" "$@"
}
# bat_act <dir> — the template written by `baton new act` into <dir> (a baton script that creates one file); prints its path
bat_act() { cp "$SRC_ROOT/tests/fixtures/baton-positional.sh" "$1/act.sh"; printf '%s' "$1/act.sh"; }   # positional: <file> <text>
POSTCHECK_OK=$'postcheck() {\n  holds_text\n}'; POSTCHECK_NO=$'postcheck() {\n  false\n}'
# pr_wt — main tree and a linked worktree on feat/x with one commit, plus summary/evidence files; sets PW PT F
pr_wt() { mk_pr_repo; commit_in "$PT" a.txt a "feat: x"; }
# gh_refusing <dir> — a gh that names the repository and refuses to create the PR
gh_refusing() {
  mkdir -p "$1"; printf '#!/bin/bash\ncase "$1 $2" in\n  "repo view") echo acme/app-demo;;\n  "pr create") echo "HTTP 422" >&2; exit 1;;\nesac\nexit 0\n' > "$1/gh"
  chmod +x "$1/gh"; printf '%s' "$1"
}
trig() {
  P=$1; local e=$2 c=$3 W S T wt r
  PLX=$P
  case "$e $c" in
    "scripts/intent-branch.sh 0")  W=$(mk_origin); rec_ "$W" 2026-01-01-zero; ib "$W" --cwd "$W" create-intent --slug 2026-01-01-zero --no-issue;;
    "scripts/intent-branch.sh 1")  W=$(mk_origin); rec_ "$W" 2026-01-01-one; IBENV=(GH_LABEL_CREATE_FAIL=1); ib "$W" --cwd "$W" retry-issue --slug 2026-01-01-one; IBENV=();;
    "scripts/intent-branch.sh 2")  T=$(fresh); W=$(mk_origin); rec_ "$W" 2026-01-01-two
                                   all_rc 2 "$(ib "$T" --cwd "$T" create-intent --slug 2026-01-01-two --no-issue)" \
                                     "$( (cd "$W" && cenv PATH="$(bare_path nogh-nopy)" bash "$P/scripts/intent-branch.sh" --cwd "$W" create-intent --slug 2026-01-01-two --no-issue) >/dev/null 2>&1; echo $?)" \
                                     "$( (cd "$W" && cenv PATH="$GHB:$PATH" bash "$(no_core "$P" intent_branch.py)/scripts/intent-branch.sh" --cwd "$W" create-intent --slug 2026-01-01-two --no-issue) >/dev/null 2>&1; echo $?)" \
                                     "$(ib "$W" --cwd "$W" create-intent --slug 2026-01-01-two --no-issue --load-bearing)";;
    "scripts/intent-branch.sh 3")  W=$(mk_origin); ib "$W" --cwd "$W" create-intent --slug 2026-01-01-three --no-issue;;
    "scripts/intent-branch.sh 4")  W=$(mk_origin); S=2026-01-01-four; new_intent "$W" "$S"; wt=$(task_wt "$W" feat/t4 "$S" 1)
                                   printf '#!/bin/sh\nexit 1\n' > "$W/../origin.git/hooks/pre-receive"; chmod +x "$W/../origin.git/hooks/pre-receive"
                                   ib "$wt" --cwd "$wt" integrate --intent "$S" --branch feat/t4 --to origin;;
    "scripts/intent-branch.sh 5")  W=$(mk_origin); S=2026-01-01-five2; new_intent "$W" "$S"; wt=$(task_wt "$W" feat/t5 "$S" 1); rec_ "$W" 2026-01-01-five
                                   all_rc 5 "$(ib "$W" --cwd "$W" create-intent --slug 2026-01-01-five --no-issue --base origin/nothing)" \
                                     "$(ib "$W" --cwd "$W" worker-branch --intent 2026-01-01-nothing --name feat/t5n --no-checkout)" \
                                     "$(ib "$wt" --cwd "$wt" integrate --intent 2026-01-01-nowhere --branch feat/t5 --to origin)" \
                                     "$(ib "$wt" --cwd "$wt" integrate --intent "$S" --branch feat/nothing --to origin)";;
    "scripts/intent-branch.sh 6")  W=$(mk_origin); rec_ "$W" 2026-01-01-six; ib "$W" --cwd "$W" create-intent --slug 2026-01-01-six --no-issue >/dev/null
                                   git_ -C "$W" checkout -q main; ib "$W" --cwd "$W" create-intent --slug 2026-01-01-six --no-issue;;
    "scripts/intent-branch.sh 7")  W=$(mk_origin); S=2026-01-01-seven; new_intent "$W" "$S"; wt=$(task_wt "$W" feat/t7g "$S" 1)
                                   r=$(mk_submodule "$W" "$(fresh)"); git_ -C "$r" push -q origin "main:intent/$S"; git_ -C "$r" fetch -q origin
                                   all_rc 7 "$(ib "$W" --cwd "$W" worker-branch --intent "$S" --name feat/t7)" \
                                     "$(IBENV=(GIT_DIR="$W/.git" GIT_WORK_TREE="$W"); ib "$wt" --cwd "$wt" integrate --intent "$S" --branch feat/t7g --to origin)" \
                                     "$(ib "$r" --cwd "$r" worker-branch --intent "$S" --name feat/t7s)";;
    "scripts/intent-branch.sh 8")  W=$(mk_origin); S=2026-01-01-eight; new_intent "$W" "$S"; wt=$(task_wt "$W" feat/t8 "$S" 2)
                                   ib "$wt" --cwd "$wt" integrate --intent "$S" --branch feat/t8 --to origin;;
    "scripts/intent-branch.sh 64") ib "$(fresh)";;
    "scripts/open-pr.sh 0")        pr_wt
                                   all_rc 0 "$(op "$PT" "$GHB" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt")" \
                                     "$(op "$PT" "$GHB" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run)";;
    "scripts/open-pr.sh 1")        pr_wt; op "$PT" "$(gh_refusing "$(fresh)")" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt";;
    "scripts/open-pr.sh 2")        pr_wt; : > "$F/sum-empty.md"
                                   all_rc 2 "$(op "$PT" "$GHB" --title "feat: x" --summary "$F/sum-empty.md" --evidence "$F/ev.txt")" \
                                     "$( (cd "$PT" && cenv PATH="$(bare_path nogh)" bash "$P/scripts/open-pr.sh" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt") >/dev/null 2>&1; echo $?)" \
                                     "$( (cd "$PT" && cenv PATH="$GHB:$(bare_path nogh-nopy)" bash "$P/scripts/open-pr.sh" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt") >/dev/null 2>&1; echo $?)" \
                                     "$( (cd "$PT" && cenv PATH="$GHB:$PATH" bash "$(no_core "$P" open_pr.py)/scripts/open-pr.sh" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt") >/dev/null 2>&1; echo $?)";;
    "scripts/open-pr.sh 3")        pr_wt; op "$PT" "$GHB" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev-empty.txt";;
    "scripts/open-pr.sh 4")        pr_wt; mkdir -p "$PT/kb" "$PT/watched"
                                   put_cfg "$PT" '{"schema": 1, "current_state": {"watch": ["watched/"]}}'; echo ledger > "$PT/kb/current-state.md"
                                   git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "feat: config"; git_ -C "$PT" push -q origin feat/x:main
                                   commit_in "$PT" watched/k.yaml k "feat: a watched change"
                                   op "$PT" "$GHB" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run;;
    "scripts/open-pr.sh 5")        pr_wt; op "$PW" "$GHB" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt";;
    "scripts/open-pr.sh 64")       pr_wt
                                   all_rc 64 "$(op "$PT" "$GHB" --summary "$F/sum.md" --evidence "$F/ev.txt")" \
                                     "$(put_cfg "$PT" '{"schema": 1, "pr": {"title": {"pattern": "^feat"}}}'; op "$PT" "$GHB" --title "fix: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run)" \
                                     "$(put_cfg "$PT" "$BADCFG"; op "$PT" "$GHB" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run)";;
    "scripts/open-pr.sh 66")       pr_wt; op "$PT" "$GHB" --title "feat: x" --summary "$F/none.md" --evidence "$F/ev.txt";;
    "scripts/kb.py 0")             W=$(mk_origin); py scripts/kb.py config check --root "$W";;
    "scripts/kb.py 2")             T=$(fresh); r=$(gate_repo "feat: x")
                                   all_rc 2 "$(cd "$T" && py scripts/kb.py new intent example)" "$(cd "$r" && py scripts/kb.py new intent example)";;
    "scripts/kb.py 6")             W=$(mk_origin); ( cd "$W" && py scripts/kb.py init >/dev/null && py scripts/kb.py new intent example --date 2026-01-01 >/dev/null \
                                     && py scripts/kb.py new intent example --date 2026-01-01 );;
    "scripts/kb.py 64")            py scripts/kb.py;;
    "scripts/kb.py 65")            W=$(mk_origin); r=$(gate_repo "feat: x"); mkdir -p "$r/kb"; printf '# State\n\nnot a spec\n' > "$r/kb/spec.md"
                                   printf '# State\n\n- Measured on 2026-01-01 in PR #12, before that it was different\n' > "$r/kb/current-state.md"
                                   all_rc 65 "$(cd "$r" && py scripts/kb.py check spec "$r/kb/spec.md")" "$(cd "$r" && py scripts/kb.py check current-state)" \
                                     "$(put_cfg "$W" "$BADCFG"; py scripts/kb.py config check --root "$W")";;
    "scripts/kb.py 66")            W=$(mk_origin); ( cd "$W" && py scripts/kb.py check current-state "$W/kb/no-such.md" );;
    "scripts/sdlc_config.py 0")    W=$(mk_origin); py scripts/sdlc_config.py get schema --root "$W";;
    "scripts/sdlc_config.py 64")   W=$(mk_origin); r=$(gate_repo "feat: x"); put_cfg "$r" "$BADCFG"
                                   all_rc 64 "$(py scripts/sdlc_config.py)" "$(py scripts/sdlc_config.py get no.such.key --root "$W")" "$(py scripts/sdlc_config.py get schema --root "$r")";;
    "scripts/install_gates.py 0")  W=$(mk_origin)
                                   all_rc 0 "$(py scripts/install_gates.py --root "$W" --dry-run)" "$(py scripts/install_gates.py --root "$W")" \
                                     "$( [ -f "$W/.github/workflows/pr-title.yml" ] && py scripts/install_gates.py --root "$W" || echo 'nothing installed')";;
    "scripts/install_gates.py 64") W=$(mk_origin)
                                   all_rc 64 "$(py scripts/install_gates.py --root "$W" --only no-such-gate --dry-run)" \
                                     "$(py scripts/install_gates.py --root "$W" --runner-default 'bad label!' --dry-run)" "$(py scripts/install_gates.py --root "$(fresh)" --dry-run)";;
    "scripts/install_gates.py 65") W=$(mk_origin); put_cfg "$W" "$BADCFG"; py scripts/install_gates.py --root "$W" --dry-run;;
    "scripts/baton.py 0")          W=$(fresh); bat "$W" "$W/st" new act --dir "$W";;
    "scripts/baton.py 1")          W=$(fresh); S=$(bat_act "$W"); cp "$S" "$W/b.sh"; mutate "$W/b.sh" '# Undo: ' '# Undone: '
                                   mutate "$S" '# Expect: create *' '# Expect: delete *'
                                   all_rc 1 "$(bat "$W" "$W/st" check "$W/b.sh")" "$(bat "$W" "$W/st" rehearse "$S" "$W/out.txt" x)" \
                                     "$(bat "$W" "$W/st" pack "$S" user:act)";;
    "scripts/baton.py 2")          W=$(fresh); S=$(bat_act "$W"); mk_tools "$W/py" python3; echo f > "$W/a-file"
                                   all_rc 2 "$( (cd "$W" && cenv PATH="$W/py" python3 "$P/scripts/baton.py" check "$S") >/dev/null 2>&1; echo $?)" \
                                     "$(bat "$W" "$W/a-file" mode auto)";;
    "scripts/baton.py 3")          W=$(fresh); S=$(bat_act "$W"); cp "$S" "$W/ib.sh"
                                   mutate "$W/ib.sh" $'act() {\n' $'act() {\n  if [ -e "$DEST.stop" ]; then kill -TERM "$PPID"; fi\n'
                                   bat_sign "$W" "$W/st" owner "$W/ib.sh" "$W/i.txt" x >/dev/null; : > "$W/i.txt.stop"
                                   all_rc 3 "$(bat "$W" "$W/st" run "$S" "$W/out.txt" x)" "$(bat_sign "$W" "$W/st" coordinator-auto "$S" "$W/out.txt" x)" \
                                     "$(bat "$W" "$W/st" run "$W/ib.sh" "$W/i.txt" x)" \
                                     "$(bat "$W" "$W/st" sign --by owner --seal 0000000000000000.0000000000000000 "$S" "$W/out.txt" x)";;
    "scripts/baton.py 4")          W=$(fresh); S=$(bat_act "$W"); mutate "$S" "$POSTCHECK_OK" "$POSTCHECK_NO"
                                   bat_sign "$W" "$W/st" owner "$S" "$W/out.txt" x >/dev/null; bat "$W" "$W/st" run "$S" "$W/out.txt" x;;
    "scripts/baton.py 5")          W=$(fresh); S=$(bat_act "$W"); cp "$S" "$W/i.sh"
                                   mutate "$S" "$POSTCHECK_OK" "$POSTCHECK_NO"; mutate "$S" $'undo() {\n' $'undo() {\n  false\n'
                                   mutate "$W/i.sh" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  write "interrupt" kill -TERM "$PPID"\n}'
                                   mutate "$W/i.sh" '# Expect: create *' $'# Expect: create *\n# Expect: interrupt'
                                   bat_sign "$W" "$W/st" owner "$S" "$W/a.txt" x >/dev/null; bat_sign "$W" "$W/st" owner "$W/i.sh" "$W/b.txt" x >/dev/null
                                   all_rc 5 "$(bat "$W" "$W/st" run "$S" "$W/a.txt" x)" "$(bat "$W" "$W/st" run "$W/i.sh" "$W/b.txt" x)";;
    "scripts/baton.py 6")          W=$(fresh); bat "$W" "$W/st" new act --dir "$W" >/dev/null; bat "$W" "$W/st" new act --dir "$W";;
    "scripts/baton.py 7")          W=$(fresh); echo '{}' > "$W/s.json"; bat "$W" "$W/st" permissions --check --settings "$W/s.json";;
    "scripts/baton.py 8")          W=$(fresh); S=$(bat_act "$W"); bat "$W" "$W/st" go "$S" "$W/out.txt" hello;;
    "scripts/baton.py 9")          W=$(fresh); S=$(bat_act "$W"); mutate "$S" "$POSTCHECK_OK" "$POSTCHECK_NO"
                                   bat_sign "$W" "$W/st" owner "$S" "$W/out.txt" x >/dev/null; bat "$W" "$W/st" run "$S" "$W/out.txt" x >/dev/null
                                   all_rc 9 "$(bat "$W" "$W/st" log --wait-names act.sh --timeout 1)" "$(bat "$W" "$W/st" log --wait-names never.sh --timeout 1)";;
    "scripts/baton.py 64")         W=$(fresh); all_rc 64 "$(bat "$W" "$W/st")" "$(bat "$W" "$W/st" pack "$W/act.sh" act)";;
    "scripts/baton.py 10")         W=$(fresh); V="$W/cfg/plugins/cache/vibemaestro/vibemaestro-sdlc"; mkdir -p "$V"
                                   cp -r "$P" "$V/4dc7de6c9e01"; cp -r "$P" "$V/3dd2665ed242"
                                   printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s", "lastUpdated": "2"}]}}' \
                                     "$V/3dd2665ed242" > "$W/cfg/plugins/installed_plugins.json"
                                   all_rc 10 "$( (cd "$W" && cenv XDG_STATE_HOME="$W/st" CLAUDE_CONFIG_DIR="$W/cfg" python3 "$V/4dc7de6c9e01/scripts/baton.py" permissions --check) >/dev/null 2>&1; echo $?)" \
                                     "$( (cd "$W" && cenv XDG_STATE_HOME="$W/st" CLAUDE_CONFIG_DIR="$W/cfg" python3 "$V/4dc7de6c9e01/scripts/baton.py" permissions --install-launcher) >/dev/null 2>&1; echo $?)";;
    "scripts/baton.py 66")         W=$(fresh)
                                   all_rc 66 "$(bat "$W" "$W/st" check "$W/none.sh")" \
                                     "$(bat "$W" "$W/st" pack --retire user:act 0000000000000000000000000000000000000000000000000000000000000000)";;
    "gates/commit_discipline.py 0")  r=$(gate_repo "feat: x"); py gates/commit_discipline.py main HEAD --cwd "$r";;
    "gates/commit_discipline.py 1")  r=$(gate_repo "wip: x"); py gates/commit_discipline.py main HEAD --cwd "$r";;
    "gates/commit_discipline.py 2")  r=$(gate_repo "feat: x"); py gates/commit_discipline.py main no-such-ref --cwd "$r";;
    "gates/commit_discipline.py 64") py gates/commit_discipline.py --no-such-flag;;
    "gates/commit_discipline.py 65") r=$(gate_repo "feat: x"); put_cfg "$r" "$BADCFG"; py gates/commit_discipline.py main HEAD --cwd "$r";;
    "gates/pr_sensitive.py 0")     r=$(gate_repo "feat: x"); pyin "a clean line" gates/pr_sensitive.py --text --cwd "$r";;
    "gates/pr_sensitive.py 1")     r=$(gate_repo "feat: x"); pyin "reach it at $(printf '%s.%s.%s.%s' 103 97 12 44)" gates/pr_sensitive.py --text --cwd "$r";;
    "gates/pr_sensitive.py 2")     r=$(gate_repo "feat: x"); py gates/pr_sensitive.py --git-log no-such-ref..HEAD --cwd "$r";;
    "gates/pr_sensitive.py 64")    py gates/pr_sensitive.py;;
    "gates/pr_sensitive.py 65")    r=$(gate_repo "feat: x"); put_cfg "$r" "$BADCFG"; pyin "a clean line" gates/pr_sensitive.py --text --cwd "$r";;
    "gates/pr_title.py 0")         r=$(gate_repo "feat: x"); T=$(gate_repo "feat: x"); put_cfg "$T" '{"schema": 1, "pr": {"title": {"pattern": "^feat"}}}'
                                   all_rc 0 "$(pyin '{"title":"feat: x","draft":true,"files":["a"],"head":"feat/x"}' gates/pr_title.py --cwd "$r")" \
                                     "$(pyin '{"title":"feat: x","draft":true,"files":["a"],"head":"feat/x"}' gates/pr_title.py --cwd "$T")";;
    "gates/pr_title.py 1")         r=$(gate_repo "feat: x"); put_cfg "$r" '{"schema": 1, "pr": {"title": {"pattern": "^feat"}}}'
                                   all_rc 1 "$(pyin '{"title":"fix: x","draft":true,"files":["a"],"head":"feat/x"}' gates/pr_title.py --cwd "$r")" \
                                     "$(pyin 'not json' gates/pr_title.py --cwd "$r")";;
    "gates/pr_title.py 2")         r=$(gate_repo "feat: x"); pyin '{"title":"feat: x"}' gates/pr_title.py --cwd "$r" --config-ref no-such-ref;;
    "gates/pr_title.py 64")        pyin '' gates/pr_title.py --no-such-flag;;
    "gates/pr_title.py 65")        r=$(gate_repo "feat: x"); put_cfg "$r" "$BADCFG"; pyin '{"title":"feat: x"}' gates/pr_title.py --cwd "$r";;
    "gates/dead_branches.sh 0")    W=$(mk_origin); cenv bash "$P/gates/dead_branches.sh" --repo "$W" >/dev/null 2>&1; echo $?;;
    "gates/dead_branches.sh 1")    W=$(mk_origin); git_ -C "$W" push -q origin main:feat/merged; git_ -C "$W" fetch -q origin
                                   cenv bash "$P/gates/dead_branches.sh" --repo "$W" >/dev/null 2>&1; echo $?;;
    "gates/dead_branches.sh 2")    cenv bash "$P/gates/dead_branches.sh" --repo "$(fresh)" >/dev/null 2>&1; echo $?;;
    "gates/dead_branches.sh 64")   cenv bash "$P/gates/dead_branches.sh" --no-such-flag >/dev/null 2>&1; echo $?;;
    "gates/dead_branches.sh 65")   W=$(mk_origin); put_cfg "$W" "$BADCFG"; cenv bash "$P/gates/dead_branches.sh" --repo "$W" >/dev/null 2>&1; echo $?;;
    "gates/merge_guard.py 0")      all_rc 0 "$(mg -- "${MG[@]}")" "$(mg -- "${MG[@]}" --merge)";;
    "gates/merge_guard.py 1")      mg closed -- "${MG[@]}";;
    "gates/merge_guard.py 2")      all_rc 2 "$(mg pr-view-fail -- "${MG[@]}")" "$(mg tree-truncated -- "${MG[@]}")" \
                                     "$(mg moved-head -- "${MG[@]}" --merge)" "$(mg merge-mode=queue -- "${MG[@]}" --merge)" \
                                     "$(mg external-ci=exit -- "${MG[@]}")" "$(MG_NOLOG=1 mg -- "${MG[@]}" --merge)";;
    "gates/merge_guard.py 64")     all_rc 64 "$(py gates/merge_guard.py)" "$(mg -- --repo acme/app --pr 7 --head "${MG_HEAD:0:12}" --brief brief.txt)" \
                                     "$(mg -- "${MG[@]}" --admin)" "$(mg -- "${MG[@]}" --image-bump)" \
                                     "$(mg registry-none -- "${MG[@]}" --require-image v1)" "$(mg -- "${MG[@]}" --require-image ghcr.io/other/img:v1)";;
    "gates/merge_guard.py 65")     all_rc 65 "$(mg bad-config -- "${MG[@]}")" "$(mg config-no-merge -- "${MG[@]}")";;
    "gates/gh_write.py 0")         all_rc 0 "$(gw -- --spec spec.json)" "$(gw "$GW_DONE" 'W["repos"]["acme/app"]["comments"]["100"] = {"issue": 5, "body": "hi <!-- m -->", "user": "bot"}' -- --spec spec.json --postcheck)" \
                                     "$(gw -- --spec spec.json --undo-plan)";;
    "gates/gh_write.py 1")         all_rc 1 "$(gw 'W["repos"]["acme/app"].update(private=False, visibility="public")' -- --spec spec.json)" \
                                     "$(gw "$GW_DONE" 'W["repos"]["acme/app"]["comments"]["100"] = {"issue": 5, "body": "hi <!-- m -->\n", "user": "bot"}' -- --spec spec.json --postcheck)" \
                                     "$(gw 'open(os.path.join(d, "plan.txt"), "w").write("")' -- --spec spec.json --do 1 --expect-plan plan.txt)" \
                                     "$(gw "$GW_DONE" 'W["repos"]["acme/app"]["comments"]["100"] = {"issue": 5, "body": "edited by a person", "user": "bot"}' -- --spec spec.json --undo-step 1)";;
    "gates/gh_write.py 2")         all_rc 2 "$(GW_PATH="$GWFAIL:$PATH" gw -- --spec spec.json)" "$(GW_PATH="$GWJUNK:$PATH" gw -- --spec spec.json)";;
    "gates/gh_write.py 64")        all_rc 64 "$(py gates/gh_write.py)" "$(GW_SPEC='[{"op": "issue-delete", "repo": "acme/app", "issue": 5}]' gw -- --spec spec.json)" \
                                     "$(GW_SPEC='[{"op": "repo-create", "repo": "acme/new"}]' gw -- --spec spec.json)" \
                                     "$(GW_SPEC='[{"op": "issue-lock", "repo": "acme/app", "issue": 5}]' gw -- --spec spec.json)";;
    "hooks/hooks.json 0")          hooks_rc;;
    *) echo none;;
  esac
}
# all_rc <want> <rc>... — <want> when every reason's trigger got it, else the first rc that is not <want>
all_rc() { local w=$1 r; shift; for r in "$@"; do [ "$r" = "$w" ] || { echo "$r"; return; }; done; echo "$w"; }
# no_core <plugin> <core file> — a copy of the plugin without that core; prints the copy
no_core() { local d; d=$(fresh)/p; cp -R "$1" "$d"; rm -f "$d/scripts/$2"; printf '%s' "$d"; }
rec_() { mkdir -p "$1/kb/intent"; printf -- '---\ndescription: "example record"\n---\n\nintent text\n' > "$1/kb/intent/$2.md"; }
# hooks_rc — every hook command, on its usual payload and on a payload that is not JSON: the first rc that is not 0, else 0
hooks_rc() {
  local A ev c rc; A=$(mk_origin)
  while IFS=$'\t' read -r ev c; do
    for in in "$(payload "$ev")" "not json {"; do
      rc=$(run_hook "$P" "$A" "$ev" "$c" "$in" | head -1)
      [ "$rc" = 0 ] || { echo "$rc"; return; }
    done
  done <<<"$(hook_cmds_of "$P")"
  echo 0
}
# fam_cli <repo copy> — every exit-code row of the contract (CLI_ONLY=<entry> limits it to one entry point)
fam_cli() {
  R=$1; local rows e c got n=0
  rows=$(cj "$R" '"\n".join(r[0]+" "+r[1] for r in d["codes"])' | python3 -c 'import json,sys; print(json.load(sys.stdin))')
  while read -r e c; do
    [ -n "$e" ] || continue
    [ -z "${CLI_ONLY:-}" ] || [ "$e" = "$CLI_ONLY" ] || continue
    printf '%s\n' "$TRIGGERS" | grep -qxF "$e $c" || { bad "[cli] $e rc $c: a contract row with no trigger in this suite"; continue; }
    [ -e "$R/$PLREL/$e" ] || { bad "[cli] $e rc $c: the entry point does not exist"; continue; }
    got=$(trig "$R/$PLREL" "$e" "$c" | tail -1); n=$((n+1))
    eq "$got" "$c" "[cli] $e rc $c: the trigger gets rc $c"
  done <<<"$rows"
  while read -r e c; do
    [ -n "$e" ] || continue
    [ -z "${CLI_ONLY:-}" ] || [ "$e" = "$CLI_ONLY" ] || continue
    printf '%s\n' "$rows" | grep -qxF "$e $c" || bad "[cli] $e rc $c: a trigger with no contract row"
  done <<<"$TRIGGERS"
  [ "$n" -gt 0 ] && ok "[cli] instrument: $n exit codes triggered" || bad "[cli] instrument: no exit code was triggered"
}

# ── config-schema ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_config_schema() {
  local R=$1 P="$1/$PLREL" cf sv X ck sk k bad_get=""
  facts_exact "$R" config-schema "config file|schema"
  cf=$(fact "$R" config-schema "config file"); sv=$(fact "$R" config-schema schema)
  X=$(mk_origin)
  mkdir -p "$X/$(dirname "$cf")"
  printf '{"schema": %s}' "$sv" > "$X/$cf"; cenv python3 "$P/scripts/kb.py" config check --root "$X" >/dev/null 2>&1
  eq "$?" 0 "[config-schema] schema: a config of schema $sv is accepted"
  printf '{"schema": %s}' "$((sv+1))" > "$X/$cf"; cenv python3 "$P/scripts/kb.py" config check --root "$X" >/dev/null 2>&1
  eq "$?" 65 "[config-schema] schema: a config of schema $((sv+1)) is refused (65)"
  printf '{"schema": %s, "hooks": 1}' "$sv" > "$X/$cf"; cenv python3 "$P/scripts/kb.py" config check --root "$X" >/dev/null 2>&1
  eq "$?" 65 "[config-schema] config file: '$cf' is the file read (a wrong-typed key in it is refused)"
  printf '{"schema": %s, "no_such_key": 1}' "$sv" > "$X/$cf"; cenv python3 "$P/scripts/kb.py" config check --root "$X" >/dev/null 2>&1
  eq "$?" 0 "[config-schema] …and an unknown key in it is a warning, not a refusal (rule config-compat)"
  rm -f "$X/$cf"
  ck=$(cj "$R" '"\n".join(d["keys"])' | python3 -c 'import json,sys; print(json.load(sys.stdin))' | sort)
  sk=$(python3 "$CT" schema-keys "$P/scripts" | sort)
  [ -n "$sk" ] && ok "[config-schema] instrument: the schema has $(printf '%s\n' "$sk" | wc -l | tr -d ' ') keys" || bad "[config-schema] instrument: no key read from the schema"
  for k in $(comm -23 <(printf '%s\n' "$ck") <(printf '%s\n' "$sk")); do bad "[config-schema] key $k: in the contract, not in the schema"; done
  for k in $(comm -13 <(printf '%s\n' "$ck") <(printf '%s\n' "$sk")); do bad "[config-schema] key $k: in the schema, not in the contract"; done
  for k in $ck; do cenv python3 "$P/scripts/sdlc_config.py" get "$k" --root "$X" >/dev/null 2>&1 || bad_get="$bad_get $k"; done
  empty "$bad_get" "[config-schema] keys: every contract key reads with 'sdlc_config.py get' (rc 0)"
  python3 "$CT" defaults-config "$P/scripts" > "$X/$cf"
  [ "$(python3 "$CT" config-keys "$X/$cf" | sort)" = "$ck" ] && ok "[config-schema] keys: instrument: the full config sets exactly the contract keys" \
    || bad "[config-schema] keys: instrument: the full config does not set exactly the contract keys"
  cenv python3 "$P/scripts/kb.py" config check --root "$X" >/dev/null 2>&1
  eq "$?" 0 "[config-schema] keys: a schema-$sv config that sets every key (to its default) is valid"
  rm -f "$X/$cf"
  cenv python3 "$P/scripts/kb.py" config check --root "$R/tests/fixtures/hub-shaped" >/dev/null 2>&1
  eq "$?" 0 "[config-schema] schema: the worked example (tests/fixtures/hub-shaped) is a valid schema-$sv config"
}

# ── rule-packs ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Each check builds its plugins and registries from the facts (registry paths, manifest, dependency name, rules directory, rule
# suffix), so a fact the hooks no longer honour is red. The registry is fabricated in the format of Claude Code 2.1.290.
# rp_cmd <plugin> <app> <command> <VAR=value...> — the PreToolUse Bash hook of hooks.json, a new session, a minimal environment
rp_cmd() {
  local P=$1 A=$2 cmd=$3 c; shift 3
  c=$(hook_cmds_of "$P" | awk -F'\t' '$1 == "PreToolUse" && $2 ~ /pre-bash/ {print $2}')
  (cd "$A" && p_bash "s$RANDOM$RANDOM" "$cmd" | cenv CLAUDE_PROJECT_DIR="$A" CLAUDE_PLUGIN_ROOT="$P" "$@" bash -c "$c" 2>/dev/null)
}
# rp_pack <install dir> <name> <dependencies JSON> <rule base name> <description> — a plugin as the facts describe it, one rule
# that matches the command `contract-probe`
rp_pack() {
  mkdir -p "$1/$(dirname "$RP_MAN")" "$1/$RP_DIR"
  printf '{"name": "%s", "version": "1.0.0", "dependencies": %s}\n' "$2" "$3" > "$1/$RP_MAN"
  printf -- '---\napplyWhen: "contract-probe"\ndescription: "%s"\n---\n\n# probe\n' "$5" > "$1/$RP_DIR/$4${RP_SUF#\*}"
}
# rp_reg <registry file> <id=installPath[|projectPath]>... — the registry, ids in the order given, and the user settings next to
# its plugins directory with each id enabled (what an install writes)
rp_reg() {
  python3 - "$@" <<'PY'
import json, os, sys
path, plugins = sys.argv[1], {}
for it in sys.argv[2:]:
    pid, _, rest = it.partition("=")
    inst, _, proj = rest.partition("|")
    e = {"scope": "project" if proj else "user", "installPath": inst, "version": "1.0.0"}
    if proj:
        e["projectPath"] = proj
    plugins.setdefault(pid, []).append(e)
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"version": 2, "plugins": plugins}, open(path, "w"))
json.dump({"enabledPlugins": {k: True for k in plugins}}, open(os.path.join(os.path.dirname(os.path.dirname(path)), "settings.json"), "w"))
PY
}
fam_rule_packs() {
  local R=$1 P="$1/$PLREL" A B C H reg0 reg1 dep RP_MAN RP_DIR RP_SUF root D N X Z out
  facts_exact "$R" rule-packs "registry|registry without CLAUDE_CONFIG_DIR|manifest under installPath|dependency named in dependencies|rules directory under installPath|rule files|precedence|project scope|enabled"
  reg0=$(fact "$R" rule-packs registry); reg1=$(fact "$R" rule-packs "registry without CLAUDE_CONFIG_DIR")
  dep=$(fact "$R" rule-packs "dependency named in dependencies"); RP_MAN=$(fact "$R" rule-packs "manifest under installPath")
  RP_DIR=$(fact "$R" rule-packs "rules directory under installPath"); RP_SUF=$(fact "$R" rule-packs "rule files")
  A=$(fresh)/app; mk_app "$A" >/dev/null; B=$(fresh)/app; mk_app "$B" >/dev/null
  C=$(fresh)/cfg; H=$(fresh)/home
  reg0=${reg0/\$CLAUDE_CONFIG_DIR/$C}; reg1=${reg1/#\~/$H}
  root=$(dirname "$reg0"); D="$root/cache/acme/dep/1.0.0"; N="$root/cache/acme/nodep/1.0.0"
  rp_pack "$D" dep "[{\"name\": \"$dep\", \"version\": \">=2.5.0\"}]" probe PACK-PROBE
  rp_pack "$N" nodep '[]' other NODEP-PROBE
  rp_reg "$reg0" "dep@acme=$D" "nodep@acme=$N"
  out=$(rp_cmd "$P" "$A" "contract-probe" CLAUDE_CONFIG_DIR="$C")
  has "$out" "$D/$RP_DIR/probe${RP_SUF#\*}" "[rule-packs] registry: a pack listed in the registry under CLAUDE_CONFIG_DIR is reminded"
  has "$out" "PACK-PROBE" "[rule-packs] dependency named in dependencies: the plugin that names it is served"
  hasnt "$out" "NODEP-PROBE" "[rule-packs] dependency named in dependencies: the same rule in a plugin that does not name it is not"
  root=$(dirname "$reg1"); X="$root/cache/acme/home/1.0.0"
  rp_pack "$X" home "[\"$dep\"]" probe HOME-PROBE; rp_reg "$reg1" "home@acme=$X"
  out=$(rp_cmd "$P" "$A" "contract-probe" HOME="$H")
  has "$out" "HOME-PROBE" "[rule-packs] registry without CLAUDE_CONFIG_DIR: the registry under HOME is read"
  rp_pack "$D" dep "[\"$dep\"]" "$(basename "$(ls "$P/rules/"*"${RP_SUF#\*}" | head -n 1)" "${RP_SUF#\*}")" PACK-SDLC-NAME
  out=$(rp_cmd "$P" "$A" "contract-probe" CLAUDE_CONFIG_DIR="$C")
  nonempty "$(ls "$P/rules/"*"${RP_SUF#\*}" 2>/dev/null)" "[rule-packs] precedence: instrument, the plugin has rule files"
  hasnt "$out" "PACK-SDLC-NAME" "[rule-packs] precedence: a pack rule named like a rule of this plugin is not delivered"
  has "$out" "PACK-PROBE" "[rule-packs] precedence: instrument, the pack's other rule is still delivered"
  mkdir -p "$A/policy" "$A/.vibemaestro"; printf '{"schema": 1, "rules": {"dirs": ["policy"]}}' > "$A/.vibemaestro/sdlc.json"
  printf -- '---\napplyWhen: "contract-probe"\ndescription: "REPO-PROBE"\n---\n' > "$A/policy/probe${RP_SUF#\*}"
  out=$(rp_cmd "$P" "$A" "contract-probe" CLAUDE_CONFIG_DIR="$C")
  has "$out" "$A/policy/probe${RP_SUF#\*}" "[rule-packs] precedence: a repo rule replaces the pack rule of its name"
  hasnt "$out" "$D/$RP_DIR/probe${RP_SUF#\*}" "[rule-packs] precedence: …and the pack rule is not delivered"
  C=$(fresh)/cfg; reg0=$(fact "$R" rule-packs registry); reg0=${reg0/\$CLAUDE_CONFIG_DIR/$C}; root=$(dirname "$reg0")
  X="$root/cache/acme/aaa/1.0.0"; Z="$root/cache/acme/zzz/1.0.0"
  rp_pack "$X" aaa "[\"$dep\"]" shared FROM-AAA; rp_pack "$Z" zzz "[\"$dep\"]" shared FROM-ZZZ
  rp_reg "$reg0" "zzz@acme=$Z" "aaa@acme=$X"
  out=$(rp_cmd "$P" "$B" "contract-probe" CLAUDE_CONFIG_DIR="$C")
  has "$out" "FROM-AAA" "[rule-packs] precedence: between packs, the first plugin id in sort order, whatever the registry order"
  hasnt "$out" "FROM-ZZZ" "[rule-packs] precedence: …and only that one"
  rp_reg "$reg0" "aaa@acme=$X|$A"
  hasnt "$(rp_cmd "$P" "$B" "contract-probe" CLAUDE_CONFIG_DIR="$C")" "FROM-AAA" "[rule-packs] project scope: an entry of another project is not served"
  has "$(rp_cmd "$P" "$A" "contract-probe" CLAUDE_CONFIG_DIR="$C")" "FROM-AAA" "[rule-packs] project scope: …and is in its own"
  rp_reg "$reg0" "aaa@acme=$X"; printf '{"enabledPlugins": {"aaa@acme": false}}' > "$C/settings.json"
  hasnt "$(rp_cmd "$P" "$B" "contract-probe" CLAUDE_CONFIG_DIR="$C")" "FROM-AAA" "[rule-packs] enabled: false in the user settings, not served"
  mkdir -p "$B/.claude"; printf '{"enabledPlugins": {"aaa@acme": true}}' > "$B/.claude/settings.json"
  has "$(rp_cmd "$P" "$B" "contract-probe" CLAUDE_CONFIG_DIR="$C")" "FROM-AAA" "[rule-packs] enabled: true in the project settings, the later file, is served"
  printf '{"enabledPlugins": {}}' > "$C/settings.json"; rm -f "$B/.claude/settings.json"
  hasnt "$(rp_cmd "$P" "$B" "contract-probe" CLAUDE_CONFIG_DIR="$C")" "FROM-AAA" "[rule-packs] enabled: named by no settings file, not served"
}

# ── dependents ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Each row of `## Dependent calls` is a call another repository makes into this one; its probe makes that call the way the
# dependent does, on the repo copy: the copy's owner fixture sourced, the baton forms on a kit baton staged in the copy's plugin
# (tests/fixtures/baton-dependent.sh as kit:dep-probe), the kit-root scripts and the adapters in scratch repositories, the
# imported modules and their names, the gates with the dependent's flags. Every expected value comes from the row (hrc, htick):
# a change of what a call gives goes green only by editing its row, which the change rule then makes name the call. DEP_CALLS
# lists the probes; the family compares it with the rows both ways, like cli.
SDLC=plugins/vibemaestro-sdlc
DBX=kb/research-runs/2026-10-26-dependent-batons   # private (kb/): the pinned copies of a dependent's kit batons
BAT="$SDLC/scripts/baton.py"
KB="$SDLC/scripts/kb.py"
IBS="$SDLC/scripts/intent-branch.sh"
DEP_CALLS="tests/fixtures/baton-owner.sh
owner_asked <plugin> <dir> <state dir> <session id> <sign arguments>
CLAUDE_CODE_SESSION_ID
XDG_STATE_HOME
$BAT check kit:<name>
$BAT check <script path>
kit:release-promote
kit:publish-public
$BAT rehearse kit:<name> <args>
$BAT mode auto
$BAT sign --by coordinator-auto --seal <seal> kit:<name> <args>
$BAT sign --by owner --seal <seal> kit:<name> <args>
$BAT run kit:<name> <args>
$BAT go --reuse <script path> <args>
BATON_PHASE BATON_PLAN BATON_WRITES BATON_PLUGIN_ROOT
scripts/scan-internal-terms.sh --terms <file> --tree
scripts/export-public.sh <rev> <outdir>
$SDLC/gates/gate_common.py
$SDLC/gates/backends
$SDLC/scripts/sdlc_config.py
$SDLC/scripts/sdlc_config.py get <key> --root <dir>
$SDLC/scripts/rule_packs.py
$SDLC/scripts/vsdlc.py
$KB init --lang en
$KB config check
$KB new <kind> <slug> --date <date>
$KB check spec <date>-<slug>
$KB check current-state
$KB check current-state <file>
$KB check current-state --diff <base>...<head> --body-file <file> --config-ref <ref>
$SDLC/gates/commit_discipline.py <base> <head> --body-file <file> --config-ref <ref>
$SDLC/gates/commit_discipline.py <base> <head> --body-file <file> --cwd <dir>
$SDLC/gates/pr_sensitive.py --pr <n> --repo <owner/name> --config-ref <ref>
$SDLC/gates/pr_sensitive.py --payload <file> --cwd <dir>
$SDLC/gates/pr_title.py --pr <n> --repo <owner/name> --config-ref <ref>
$SDLC/gates/pr_title.py --cwd <dir>
$SDLC/gates/pr_body.py --pr <n> --repo <owner/name> --config-ref <ref>
$IBS create-intent --slug <slug>
$IBS create-intent --slug <slug> --base <ref>
$IBS worker-branch --intent <slug> --name <branch> --no-checkout
$IBS integrate --intent <slug> --to origin
$SDLC/scripts/open-pr.sh --title <title> --summary <file> --evidence <file> --draft
$SDLC/scripts/open-pr.sh --title <title> --summary <file> --evidence <file> --dry-run --fixes <n>
$SDLC/scripts/open_pr.py --title <title> --summary-file <file> --evidence-file <file> --dry-run --payload-out <file>
$SDLC/rules/batonrun.instructions.md
$SDLC/hooks/hooks.json
$SDLC/scripts/session-start.py
$SDLC/skills/intake/SKILL.md"

# hrc <holds> <n> — the n-th `rc N` of a row's holds (empty when it has none); htick <holds> <n> — its n-th name in backticks;
# hticks <holds> <from> — its names in backticks from the from-th on, one per line
hrc() { printf '%s\n' "$1" | grep -oE '(^|[^a-z])rc [0-9]+' | sed -n "$2s/.*rc //p"; }
htick() { printf '%s\n' "$1" | grep -oE '`[^`]+`' | sed -n "$2s/^.\(.*\).$/\1/p"; }
hticks() { printf '%s\n' "$1" | grep -oE '`[^`]+`' | sed -n "$2,\$s/^.\(.*\).$/\1/p"; }
# dep_names <call> <names> — the names among <names> that the call (a list of variable names) also holds, sorted, one line
dep_names() { printf '%s\n' $2 | grep -xF -f <(printf '%s\n' $1) | sort | tr '\n' ' '; }
# hpre <text> — the text up to its first `<` (the literal head of a line shape such as `seal <seal> …`)
hpre() { printf '%s' "${1%%<*}"; }

# dep_baton <repo copy> — the dependent's baton flow once, on a copy of the plugin with the probe baton as kit:dep-probe, the
# copy's owner fixture sourced in a subshell for each use; writes into $DS one file per step: rc-<step>, out-<step>
dep_baton() {
  local R=$1 W S seal fx="$1/tests/fixtures/baton-owner.sh"; DB=$(fresh)/p; W=$(fresh); S=$(fresh)
  cp -R "$R/$SDLC" "$DB"; cp "$R/tests/fixtures/baton-dependent.sh" "$DB/batons/dep-probe.sh"
  ( . "$fx" && baton_isolate "$DB" ) || bad "[dependents] instrument: the copy's owner fixture isolates the plugin copy"
  DA=(kit:dep-probe "$W/f" hello)
  db() { local k=$1; shift; ( cd "$W" && cenv XDG_STATE_HOME="$S" CLAUDE_CODE_SESSION_ID=s-owner python3 "$DB/scripts/baton.py" "$@" ) > "$DS/out-$k" 2>&1; echo $? > "$DS/rc-$k"; }
  db check check kit:dep-probe
  for f in release-promote publish-public; do   # a dependent's own baton, pinned: staged as a kit baton beside the probe baton (absent in the public export)
    [ -f "$R/$DBX/$f.sh" ] && { cp "$R/$DBX/$f.sh" "$DB/batons/$f.sh"; db "check-$f" check "kit:$f"; }
  done
  cp "$R/tests/fixtures/baton-positional.sh" "$W/act.sh"; db check-path check "$W/act.sh"
  db rehearse rehearse "${DA[@]}"
  cp "$W/f.env" "$DS/env-rehearse" 2>/dev/null
  seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$DS/out-rehearse")
  ( . "$fx" && mode_asked "$DB" "$W" "$S" s-owner auto ) >/dev/null 2>&1    # the owner's dialog for the mode change
  db mode mode auto
  ( . "$fx" && mode_asked "$DB" "$W" "$S" s-owner auto ) >/dev/null 2>&1
  db mode2 mode auto
  db sign-session sign --by coordinator-auto --seal "${seal:-none}" "${DA[@]}"
  db sign-bare sign --by owner --seal "${seal:-none}" "${DA[@]}"
  ( . "$fx" && owner_asked "$DB" "$W" "$S" s-other --by owner --seal "${seal:-none}" "${DA[@]}" ) > "$DS/out-asked-other" 2>/dev/null
  db sign-other-session sign --by owner --seal "${seal:-none}" "${DA[@]}"
  ( . "$fx" && owner_asked "$DB" "$W" "$S" s-owner --by owner --seal "${seal:-none}" "${DA[@]}" ) > "$DS/out-asked" 2>/dev/null
  db sign-owner sign --by owner --seal "${seal:-none}" "${DA[@]}"
  : > "$W/f.env"; db run run "${DA[@]}"
  cp "$W/f.env" "$DS/env-run" 2>/dev/null
  cp "$R/tests/fixtures/baton-positional.sh" "$W/old.sh"; touch -d '1 hour ago' "$W/old.sh"
  db go-plain go "$W/old.sh" "$W/g1" hi
  db go-reuse go --reuse "$W/old.sh" "$W/g2" hi
  DSTATE=$S
}

# py_names <dir> <module> <name>... — the names a module imported from <dir> lacks (empty: all there), or `unimportable`
py_names() {
  local d=$1 m=$2; shift 2
  ( cd "$d" && cenv python3 -B -c 'import importlib, sys
sys.path.insert(0, ".")
try:
    m = importlib.import_module(sys.argv[1])
except Exception as e:
    print("unimportable: %s" % e); sys.exit(0)
print(" ".join(n for n in sys.argv[2:] if not hasattr(m, n)))' "$m" "$@" ) 2>&1
}

# dep_repo — a git repository on main with a branch feat/x of one commit and origin/main at main; prints its path
dep_repo() {
  local r; r=$(fresh)/r; git_ init -q -b main "$r"; echo a > "$r/a"; git_ -C "$r" add -A; git_ -C "$r" commit -q -m "feat: a"
  git_ -C "$r" checkout -q -b feat/x; echo b > "$r/b"; git_ -C "$r" add -A; git_ -C "$r" commit -q -m "feat: b"
  git_ -C "$r" update-ref refs/remotes/origin/main main; printf '%s' "$r"
}

# drc <dir> <command...> — the rc of a command run from <dir> with the failing gh first in PATH
drc() { local d=$1; shift; ( cd "$d" && cenv PATH="$DG:$PATH" "$@" ) >/dev/null 2>&1; echo $?; }

# dep_kb — a repository after `kb.py init --lang en` (its config then also watching infrastructure/, with a title pattern), with
# origin/main, a branch feat/i changing a watched path and feat/n another; then the kb and adapter calls of a dependent's flow
# test, each rc into $DS, in the dependent's order (new intent, spec, plan, check, create-intent, worker-branch, integrate)
dep_kb() {
  local k O
  DK=$(fresh)/k; git_ init -q -b main "$DK"
  echo $(cd "$DK" && cenv python3 "$DP/scripts/kb.py" init --lang en >/dev/null 2>&1; echo $?) > "$DS/rc-kb-init"
  cp "$DK/.vibemaestro/sdlc.json" "$DS/init-config.json"
  python3 -c 'import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.setdefault("current_state", {})["watch"] = ["infrastructure/"]
d.setdefault("pr", {}).setdefault("title", {})["pattern"] = "^[a-z]+(\\([^()]+\\))?!?: \\S"
json.dump(d, open(p, "w"), indent=2)' "$DK/.vibemaestro/sdlc.json"
  git_ -C "$DK" add -A; git_ -C "$DK" commit -q -m "chore: kb"; git_ -C "$DK" update-ref refs/remotes/origin/main main
  for k in i n; do
    git_ -C "$DK" checkout -q -b "feat/$k" main; mkdir -p "$DK/infrastructure"
    if [ "$k" = i ]; then echo x > "$DK/infrastructure/x"; else echo x > "$DK/other"; fi
    git_ -C "$DK" add -A; git_ -C "$DK" commit -q -m "feat: $k"
  done
  git_ -C "$DK" checkout -q main
  drc "$DK" python3 "$DP/scripts/kb.py" config check > "$DS/rc-kb-config"
  for k in intent spec plan; do drc "$DK" python3 "$DP/scripts/kb.py" new "$k" dep-probe --date 2026-10-15 > "$DS/rc-kb-new-$k"; done
  drc "$DK" python3 "$DP/scripts/kb.py" check spec 2026-10-15-dep-probe > "$DS/rc-kb-check-spec"
  cp "$DK/kb/specs/2026-10-15-dep-probe.md" "$DS/spec.md"
  python3 -c 'import re, sys
p = sys.argv[1]; s = re.sub(r"<FILL:[^>]*>", "filled", open(p).read(), flags=re.S); open(p, "w").write(s)' "$DK/kb/specs/2026-10-15-dep-probe.md"
  drc "$DK" python3 "$DP/scripts/kb.py" check spec 2026-10-15-dep-probe > "$DS/rc-kb-check-spec-filled"
  cp "$DS/spec.md" "$DK/kb/specs/2026-10-15-dep-probe.md"
  drc "$DK" python3 "$DP/scripts/kb.py" check current-state > "$DS/rc-kb-cs"
  O=$(fresh)/o; git_ init -q -b main "$O"; mkdir -p "$O/.vibemaestro"; cp "$DK/.vibemaestro/sdlc.json" "$O/.vibemaestro/"
  drc "$O" python3 "$DP/scripts/kb.py" check current-state "$DK/kb/current-state.md" > "$DS/rc-kb-cs-file"
  k=$(cenv python3 "$DP/scripts/sdlc_config.py" get current_state.limits.lines --root "$O" 2>/dev/null)
  for k in $(seq 0 "${k:-120}"); do echo "- line $k"; done > "$DS/big.md"   # one line over the cap
  drc "$O" python3 "$DP/scripts/kb.py" check current-state "$DS/big.md" > "$DS/rc-kb-cs-big"
  drc "$DK" bash "$DP/scripts/intent-branch.sh" create-intent --slug 2026-10-15-dep-probe > "$DS/rc-ib-create"
  drc "$DK" bash "$DP/scripts/intent-branch.sh" worker-branch --intent 2026-10-15-dep-probe --name task/dep-1 --no-checkout > "$DS/rc-ib-worker"
  drc "$DK" bash "$DP/scripts/intent-branch.sh" integrate --intent 2026-10-15-dep-probe --to origin > "$DS/rc-ib-integrate"
  drc "$DK" bash "$DP/scripts/open-pr.sh" --title "feat: x" --summary "$DF" --evidence "$DF" --draft > "$DS/rc-op-main"
  git_ -C "$DK" worktree add -q -b feat/pl "$DK.wt" main
  drc "$DK.wt" python3 "$DP/scripts/open_pr.py" --title "feat(x): y" --summary-file "$DF" --evidence-file "$DF" --dry-run --payload-out "$DS/payload.json" > "$DS/rc-op-core"
  ( cd "$DK.wt" && cenv PATH="$DG:$PATH" bash "$DP/scripts/open-pr.sh" --title "feat: x" --summary "$DF" --evidence "$DF" --dry-run --fixes 7 ) > "$DS/out-op-dry" 2>/dev/null
  echo $? > "$DS/rc-op-dry"
  drc "$DK" python3 "$DP/scripts/kb.py" new intent dep-base --date 2026-10-15 >/dev/null
  drc "$DK" bash "$DP/scripts/intent-branch.sh" create-intent --slug 2026-10-15-dep-base --base feat/n > "$DS/rc-ib-create-base"   # a ref that is not HEAD
}

# dep_probe <repo copy> <call> <holds> — the probe of one row, every expected value read from <holds>
dep_probe() {
  local R=$1 c=$2 h=$3 L="[dependents] $2" X out r t n f
  case "$c" in
    tests/fixtures/*.sh)
      for f in $(hticks "$h" 1); do
        eq "$(bash -c '. "$1" >/dev/null 2>&1 && declare -F "$2"' _ "$R/$c" "$f")" "$f" "$L: sourced, it defines $f"
      done;;
    "owner_asked "*)
      eq "$(cat "$DS/out-asked")" "$(htick "$h" 1)" "$L: the guard hook's answer for the owner's sign";;
    CLAUDE_CODE_SESSION_ID)
      eq "$(cat "$DS/out-asked-other")" ask "$L: instrument, the guard hook asked for the other session"
      eq "$(cat "$DS/rc-sign-other-session")" "$(hrc "$h" 1)" "$L: owner_asked for another session id, then sign";;
    XDG_STATE_HOME)
      t=$(htick "$h" 1); has "$(cat "$DS/out-run")" "${t/\$XDG_STATE_HOME/$DSTATE}/" "$L: the run log lies under $t";;
    "$BAT check kit:<name>")
      eq "$(cat "$DS/rc-check")" "$(hrc "$h" 1)" "$L: rc"
      for f in $(hticks "$h" 1); do grep -q "^# $f:" "$R/tests/fixtures/baton-dependent.sh" && ok "$L: the probe baton's header holds $f" || bad "$L: the probe baton's header holds $f"; done;;
    kit:release-promote | kit:publish-public)
      # the row: backtick 1 the call, 2 on the header words; the copy is a dependent's baton at a recorded blob id, kept in a private folder
      f=${c#kit:}; t="$R/$DBX/$f.sh"
      if [ ! -f "$t" ]; then
        if [ "$(tree_shape "$R")" = export ]; then echo "  (not counted: $L: the pinned copies are not in the public export, probe not run)"
        else bad "$L: the pinned copy $DBX/$f.sh is missing from the private tree"; fi
      else
        eq "$(htick "$h" 1)" "$BAT check kit:$f" "$L: the row names the call the probe makes"
        eq "$(cat "$DS/rc-check-$f")" "$(hrc "$h" 1)" "$L: rc of $(htick "$h" 1)"
        for n in $(hticks "$h" 2); do grep -q "^# $n:" "$t" && ok "$L: the pinned copy's header holds $n" || bad "$L: the pinned copy's header holds $n"; done
        eq "$(python3 - "$t" <<'PY'
import hashlib, sys
d = open(sys.argv[1], "rb").read()
print(hashlib.sha1(b"blob %d\0" % len(d) + d).hexdigest())
PY
)" "$(sed -n "s/^| \`$f.sh\` | \`\([0-9a-f]*\)\`.*/\1/p" "$R/$DBX/README.md")" "$L: the pinned copy is the blob its README records"
      fi;;
    "$BAT check <script path>")
      eq "$(cat "$DS/rc-check-path")" "$(hrc "$h" 1)" "$L: rc"
      for f in $(hticks "$h" 1); do grep -q "^# $f:" "$R/tests/fixtures/baton-positional.sh" && ok "$L: the probe baton's header holds $f" || bad "$L: the probe baton's header holds $f"; done;;
    "$BAT rehearse kit:<name> <args>")
      eq "$(cat "$DS/rc-rehearse")" "$(hrc "$h" 1)" "$L: rc"
      t=$(hpre "$(htick "$h" 1)"); nonempty "$(grep -F -- "$t" "$DS/out-rehearse" | grep -E "^${t}[^ ]+ ")" "$L: a stdout line '$(htick "$h" 1)'";;
    "$BAT mode auto")
      eq "$(cat "$DS/rc-mode") $(cat "$DS/rc-mode2")" "$(hrc "$h" 1) $(hrc "$h" 1)" "$L: rc, both calls"
      eq "$(cat "$DS/out-mode")" "$(htick "$h" 1)" "$L: the first call's one stdout line"
      eq "$(cat "$DS/out-mode2")" "$(htick "$h" 2)" "$L: the next call's one stdout line";;
    "$BAT sign --by coordinator-auto --seal <seal> kit:<name> <args>")
      eq "$(cat "$DS/rc-sign-session")" "$(hrc "$h" 1)" "$L: rc for a baton whose Stops is not none";;
    "$BAT sign --by owner --seal <seal> kit:<name> <args>")
      eq "$(cat "$DS/rc-sign-owner")" "$(hrc "$h" 1)" "$L: rc right after owner_asked for that very call"
      eq "$(cat "$DS/rc-sign-bare")" "$(hrc "$h" 2)" "$L: rc without owner_asked (the bare form)";;
    "$BAT run kit:<name> <args>")
      eq "$(cat "$DS/rc-run")" "$(hrc "$h" 1)" "$L: rc"
      t=$(hpre "$(htick "$h" 1)"); f=$(sed -n "s/^$t[0-9]* writes\{0,1\} — //p" "$DS/out-run")
      nonempty "$f" "$L: a stdout line '$(htick "$h" 1)'"
      has "$(cat "$f" 2>/dev/null)" "$(htick "$h" 2)" "$L: …whose run log holds '$(htick "$h" 2)'";;
    "$BAT go --reuse <script path> <args>")
      eq "$(cat "$DS/rc-go-reuse")" "$(hrc "$h" 1)" "$L: rc with --reuse"
      eq "$(cat "$DS/rc-go-plain")" "$(hrc "$h" 2)" "$L: rc without --reuse";;
    "BATON_PHASE BATON_PLAN BATON_WRITES BATON_PLUGIN_ROOT")
      has "$(cat "$DS/out-rehearse")" "PLAN create" "$L: BATON_PHASE rehearse: the write is planned"
      has "$(cat "$DS/out-run")" "run: ok" "$L: BATON_PHASE run: the write is done"
      for t in rehearse:1 run:2; do   # each `the <phase> phase … gets <names>` part of the row against the line of that phase:
        # the rehearse call logs its one phase; the run call logs rehearse, run and postcheck, in that order
        f=$(printf '%s\n' "$h" | tr ';' '\n' | grep -F "the ${t%:*} phase")
        nonempty "$f" "$L: the row says what the ${t%:*} phase gets"
        eq "$(dep_names "$c" "$(hticks "$f" 1 | tr '\n' ' ')")" "$(dep_names "$c" "$(sed -n "${t#*:}p" "$DS/env-${t%:*}" 2>/dev/null)")" "$L: the ${t%:*} phase gets what the row says"
      done;;
    "scripts/scan-internal-terms.sh --terms <file> --tree")
      X=$(fresh); git_ init -q -b main "$X/r"; printf 'zq-dep-term\n' > "$X/terms"
      echo "a zq-dep-term" > "$X/r/hit.txt"; echo clean > "$X/r/b.txt"; git_ -C "$X/r" add -A; git_ -C "$X/r" commit -q -m x
      out=$(cd "$X/r" && bash "$R/scripts/scan-internal-terms.sh" --terms "$X/terms" --tree 2>&1); r=$?
      eq "$r" "$(hrc "$h" 1)" "$L: rc when a term is in a tracked file"
      has "$out" "hit.txt" "$L: …and the output names that file"
      git_ -C "$X/r" rm -q hit.txt; git_ -C "$X/r" commit -q -m y
      out=$(cd "$X/r" && bash "$R/scripts/scan-internal-terms.sh" --terms "$X/terms" --tree 2>&1); r=$?
      eq "$r" "$(hrc "$h" 2)" "$L: rc when none is"
      eq "$(printf '%s\n' "$out" | tail -n 1)" "$(htick "$h" 1)" "$L: …and its last line";;
    "scripts/export-public.sh <rev> <outdir>")
      X=$(fresh); cp -R "$R" "$X/k"; git_ init -q -b main "$X/k"; git_ -C "$X/k" add -A; git_ -C "$X/k" commit -q -m k
      out=$(cd "$X/k" && bash -s -- HEAD "$X/out" < "$R/scripts/export-public.sh" 2>/dev/null); r=$?
      eq "$r" "$(hrc "$h" 1)" "$L: run as 'bash -s -- <rev> <outdir>' with the script on stdin: rc"
      cp -R "$X/out" "$X/o2"; git_ init -q "$X/o2"; t=$(git_ -C "$X/o2" add -Af -- . && git_ -C "$X/o2" write-tree)
      [[ "$out" =~ ^[0-9a-f]{40}$ ]] && eq "$out" "$t" "$L: stdout is the tree id git write-tree gives for <outdir>" || bad "$L: stdout is one 40-hex tree id (got '${out:0:80}')"
      for f in $(hticks "$h" 1 | grep -xE '[A-Z]+'); do
        [ -f "$X/out/$f" ] && ok "$L: <outdir>/$f" || bad "$L: <outdir>/$f"
        for t in "$X/out"/plugins/*/; do [ -f "$t$f" ] || bad "$L: <outdir>/plugins/$(basename "$t")/$f"; done
      done;;
    "$SDLC/gates/gate_common.py"|"$SDLC/gates/backends"|"$SDLC/scripts/sdlc_config.py"|"$SDLC/scripts/rule_packs.py"|"$SDLC/scripts/vsdlc.py")
      t=$(basename "$c"); t=${t%.py}
      eq "$(py_names "$DP/$(htick "$h" 1)" "$t" $(hticks "$h" 2))" "" "$L: importable from $(htick "$h" 1), defines $(hticks "$h" 2 | tr '\n' ' ')";;
    "$SDLC/scripts/sdlc_config.py get <key> --root <dir>")
      for t in $(hticks "$h" 1); do
        out=$(cenv python3 "$DP/scripts/sdlc_config.py" get "$t" --root "$DK" 2>/dev/null); r=$?
        eq "$r" "$(hrc "$h" 1)" "$L: rc for $t"
        python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out" 2>/dev/null && ok "$L: …stdout is JSON" || bad "$L: …stdout is JSON (got '${out:0:80}')"
      done;;
    "$KB init --lang en")
      eq "$(cat "$DS/rc-kb-init")" "$(hrc "$h" 1)" "$L: rc in a git repository"
      eq "$(jget "$DK/$(htick "$h" 1)" "d.get('$(htick "$h" 2)')")" "$(htick "$h" 3)" "$L: it writes $(htick "$h" 1) whose $(htick "$h" 2) is $(htick "$h" 3)";;
    "$KB config check")
      eq "$(cat "$DS/rc-kb-config")" "$(hrc "$h" 1)" "$L: rc on the config kb.py init wrote";;
    "$KB new <kind> <slug> --date <date>")
      n=1; for t in $(hticks "$h" 1 | head -n 3); do
        eq "$(cat "$DS/rc-kb-new-$t" 2>/dev/null)" "$(hrc "$h" 1)" "$L: rc for $t"
        f=$(htick "$h" $((n+3))); f=${f/<date>/2026-10-15}; f=${f/<slug>/dep-probe}
        [ -f "$DK/$f" ] && ok "$L: …it writes $f" || bad "$L: …it writes $f"; n=$((n+1))
      done;;
    "$KB check spec <date>-<slug>")
      eq "$(cat "$DS/rc-kb-check-spec-filled")" "$(hrc "$h" 1)" "$L: rc on the spec kb.py new spec wrote, its blanks filled"
      eq "$(cat "$DS/rc-kb-check-spec")" "$(hrc "$h" 2)" "$L: rc while its blanks are not";;
    "$KB check current-state")
      eq "$(cat "$DS/rc-kb-cs")" "$(hrc "$h" 1)" "$L: rc on the ledger kb.py init wrote";;
    "$KB check current-state <file>")
      eq "$(cat "$DS/rc-kb-cs-file")" "$(hrc "$h" 1)" "$L: rc on the ledger kb.py init wrote, by absolute path from another repository"
      eq "$(cat "$DS/rc-kb-cs-big")" "$(hrc "$h" 2)" "$L: rc on a file over the line cap";;
    "$KB check current-state --diff "*)
      eq "$(drc "$DK" python3 "$DP/scripts/kb.py" check current-state --diff main...feat/n --body-file "$DF" --config-ref origin/main)" "$(hrc "$h" 1)" "$L: rc, no watched path changed"
      eq "$(drc "$DK" python3 "$DP/scripts/kb.py" check current-state --diff main...feat/i --body-file "$DF" --config-ref origin/main)" "$(hrc "$h" 2)" "$L: rc, a watched path changed and the ledger did not"
      eq "$(drc "$DK" python3 "$DP/scripts/kb.py" check current-state --diff main...feat/n --body-file "$DF" --config-ref no-such-ref)" "$(hrc "$h" 3)" "$L: rc, a config ref that does not resolve";;
    "$SDLC/gates/commit_discipline.py <base> <head> --body-file <file> --config-ref <ref>")
      eq "$(drc "$DR" python3 "$DP/gates/commit_discipline.py" main feat/x --body-file "$DF" --config-ref origin/main)" "$(hrc "$h" 1)" "$L: rc on one plain commit"
      n=$(cenv python3 "$DP/scripts/sdlc_config.py" get "$(htick "$h" 1)" --root "$DR" 2>/dev/null)
      git_ -C "$DR" checkout -q -b feat/t main
      for t in $(seq 0 "${n:-0}"); do echo "$t" > "$DR/t"; git_ -C "$DR" add -A; git_ -C "$DR" commit -q -m "feat: t$t"; done
      git_ -C "$DR" checkout -q feat/x
      eq "$(drc "$DR" python3 "$DP/gates/commit_discipline.py" main feat/t --body-file "$DF" --config-ref origin/main)" "$(hrc "$h" 2)" "$L: rc, one file touched in $((n+1)) commits ($(htick "$h" 1) $n)"
      eq "$(drc "$DR" python3 "$DP/gates/commit_discipline.py" main feat/x --body-file "$DF" --config-ref no-such-ref)" "$(hrc "$h" 3)" "$L: rc, a config ref that does not read";;
    "$SDLC/gates/commit_discipline.py <base> <head> --body-file <file> --cwd <dir>")
      eq "$(drc "$DG" python3 "$DP/gates/commit_discipline.py" main feat/x --body-file "$DF" --cwd "$DR")" "$(hrc "$h" 1)" "$L: rc, called from another directory";;
    "$SDLC/gates/pr_sensitive.py --pr "*|"$SDLC/gates/pr_title.py --pr "*|"$SDLC/gates/pr_body.py --pr "*)
      t=${c#"$SDLC"/}; t=${t%% *}
      eq "$(drc "$DR" python3 "$DP/$t" --pr 7 --repo acme/app --config-ref origin/main)" "$(hrc "$h" 1)" "$L: rc, gh failing";;
    "$SDLC/gates/pr_sensitive.py --payload <file> --cwd <dir>")
      printf '{"title": "feat: x", "body": "clean"}' > "$DG/sens.json"
      eq "$(drc "$DG" python3 "$DP/gates/pr_sensitive.py" --payload "$DG/sens.json" --cwd "$DR")" "$(hrc "$h" 1)" "$L: rc for a clean payload"
      printf '{"title": "feat: x", "body": "mail jane@corp.test"}' > "$DG/sens.json"
      eq "$(drc "$DG" python3 "$DP/gates/pr_sensitive.py" --payload "$DG/sens.json" --cwd "$DR")" "$(hrc "$h" 2)" "$L: rc, an e-mail address in the body";;
    "$SDLC/gates/pr_title.py --cwd <dir>")
      for t in "feat: x" "a title without a type"; do
        printf '{"title": "%s", "draft": false, "files": ["a"], "head": "feat/x"}' "$t" > "$DG/title.json"
        r=$( (cd "$DG" && cenv python3 "$DP/gates/pr_title.py" --cwd "$DK" < "$DG/title.json") >/dev/null 2>&1; echo $?)
        if [ "$t" = "feat: x" ]; then eq "$r" "$(hrc "$h" 1)" "$L: rc, a title $(htick "$h" 1) allows"; else eq "$r" "$(hrc "$h" 2)" "$L: rc, a title it does not"; fi
      done;;
    "$IBS create-intent --slug <slug>")
      eq "$(cat "$DS/rc-ib-create")" "$(hrc "$h" 1)" "$L: rc";;
    "$IBS create-intent --slug <slug> --base <ref>")
      eq "$(cat "$DS/rc-ib-create-base")" "$(hrc "$h" 1)" "$L: rc"
      ne "$(git_ -C "$DK" rev-parse feat/n)" "$(git_ -C "$DK" rev-parse main)" "$L: instrument, the ref given is not the checked-out commit"
      eq "$(git_ -C "$DK" rev-parse -q --verify intent/2026-10-15-dep-base)" "$(git_ -C "$DK" rev-parse feat/n)" "$L: …the branch tip is that ref";;
    "$IBS worker-branch "*)
      eq "$(cat "$DS/rc-ib-worker")" "$(hrc "$h" 1)" "$L: rc";;
    "$IBS integrate "*)
      eq "$(cat "$DS/rc-ib-integrate")" "$(hrc "$h" 1)" "$L: rc from the main tree";;
    "$SDLC/scripts/open-pr.sh "*--dry-run*)
      eq "$(cat "$DS/rc-op-dry")" "$(hrc "$h" 1)" "$L: rc in a linked worktree"
      t=$(htick "$h" 2); t=${t/<n>/7}   # the probe passes --fixes 7
      eq "$(sed -n '/^{/,$p' "$DS/out-op-dry" | python3 -c 'import json,sys; b = json.load(sys.stdin).get(sys.argv[1]); print(type(b).__name__, sys.argv[2] in (b or ""))' "$(htick "$h" 1)" "$t" 2>/dev/null)" "str True" "$L: …stdout ends with a JSON payload whose $(htick "$h" 1) names $t";;
    "$SDLC/scripts/open-pr.sh "*)
      eq "$(cat "$DS/rc-op-main")" "$(hrc "$h" 1)" "$L: rc from the main tree";;
    "$SDLC/scripts/open_pr.py "*)
      eq "$(cat "$DS/rc-op-core")" "$(hrc "$h" 1)" "$L: rc in a linked worktree"
      eq "$(jget "$DS/payload.json" "type(d.get('$(htick "$h" 1)')).__name__")" str "$L: …the payload holds a $(htick "$h" 1) string";;
    "$SDLC/"*)
      [ -f "$R/$c" ] && [ ! -L "$R/$c" ] && ok "$L: a regular file" || bad "$L: a regular file";;
    *) bad "$L: no probe for this call";;
  esac
}

# fam_dependents <repo copy> — every row of `## Dependent calls`, and the rows against DEP_CALLS both ways
fam_dependents() {
  local R=$1 rows c h DS DB DA DSTATE DP="$1/$SDLC" DR DG DF DK
  rows=$(cj "$R" '"\n".join(r[0] for r in d["deps"])' | python3 -c 'import json,sys; print(json.load(sys.stdin))')
  nonempty "$rows" "[dependents] instrument: the contract lists dependent calls"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '%s\n' "$DEP_CALLS" | grep -qxF -- "$c" || bad "[dependents] $c: a contract row with no probe"
  done <<< "$rows"
  while IFS= read -r c; do
    printf '%s\n' "$rows" | grep -qxF -- "$c" || bad "[dependents] $c: a probe with no contract row"
  done <<< "$DEP_CALLS"
  DS=$(fresh); dep_baton "$R"
  DR=$(dep_repo); DG=$(fresh); DF="$DG/body"; echo summary > "$DF"
  printf '#!/bin/sh\necho "fake gh: no network" >&2\nexit 1\n' > "$DG/gh"; chmod +x "$DG/gh"
  eq "$(drc "$DR" python3 "$DP/gates/pr_title.py" --pr 7 --repo acme/app --config-reff origin/main)" 64 "[dependents] instrument: a misspelled flag is the usage rc 64"
  eq "$(hrc 'rc 0 here; rc 65 there' 2) $(htick 'a `x` and `y z`' 2)" "65 y z" "[dependents] instrument: a row's values are read (hrc, htick)"
  dep_kb
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '%s\n' "$DEP_CALLS" | grep -qxF -- "$c" || continue
    h=$(cj "$R" '[r[1] for r in d["deps"] if r[0] == '"$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$c")"'][0]' | python3 -c 'import json,sys; print(json.load(sys.stdin))')
    dep_probe "$R" "$c" "$h"
  done <<< "$rows"
  if [ -z "${DEP_NESTED:-}" ]; then   # the public export's shape: no fixture directory (private), no kb, no config: both probes say not run, nothing fails
    local X out; X=$(fresh)/x; mk_repo_copy "$X"; rm -rf "$X/kb" "$X/$DBX" "$X/.vibemaestro/sdlc.json"; : > "$X/$SDLC/LICENSE"
    out=$(DEP_NESTED=1 fam_dependents "$X" 2>&1)
    eq "$(tree_shape "$X")" export "[dependents] instrument: the scratch copy has the public export's shape"
    eq "$(printf '%s\n' "$out" | grep -c 'probe not run')" 2 "[dependents] the public export: both pinned-copy probes say not run"
    eq "$(printf '%s\n' "$out" | grep -c '^  FAIL \[dependents\] kit:')" 0 "[dependents] …and neither fails (the other probes are the private tree's)"
  fi
}

# ── local-state ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# The writer runs from the copy with no `session-notify` on the PATH, a throw-away HOME and XDG_STATE_HOME; each fact's value is
# read from the contract (the first `…` of its cell, or the whole cell) and checked against what the writer does.
# lfv <repo copy> <fact> — the first backticked value of a local-state fact, or the whole cell
lfv() { local v; v=$(fact "$1" local-state "$2"); printf '%s\n' "$v" | grep -qF '`' && v=$(printf '%s\n' "$v" | grep -oE '`[^`]+`' | head -1 | tr -d '`'); printf '%s' "$v"; }
# lsig <state home or -> <home> <session or -> <child 0|1> <cwd> <args...> — the writer, stdin passed through
lsig() {
  local xs=$1 hm=$2 sid=$3 ch=$4 cwd=$5; shift 5; local e=(PATH="$(bare_path nogh)" HOME="$hm")
  [ "$xs" = - ] || e+=(XDG_STATE_HOME="$xs"); [ "$sid" = - ] || e+=(CLAUDE_CODE_SESSION_ID="$sid"); [ "$ch" = 1 ] && e+=(CLAUDE_CODE_CHILD_SESSION=1)
  ( cd "$cwd" && env -i "${e[@]}" bash "$LSP/$LSW" "$@" )
}
# ljf <file> <python expression on d> — a value of the JSON file (a string bare, else JSON)
ljf() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print(v if isinstance(v,str) else json.dumps(v))' "$1" "$2" 2>/dev/null || echo "<unreadable>"; }
fam_local_state() {
  local R=$1 XS HM C SID=s-contract S=2026-01-02-contract S2=2026-01-02-child S3=2026-01-02-main F D v rx n st seen
  LSP="$1/$PLREL"
  facts_exact "$R" local-state "writer|place|place without XDG_STATE_HOME|session|stem|reader's files|schema|fields|local fields|local version|states|mode|question|report|transcript of a bound subagent|transcript of a session|unbound subagent|coordinator"
  XS=$(fresh)/state; HM=$(fresh)/home; mkdir -p "$HM"; C=$(fresh)
  LSW=$(lfv "$R" writer); [ -f "$LSP/$LSW" ] && ok "[local-state] writer: $LSW is in the plugin" || bad "[local-state] writer: $LSW is not in the plugin"
  # place
  lsig "$XS" "$HM" "$SID" 0 "$C" spec "$S" </dev/null
  F=$(lfv "$R" place); F=${F//\$XDG_STATE_HOME/$XS}; F=${F//<session>/$SID}; F=${F//<stem>/$S}; D=$(dirname "$F")
  [ -f "$F" ] && ok "[local-state] place: the file is where the contract says" || bad "[local-state] place: no file at $F"
  local XS0; XS0=$(fresh)/state; lsig "$XS0" "$HM" - 0 "$C" spec "$S" </dev/null
  [ ! -e "$XS0" ] && ok "[local-state] writer: nothing without CLAUDE_CODE_SESSION_ID" || bad "[local-state] writer: a file without CLAUDE_CODE_SESSION_ID"
  v=$(lfv "$R" "place without XDG_STATE_HOME"); v=${v/#\~/$HM}; v=${v//<session>/$SID}; v=${v//<stem>/$S}
  lsig - "$HM" "$SID" 0 "$C" spec "$S" </dev/null
  [ -f "$v" ] && ok "[local-state] place without XDG_STATE_HOME: the file is there" || bad "[local-state] place without XDG_STATE_HOME: no file at $v"
  rm -f "$v"; lsig rel/state "$HM" "$SID" 0 "$C" spec "$S" </dev/null
  [ -f "$v" ] && ok "[local-state] place without XDG_STATE_HOME: a relative one counts as unset" || bad "[local-state] place without XDG_STATE_HOME: a relative one was used"
  # session, coordinator, unbound subagent: a subagent's env has its main session's id
  has "$(fact "$R" local-state session)" CLAUDE_CODE_SESSION_ID "[local-state] session: the variable is named"
  lsig "$XS" "$HM" "$SID" 1 "$C" spec "$S2" </dev/null
  eq "$(ljf "$D/$S2.json" 'd["session"]')" "$SID" "[local-state] coordinator: a child's file is in its main session's directory and names that session"
  eq "$(ljf "$D/$S2.json" '[d["local"]["child"], d["local"]["agent"]]')" "[true, null]" "[local-state] unbound subagent: child true, agent null"
  lsig "$XS" "$HM" "$SID" 0 "$C" spec "$S3" </dev/null
  eq "$(ljf "$D/$S3.json" '[d["local"]["child"], d["local"]["agent"]]')" "[false, null]" "[local-state] transcript of a session: child false, agent null"
  lsig "$XS" "$HM" "$SID" 0 "$C" bind "$S2" --agent a1b2c3 </dev/null
  eq "$(ljf "$D/$S2.json" '[d["session"], d["local"]["agent"]]')" "[\"$SID\", \"a1b2c3\"]" "[local-state] transcript of a bound subagent: bind writes local.agent"
  # stem
  rx=$(lfv "$R" stem); has "$(fact "$R" local-state stem)" "at most 80" "[local-state] stem: its length is stated"
  python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' "$rx" "$S" && ok "[local-state] stem: the stem used here matches the pattern" || bad "[local-state] stem: the pattern does not match $S"
  lsig "$XS" "$HM" "$SID" 0 "$C" spec my-intent </dev/null 2>/dev/null
  lsig "$XS" "$HM" "$SID" 0 "$C" spec "2026-01-02-$(printf 'a%.0s' $(seq 1 70))" </dev/null 2>/dev/null
  # reader's files
  eq "$(cd "$D" && ls -A | grep -E '\.json$' | grep -v '^\.' | sort | tr '\n' ' ')" "$(printf '%s.json\n' "$S" "$S2" "$S3" | sort | tr '\n' ' ')" "[local-state] reader's files: exactly one per written stem (a stem outside the pattern or over 80 is not written)"
  # shape and versions
  eq "$(ljf "$F" 'd["schema"]')" "$(lfv "$R" schema)" "[local-state] schema"
  eq "$(ljf "$F" '" ".join(d)')" "$(lfv "$R" fields)" "[local-state] fields: exactly these, in this order"
  eq "$(ljf "$F" '" ".join(d["local"])')" "$(lfv "$R" "local fields")" "[local-state] local fields"
  eq "$(ljf "$F" 'd["local"]["v"]')" "$(lfv "$R" "local version")" "[local-state] local version"
  # states, question, report
  seen="$(ljf "$F" 'd["state"]')"
  python3 -c 'print("Q"*2500)' | lsig "$XS" "$HM" "$SID" 0 "$C" ask "$S"
  st=$(ljf "$F" 'd["state"]'); seen="$seen $st"; n=$(lfv "$R" question)
  eq "$(ljf "$F" '[d["state"], len(d["question"])]')" "[\"waiting\", $n]" "[local-state] question: cut to $n characters, while waiting"
  python3 -c 'print("R"*900)' | lsig "$XS" "$HM" "$SID" 0 "$C" done "$S"
  st=$(ljf "$F" 'd["state"]'); seen="$seen $st"; n=$(fact "$R" local-state report | grep -oE '`[0-9]+`' | tr -d '`')
  eq "$(ljf "$F" '[d["state"], len(d["tail"]), d["tail"][:3]]')" "[\"done\", $n, \"RRR\"]" "[local-state] report: tail keeps its first $n characters, while done"
  eq "$seen" "$(lfv "$R" states)" "[local-state] states: spec, ask and done give exactly these, in this order"
  # mode
  eq "$(python3 -c 'import os,stat,sys; print("%o %o" % (stat.S_IMODE(os.stat(sys.argv[1]).st_mode), stat.S_IMODE(os.stat(sys.argv[2]).st_mode)))' "$F" "$D")" \
     "$(lfv "$R" mode | sed 's/^0//') $(fact "$R" local-state mode | grep -oE '`0[0-7]+`' | sed -n 2p | tr -d '`' | sed 's/^0//')" "[local-state] mode: the file and its session directory"
}

# ── exactness of the item list, and the in-tree half of the version rule ────────────────────────────────────────────────────────
fam_contract() {
  local R=$1 ids proofs fa mv
  ids=$(cj "$R" '" ".join(r[0] for r in d["items"])' | tr -d '"')
  eq "$ids" "$ITEMS" "[contract] items: the contract lists exactly the items this suite proves, in order"
  proofs=$(cj "$R" '"|".join(r[2] for r in d["items"])' | tr -d '"')
  eq "$proofs" "$(for i in $ITEMS; do printf 'bash tests/test-contract.sh %s|' "$i"; done | sed 's/|$//')" "[contract] items: each proof is 'bash tests/test-contract.sh <id>'"
  eq "$(cj "$R" 'sorted(set(r[0] for r in d["facts"]) - set(r[0] for r in d["items"]))')" "[]" "[contract] facts: every fact belongs to an item"
  fa=$(cj "$R" 'd["frozen_at"]' | tr -d '"'); mv=$(python3 "$CT" version "$R/$PLREL")
  if [ "$mv" = unreleased ]; then
    ok "[contract] Frozen at $fa: no public release yet (the first release sets it to its version)"
  else
    python3 -c 'import sys; f=tuple(map(int,sys.argv[1].split("."))); m=tuple(map(int,sys.argv[2].split("."))); sys.exit(0 if f<=m and f[0]==m[0] else 1)' "$fa" "$mv" \
      && ok "[contract] Frozen at $fa: not above the released version $mv, same major" || bad "[contract] Frozen at $fa: above the released version $mv or another major"
  fi
}

fam_name() { echo "fam_${1//-/_}"; }

echo "== the contract against the real tree =="
N=0
for i in ${ONLY:-$ITEMS}; do
  R="$TMP/real-$i"; mk_repo_copy "$R"
  echo "-- $i"; "$(fam_name "$i")" "$R"; N=$((N+1))
done
if [ -n "$ONLY" ]; then echo; summary; exit $?; fi
R="$TMP/real-contract"; mk_repo_copy "$R"; echo "-- contract"; fam_contract "$R"

echo "== the version-bump rule against the base branch =="
OUT=$(cd "$SRC_ROOT" && python3 "$CT" base-check "$SRC_ROOT" "$CBASE" 2>&1); rc=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
case "$rc" in
  0) ok "[bump] the surface against the base: no change, or a change with its bump";;
  3) if [ "$(tree_shape "$SRC_ROOT")" = export ]; then   # the public export has one commit of its own and no origin: nothing to compare
       has "$OUT" "origin/main does not resolve" "[bump] the public export: no base to compare (its history is the private repo's), the check says so"
     else echo "  (not counted: base check not run)"; fi;;
  *) bad "[bump] the version-bump rule against the base is red (rc $rc; the reason is printed above)";;
esac

echo "== instrument: the version-bump rule on a scratch history =="
# bump_repo — a git repo holding the contract and the manifest of this checkout, version V, Frozen at V; prints its path
bump_repo() {
  local d; d=$(fresh)/b; mkdir -p "$d/$PLREL/.claude-plugin"
  cp "$SRC_ROOT/$PLREL/CONTRACT.md" "$d/$PLREL/CONTRACT.md"
  printf '{"name": "vibemaestro-sdlc", "version": "%s"}\n' "$1" > "$d/$PLREL/.claude-plugin/plugin.json"
  set_frozen "$d" "$1"
  git_ init -q -b main "$d"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m base; printf '%s' "$d"
}
set_frozen() { python3 - "$1/$PLREL/CONTRACT.md" "$2" <<'PY'
import re, sys
p, v = sys.argv[1:]; t = open(p).read(); open(p, "w").write(re.sub(r"^Frozen at: .*$", "Frozen at: " + v, t, count=1, flags=re.M))
PY
}
set_version() { printf '{"name": "vibemaestro-sdlc", "version": "%s"}\n' "$2" > "$1/$PLREL/.claude-plugin/plugin.json"; }
edit_surface() { python3 - "$1/$PLREL/CONTRACT.md" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]; t = open(p).read()
assert t.count(old) == 1, old
open(p, "w").write(t.replace(old, new, 1))
PY
}
bcheck() { python3 "$CT" base-check "$1" "$2" >/dev/null 2>&1; echo $?; }
B=$(bump_repo 1.0.0)
eq "$(bcheck "$B" HEAD)" 0 "[bump] instrument: no change against the base: green"
# row <entry> <rc> — that exit-code row of this checkout's contract, whatever its wording (the probes must survive a reworded row)
row() { grep -m1 -F "| \`$1\` | $2 |" "$SRC_ROOT/$PLREL/CONTRACT.md"; }
ROW=$(row scripts/kb.py 66)
nonempty "$ROW" "[bump] instrument: the contract has a row for scripts/kb.py rc 66"
edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"
eq "$(bcheck "$B" HEAD)" 1 "[bump] a reworded row without a version bump: red"
set_version "$B" 1.1.0
eq "$(bcheck "$B" HEAD)" 1 "[bump] a reworded row with a bump but 'Frozen at' left behind: red"
set_version "$B" 1.0.1; set_frozen "$B" 1.0.1
eq "$(bcheck "$B" HEAD)" 1 "[bump] a reworded row with only a patch bump: red (a surface change is at least minor)"
set_version "$B" 1.1.0; set_frozen "$B" 1.1.0
eq "$(bcheck "$B" HEAD)" 0 "[bump] a reworded row with a minor bump and 'Frozen at' 1.1.0: green"
eq "$(bcheck "$B" no-such-ref)" 1 "[bump] CONTRACT_BASE names a ref that does not resolve: red, not 'not run'"
B=$(bump_repo 1.0.0); edit_surface "$B" "$ROW"$'\n' ""; set_version "$B" 1.1.0; set_frozen "$B" 1.1.0
eq "$(bcheck "$B" HEAD)" 1 "[bump] a removed exit code with only a minor bump: red"
set_version "$B" 2.0.0; set_frozen "$B" 2.0.0
eq "$(bcheck "$B" HEAD)" 0 "[bump] a removed exit code with a major bump: green"
B=$(bump_repo 1.0.0); git_ -C "$B" rm -q --cached "$PLREL/CONTRACT.md"; git_ -C "$B" commit -q -m "no contract"
set_version "$B" 1.0.0
eq "$(bcheck "$B" HEAD)" 1 "[bump] a base without the contract and no bump: red"
set_version "$B" 1.1.0; set_frozen "$B" 1.1.0
eq "$(bcheck "$B" HEAD)" 0 "[bump] a base without the contract, the contract added with a bump: green"
B=$(bump_repo 1.0.0); T=$(fresh); cp -R "$B/." "$T/"; rm -rf "$T/.git"; git_ init -q -b main "$T"
eq "$(cd "$T" && python3 "$CT" base-check "$T" "" >/dev/null 2>&1; echo $?)" 3 "[bump] no origin/main and no CONTRACT_BASE: 'base check not run' (rc 3, not green, not red)"
has "$(cd "$T" && python3 "$CT" base-check "$T" "" 2>&1)" "base check not run" "[bump] …and it says so"

echo "== instrument: the surface needs a change file on a base with .changes/ =="
# cf_repo — bump_repo 1.0.0 whose base also has .changes/README.md and the version reset (the manifest carries no version, the
# CHANGELOG records 1.0.0 as released); sets B
cf_repo() {
  B=$(bump_repo 1.0.0); mkdir -p "$B/.changes"; echo x > "$B/.changes/README.md"
  printf '{"name": "vibemaestro-sdlc"}\n' > "$B/$PLREL/.claude-plugin/plugin.json"; set_rel "$B" 1.0.0
  git_ -C "$B" add -A; git_ -C "$B" commit -q -m changes
}
# set_rel <repo> <version|-> — the released version: the CHANGELOG's first heading (- : the private history, never released)
set_rel() {
  local h="## $2"; [ "$2" = - ] && h="## Private history"
  printf '# Changelog of vibemaestro-sdlc\n\n%s\n\n- patch: x\n' "$h" > "$1/$PLREL/CHANGELOG.md"
}
# cfc <repo> <plugins> <level> <file> — a change file in the working tree
cfc() { mkdir -p "$1/.changes"; printf -- '---\nplugins: %s\nlevel: %s\n---\none line\n' "$2" "$3" > "$1/.changes/$4"; }
# cfn <repo> <level> <file> <line> — a change file naming sdlc whose one line is <line>
cfn() { mkdir -p "$1/.changes"; printf -- '---\nplugins: vibemaestro-sdlc\nlevel: %s\n---\n%s\n' "$2" "$4" > "$1/.changes/$3"; }
# drow <call> — the dependent-call row of this checkout's contract for <call>
drow() { grep -m1 -F "| \`$1\` |" "$SRC_ROOT/$PLREL/CONTRACT.md"; }
DFIX=tests/fixtures/baton-owner.sh; DSIGN="$BAT sign --by owner --seal <seal> kit:<name> <args>"
# cf_probes <contract.py> — the change-file cases; prints one line per case: <tag> <rc>
cf_probes() { local CT=$1 F S
  cf_repo; edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"
  echo "C1 $(bcheck "$B" HEAD)"
  cfc "$B" vibemaestro-sdlc patch a.md; echo "C2 $(bcheck "$B" HEAD)"
  cfc "$B" vibemaestro-brain minor a.md; echo "C3 $(bcheck "$B" HEAD)"
  cfc "$B" "vibemaestro-brain, vibemaestro-sdlc" minor a.md; echo "C4 $(bcheck "$B" HEAD)"
  cf_repo; edit_surface "$B" "$ROW"$'\n' ""; cfc "$B" vibemaestro-sdlc minor a.md; echo "C5 $(bcheck "$B" HEAD)"
  cfc "$B" vibemaestro-sdlc major a.md; echo "C6 $(bcheck "$B" HEAD)"
  cf_repo; set_frozen "$B" 1.1.0; echo "C7 $(bcheck "$B" HEAD)"
  cf_repo; cfc "$B" vibemaestro-sdlc minor a.md; git_ -C "$B" add -A; git_ -C "$B" commit -q -m "pending on the base"
  edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"; echo "C8 $(bcheck "$B" HEAD)"
  cf_repo; git_ -C "$B" rm -q .changes/README.md; git_ -C "$B" commit -q -m "README gone"
  edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"; cfc "$B" vibemaestro-sdlc minor a.md; echo "C9 $(bcheck "$B" HEAD)"
  cf_repo; edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"; mkdir -p "$B/notes"
  printf -- '---\nplugins: vibemaestro-sdlc\nlevel: minor\n---\nx\n' > "$B/notes/n.txt"; ln -s ../notes/n.txt "$B/.changes/a.md"
  echo "C10 $(bcheck "$B" HEAD)"
  F=$(drow "$DFIX"); S=$(drow "$DSIGN")
  cf_repo; edit_surface "$B" "$F" "${F/$DFIX/tests/fixtures/baton-owner-v2.sh}"; cfn "$B" major a.md 'the owner fixture moved'
  echo "C11 $(bcheck "$B" HEAD)"
  cfn "$B" major a.md "\`$DFIX\` is now \`tests/fixtures/baton-owner-v2.sh\`"; echo "C12 $(bcheck "$B" HEAD)"
  cf_repo; edit_surface "$B" "$S" "${S% |}, and only from the owner's own terminal |"; cfn "$B" major a.md 'owner signs from a terminal'
  echo "C13 $(bcheck "$B" HEAD)"
  cfn "$B" major a.md "$DSIGN: only from a terminal"; echo "C14 $(bcheck "$B" HEAD)"
  cfn "$B" major a.md "\`$DSIGN\`: only from a terminal"; echo "C15 $(bcheck "$B" HEAD)"
  cf_repo; edit_surface "$B" "$F" "$F"$'\n''| `tests/fixtures/new-helper.sh` | defines `x` |'; cfn "$B" minor a.md 'a new helper'
  echo "C16 $(bcheck "$B" HEAD)"
}
P=$(cf_probes "$CT")
probe() { printf '%s\n' "$P" | sed -n "s/^$1 //p"; }
eq "$(probe C1)" 1 "[changes] C1 a reworded row and no change file: red (no version bump asked)"
eq "$(probe C2)" 1 "[changes] C2 …with a patch change file naming sdlc: red (a surface change is at least minor)"
eq "$(probe C3)" 1 "[changes] C3 …with a minor change file naming another plugin: red"
eq "$(probe C4)" 0 "[changes] C4 …with a minor change file naming sdlc among others, version and 'Frozen at' unchanged: green"
eq "$(probe C5)" 1 "[changes] C5 a removed exit code with a minor change file: red"
eq "$(probe C6)" 0 "[changes] C6 …with a major change file: green"
eq "$(probe C7)" 1 "[changes] C7 'Frozen at' moved outside a release: red"
eq "$(probe C8)" 1 "[changes] C8 a change file already on the base does not count for this change: red"
eq "$(probe C9)" 0 "[changes] C9 a base whose .changes/README.md was deleted keeps the change-file rule (minor file, no bump: green)"
eq "$(probe C10)" 1 "[changes] C10 a change file that is a symlink does not count: red"
nonempty "$(drow "$DFIX")" "[changes] instrument: the contract has a dependent-call row for $DFIX"
nonempty "$(drow "$DSIGN")" "[changes] instrument: the contract has a dependent-call row for the owner's sign"
eq "$(probe C11)" 1 "[changes] C11 a renamed dependent call with a major change file that does not name it: red"
eq "$(probe C12)" 0 "[changes] C12 …with a major change file naming the old call in backticks: green"
eq "$(probe C13)" 1 "[changes] C13 what a dependent call holds changed (an owner sign that needs more), major file not naming it: red"
eq "$(probe C14)" 1 "[changes] C14 …the call named without backticks: red"
eq "$(probe C15)" 0 "[changes] C15 …the call named in backticks: green"
eq "$(probe C16)" 0 "[changes] C16 a dependent call added, with a minor change file that does not name it: green"
# planted breaks of the change-file check: each flips its probe
cbrk() {  # cbrk <label> <probe> <rc on the broken copy> <old> <new>
  local d="$TMP/cbrk-$1"; mkdir -p "$d/tests/fixtures" "$d/$PLREL/scripts"; cp "$CT" "$d/tests/fixtures/contract.py"
  cp "$SRC_ROOT/$PLREL/scripts/release.py" "$d/$PLREL/scripts/release.py"      # the copy reads change files as the checkout does
  mutate "$d/tests/fixtures/contract.py" "$4" "$5" || return
  local out rc got; out=$(capped cf_probes "$d/tests/fixtures/contract.py"); rc=$?   # capped: memory and time caps (fixtures/capped.sh)
  cap_red "$rc" "break [$1]" && return   # a cap hit is red by the cap, not a blind probe
  got=$(printf '%s\n' "$out" | sed -n "s/^$2 //p")
  [ "$got" = "$3" ] && ok "break [$1]: probe $2 flips to rc $3, so its check above would go red" || bad "break [$1]: probe $2 gives rc ${got:-none}, not $3: the probe is blind"
}
cbrk level-ignored C2 0 'if best is None or LEVELS.index(best) < LEVELS.index(need):' 'if best is None:'
cbrk plugin-ignored C3 0 '        if plugin in plugins:' '        if True:'
cbrk major-not-needed C5 0 '        need = "major" if lost else "minor"' '        need = "minor"'
cbrk frozen-unchecked C7 0 '    if base_t is not None and cur["frozen_at"] != base_t["frozen_at"] and cur_ver == base_ver:' '    if False:'
cbrk base-file-counted C8 0 'or git(repo, "cat-file", "-e", "%s:%s" % (base, rel))[0] == 0:' 'or False:'
cbrk symlink-counted C10 0 '        if os.path.islink(os.path.join(d, name)):' '        if False:'
cbrk tip-decides-mode C9 1 '    if git(repo, "log", "-1", "--full-history", "--format=%H", base, "--", ".changes/README.md")[1].strip():' '    if git(repo, "ls-tree", "--name-only", base, "--", ".changes")[1].strip():'
cbrk dep-name-ignored C11 0 '        if call is not None and call not in out and not any("`%s`" % call in line for line in lines):' '        if False:'
cbrk dep-name-bare C14 0 '        if call is not None and call not in out and not any("`%s`" % call in line for line in lines):' '        if call is not None and call not in out and not any(call in line for line in lines):'
cbrk dep-not-identity C13 0 ' | {("dep",) + tuple(r) for r in t["deps"]}' ''
cbrk never-change-mode C4 1 '    if git(repo, "log", "-1", "--full-history", "--format=%H", base, "--", ".changes/README.md")[1].strip():' '    if False:'

echo "== instrument: the release-time rule (a release, a hotfix, a back-merge) =="
# rl_repo — cf_repo whose origin/release is the base commit, then a surface change merged on main with its minor change file; sets B
rl_repo() {
  cf_repo; git_ -C "$B" update-ref refs/remotes/origin/release HEAD
  edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"; cfc "$B" vibemaestro-sdlc minor a.md; git_ -C "$B" add -A; git_ -C "$B" commit -q -m "a surface change"
}
# rl_release <repo> <version> <frozen> — what a release does to the contract's plugin (the change file consumed)
rl_release() { set_rel "$1" "$2"; set_frozen "$1" "$3"; rm -f "$1/.changes/a.md"; }
# fr_repo — rl_repo whose main reset the numbering after release (the CHANGELOG starts with the private history): the next
# release is the first public one; sets B
fr_repo() { rl_repo; set_rel "$B" -; git_ -C "$B" add -A; git_ -C "$B" commit -q -m "the version reset"; }
# pr_repo — origin/release left at a commit from before the reset (its manifest carries 1.0.0, the first public release never
# promoted), then main: the reset, the first release 0.1.0 (Frozen at 0.1.0), a surface change with its minor change file; sets B
pr_repo() {
  B=$(bump_repo 1.0.0); mkdir -p "$B/.changes"; echo x > "$B/.changes/README.md"; git_ -C "$B" add -A; git_ -C "$B" commit -q -m changes
  git_ -C "$B" update-ref refs/remotes/origin/release HEAD
  printf '{"name": "vibemaestro-sdlc"}\n' > "$B/$PLREL/.claude-plugin/plugin.json"; set_rel "$B" 0.1.0; set_frozen "$B" 0.1.0
  git_ -C "$B" add -A; git_ -C "$B" commit -q -m "the reset and the first release"
  edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"; cfc "$B" vibemaestro-sdlc minor a.md; git_ -C "$B" add -A; git_ -C "$B" commit -q -m "a surface change"
}
# rl_probes <contract.py> — one line per case: <tag> <rc>
rl_probes() { local CT=$1
  rl_repo; rl_release "$B" 1.1.0 1.1.0; echo "L1 $(bcheck "$B" HEAD)"
  rl_repo; rl_release "$B" 1.1.0 1.0.0; echo "L2 $(bcheck "$B" HEAD)"
  rl_repo; rl_release "$B" 1.1.0 1.0.0; git_ -C "$B" tag origin/release HEAD; echo "L8 $(bcheck "$B" HEAD)"
  rl_repo; rl_release "$B" 1.0.1 1.0.1; echo "L3 $(bcheck "$B" HEAD)"
  cf_repo; git_ -C "$B" update-ref refs/remotes/origin/release HEAD; edit_surface "$B" "$ROW"$'\n' ""; cfc "$B" vibemaestro-sdlc major a.md
  git_ -C "$B" add -A; git_ -C "$B" commit -q -m "a row removed"; rl_release "$B" 1.1.0 1.1.0; echo "L4 $(bcheck "$B" HEAD)"
  rl_release "$B" 2.0.0 2.0.0; echo "L5 $(bcheck "$B" HEAD)"
  cf_repo; git_ -C "$B" update-ref refs/remotes/origin/release HEAD; set_rel "$B" 1.0.1; set_frozen "$B" 1.0.1; echo "L6 $(bcheck "$B" HEAD)"
  cf_repo; git_ -C "$B" update-ref refs/remotes/origin/release HEAD; set_rel "$B" 1.0.1; echo "L7 $(bcheck "$B" HEAD)"
  cf_repo; git_ -C "$B" update-ref refs/remotes/origin/release HEAD; set_rel "$B" 1.0.1
  edit_surface "$B" "$ROW" "${ROW% |} (reworded) |"; echo "H1 $(bcheck "$B" origin/release)"
  cf_repo; git_ -C "$B" update-ref refs/remotes/origin/release HEAD; set_rel "$B" 1.0.1; echo "H2 $(bcheck "$B" origin/release)"
  cf_repo; git_ -C "$B" update-ref refs/remotes/origin/release HEAD; set_rel "$B" 1.0.1; set_frozen "$B" 1.0.1; echo "H3 $(bcheck "$B" origin/release)"
  fr_repo; rl_release "$B" 0.1.0 0.1.0; echo "F1 $(bcheck "$B" HEAD)"
  fr_repo; rl_release "$B" 0.1.0 1.0.0; echo "F2 $(bcheck "$B" HEAD)"
  pr_repo; rl_release "$B" 0.2.0 0.2.0; echo "F3 $(bcheck "$B" HEAD)"
}
P=$(rl_probes "$CT")
eq "$(probe L1)" 0 "[release] L1 a release after a surface change: minor above release, 'Frozen at' the new version: green"
eq "$(probe L2)" 1 "[release] L2 …with 'Frozen at' left at the old version: red"
eq "$(probe L3)" 1 "[release] L3 …raised only a patch: red"
eq "$(probe L4)" 1 "[release] L4 a release after a removed row, raised a minor: red"
eq "$(probe L5)" 0 "[release] L5 …raised a major with 'Frozen at' 2.0.0: green"
eq "$(probe L6)" 1 "[release] L6 a release with no surface change that moves 'Frozen at': red"
eq "$(probe L8)" 1 "[release] L8 …and a tag named origin/release at the head does not stand in for the branch: red"
eq "$(probe L7)" 0 "[release] L7 a release with no surface change and 'Frozen at' left: green"
eq "$(probe H1)" 1 "[hotfix] H1 a hotfix into release that changes the surface: red"
eq "$(probe H2)" 0 "[hotfix] H2 a hotfix with the surface of release: green"
eq "$(probe H3)" 1 "[hotfix] H3 a hotfix that moves 'Frozen at': red"
eq "$(probe F1)" 0 "[first] F1 the first public release after the reset: 0.1.0, below release's 1.0.0, 'Frozen at' 0.1.0: green"
eq "$(probe F2)" 1 "[first] F2 …with 'Frozen at' left at the old 1.0.0: red"
eq "$(probe F3)" 0 "[first] F3 the release after an unpromoted first one (origin/release still from before the reset): 0.2.0 compared with the base's 0.1.0: green"
rbrk() {  # rbrk <label> <probe> <rc on the broken copy> <old> <new>
  local d="$TMP/rbrk-$1"; mkdir -p "$d/tests/fixtures" "$d/$PLREL/scripts"; cp "$CT" "$d/tests/fixtures/contract.py"
  cp "$SRC_ROOT/$PLREL/scripts/release.py" "$d/$PLREL/scripts/release.py"
  mutate "$d/tests/fixtures/contract.py" "$4" "$5" || return
  local got; got=$(capped rl_probes "$d/tests/fixtures/contract.py" | sed -n "s/^$2 //p")   # capped: memory and time caps (fixtures/capped.sh)
  [ "$got" = "$3" ] && ok "break [$1]: probe $2 flips to rc $3, so its check above would go red" || bad "break [$1]: probe $2 gives rc ${got:-none}, not $3: the probe is blind"
}
rbrk frozen-not-set L2 0 '        if cur["frozen_at"] != cur_ver:' '        if False:'
rbrk minor-not-needed L3 0 '        elif vtuple(cur_ver)[:2] <= vtuple(ref_ver)[:2]:' '        elif False:'
rbrk major-not-needed L4 0 '        if lost and vtuple(cur_ver)[0] <= vtuple(ref_ver)[0]:' '        if False:'
rbrk frozen-free L6 0 '        if base_t is not None and cur["frozen_at"] != base_t["frozen_at"]:' '        if False:'
rbrk base-not-release L1 1 '    ref, what = (ref.strip(), "origin/release") if rc == 0 and ref.strip() else (base, "the base")' '    ref, what = base, "the base"'
rbrk hotfix-surface-free H1 0 '    if not same:
        bad.append("the surface changed in a %s' '    if False:
        bad.append("the surface changed in a %s'
rbrk hotfix-frozen-free H3 0 '% (kind, kind))
    if base_t is not None and cur["frozen_at"] != base_t["frozen_at"]:' '% (kind, kind))
    if False:'
rbrk release-ref-shadowed L8 0 '"refs/remotes/origin/release^{commit}"' '"origin/release^{commit}"'
rbrk hotfix-as-release H3 0 '        if kind in ("hotfix", "back-merge"):' '        if False:'
rbrk first-ordered F1 1 '    if not base_ver:
        if cur_ver != cur["frozen_at"]:' '    if False:
        if cur_ver != cur["frozen_at"]:'
rbrk first-frozen-free F2 0 '        if cur_ver != cur["frozen_at"]:' '        if False:'
rbrk stale-release-ordered F3 1 "    if what == \"origin/release\" and rc == 0 and '\"version\"' in rel_manifest:" '    if False:'

echo "== planted breaks: each check must go red on a copy with one break =="
# BRK <label> <family> <needle> <file under the repo> <old> <new>
BRK() {
  local d="$TMP/break-$1"; mk_repo_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
for e in scripts/intent-branch.sh scripts/open-pr.sh scripts/kb.py scripts/sdlc_config.py scripts/install_gates.py scripts/baton.py \
         gates/commit_discipline.py gates/pr_sensitive.py gates/pr_title.py gates/dead_branches.sh hooks/hooks.json; do
  f="fam_cli_$(printf '%s' "$e" | tr -c 'A-Za-z0-9\n' '_')"
  eval "$f() { CLI_ONLY='$e' fam_cli \"\$1\"; }"
done
MP=.claude-plugin/marketplace.json; MAN=$PLREL/.claude-plugin/plugin.json; ACT=.github/actions/fetch-plugin/action.yml
BRK marketplace-renamed fam_marketplace '[marketplace] marketplace name' $MP '"name": "vibemaestro",' '"name": "vibemaestro-next",'
BRK plugin-renamed fam_marketplace '[marketplace] plugin id' $MAN '"name": "vibemaestro-sdlc"' '"name": "vibemaestro-sdlc-next"'
BRK source-form fam_layout '[layout] plugin source' $MP '"source": "./plugins/vibemaestro-sdlc"' '"source": "plugins/vibemaestro-sdlc"'
BRK input-renamed fam_fetch_action '[fetch-action] inputs' $ACT '  dest:' '  target:'
BRK input-optional fam_fetch_action '[fetch-action] required inputs' $ACT 'required: true' 'required: false'
BRK input-unread fam_fetch_action '[fetch-action] copies' $ACT 'DEST: ${{ inputs.dest }}' 'DEST: ${{ inputs.target }}'
BRK copies-git fam_fetch_action '[fetch-action] copies' $ACT 'tar --exclude=.git -C' 'tar -C'
BRK seat-renamed fam_sandbox_env '[sandbox-env] variables' $PLREL/scripts/vsdlc.py 'SANDBOX_ENV = ("INTENT_SLUG", "SEAT")' 'SANDBOX_ENV = ("INTENT_SLUG", "SEAT_ID")'
BRK one-variable-enough fam_sandbox_env '[sandbox-env] variables' $PLREL/scripts/vsdlc.py 'return all(os.environ.get(v, "").strip() for v in SANDBOX_ENV)' 'return any(os.environ.get(v, "").strip() for v in SANDBOX_ENV)'
# seedable: kb.py imports a helper that lives outside the plugin directory; in place it works, seeded alone it does not
d="$TMP/break-reaches-outside"; mk_repo_copy "$d"; mkdir -p "$d/scripts"; echo 'X = 1' > "$d/scripts/outside_helper.py"
mutate "$d/$PLREL/scripts/kb.py" 'import datetime' 'import datetime
sys_path_probe = __import__("sys").path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "..", "..", "scripts")); import outside_helper' \
  && expect_red reaches-outside fam_seedable "$d" '[seedable] scripts/kb.py from the seed'
BRK rc-intent-branch fam_cli_scripts_intent_branch_sh '[cli] scripts/intent-branch.sh rc 8' $PLREL/scripts/intent-branch.sh '        exit 8' '        exit 9'
BRK rc-open-pr fam_cli_scripts_open_pr_sh '[cli] scripts/open-pr.sh rc 66' $PLREL/scripts/open_pr.py '    if summary is None:
        return 66' '    if summary is None:
        return 65'
BRK rc-kb fam_cli_scripts_kb_py '[cli] scripts/kb.py rc 66' $PLREL/scripts/kb.py 'return die(M("kb.cs_unreadable", path), 66)' 'return die(M("kb.cs_unreadable", path), 1)'
BRK rc-sdlc-config fam_cli_scripts_sdlc_config_py '[cli] scripts/sdlc_config.py rc 64' $PLREL/scripts/sdlc_config.py 'no such key: %s\n" % rest[1])
        return 64' 'no such key: %s\n" % rest[1])
        return 2'
BRK rc-install-gates fam_cli_scripts_install_gates_py '[cli] scripts/install_gates.py rc 64' $PLREL/scripts/install_gates.py 'return die(64, "unknown gate %s' 'return die(2, "unknown gate %s'
BRK rc-baton fam_cli_scripts_baton_py '[cli] scripts/baton.py rc 6' $PLREL/scripts/baton.py 'EXISTS, PERMS, OWNER, USAGE, NOINPUT = 0, 1, 2, 3, 4, 5, 6, 7, 8, 64, 66' 'EXISTS, PERMS, OWNER, USAGE, NOINPUT = 0, 1, 2, 3, 4, 5, 9, 7, 8, 64, 66'
BRK rc-commit-discipline fam_cli_gates_commit_discipline_py '[cli] gates/commit_discipline.py rc 1' $PLREL/gates/commit_discipline.py '% (cfg["tokens"]["commit_exception"], MIN_REASON))
    return rc' '% (cfg["tokens"]["commit_exception"], MIN_REASON))
    return 3 if rc == 1 else rc'
BRK rc-pr-sensitive fam_cli_gates_pr_sensitive_py '[cli] gates/pr_sensitive.py rc 1' $PLREL/gates/pr_sensitive.py 'return gc.RED if total else gc.OK' 'return 3 if total else gc.OK'
BRK rc-pr-title fam_cli_gates_pr_title_py '[cli] gates/pr_title.py rc 1' $PLREL/gates/pr_title.py 'print("FAIL cannot read the payload: %s" % e)
        return gc.RED' 'print("FAIL cannot read the payload: %s" % e)
        return 3'
BRK rc-dead-branches fam_cli_gates_dead_branches_sh '[cli] gates/dead_branches.sh rc 1' $PLREL/gates/dead_branches.sh '  exit 1' '  exit 3'
BRK rc-hooks fam_cli_hooks_hooks_json '[cli] hooks/hooks.json rc 0' $PLREL/scripts/pre-bash.py '    sys.exit(vsdlc.run(lambda: vsdlc.pretool_command(sys.stdin.read())))' '    _in = sys.stdin.read(); __import__("json").loads(_in); sys.exit(vsdlc.run(lambda: vsdlc.pretool_command(_in)))'
BRK code-row-removed fam_cli_scripts_intent_branch_sh '[cli] scripts/intent-branch.sh rc 8: a trigger with no contract row' $PLREL/CONTRACT.md \
    "$(row scripts/intent-branch.sh 8)"$'\n' ''
BRK code-row-added fam_cli_scripts_kb_py '[cli] scripts/kb.py rc 67: a contract row with no trigger' $PLREL/CONTRACT.md \
    "$ROW" "$ROW"$'\n''| `scripts/kb.py` | 67 | a code nobody produces |'
BRK key-retyped fam_config_schema '[config-schema] keys: a schema-' $PLREL/scripts/sdlc_config.py '"kb": ("obj", {"spec_warn_bytes": ("intnull", 1)}),' '"kb": ("obj", {"spec_warn_bytes": ("bool",)}),'
BRK title-never-passes fam_cli_gates_pr_title_py '[cli] gates/pr_title.py rc 0' $PLREL/gates/pr_title.py '    print(("FAIL " if rc else "ok   ") + msg)
    return rc' '    print(("FAIL " if rc else "ok   ") + msg)
    return rc if (rc or cfg["pr"]["title"]["pattern"] is None) else 1'
BRK title-rule-green fam_cli_gates_pr_title_py '[cli] gates/pr_title.py rc 1' $PLREL/gates/pr_title.py '    print(("FAIL " if rc else "ok   ") + msg)
    return rc' '    print(("FAIL " if rc else "ok   ") + msg)
    return 0'
BRK no-gh-rc fam_cli_scripts_open_pr_sh '[cli] scripts/open-pr.sh rc 2' $PLREL/scripts/open-pr.sh 'command -v gh >/dev/null 2>&1 || die "$(say op.sh.no_gh)" 2' 'command -v gh >/dev/null 2>&1 || die "$(say op.sh.no_gh)" 9'
BRK key-renamed fam_config_schema '[config-schema] key pr.draft' $PLREL/scripts/sdlc_config.py '        "draft": ("bool",),' '        "draft_default": ("bool",),'
BRK schema-bump fam_config_schema '[config-schema] schema' $PLREL/scripts/sdlc_config.py 'SCHEMA = 1 ' 'SCHEMA = 2 '
BRK config-moved fam_config_schema '[config-schema] config file' $PLREL/scripts/sdlc_config.py 'CONFIG_REL = ".vibemaestro/sdlc.json"' 'CONFIG_REL = ".vibemaestro/config.json"'
BRK item-removed fam_contract '[contract] items' $PLREL/CONTRACT.md '| `seedable` | the plugin directory' '| `seedable-x` | the plugin directory'
RPP=$PLREL/scripts/rule_packs.py
BRK local-version-raised fam_local_state '[local-state] local version' $PLREL/scripts/local_state.py 'LOCAL_V = 1' 'LOCAL_V = 2'
BRK local-place-moved fam_local_state '[local-state] place: no file at' $PLREL/scripts/local_state.py 'base = os.path.join(top, "sessions")' 'base = os.path.join(top, "local")'
BRK local-field-added fam_local_state '[local-state] fields: exactly these' $PLREL/scripts/local_state.py '        "hint": False,' '        "hint": False, "extra": None,'
BRK local-mode-wide fam_local_state '[local-state] mode' $PLREL/scripts/local_state.py 'os.fchmod(f.fileno(), 0o600)' 'os.fchmod(f.fileno(), 0o640)'
BRK pack-dependency-renamed fam_rule_packs '[rule-packs] dependency named in dependencies: the plugin that names it' $RPP 'DEPENDENCY = "vibemaestro-sdlc"' 'DEPENDENCY = "vibemaestro-core"'
BRK pack-registry-moved fam_rule_packs '[rule-packs] registry: a pack listed' $RPP 'REGISTRY_REL = ("plugins", "installed_plugins.json")' 'REGISTRY_REL = ("plugins", "registry.json")'
BRK pack-home-moved fam_rule_packs '[rule-packs] registry without CLAUDE_CONFIG_DIR' $RPP '        return os.path.join(home, ".claude"), None' '        return os.path.join(home, ".claude-code"), None'
BRK pack-takes-sdlc-name fam_rule_packs '[rule-packs] precedence: a pack rule named like' $PLREL/scripts/rules.py '                if n in own:' '                if False:'
BRK pack-beats-repo fam_rule_packs '[rule-packs] precedence: a repo rule replaces' $PLREL/scripts/rules.py '                elif repo.get(n):' '                elif False:'
BRK pack-any-project fam_rule_packs '[rule-packs] project scope: an entry of another project' $RPP '        if pp is not None and real(pp)[0] != project:' '        if False:'
BRK pack-disabled-served fam_rule_packs '[rule-packs] enabled: false in the user settings' $RPP '            if enabled.get(pid) is not True:    # measured: a plugin no settings file enables is not enabled' '            if False:'
BRK pack-unnamed-served fam_rule_packs '[rule-packs] enabled: named by no settings file' $RPP '            if enabled.get(pid) is not True:    # measured: a plugin no settings file enables is not enabled' '            if enabled.get(pid) is False:'
# dependents: the brief's two planted breaks. Each goes red on the tree (the family), then, with the contract row edited to the new
# form, red on a scratch history of the copy (base-check: the old call is gone and no change file names it), and green with a
# change file naming the old call. (The real change also renames the probe in DEP_CALLS: a row with no probe is red.)
SEALK='        if rest[0] == "--seal" and len(rest) > 1 and seal is None:'
d="$TMP/break-dep-fixture"; mk_repo_copy "$d"; mv "$d/$DFIX" "$d/tests/fixtures/baton-owner-v2.sh"
expect_red dep-fixture-renamed fam_dependents "$d" "[dependents] $DFIX"
BRK dep-row-drift fam_dependents "[dependents] $DSIGN: rc without owner_asked" $PLREL/CONTRACT.md 'for that very call; rc 3 without it |' 'for that very call; rc 0 without it |'
BRK dep-base-ignored fam_dependents "[dependents] $IBS create-intent --slug <slug> --base <ref>: …the branch tip" $SDLC/scripts/intent_branch.py '    if not ref_exists(a.base, a.cwd):' '    a.base = "HEAD"
    if not ref_exists(a.base, a.cwd):'
BRK dep-fixes-ignored fam_dependents "[dependents] $SDLC/scripts/open-pr.sh --title <title> --summary <file> --evidence <file> --dry-run --fixes <n>: …stdout" $SDLC/scripts/open_pr.py 'body = build_body(summary, evidence, crit, a.fixes,' 'body = build_body(summary, evidence, crit, "",'
BRK dep-seal-dropped fam_dependents "[dependents] $DSIGN" $BAT "$SEALK" '        if False:'
# a dependent's own kit baton: a new `check` rule that fails the pinned copy (every kit baton here), and a pinned copy edited by hand
BRK dep-kit-baton-rule fam_dependents "[dependents] kit:release-promote: rc of $BAT check kit:release-promote" $BAT '    elif (s.kit or s.kind is not None) and not pl and not ul:' '    elif (s.kit or s.kind is not None):'
BRK dep-pin-edited fam_dependents "[dependents] kit:release-promote: the pinned copy is the blob its README records" $DBX/release-promote.sh '# Usage: --repo <owner/name> --commit <full sha>' '# Usage: --repo <owner/name> --commit <full sha> --edited'
# dep_hist <label> <old call> <new call> <shell edit of the tree in $H> — the list and note states of one planted break
dep_hist() {
  H=$(fresh)/h; mk_repo_copy "$H"; git_ init -q -b main "$H"; git_ -C "$H" add -A; git_ -C "$H" commit -q -m base
  eval "$4"; edit_surface "$H" "| \`$2\` |" "| \`$3\` |"
  eq "$(bcheck "$H" HEAD)" 1 "break [$1]: the contract row edited, no change file: base-check red"
  cfn "$H" major dep.md "a dependent call changed"
  eq "$(bcheck "$H" HEAD)" 1 "break [$1]: …a major change file that does not name the old call: red"
  cfn "$H" major dep.md "\`$2\` is now \`$3\`"
  eq "$(bcheck "$H" HEAD)" 0 "break [$1]: …a major change file naming \`$2\`: green"
}
dep_hist dep-fixture-renamed "$DFIX" tests/fixtures/baton-owner-v2.sh 'git_ -C "$H" mv "$DFIX" tests/fixtures/baton-owner-v2.sh'
dep_hist dep-seal-dropped "$DSIGN" "$BAT sign --by owner --seal=<seal> kit:<name> <args>" 'mutate "$H/$BAT" "$SEALK" "        if False:"'
dep_hist dep-kit-baton-row kit:release-promote 'kit:release-promote <args>' ':'
# a released version below `Frozen at`: a 0.0.1 heading on top of the CHANGELOG (below any Frozen at, before and after the first
# release), anchored on the header line the release never rewrites; a manifest that carries a version (the public export of a
# release, where it equals the CHANGELOG's) gets 0.0.1 too, as the export would write it
d="$TMP/break-frozen-ahead"; mk_repo_copy "$d"
if mutate "$d/$PLREL/CHANGELOG.md" 'the first public release is 0.1.0.
' 'the first public release is 0.1.0.

## 0.0.1

- patch: planted
' && python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); "version" in d and d.update(version="0.0.1"); json.dump(d, open(p, "w"), indent=2)' "$d/$MAN"; then
  expect_red frozen-ahead fam_contract "$d" '[contract] Frozen at'
else bad "break [frozen-ahead]: the plant did not apply (the CHANGELOG anchor or the manifest)"; fi

echo; summary
