#!/bin/bash
# =============================================================================
# BatonRun permissions: `baton.py permissions --print|--check|--install-launcher`, the launcher, and the SessionStart line
# =============================================================================
# Run: bash tests/test-baton-permissions.sh
#
# Every family takes a plugin copy; the suite runs them on a copy
# of the real plugin, then each planted break (one changed line in baton.py, the launcher or session-start.py) on its own copy
# and requires red on the intended check (expect_red, tests/fixtures/ports.sh). HOME, XDG_STATE_HOME and CLAUDE_PROJECT_DIR are
# scratch directories: the settings files are fakes the suite writes, and nothing outside the scratch tree is written, which
# the last section checks. The managed settings file of the machine running the suite is read by the default-scope cases; a
# machine whose managed settings hold baton rules can turn those cases red. Assertions read exit codes, the finding kinds
# (MISSING, STALE, UNSAFE, UNREADABLE) and JSON fields; prose is never asserted.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
PB_OUT="$TMP/pb.out"; PB_ERR="$TMP/pb.err"
H=""; ST=""; PJ=""; L=""

# fresh_env — a new scratch HOME (with an empty ~/.claude), state directory and project for one family run
fresh_env() {
  H="$(fresh)/home"; ST="$(fresh)/state"; PJ="$(fresh)/proj"
  mkdir -p "$H/.claude" "$PJ"; L="$ST/vibemaestro/baton/bin/baton"
}
# pb <plugin> <baton args...> — rc of baton.py run from the project; stdout in $PB_OUT, stderr in $PB_ERR
pb() {
  local p=$1; shift
  ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" CLAUDE_PROJECT_DIR="$PJ" python3 "$p/scripts/baton.py" "$@" ) >"$PB_OUT" 2>"$PB_ERR"
  echo $?
}
# kinds — the sorted unique finding kinds of the last `permissions --check` output
kinds() { awk '$1 ~ /^(MISSING|STALE|UNSAFE|UNREADABLE)$/ {print $1}' "$PB_OUT" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# chk <plugin> <settings file> — rc of `permissions --check --settings <file>`
chk() { pb "$1" permissions --check --settings "$2"; }
# jedit <in> <out> <python statements> — rewrite a settings file; `p` is its permissions object, `L` the launcher path
jedit() {
  python3 - "$1" "$2" "$3" "$L" <<'PY'
import json, sys
src, dst, code, L = sys.argv[1:5]
d = json.load(open(src))
p = d.setdefault("permissions", {})
exec(code)
json.dump(d, open(dst, "w"), indent=1)
PY
}
# good_settings <plugin> — the printed snippet as $PJ/good.json, with the launcher installed
good_settings() {
  pb "$1" permissions --install-launcher >/dev/null
  pb "$1" permissions --print >/dev/null; cp "$PB_OUT" "$PJ/good.json"
}
sha() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

# ── print ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_print() {
  local P=$1 v
  fresh_env
  eq "$(pb "$P" permissions --print)" 0 "[print] rc 0"
  v=$(python3 - "$PB_OUT" "$L" "$H/.claude/plugins" "$ST/vibemaestro/baton" <<'PY'
import json, sys
f, L, plugins, st = sys.argv[1:5]
p = json.load(open(f))["permissions"]
out = []
out.append("allow=%s" % sorted(r[len("Bash(%s " % L):-len(":*)")] for r in p["allow"] if r.startswith("Bash(%s " % L)))
out.append("allow-other=%d" % sum(1 for r in p["allow"] if not r.startswith("Bash(%s " % L)))
out.append("ask-owner=%s" % ("Bash(%s sign --by owner:*)" % L in p["ask"]))
out.append("ask-mode=%s" % ("Bash(%s mode:*)" % L in p["ask"]))
out.append("deny=%d/%s/%s" % (len(p["deny"]), "Edit(/%s/**)" % plugins in p["deny"], "Edit(/%s/**)" % st in p["deny"]))
print("|".join(out))
PY
)
  has "$v" "allow=['check', 'go', 'log', 'new', 'rehearse', 'run', 'sign --by coordinator-auto']" "[print] allow: new, check, rehearse, run, go, log and sign --by coordinator-auto, through the launcher"
  has "$v" "allow-other=0" "[print] no other allow rule"
  has "$v" "ask-owner=True|ask-mode=True" "[print] ask: sign --by owner and mode, through the launcher"
  has "$v" "deny=2/True/True" "[print] deny: Edit on the plugins directory and the state directory, // absolute, nothing else"
  v=$(python3 - "$P/scripts" "$PB_OUT" "$L" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import baton
asks = [r[len("Bash("):-1] for r in json.load(open(sys.argv[2]))["permissions"]["ask"]]
benign = ['git commit -m "fix(baton): auto mode docs"', "grep -rn baton kb | grep ' mode '", "%s run deploy.sh mode fast" % sys.argv[3],
          "%s rehearse mode-switch.sh" % sys.argv[3], "%s sign --by coordinator-auto --seal S owner.sh" % sys.argv[3],
          "%s go owner.sh" % sys.argv[3]]
print(" ".join(str(sum(baton.bash_matches(a, c) for a in asks)) for c in benign))
PY
)
  eq "$v" "0 0 0 0 0 0" "[print] the ask rules leave ordinary commands and normal batons alone (commit messages, greps, a 'mode' argument)"
  v=$(python3 - "$P/scripts" "$PB_OUT" "$L" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import baton
asks = [r[len("Bash("):-1] for r in json.load(open(sys.argv[2]))["permissions"]["ask"]]
real, L = "/x/plugins/cache/vibemaestro/vibemaestro-sdlc/2.1.0/scripts/baton.py", sys.argv[3]
spelled = ['python3 "%s" sign --by owner --seal S a.sh' % real, "python3 '%s' sign --by owner --seal S a.sh" % real,
           '"%s" sign --by owner --seal S a.sh' % L, "'%s' sign --by owner --seal S a.sh" % L, "cd /x && ./baton sign --by owner".split(" && ")[1],
           'python3 "%s" mode auto' % real, "'%s' mode auto" % L, '"%s" mode manual' % L, "python3 scripts/baton.py mode auto"]
print(" ".join(str(int(any(baton.bash_matches(a, c) for a in asks))) for c in spelled))
PY
)
  v="$v $(python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import baton; print(int(any(baton.bash_matches(r[5:-1], "baton mode auto") for r in json.load(open(sys.argv[2]))["permissions"]["ask"])))' "$P/scripts" "$PB_OUT")"
  eq "$v" "1 1 1 1 1 1 1 1 1 1" "[print] the ask rules catch quoted and relative spellings of sign --by owner and mode"
  # the one-time mode question (skill batonrun, modes.md): the session runs `<launcher> mode <answer>` only after the person's answer,
  # and the printed rules still turn that command into the person's dialog; the mode file itself cannot be edited
  v=$(python3 - "$P/scripts" "$PB_OUT" "$L" "$ST/vibemaestro/baton/mode" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import baton
rules, _probs = baton.read_rules([("printed", sys.argv[2])])
out = [baton.decide(rules, "%s mode %s" % (sys.argv[3], m))[0] for m in ("auto", "manual")]
out.append(str(any(k == "deny" and t == "Edit" and baton.path_matches(c, sys.argv[4]) for k, t, c, _r, _w in rules)))
print(" ".join(out))
PY
)
  eq "$v" "ask ask True" "[mode-choice] the printed rules make 'mode auto' and 'mode manual' ask (the person's dialog) and deny an edit of the mode file"
  [ ! -e "$ST" ] && ok "[print] writes nothing (no state directory)" || bad "[print] writes nothing (no state directory)"
  eq "$(find "$H" -type f | wc -l | tr -d ' ')" 0 "[print] writes nothing under HOME"
  ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" CLAUDE_CONFIG_DIR="$H/alt" python3 "$P/scripts/baton.py" permissions --print ) >"$PB_OUT" 2>/dev/null
  has "$(cat "$PB_OUT")" "Edit(/$H/alt/plugins/**)" "[print] CLAUDE_CONFIG_DIR moves the plugins deny"
}

# ── check ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_check() {
  local P=$1 s h
  fresh_env; good_settings "$P"; s="$PJ/s.json"
  h=$(sha "$PJ/good.json")
  eq "$(chk "$P" "$PJ/good.json")" 0 "[check] all-good: the printed rules with the launcher installed: rc 0"
  eq "$(kinds)" "" "[check] all-good: no finding"
  eq "$(sha "$PJ/good.json")" "$h" "[check] never writes the settings file"
  echo '{}' > "$s"
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING" "[check] missing: an empty settings file: rc 7, MISSING"
  jedit "$PJ/good.json" "$s" 'p["ask"] = [r for r in p["ask"] if "owner" not in r]'
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING" "[check] missing: no ask for sign --by owner: rc 7, MISSING"
  jedit "$PJ/good.json" "$s" 'p["allow"] = [r for r in p["allow"] if " go:" not in r]'
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING" "[check] missing: the 2.10 block (no allow for go): rc 7, MISSING"
  has "$(cat "$PB_OUT")" "$L go act.sh" "[check] …the finding names go"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(python3 /x/.claude/plugins/cache/vibemaestro/vibemaestro-sdlc/1.9.0/scripts/baton.py run:*)")'
  eq "$(chk "$P" "$s")/$(kinds)" "7/STALE" "[check] stale version: a rule naming 1.9.0's baton.py: rc 7, STALE"
  has "$(cat "$PB_OUT")" "1.9.0" "[check] stale version: the finding names the version"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(python3 /x/.claude/plugins/cache/vibemaestro/vibemaestro-sdlc/4dc7de6c9e01/scripts/baton.py run:*)")'
  eq "$(chk "$P" "$s")/$(kinds)" "7/STALE" "[check] stale version: a rule naming a git-SHA version directory's baton.py: rc 7, STALE"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(python3 /x/.claude/plugins/cache/vibemaestro/vibemaestro-sdlc/3d15f5b67818-be49dd83/scripts/baton.py run:*)")'
  eq "$(chk "$P" "$s")/$(kinds)" "7/STALE" "[check] stale version: a rule naming a git-subdir version directory's baton.py (<12 hex>-<8 hex>): rc 7, STALE"
  has "$(cat "$PB_OUT")" "names version 3d15f5b67818-be49dd83" "[check] …the finding names the whole git-subdir directory"
  G="$(fresh)/plugins/cache/vibemaestro/vibemaestro-sdlc/3d15f5b67818-be49dd83"; mkdir -p "$(dirname "$G")"; cp -r "$P" "$G"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(python3 '"$G"'/scripts/baton.py run:*)")'
  eq "$(chk "$G" "$s")/$(kinds)" "0/" "[check] a rule naming the running copy's own git-subdir directory: rc 0, no finding"
  jedit "$PJ/good.json" "$s" 'p["ask"].append("Bash(%s sign:*)" % L)'
  eq "$(chk "$P" "$s")/$(kinds)" "7/STALE" "[check] broad sign ask: an ask on every sign: rc 7, STALE"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(%s sign:*)" % L)'
  eq "$(chk "$P" "$s")/$(kinds)" "7/UNSAFE" "[check] unsafe allow: an allow on every sign, behind the owner ask: rc 7, UNSAFE"
  jedit "$PJ/good.json" "$s" 'p["ask"] = []; p["allow"].append("Bash(%s sign:*)" % L)'
  eq "$(chk "$P" "$s")" 7 "[check] unsafe allow: an allow on every sign and no ask: rc 7"
  has "$(kinds)" UNSAFE "[check] unsafe allow: …UNSAFE"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(%s mode:*)" % L)'
  eq "$(chk "$P" "$s")/$(kinds)" "7/UNSAFE" "[check] unsafe allow: an allow on mode: rc 7, UNSAFE"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(*)")'
  eq "$(chk "$P" "$s")/$(kinds)" "7/UNSAFE" "[check] unsafe allow: Bash(*): rc 7, UNSAFE"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash")'
  eq "$(chk "$P" "$s")/$(kinds)" "7/UNSAFE" "[check] unsafe allow: a bare Bash: rc 7, UNSAFE"
  jedit "$PJ/good.json" "$s" 'p["allow"].append("Bash(*baton.py *)")'
  eq "$(chk "$P" "$s")/$(kinds)" "7/UNSAFE" "[check] unsafe allow: a wildcard on the real baton.py: rc 7, UNSAFE"
  jedit "$PJ/good.json" "$s" 'p["deny"] = [r.replace("Edit(", "Write(") for r in p["deny"]]'
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING STALE" "[check] Write(path) deny rules: no deny counted (MISSING) and STALE"
  jedit "$PJ/good.json" "$s" 'p["deny"].append("Write(//nowhere/unrelated/**)")'
  eq "$(chk "$P" "$s")" 0 "[check] an unrelated Write(path) deny is not a finding: rc 0"
  jedit "$PJ/good.json" "$s" 'p["deny"] = [r.replace("Edit(", "Read(") for r in p["deny"]]'
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING" "[check] Read(path) deny rules in place of Edit: rc 7, MISSING (only the Edit rule the snippet prints counts)"
  jedit "$PJ/good.json" "$s" 'p["deny"] = [r for r in p["deny"] if "plugins" not in r]'
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING" "[check] no deny on the plugins directory: rc 7, MISSING"
  has "$(cat "$PB_OUT")" "installed_plugins.json" "[check] …it names installed_plugins.json"
  jedit "$PJ/good.json" "$s" 'p["deny"] = [p["deny"][0], "Edit(/%s)" % L]'
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING" "[check] a deny on the launcher only, not the signatures and mode: rc 7, MISSING"
  printf '{"permissions": ' > "$s"
  eq "$(chk "$P" "$s")" 7 "[check] a settings file that is not JSON: rc 7"
  has "$(kinds)" UNREADABLE "[check] …UNREADABLE"
  printf '# planted\n' >> "$L"
  eq "$(chk "$P" "$PJ/good.json")/$(kinds)" "7/STALE" "[check] a launcher that differs from this version's: rc 7, STALE"
  rm -f "$L"
  eq "$(chk "$P" "$PJ/good.json")/$(kinds)" "7/MISSING" "[check] no launcher: rc 7, MISSING"
  eq "$(pb "$P" permissions)" 64 "[check] usage: no option: rc 64"
  eq "$(pb "$P" permissions --check --settings "$PJ/none.json")" 64 "[check] usage: a settings file that does not exist: rc 64"
  eq "$(pb "$P" permissions --check --settings)" 64 "[check] usage: --settings without a file: rc 64"
}

# a state directory with a space: the launcher is quoted the same way in the rules, the probes and the hints
fam_space() {
  local P=$1
  fresh_env; ST="$(fresh)/st ate"; L="$ST/vibemaestro/baton/bin/baton"; good_settings "$P"
  has "$(cat "$PJ/good.json")" "Bash('$L' sign --by owner:*)" "[space] the rules name the launcher quoted"
  eq "$(chk "$P" "$PJ/good.json")" 0 "[space] the printed rules pass the check: rc 0"
  pb "$P" new act --dir "$PJ" >/dev/null; pb "$P" rehearse "$PJ/act.sh" "$PJ/a.txt" hi >/dev/null
  has "$(cat "$PB_OUT")" "After the owner's go: '$L' sign --by owner" "[space] rehearse prints the launcher as the rules name it"
}

# attribution: --print turns it off in object form; --check warns when it is on, without changing the exit code
warns() { grep -c '^WARNING ' "$PB_OUT"; }
fam_attribution() {
  local P=$1 s
  fresh_env; good_settings "$P"; s="$PJ/s.json"
  eq "$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])).get("attribution"), sort_keys=True))' "$PJ/good.json")" \
     '{"commit": "", "pr": "", "sessionUrl": false}' "[attribution] --print: attribution off, as an object"
  eq "$(chk "$P" "$PJ/good.json")/$(warns)" "0/0" "[attribution] the printed block: rc 0, no WARNING"
  jedit "$PJ/good.json" "$s" 'del d["attribution"]'
  eq "$(chk "$P" "$s")/$(warns)" "0/1" "[attribution] not set (Claude Code's default is on): rc 0, one WARNING"
  jedit "$PJ/good.json" "$s" 'd["attribution"]["commit"] = "Co-Authored-By: x"'
  eq "$(chk "$P" "$s")/$(warns)" "0/1" "[attribution] commit trailer set: rc 0, one WARNING"
  has "$(grep '^WARNING ' "$PB_OUT")" commit "[attribution] …it names the key"
  jedit "$PJ/good.json" "$s" 'd["attribution"]["sessionUrl"] = True'
  eq "$(chk "$P" "$s")/$(warns)" "0/1" "[attribution] sessionUrl on: rc 0, one WARNING"
  jedit "$PJ/good.json" "$s" 'd["attribution"] = False'
  eq "$(chk "$P" "$s")/$(warns)" "0/1" "[attribution] a boolean: rc 0, one WARNING"
  jedit "$PJ/good.json" "$s" 'd["permissions"] = {}'
  eq "$(chk "$P" "$s")/$(warns)" "7/0" "[attribution] off, but the permission rules missing: rc 7"
  cp "$PJ/good.json" "$H/.claude/settings.json"; mkdir -p "$PJ/.claude"
  echo '{"attribution": {"commit": "x", "pr": "", "sessionUrl": false}}' > "$PJ/.claude/settings.local.json"
  eq "$(pb "$P" permissions --check)/$(warns)" "0/1" "[attribution] the project's local file wins over the user's: one WARNING"
  jedit "$PJ/good.json" "$H/.claude/settings.json" 'd["attribution"]["pr"] = "x"'
  echo '{"attribution": {"commit": "", "pr": "", "sessionUrl": false}}' > "$PJ/.claude/settings.local.json"
  eq "$(pb "$P" permissions --check)/$(warns)" "0/0" "[attribution] the user's on, the project's local file off: no WARNING"
  cp "$PJ/good.json" "$H/.claude/settings.json"; echo '{"attribution": {"commit": ""}}' > "$PJ/.claude/settings.local.json"
  eq "$(pb "$P" permissions --check)/$(warns)" "0/0" "[attribution] keys merge across scopes: a partial object over the user's block: no WARNING"
  echo '{"attribution": {"commit": "x"}}' > "$PJ/.claude/settings.local.json"
  eq "$(pb "$P" permissions --check)/$(grep '^WARNING ' "$PB_OUT" | grep -c 'commit (project local')/$(grep '^WARNING ' "$PB_OUT" | grep -c 'pr (')" "0/1/0" \
     "[attribution] keys merge across scopes: only the key that is on is named"
}

# the default scopes: user settings and the project's two files are combined, as Claude Code combines them
fam_scopes() {
  local P=$1
  fresh_env; good_settings "$P"; cp "$PJ/good.json" "$H/.claude/settings.json"
  eq "$(pb "$P" permissions --check)" 0 "[scopes] control: the printed rules in the user settings: rc 0"
  mkdir -p "$PJ/.claude"; echo '{"permissions": {"allow": ["Bash(*)"]}}' > "$PJ/.claude/settings.local.json"
  eq "$(pb "$P" permissions --check)/$(kinds)" "7/UNSAFE" "[scopes] an allow Bash(*) in the project's settings.local.json: rc 7, UNSAFE"
  rm "$PJ/.claude/settings.local.json"; echo '{"permissions": {"ask": ["Bash(*baton* sign:*)", "Bash(*sign*)"]}}' > "$PJ/.claude/settings.json"
  eq "$(pb "$P" permissions --check)/$(kinds)" "7/STALE" "[scopes] a broad sign ask in the project's settings.json: rc 7, STALE"
}

# ── the launcher ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
# ver <plugin> <dir> <version> — a marked copy of the plugin at <dir>/<version>: its --help starts with "MARK <version>"
ver() { mkdir -p "$2"; cp -r "$1" "$2/$3"; mutate "$2/$3/scripts/baton.py" '"""baton: the BatonRun runner' "\"\"\"MARK $3: the BatonRun runner"; }
# reg <path>... — installed_plugins.json of the scratch HOME, one vibemaestro-sdlc entry per path, each updated after the one before
# (lastUpdated rises with the position)
reg() {
  python3 - "$H/.claude/plugins/installed_plugins.json" "$@" <<'PY'
import json, sys
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [
    {"scope": "user", "installPath": p, "lastUpdated": "2026-10-20T03:%02d:00.000Z" % i} for i, p in enumerate(sys.argv[2:])]}},
    open(sys.argv[1], "w"))
PY
}
# lr — rc of the installed launcher run with --help; stdout in $PB_OUT, stderr in $PB_ERR
lr() { ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" "$L" --help ) >"$PB_OUT" 2>"$PB_ERR"; echo $?; }
# evil <dir> — a plugin-shaped tree whose baton.py leaves $H/EVIL when it runs
evil() { mkdir -p "$1/scripts"; printf 'import os\nopen(os.path.join(os.environ["HOME"], "EVIL"), "w").close()\n' > "$1/scripts/baton.py"; }
# refused <label> — the last launcher run refused: rc 2 (passed in), the reason on stderr, the evil baton.py never ran
refused() {
  eq "$1" 2 "[launcher] $2: rc 2"
  nonempty "$(cat "$PB_ERR")" "[launcher] $2: the reason is printed"
  [ ! -e "$H/EVIL" ] && ok "[launcher] $2: nothing else ran" || bad "[launcher] $2: nothing else ran"
  rm -f "$H/EVIL"
}
fam_launcher() {
  local P=$1 C V E
  fresh_env; C="$H/.claude/plugins"; V="$C/cache/vibemaestro/vibemaestro-sdlc"; E="$(fresh)/9.9.9"   # semver-named: only the place refuses it
  eq "$(pb "$P" permissions --install-launcher)" 0 "[launcher] --install-launcher: rc 0"
  [ -x "$L" ] && ok "[launcher] installed at <state>/bin/baton, executable" || bad "[launcher] installed at <state>/bin/baton, executable"
  ver "$P" "$V" 0.1.0; ver "$P" "$V" 2.9.0; ver "$P" "$V" 2.10.0; evil "$E"
  ver "$P" "$V" 4dc7de6c9e01; ver "$P" "$V" unknown; ver "$P" "$V" 0.1.0-2ceee4aec794; ver "$P" "$V" 3d15f5b67818-be49dd83
  reg "$V/2.10.0" "$V/2.9.0"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 2.9.0" "[launcher] the registry's latest entry runs (2.9.0, updated after 2.10.0: numbers are not compared)"
  reg "$V/2.9.0" "$V/2.10.0"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 2.10.0" "[launcher] …and the other way round"
  ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" python3 "$L" --help ) >"$PB_OUT" 2>/dev/null
  eq "$(head -n 1 "$PB_OUT" | cut -d: -f1)" "MARK 2.10.0" "[launcher] started as python3 <launcher>: the same"
  reg "$V/2.10.0" "$V/4dc7de6c9e01"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 4dc7de6c9e01" "[launcher] a git-SHA version directory (a private install with no version) runs"
  reg "$V/unknown"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK unknown" "[launcher] the directory unknown (a directory marketplace without git) runs"
  reg "$V/0.1.0-2ceee4aec794"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 0.1.0-2ceee4aec794" "[launcher] a tag-resolved dependency directory X.Y.Z-<12 hex> runs"
  reg "$V/3d15f5b67818-be49dd83"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 3d15f5b67818-be49dd83" "[launcher] a git-subdir source directory <12 hex>-<8 hex> runs (measured 22/10)"
  reg "$V/0.1.0"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 0.1.0" "[launcher] 0.1.0, the first public release, runs (no floor: the numbering restarted)"
  mkdir -p "$V/5.0.0"; reg "$V/2.10.0" "$V/5.0.0"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 2.10.0" "[launcher] a version directory without baton.py next to a good one: the good one runs"
  rm -rf "$V/5.0.0"; reg "$V/2.10.0"
  X="$(fresh)/cfg"; mkdir -p "$X/plugins/cache/vibemaestro/vibemaestro-sdlc"; evil "$X/plugins/cache/vibemaestro/vibemaestro-sdlc/9.9.9"
  printf '{"plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s"}]}}' "$X/plugins/cache/vibemaestro/vibemaestro-sdlc/9.9.9" > "$X/plugins/installed_plugins.json"
  ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" CLAUDE_CONFIG_DIR="$X" HOME="$(dirname "$X")" "$L" --help ) >"$PB_OUT" 2>/dev/null
  eq "$(head -n 1 "$PB_OUT" | cut -d: -f1)" "MARK 2.10.0" "[launcher] CLAUDE_CONFIG_DIR and HOME pointing elsewhere: still the installed plugin"
  [ ! -e "$H/EVIL" ] && [ ! -e "$(dirname "$X")/EVIL" ] && ok "[launcher] …and the other baton.py never ran" || bad "[launcher] …and the other baton.py never ran"
  rm -f "$H/EVIL" "$(dirname "$X")/EVIL"
  pb "$P" mode auto >/dev/null
  eq "$( (cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$(fresh)" "$L" mode) 2>/dev/null)" auto "[launcher] XDG_STATE_HOME pointing elsewhere: baton still reads the installed state"
  u=$(cenv HOME="$H" python3 -c 'import site; print(site.getusersitepackages())'); mkdir -p "$u" "$H/pp"
  printf 'import os\nopen(os.path.join(os.environ["HOME"], "EVIL"), "w").close()\n' | tee "$u/usercustomize.py" > "$H/pp/sitecustomize.py"
  ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" PYTHONPATH="$H/pp" "$L" --help ) >"$PB_OUT" 2>/dev/null
  [ ! -e "$H/EVIL" ] && ok "[launcher] a usercustomize.py or a PYTHONPATH sitecustomize.py never runs" || bad "[launcher] a usercustomize.py or a PYTHONPATH sitecustomize.py never runs"
  eq "$(cenv HOME="$H" python3 -c 'import sys; print(1)' 2>/dev/null; [ -e "$H/EVIL" ] && echo planted)" $'1\nplanted' "[launcher] instrument: that usercustomize.py runs in a plain python3"
  rm -rf "$u/usercustomize.py" "$H/pp" "$H/EVIL"
  eq "$( (cd "$PJ" && cenv HOME="$H" python3 "$P/scripts/baton-launcher.py" --help) >/dev/null 2>&1; echo $?)" 2 "[launcher] the plugin's own copy, not installed: rc 2"
  printf 'import os\nopen(os.path.join(os.environ["HOME"], "EVIL"), "w").close()\n' > "$(dirname "$L")/json.py"
  eq "$(lr)/$(head -n 1 "$PB_OUT" | cut -d: -f1)" "0/MARK 2.10.0" "[launcher] a json.py next to the launcher: still the newest version"
  [ ! -e "$H/EVIL" ] && ok "[launcher] a json.py next to the launcher is never imported" || bad "[launcher] a json.py next to the launcher is never imported"
  ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" python3 "$L" --help ) >/dev/null 2>&1
  [ ! -e "$H/EVIL" ] && ok "[launcher] started as python3 <launcher>: the json.py is never imported either" || bad "[launcher] started as python3 <launcher>: the json.py is never imported either"
  rm -f "$(dirname "$L")/json.py" "$H/EVIL"
  rm -f "$C/installed_plugins.json"
  refused "$(lr)" "no installed_plugins.json"
  echo '{"version": 2, "plugins": {}}' > "$C/installed_plugins.json"
  refused "$(lr)" "no vibemaestro-sdlc entry"
  reg "$E"; refused "$(lr)" "installPath outside the cache"
  reg "$V/2.10.0" "$E"; refused "$(lr)" "installPath outside the cache, next to a good entry"
  reg "$V/../../../../../../$(basename "$(dirname "$E")")/9.9.9"; refused "$(lr)" "installPath outside the cache through .."
  ln -s "$E" "$V/3.0.0"; reg "$V/3.0.0"; refused "$(lr)" "installPath outside the cache through a symlinked version directory"
  mkdir -p "$V/latest/scripts"; cp "$P/scripts/baton.py" "$V/latest/scripts/"; reg "$V/latest"
  refused "$(lr)" "a version directory that is not a version Claude Code names"
  mkdir -p "$V/4DC7DE6C9E01/scripts"; cp "$P/scripts/baton.py" "$V/4DC7DE6C9E01/scripts/"; reg "$V/4DC7DE6C9E01"
  refused "$(lr)" "a SHA directory in capitals (Claude Code writes lower case)"
  # near misses of <12 hex>-<8 hex>: each directory holds a baton.py that leaves $H/EVIL when it runs
  gs_refused() { evil "$V/$1"; reg "$V/$1"; refused "$(lr)" "git-subdir shape: $2"; }
  gs_refused 3d15f5b6781-be49dd83 "11 hex before the dash"
  gs_refused 3d15f5b678189-be49dd83 "13 hex before the dash"
  gs_refused 3d15f5b67818-be49dd8 "7 hex after the dash"
  gs_refused 3d15f5b67818-be49dd834 "9 hex after the dash"
  gs_refused 3D15F5B67818-BE49DD83 "upper case"
  gs_refused 3d15f5b67818-BE49DD83 "upper case after the dash"
  gs_refused 3d15f5b67818-be49dd83-adc9e2e3 "an extra segment"
  gs_refused 3d15f5b67818_be49dd83 "another separator"
  gs_refused $'3d15f5b67818-be49dd83\n' "a trailing newline"
  [ -f "$V/"$'3d15f5b67818-be49dd83\n'"/scripts/baton.py" ] && ok "[launcher] instrument: the trailing-newline directory exists" || bad "[launcher] instrument: the trailing-newline directory exists"
  O="$(fresh)/3d15f5b67818-be49dd83"; evil "$O"
  up=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$O" "$V/3d15f5b67818-be49dd83")
  has "$up" "../" "[launcher] instrument: the .. path climbs out of the cache"
  reg "$V/3d15f5b67818-be49dd83/$up"; refused "$(lr)" "git-subdir shape: .. from it to a same-named directory outside the cache"
  reg "$V/3d15f5b67818-be49dd83/.."; refused "$(lr)" "git-subdir shape: .. from it to the plugin directory"
  ver "$P" "$V" 4.0.0; rm "$V/4.0.0/scripts/baton.py"; ln -s "$E/scripts/baton.py" "$V/4.0.0/scripts/baton.py"; reg "$V/4.0.0"
  refused "$(lr)" "baton.py symlink out of the version directory"
  mkdir -p "$V/5.0.0"; reg "$V/5.0.0"; refused "$(lr)" "a version directory without baton.py"
  mv "$C/cache/vibemaestro" "$E/mkt"; ln -s "$E/mkt" "$C/cache/vibemaestro"; reg "$V/2.10.0"
  refused "$(lr)" "cache symlink: the marketplace directory is a symlink"
}

# ── the SessionStart line ──────────────────────────────────────────────────────────────────────────────────────────────────────
# ss <plugin> <loi|boi-canh> — the hook's JSON, run as Claude Code runs it, from the project with a new session id
ss() {
  ( cd "$PJ" && p_start "$(sid)" | cenv HOME="$H" XDG_STATE_HOME="$ST" CLAUDE_PROJECT_DIR="$PJ" CLAUDE_PLUGIN_ROOT="$1" \
      python3 "$1/scripts/session-start.py" "$2" ) 2>/dev/null
}
# lines <json> — how many times the baton line appears in the system message, and in the context
lines() { printf '%s/%s' "$(sysm "$1" | grep -c 'baton permissions')" "$(ctx "$1" | grep -c 'baton permissions')"; }
fam_session() {
  local P=$1 out
  fresh_env
  out=$(ss "$P" loi); nonempty "$(ctx "$out")" "[session] instrument: the loi hook delivers the process core"
  eq "$(lines "$out")" "0/0" "[session] manual, no rules: silent (every baton command opening a dialog is the intended manual behaviour)"
  mkdir -p "$ST/vibemaestro/baton"; echo auto > "$ST/vibemaestro/baton/mode"
  out=$(ss "$P" loi)
  eq "$(lines "$out")" "1/1" "[session] auto, no rules: one line, to the owner and to the session"
  has "$(sysm "$out")" "permissions --print" "[session] auto, no rules: the line names the command that prints the fix"
  nonempty "$(ctx "$out" | grep -v 'baton permissions')" "[session] auto, no rules: the process core is still delivered"
  eq "$(lines "$(ss "$P" boi-canh)")" "0/0" "[session] the second hook does not repeat the line"
  good_settings "$P"; cp "$PJ/good.json" "$H/.claude/settings.json"
  eq "$(lines "$(ss "$P" loi)")" "0/0" "[session] auto, the printed rules and the launcher: silent"
  echo manual > "$ST/vibemaestro/baton/mode"
  jedit "$PJ/good.json" "$H/.claude/settings.json" 'p["allow"].append("Bash(python3 /x/.claude/plugins/cache/vibemaestro/vibemaestro-sdlc/1.9.0/scripts/baton.py run:*)")'
  eq "$(lines "$(ss "$P" loi)")" "1/1" "[session] manual, a stale rule: one line"
  echo '{"permissions": {"allow": ["Bash(*)"]}}' > "$H/.claude/settings.json"
  eq "$(lines "$(ss "$P" loi)")" "1/1" "[session] manual, no baton rule but an allow Bash(*): one line (unsafe in every mode)"
  printf 'def (\n' >> "$P/scripts/baton.py"
  out=$(ss "$P" loi)
  eq "$(lines "$out")" "0/0" "[session] a baton.py that does not compile: no line"
  nonempty "$(ctx "$out")" "[session] …and the hook still delivers the process core"
}

# the launcher under HOME (the default ~/.local/state): --print also allows the `~/` spelling of each command, because the rules
# match the command text and a call through `~` matched no rule; kit:merge-pr and kit:gh-write
# are covered by the same rules
fam_tilde() {
  local P=$1 s v T sub
  fresh_env; ST="$H/.local/state"; L="$ST/vibemaestro/baton/bin/baton"; T="~/.local/state/vibemaestro/baton/bin/baton"
  good_settings "$P"; s="$PJ/s.json"
  for sub in new check rehearse run go log "sign --by coordinator-auto"; do
    has "$(cat "$PJ/good.json")" "\"Bash($T $sub:*)\"" "[tilde] --print allows the ~/ spelling of $sub"
  done
  eq "$(chk "$P" "$PJ/good.json")" 0 "[tilde] the printed rules pass the check: rc 0"
  jedit "$PJ/good.json" "$s" 'p["allow"] = [r for r in p["allow"] if not r.startswith("Bash(~/")]'
  eq "$(chk "$P" "$s")/$(kinds)" "7/MISSING" "[tilde] the 2.5.0 block (no ~/ allow): rc 7, MISSING"
  has "$(cat "$PB_OUT")" "$T run" "[tilde] …the finding names the ~/ spelling"
  v=$(python3 - "$P/scripts" "$PJ/good.json" "$L" "$T" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import baton
rules, _probs = baton.read_rules([("user", sys.argv[2])])
seal = "--seal 0123456789abcdef.0123456789abcdef"
for args in ("kit:merge-pr --repo acme/app --pr 7 --head a1b2c3d4e5f60718293a4b5c6d7e8f9001122334 --brief brief.txt --accept 'unit:Full suite'",
             "kit:gh-write --spec spec.json"):
    out = []
    for L in sys.argv[3:5]:
        for cmd in ("%s rehearse %s" % (L, args), "%s sign --by coordinator-auto %s %s" % (L, seal, args), "%s run %s" % (L, args),
                    "%s go %s" % (L, args), "%s sign --by owner %s %s" % (L, seal, args), "%s mode auto" % L):
            out.append(baton.decide(rules, cmd)[0] or "none")
    print(" ".join(out))
PY
)
  eq "$(printf '%s\n' "$v" | sed -n 1p)" "allow allow allow allow ask ask allow allow allow allow ask ask" \
     "[tilde] kit:merge-pr: rehearse, sign --by coordinator-auto, run and go are allowed in both spellings; sign --by owner and mode ask"
  eq "$(printf '%s\n' "$v" | sed -n 2p)" "allow allow allow allow ask ask allow allow allow allow ask ask" \
     "[tilde] kit:gh-write: the same rules cover it, no rule of its own (rehearse, sign --by coordinator-auto, run, go allowed; owner sign and mode ask)"
  fresh_env; good_settings "$P"
  hasnt "$(cat "$PJ/good.json")" '"Bash(~/' "[tilde] a state directory outside HOME: no ~/ rule"
}

# the card of a mode nobody chose (skill batonrun, modes.md): the session runs `mode <answer>` only where `permissions --check`
# is clean, so the ask rule makes it the owner's dialog; on a fresh HOME without the rules the owner runs it themselves
fam_mode_question() {
  local P=$1 A
  fresh_env
  pb "$P" new act --dir "$PJ" >/dev/null; A="$PJ/act.sh"
  eq "$(pb "$P" permissions --check)" 7 "[mode-question] instrument: a fresh HOME without rules: permissions --check rc 7"
  eq "$(pb "$P" go "$A" "$PJ/o.txt" hello)" 8 "[mode-question] no rules, mode not chosen: go rc 8"
  has "$(cat "$PB_OUT")" "the baton rules are not in force in the user or managed settings: the owner runs \`! python3 " \
    "[mode-question] no rules: the owner runs mode themselves"
  hasnt "$(cat "$PB_OUT")" "the session runs" "[mode-question] no rules: the session is not told to run mode"
  good_settings "$P"; mkdir -p "$PJ/.claude"; cp "$PJ/good.json" "$PJ/.claude/settings.json"
  eq "$(pb "$P" permissions --check)" 0 "[mode-question] instrument: the printed rules in the project only: permissions --check rc 0"
  touch "$A"
  eq "$(pb "$P" go "$A" "$PJ/o.txt" hello)" 8 "[mode-question] rules in the project only: go rc 8"
  has "$(cat "$PB_OUT")" "the owner runs \`! $L mode <answer>\` themselves" \
    "[mode-question] rules in the project only (they follow go's directory, not the session's project): the owner runs mode"
  rm -f "$PJ/.claude/settings.json"; echo '{"permissions": {"ask": 5}}' > "$H/.claude/settings.json"
  touch "$A"
  eq "$(pb "$P" go "$A" "$PJ/o.txt" hello)" 8 "[mode-question] a malformed user settings file: go still gives the card, rc 8"
  has "$(cat "$PB_OUT")" "the owner runs \`! $L mode <answer>\` themselves" "[mode-question] a malformed user settings file: the owner runs mode"
  python3 -c 'print("[" * 100000 + "]" * 100000)' > "$H/.claude/settings.json"; touch "$A"
  eq "$(pb "$P" go "$A" "$PJ/o.txt" hello)" 8 "[mode-question] a deeply nested user settings file: go still gives the card, rc 8"
  has "$(cat "$PB_OUT")" "the owner runs \`! $L mode <answer>\` themselves" "[mode-question] a deeply nested user settings file: the owner runs mode"
  cp "$PJ/good.json" "$H/.claude/settings.json"
  eq "$(pb "$P" permissions --check)" 0 "[mode-question] instrument: the printed rules and the launcher: permissions --check rc 0"
  touch "$A"
  eq "$(pb "$P" go "$A" "$PJ/o.txt" hello)" 8 "[mode-question] rules in force, mode not chosen: go rc 8"
  has "$(cat "$PB_OUT")" "on the owner's answer the session runs \`$L mode <answer>\`; the ask rule opens the owner's dialog" \
    "[mode-question] rules in force: the session runs mode through the launcher, which asks"
  [ ! -e "$ST/vibemaestro/baton/mode" ] && [ ! -e "$PJ/o.txt" ] && ok "[mode-question] go sets no mode and writes nothing" \
    || bad "[mode-question] go sets no mode and writes nothing"
}

FAMILIES="fam_print fam_check fam_space fam_attribution fam_scopes fam_launcher fam_session fam_tilde fam_mode_question"

echo "== the real plugin =="
for f in $FAMILIES; do
  if [ "$f" = fam_session ]; then d="$TMP/real-session"; mk_plugin_copy "$d"; "$f" "$d"; else "$f" "$PLUGIN"; fi   # it breaks baton.py
done

echo "== planted breaks: each one must turn its family red =="
# BRK <label> <family> <needle> <file under the plugin> <old> <new> [<old> <new>...]
BRK() {
  local label=$1 fam=$2 needle=$3 file=$4 d; shift 4; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/$file" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
B=scripts/baton.py; LA=scripts/baton-launcher.py
BRK missing-blind fam_check '[check] missing: an empty settings file' $B \
    $'        if d is None:\n            out.append(("MISSING", "no allow rule' $'        if False:\n            out.append(("MISSING", "no allow rule'
BRK owner-ask-blind fam_check '[check] missing: no ask for sign --by owner' $B \
    $'        if d is None:\n            out.append(("MISSING", "no ask rule' $'        if False:\n            out.append(("MISSING", "no ask rule'
BRK version-blind fam_check '[check] stale version' $B 'if m and (mine is None or m.group(1) != mine.group(1))' 'if False'
BRK broad-sign-blind fam_check '[check] broad sign ask' $B '        elif d == "ask" and cmd == auto_sign:' $'        elif d == "ask":\n            pass\n        elif False:'
BRK unsafe-behind-ask-blind fam_check '[check] unsafe allow: an allow on every sign, behind' $B \
    'if k == "allow" and tool == "Bash" and bash_matches(content, cmd) and d != "allow":' 'if False:'
BRK unsafe-no-ask-blind fam_check '[check] unsafe allow: …UNSAFE' $B \
    $'        elif d == "allow":\n            out.append(("UNSAFE"' $'        elif False:\n            out.append(("UNSAFE"' \
    'if k == "allow" and tool == "Bash" and bash_matches(content, cmd) and d != "allow":' 'if False:'
BRK write-deny-counted fam_check '[check] Write(path) deny rules' $B 'k == "deny" and tool == "Edit" and path_matches' 'k == "deny" and tool in ("Edit", "Write") and path_matches'
BRK wildcard-no-spaces fam_check '[check] all-good: the printed rules' $B \
    $'            stars += 1\n            out.append(".*")' $'            stars += 1\n            out.append("[^ ]*")'
BRK sha-rule-not-stale fam_check '[check] stale version: a rule naming a git-SHA' $B '(?:-[0-9a-f]{12})?|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)/")' ')/")'
BRK subdir-rule-not-stale fam_check '[check] stale version: a rule naming a git-subdir' $B '|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)/")' '|[0-9a-f]{12}|unknown)/")'
BRK own-subdir-stale fam_check "[check] a rule naming the running copy's own git-subdir directory" $B \
    'if m and (mine is None or m.group(1) != mine.group(1))' 'if m'
BRK launcher-stale-blind fam_check '[check] a launcher that differs' $B '    elif not launcher_current():' '    elif False:'
BRK unreadable-blind fam_check '[check] …UNREADABLE' $B \
    '            probs.append(("UNREADABLE",' '            0 and probs.append(("UNREADABLE",'
BRK local-scope-unread fam_scopes "[scopes] an allow Bash(*) in the project's settings.local.json" $B \
    '    out.append(("project local", os.path.join(proj, ".claude", "settings.local.json")))' ''
BRK outside-accepted fam_launcher '[launcher] installPath outside the cache: rc 2' $LA 'if parent != base or not INSTALL_DIR.match(version):' 'if not INSTALL_DIR.match(version):'
BRK any-dir-accepted fam_launcher '[launcher] a version directory that is not a version' $LA 'if parent != base or not INSTALL_DIR.match(version):' 'if parent != base:'
BRK sha-refused fam_launcher '[launcher] a git-SHA version directory' $LA '|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)\Z")' '|unknown)\Z")'
BRK unknown-refused fam_launcher '[launcher] the directory unknown' $LA '|unknown)\Z")' ')\Z")'
BRK subdir-refused fam_launcher '[launcher] a git-subdir source directory' $LA '|[0-9a-f]{12}(?:-[0-9a-f]{8})?|' '|[0-9a-f]{12}|'
BRK subdir-head-loose fam_launcher '[launcher] git-subdir shape: 11 hex before the dash' $LA '|[0-9a-f]{12}(?:-[0-9a-f]{8})?|' '|[0-9a-f]{11,13}(?:-[0-9a-f]{8})?|'
BRK subdir-tail-loose fam_launcher '[launcher] git-subdir shape: 9 hex after the dash' $LA '(?:-[0-9a-f]{8})?' '(?:-[0-9a-f]{7,9})?'
BRK subdir-case-folded fam_launcher '[launcher] git-subdir shape: upper case' $LA '|unknown)\Z")' '|unknown)\Z", re.I)'
BRK subdir-segments-repeat fam_launcher '[launcher] git-subdir shape: an extra segment' $LA '(?:-[0-9a-f]{8})?' '(?:-[0-9a-f]{8})*'
BRK end-anchor-newline fam_launcher '[launcher] git-subdir shape: a trailing newline' $LA '|unknown)\Z")' '|unknown)$")'
BRK tag-suffix-refused fam_launcher '[launcher] a tag-resolved dependency directory' $LA '(?:-[0-9a-f]{12})?|' '|'
BRK highest-wins fam_launcher "[launcher] the registry's latest entry runs" $LA '        elif best is None or stamp > best[0]:' '        elif best is None or False:'
BRK script-symlink-followed fam_launcher '[launcher] baton.py symlink' $LA '        if os.path.realpath(script) != script:' '        if False:'
BRK base-symlink-followed fam_launcher '[launcher] cache symlink' $LA \
    '    if os.path.realpath(base) != base:' '    if False:' \
    '    plugins = os.path.join(os.path.realpath(CLAUDE_DIR), "plugins")' '    plugins = os.path.join(CLAUDE_DIR, "plugins")' \
    '        real = os.path.realpath(path)' '        real = os.path.normpath(path)' \
    '        if os.path.realpath(script) != script:' '        if False:'
BRK line-dropped fam_session '[session] auto, no rules: one line' scripts/session-start.py \
    '        vsdlc.emit = with_baton_warning(vsdlc.emit)' '        pass'
BRK manual-warns fam_session '[session] manual, no rules: silent' $B \
    '    if mode == "manual" and not baton_rules_present(sources):' '    if False:'
BRK manual-unsafe-silent fam_session '[session] manual, no baton rule but an allow Bash(*)' $B \
    '        found = [f for f in found if f[0] != "MISSING"]' '        found = []'
BRK line-twice fam_session '[session] the second hook does not repeat the line' scripts/session-start.py \
    '    if mode in vsdlc.CORE_MODES:                    # one of the two hooks' '    if True:                                        # one of the two hooks'
BRK read-deny-counted fam_check '[check] Read(path) deny rules in place of Edit' $B \
    'k == "deny" and tool == "Edit" and path_matches' 'k == "deny" and tool in ("Edit", "Read") and path_matches'
BRK launcher-not-isolated fam_launcher '[launcher] a json.py next to the launcher is never imported' $LA \
    '#!/usr/bin/env -S python3 -I' '#!/usr/bin/env python3' 'if not sys.flags.isolated:' 'if False:'
BRK reexec-dropped fam_launcher '[launcher] started as python3 <launcher>: the json.py' $LA 'if not sys.flags.isolated:' 'if False:'
BRK shebang-not-isolated fam_launcher '[launcher] a usercustomize.py' $LA '#!/usr/bin/env -S python3 -I' '#!/usr/bin/env python3'
BRK no-script-refuses fam_launcher '[launcher] a version directory without baton.py next to a good one' $LA \
    $'        if not os.path.isfile(script):\n            skipped.append(' $'        if not os.path.isfile(script):\n            raise Refused("x")\n            skipped.append('
BRK env-config-read fam_launcher '[launcher] CLAUDE_CONFIG_DIR and HOME' $LA \
    'plugins = os.path.join(os.path.realpath(CLAUDE_DIR), "plugins")' 'plugins = os.path.join(os.path.realpath(os.environ.get("CLAUDE_CONFIG_DIR") or CLAUDE_DIR), "plugins")'
BRK state-not-forced fam_launcher '[launcher] XDG_STATE_HOME pointing elsewhere' $LA 'dict(os.environ, XDG_STATE_HOME=STATE_HOME)' 'dict(os.environ)'
BRK write-deny-any fam_check '[check] an unrelated Write(path) deny' $B \
    'if tool == "Write" and k == "deny" and any(path_matches(content, p) for p in guarded):' 'if tool == "Write" and k == "deny":'
BRK launcher-unquoted fam_space '[space] the printed rules pass the check' $B \
    '    L, plugins, st = shlex.quote(launcher_path()), os.path.join' '    L, plugins, st = launcher_path(), os.path.join'
BRK broad-mode-ask fam_print '[print] the ask rules leave ordinary commands' $B \
    $'"Bash(*%s%s mode *)" % (prog, q) for prog in ("baton.py", "/baton") for q in ("", \'"\', "\'")]' $'"Bash(*baton* mode *)"]'
BRK quoted-sign-missed fam_print '[print] the ask rules catch quoted' $B '"Bash(*baton* sign --by owner*)", "Bash(baton mode:*)"]' '"Bash(*baton.py sign --by owner*)", "Bash(*/baton sign --by owner*)", "Bash(baton mode:*)"]'
BRK quoted-mode-missed fam_print '[print] the ask rules catch quoted' $B $'for q in ("", \'"\', "\'")]' 'for q in ("",)]'
BRK attribution-blind fam_attribution '[attribution] commit trailer set' $B 'commits and PRs carry it" % ", ".join(on)] if on else []' 'commits and PRs carry it" % ", ".join(on)] if False else []'
BRK attribution-whole-object fam_attribution '[attribution] keys merge across scopes: a partial object' $B \
    '                got[k] = (a[k], where)' $'                got[k] = (a[k], where)\n        break'
BRK bare-mode-missed fam_print '[print] the ask rules catch quoted' $B ', "Bash(baton mode:*)"] + [' '] + ['
BRK attribution-precedence fam_attribution "[attribution] the project's local file wins" $B '"project local": 1, "project": 2, "user": 3}' '"project local": 3, "project": 2, "user": 1}'
BRK attribution-unprinted fam_attribution '[attribution] --print' $B ', "attribution": dict(ATTRIBUTION_OFF)}' '}'
BRK tilde-unprinted fam_tilde '[tilde] --print allows the ~/ spelling of run' $B '        allow += ["Bash(%s %s:*)" % (T, sub) for sub, _a in ALLOWED_SUBS] + ["Bash(%s sign --by coordinator-auto:*)" % T]' '        pass'
BRK tilde-unchecked fam_tilde '[tilde] the 2.5.0 block (no ~/ allow): rc 7, MISSING' $B '        probes += ["%s %s %s" % (T, sub, a) for sub, a in ALLOWED_SUBS] + ["%s sign --by coordinator-auto %s" % (T, SEAL_PROBE)]' '        pass'
BRK tilde-outside-home fam_tilde '[tilde] a state directory outside HOME: no ~/ rule' $B '    if rel == ".." or rel.startswith("../") or shlex.quote(rel) != rel:' '    if shlex.quote(rel) != rel:'


echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
[ ! -e "$HOME/.local/state/vibemaestro" ] && ok "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)" || bad "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)"

echo; summary
