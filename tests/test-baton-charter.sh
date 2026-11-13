#!/bin/bash
# =============================================================================
# BatonRun: the owner's focus charter (baton.py sign --by owner --charter, log --grants, grant revoke, brain op close)
# =============================================================================
# Run: bash tests/test-baton-charter.sh
#
# A charter is the owner's one signature for a focus of the brain (P<n>): its repositories, touch kinds, maximum Stops and an
# expiry at most CHARTER_LIFE_MAX (90 days) ahead, with the focus's words read through the brain installed beside the sdlc copy
# (`brain show <P> --json`, intake's lookup); signed through the same guard, dialog and record as a plan approval and kept in
# grants/ as `kind: charter`. No reader treats it as in force yet: an approval reader never does.
#   [charter-sign]          the guard asks, the click's command writes the record and its log line; log --grants lists it; the
#                           spellings and the envelope's rules (repos, kinds, expires, the five keys) refused, each named
#   [charter-card]          the dialog shows the card: the focus, its goal, quote, done when and not doing, the envelope, what it
#                           covers, what never, what the owner types; words changed after the dialog are not signed
#   [charter-second]        a second charter for the focus and directory (or a worktree of its repository) while one is in force:
#                           the dialog denied and the sign refused rc 65, naming it; another focus or project, or after a revoke: signed
#   [charter-ended]         past its expiry, revoked, revoked with its focus (`grant revoke --focus`), or its focus closed through a
#                           real brain (`brain op close`): not in force
#   [charter-floor-refused] owner-acts or a SIGN_AGAIN_STOPS word in max_stops: the dialog denied naming it, and a spec rewritten
#                           after the dialog refused rc 65
#   [charter-no-done-when]  a focus with no done when (AC11), a closed, unknown or malformed one, no brain: denied, and rc 65 at sign
# The brain is a fake answering `show <P> --json` from a file the case writes, except where a real one closes the focus. The sdlc
# copy sits in a plugin cache whose registry names the brain beside it, as an installed one does. No network, nothing outside
# the scratch tree.
# =============================================================================
set -uo pipefail
# the brain's owner dialog reads ancestors' CLAUDE_CONFIG_DIR and HOME from their initial environment, which forked subshells
# share: start again without the launcher's (clean_env then points HOME into the scratch tree; the user base is pinned first)
if [ -z "${CHARTER_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR CHARTER_SUITE_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
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
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")

# the installed sdlc copy, a fake brain beside it, and a copy of the real brain (KIT, BROOT) for the focus's close
C="$TMP/claude"; S="$C/plugins/cache/vibemaestro/vibemaestro-sdlc/1.0.0"; FB="$TMP/fakebrain"
mkdir -p "$(dirname "$S")" "$FB/scripts"; mk_plugin_copy "$S"
brain_kit "$SRC_ROOT"
cat > "$FB/scripts/brain.py" <<'PY'
import json, os, sys
items = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "items.json")))
if sys.argv[1:2] != ["show"] or sys.argv[3:] != ["--json"]:
    sys.exit(64)
it = items.get(sys.argv[2])
if it is None:
    sys.stderr.write("brain: %s is not an item of this brain\n" % sys.argv[2])
    sys.exit(1)
print(json.dumps(dict(it, id=sys.argv[2])))
PY
# registry [<brain dir>] — the plugin registry naming the sdlc copy and, given one, the brain installed beside it
registry() {
  python3 - "$C/plugins/installed_plugins.json" "$S" "${1:-}" <<'PY'
import json, sys
e = lambda p: [{"scope": "user", "installPath": p, "version": "1.0.0", "lastUpdated": "2026-11-09T00:00:00.000Z"}]
ids = {"vibemaestro-sdlc@vibemaestro": e(sys.argv[2])}
if sys.argv[3]:
    ids["vibemaestro-brain@vibemaestro"] = e(sys.argv[3])
json.dump({"version": 2, "plugins": ids}, open(sys.argv[1], "w"))
PY
}
# items [<python statements on i>] — the fake brain's items: P8 live with every word, P9 live, P3 closed, N1 a Now item
items() {
  python3 - "$FB/scripts/items.json" "${1:-}" <<'PY'
import json, sys
src = lambda q: {"type": "session", "quote": q, "where": "chat 08/11"}
i = {"P8": {"kind": "focus", "status": "live", "text": "the story process", "goal": "G3", "source": src("ký cũng dài hơn"),
            "done": "every story merged, its real run recorded", "not_doing": "a Jira sync script"},
     "P9": {"kind": "focus", "status": "live", "text": "another focus", "goal": "G3", "source": src("q9"), "done": "it shipped"},
     "P3": {"kind": "focus", "status": "closed", "text": "an old focus", "goal": "G1", "source": src("q3"), "done": "done"},
     "N1": {"kind": "now", "status": "live", "text": "a Now item", "source": {"type": "session"}}}
exec(sys.argv[2])
json.dump(i, open(sys.argv[1], "w"))
PY
}
at() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + int(sys.argv[1]))))' "$1"; }
# cspec <file> [<python statements on s>] — a charter spec: focus P8, two repositories, the four kinds, Stops at most secrets,
# a day ahead; then the statements (`at(n)`: the UTC time n seconds ahead)
cspec() {
  python3 - "$1" "${2:-}" <<'PY'
import json, sys, time
at = lambda n: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + n))
s = {"focus": "P8", "repos": ["acme/app", "acme/ops"], "kinds": ["baton", "workflow", "script", "test"], "max_stops": ["secrets"],
     "expires": at(86400)}
exec(sys.argv[2])
json.dump(s, open(sys.argv[1], "w"))
PY
}

BT_OUT="$TMP/bt.out"; ST=""; W=""; GID=""; SID=s-owner; RC=""
# bt <dir> <baton args...> — rc of the installed copy's baton from <dir> as session SID; output in $BT_OUT. No guard.
bt() {
  local d=$1; shift
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$SID" python3 "$S/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
out() { cat "$BT_OUT"; }
bdir() { printf '%s' "$ST/vibemaestro/baton"; }
asked_n() { find "$(bdir)/asked" -name '*.json' 2>/dev/null | grep -c .; }
grants_n() { find "$(bdir)/grants" -maxdepth 1 -name '*.json' 2>/dev/null | grep -c .; }
gfile() { printf '%s' "$(bdir)/grants/$GID.json"; }
glist() { bt "$W" log --grants >/dev/null; out; }
# setup — a fresh state and project directory W (a git repository), the registry naming the fake brain, its items as given
setup() {
  ST="$(fresh)/state"; W=$(fresh); GID=""; SID=s-owner
  git_ init -q -b main "$W"; W=$(cd "$W" && pwd -P); registry "$FB"; items
}
# ask <spec> [dir] — the guard on the owner's literal `sign --by owner --charter <spec>` (or ASKCMD) from <dir> (default W) as
# session SID, as Claude Code runs it; prints the decision, keeps the dialog text in $TMP/guard.reason
ask() {
  local pl
  pl=$(python3 -c 'import json, sys
print(json.dumps({"session_id": sys.argv[1], "permission_mode": "default", "cwd": sys.argv[2], "hook_event_name": "PreToolUse",
                  "tool_name": "Bash", "tool_input": {"command": sys.argv[3]}}))' "$SID" "${2:-$W}" \
       "${ASKCMD:-python3 $S/scripts/baton.py sign --by owner --charter $1}")
  printf '%s' "$pl" | ( cd "${2:-$W}" && cenv XDG_STATE_HOME="$ST" python3 "$S/scripts/baton-guard.py" ) 2>/dev/null | python3 -c 'import json, sys
t = sys.stdin.read().strip()
o = json.loads(t)["hookSpecificOutput"] if t else {}
open(sys.argv[1], "w").write(o.get("permissionDecisionReason", ""))
print(o.get("permissionDecision", "none"))' "$TMP/guard.reason"
}
reason() { cat "$TMP/guard.reason"; }
# csign <spec> [dir] — the click's command, from <dir> (default W): RC, and GID when it signed
csign() {
  local g; RC=$(bt "${2:-$W}" sign --by owner --charter "$1")
  g=$(sed -n 's/^signed charter \([0-9a-f]\{16\}\) by owner: .*/\1/p' "$BT_OUT"); [ -z "$g" ] || GID=$g
}
# charter <spec> [dir] — a charter the owner signed: the dialog, then the click's command
charter() { ask "$1" "${2:-}" >/dev/null; csign "$1" "${2:-}"; }
# the sha256 of P8's words as the card shows them (JSON of text, goal, quote, where, done, not_doing; keys sorted, no spaces)
P8_WORDS=03e3aeba71e14657aad29635a2ae96d263e67e8728354fe131af5d72c7d4ae70
# reader <python on baton> — run code with the copy's baton imported, from W
reader() { (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import baton
$1" "$S/scripts") 2>&1; }

fam_sign() {  # [charter-sign] the dialog, the record, its log line, log --grants; no approval reader treats it as in force
  local T=charter-sign exp r
  setup; cspec "$W/c.json"; exp=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["expires"])' "$W/c.json")
  csign "$W/c.json"; eq "$RC/$(grants_n)" "3/0" "[$T] sign --by owner --charter with no dialog record: rc 3, nothing signed"
  eq "$(ask "$W/c.json")/$(asked_n)" "ask/1" "[$T] the owner's literal --charter: the guard asks and writes one record"
  csign "$W/c.json"; eq "$RC/$(grants_n)/$(asked_n)" "0/1/0" "[$T] the click's command: rc 0, one record, the dialog used up"
  has "$(out)" "signed charter $GID by owner: focus P8, 2 repositories, kinds baton, workflow, script, test, Stops at most secrets, until $exp, from $W" \
      "[$T] …one line names the charter and its envelope"
  eq "$(python3 -c 'import json, sys
g = json.load(open(sys.argv[1]))
print(sorted(g), g["v"], g["kind"], g["focus"], g["repos"], g["kinds"], g["max_stops"], g["expires"], g["dir"], g["dir_key"][:8], g["signature"]["by"])' "$(gfile)")" \
     "['body_sha256', 'created', 'dir', 'dir_key', 'env', 'expires', 'focus', 'focus_sha256', 'id', 'kind', 'kinds', 'max_stops', 'repos', 'session', 'signature', 'v'] 1 charter P8 ['acme/app', 'acme/ops'] ['baton', 'workflow', 'script', 'test'] ['secrets'] $exp $W project- owner" \
     "[$T] …the record: v 1, kind charter, the focus, the envelope, the directory, the owner's signature"
  eq "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["focus_sha256"])' "$(gfile)")" "$P8_WORDS" \
     "[$T] …focus_sha256: the digest of the focus's words the card showed"
  eq "$(tail -n 1 "$(bdir)/log.tsv" | cut -f2,8,10)" "$(printf 'grant\towner\tsigned')" "[$T] …and a grant signed log line"
  has "$(glist)" "$GID  in force  charter, signed " "[$T] log --grants lists it as a charter in force"
  has "$(glist)" "  Focus:     P8 (its words sha256 ${P8_WORDS:0:12})
  Dir:       $W (a merge or a run from any other project directory is not covered)
  Repos:     acme/app, acme/ops
  Kinds:     baton, workflow, script, test
  Stops:     at most secrets
  Until:     $exp, or the close or supersede of P8 in the brain (either revokes this charter), whichever comes first" "[$T] …with its envelope"
  eq "$(reader 'print(baton.load_grant("'"$GID"'"), baton.approvals_for("acme/app", "kb/plans/p.md", "B"))')" \
     "(None, 'not in force', 'grant $GID is a charter, never read as an approval') ([], [])" \
     "[$T] an approval reader (load_grant, approvals_for): not in force, nothing found or near"
  bt "$W" log --digest >/dev/null; has "$(out)" "approvals in force: none" "[$T] log --digest: not among the approvals in force"
  # the spellings: only the owner, one absolute path, nothing after it
  eq "$(bt "$W" sign --by owner --charter c.json)" 64 "[$T] a relative spec path: rc 64"
  eq "$(bt "$W" sign --by owner --charter "$W/c.json" extra)" 64 "[$T] a word after the spec: rc 64"
  eq "$(bt "$W" sign --by coordinator-auto --charter "$W/c.json")" 64 "[$T] sign --by coordinator-auto --charter: rc 64"
  eq "$(ASKCMD="python3 $S/scripts/baton.py sign --by owner --charter c.json" ask x)/$(asked_n)" "deny/0" "[$T] the guard on a relative path: denied, no record"
  # the envelope's rules: the dialog denied, naming each, no record (the charter above revoked: one in force would deny them all)
  eq "$(bt "$W" grant revoke "$GID")" 0 "[$T] instrument: the charter above revoked"
  for r in 's["repos"] = []|repos is a list of 1 to 10 owner/name, no repository twice' \
           's["repos"] = ["acme/r%d" % n for n in range(11)]|repos is a list of 1 to 10 owner/name, no repository twice' \
           's["repos"] = ["acme/app", "ACME/App"]|repos is a list of 1 to 10 owner/name, no repository twice' \
           's["repos"] = ["acme"]|repos is a list of 1 to 10 owner/name, no repository twice' \
           's["kinds"] = []|kinds is a non-empty list of baton, workflow, script, test, none twice' \
           's["kinds"] = ["test", "test"]|kinds is a non-empty list of baton, workflow, script, test, none twice' \
           's["kinds"] = ["baton", "config"]|kinds: config is none of baton, workflow, script, test: it stays with a plan approval or the owner'"'"'s merge' \
           's["kinds"] = ["other"]|kinds: other is none of baton, workflow, script, test' \
           's["kinds"] = ["rbac"]|kinds: rbac is none of baton, workflow, script, test' \
           's["kinds"] = ["admission"]|kinds: admission is none of baton, workflow, script, test' \
           's["kinds"] = ["vault-policy"]|kinds: vault-policy is none of baton, workflow, script, test' \
           's["max_stops"] = ["fun"]|max_stops: fun is not a baton stop word' \
           's["max_stops"] = ["secrets", "secrets"]|max_stops is a list of baton stop words, none twice' \
           's["expires"] = at(-60)|expires is a UTC time YYYY-MM-DDTHH:MM:SSZ after now and at most 90 days ahead' \
           's["expires"] = at(91 * 86400)|expires is a UTC time YYYY-MM-DDTHH:MM:SSZ after now and at most 90 days ahead' \
           's["expires"] = "2027-01-01"|expires is a UTC time YYYY-MM-DDTHH:MM:SSZ after now and at most 90 days ahead' \
           's["rows"] = []|the charter spec is an object of exactly focus, repos, kinds, max_stops and expires' \
           'del s["max_stops"]|the charter spec is an object of exactly focus, repos, kinds, max_stops and expires' \
           's = [s]|the charter spec is an object of exactly focus, repos, kinds, max_stops and expires' \
           's["repos"] = ["acme/app"] * 20000|cannot be read as JSON of at most 65536 bytes'; do
    cspec "$W/d.json" "${r%%|*}"
    eq "$(ask "$W/d.json")/$(asked_n)" "deny/0" "[$T] ${r%%|*}: the dialog is denied, no record"
    has "$(reason)" "${r#*|}" "[$T] …named: ${r#*|}"
  done
  for r in 's["expires"] = at(89 * 86400)' 's["max_stops"] = []' 's["max_stops"] = ["secrets", "publish", "cluster-lane"]' \
           's["kinds"] = ["test"]' 's["repos"] = ["acme/r%d" % n for n in range(10)]'; do
    cspec "$W/d.json" "$r"; eq "$(ask "$W/d.json")" ask "[$T] control: $r is asked"
  done
  cspec "$W/d.json" 's["kinds"] = ["config"]'; ask "$W/c.json" >/dev/null; mv "$W/d.json" "$W/c.json"   # the spec rewritten after the dialog: an input, not a break
  csign "$W/c.json"; eq "$RC/$(grants_n)" "65/1" "[$T] the spec rewritten to a kind outside the four after the dialog: sign rc 65, no record"
  has "$(out)" "sign refused: the charter spec $W/c.json: kinds: config is none of baton, workflow, script, test" "[$T] …the rule named"
}

fam_card() {  # [charter-card] the dialog's card, and the words it showed bound to the signature
  local T=charter-card exp
  setup; cspec "$W/c.json"; exp=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["expires"])' "$W/c.json")
  eq "$(ask "$W/c.json")" ask "[$T] the guard asks"
  eq "$(reason)" "baton: the owner signs a charter for focus P8 the story process (goal G3):
  Quote:     \"ký cũng dài hơn\" · chat 08/11
  Done when: every story merged, its real run recorded
  Not doing: a Jira sync script
  Focus:     P8 (its words sha256 ${P8_WORDS:0:12})
  Dir:       $W (a merge or a run from any other project directory is not covered)
  Repos:     acme/app, acme/ops
  Kinds:     baton, workflow, script, test
  Stops:     at most secrets
  Until:     $exp, or the close or supersede of P8 in the brain (either revokes this charter), whichever comes first
  Covers:    the merges and \`go --row\` runs of every plan whose frontmatter says \`focus: P8\`, when every change is a touch its row declares and inside this envelope, as many PRs and runs as the row says
  Never:     the floor (the judge paths and every touch_inputs path, a .claude-plugin path, a baton or run with security-boundary, irreversible-delete, no-way-back or history-rewrite, a secrets run of a baton outside vault-put-text, vault-put-file, credential-import, credential-upload, kubeconfig-install, script-run, script-run-upload, a signing-rules finding of kind other, a touch marked (signs again)), nor any touch outside this envelope: those stay a plan approval or the owner's merge
  The owner types: the GPG passphrase on the passphrase holder's page, once for the focus's charter-covered secrets runs, held at most 24 h
Your click is the owner's signature; the session never answers this dialog for you." "[$T] the whole card: the focus, goal, quote, done when, not doing, the envelope, what it covers, what never, what the owner types"
  items 'del i["P8"]["not_doing"]'; cspec "$W/c.json" 's["max_stops"] = []'
  eq "$(ask "$W/c.json")" ask "[$T] a focus with no not doing, max_stops []: asked"
  hasnt "$(reason)" "Not doing:" "[$T] …no Not doing line"
  has "$(reason)" "  Stops:     none (only touches and runs with no Stops)" "[$T] …Stops none said so"
  has "$(reason)" "  The owner types: nothing under this charter (a secrets run is outside it)" "[$T] …and the owner types nothing under it"
  items 'i["P8"]["done"] = "every story merged"'
  csign "$W/c.json"; eq "$RC/$(grants_n)" "3/0" "[$T] the focus's done when changed after the dialog: sign rc 3, nothing signed"
  has "$(out)" "the charter changed since the dialog showed it" "[$T] …named"
  items; ask "$W/c.json" >/dev/null; items 'i["P8"]["goal"] = "G4"'
  csign "$W/c.json"; eq "$RC/$(grants_n)" "3/0" "[$T] the focus's goal changed after the dialog: sign rc 3, nothing signed"
  items; ask "$W/c.json" >/dev/null; items 'i["P8"]["source"]["where"] = "a page"'
  csign "$W/c.json"; eq "$RC/$(grants_n)" "3/0" "[$T] the quote's where changed after the dialog: sign rc 3, nothing signed"
  items 'i["P8"]["text"] = "<\u001b[31mred x>"'
  eq "$(ask "$W/c.json")" ask "[$T] a focus text with an escape and a line separator: asked"
  has "$(reason)" 'for focus P8 <\u{1b}[31mred\u{2028}x> (goal G3):' "[$T] …both written as \\u{…} on the card"
}

fam_second() {  # [charter-second] one charter per focus and directory while one is in force
  local T=charter-second first W2 WT
  setup; cspec "$W/c1.json"; cspec "$W/c2.json" 's["kinds"] = ["test"]'
  SID=s1; ask "$W/c1.json" >/dev/null; SID=s2; eq "$(ask "$W/c2.json")" ask "[$T] instrument: two sessions each have a dialog for P8"
  SID=s1; csign "$W/c1.json"; first=$GID; eq "$RC" 0 "[$T] the first is signed"
  SID=s2; csign "$W/c2.json"; eq "$RC/$(grants_n)" "65/1" "[$T] the second, its dialog shown before the first was signed: sign rc 65, no record"
  has "$(out)" "a charter for P8 is in force from $W: $first until " "[$T] …naming the one in force"
  has "$(out)" "grant revoke $first first (no dialog: a narrowing), then sign again" "[$T] …and how to change the envelope"
  eq "$(ask "$W/c2.json")/$(asked_n)" "deny/0" "[$T] the guard on the second: denied, no record"
  has "$(reason)" "a charter for P8 is in force from $W: $first until " "[$T] …naming it"
  git_ -C "$W" commit -q --allow-empty -m one; WT="$W.wt"; git_ -C "$W" worktree add -q --detach "$WT"; WT=$(cd "$WT" && pwd -P)
  eq "$(ask "$W/c2.json" "$WT")" deny "[$T] from a worktree of the same repository: denied"
  has "$(reason)" "a charter for P8 is in force from $W: $first" "[$T] …naming it"
  cspec "$W/c9.json" 's["focus"] = "P9"'; charter "$W/c9.json"; eq "$RC" 0 "[$T] control: a charter for another focus, P9, from W: signed"
  W2=$(fresh); git_ init -q -b main "$W2"; W2=$(cd "$W2" && pwd -P)
  charter "$W/c2.json" "$W2"; eq "$RC" 0 "[$T] control: a charter for P8 from another project: signed"
  eq "$(bt "$W" grant revoke "$first")" 0 "[$T] grant revoke of the first"
  charter "$W/c2.json"; eq "$RC" 0 "[$T] …then a new charter for P8 from W: signed"
  eq "$(grep -c "$GID  in force  charter" <<< "$(glist)")/$(grep -c "$first  revoked  charter" <<< "$(glist)")" "1/1" "[$T] …listed in force, the first revoked"
}

fam_ended() {  # [charter-ended] expired, revoked, revoked with its focus, or its focus closed in a real brain: not in force
  local T=charter-ended a b c W2 W3 day tok osd
  setup; cspec "$W/c.json" 's["expires"] = at(3)'; charter "$W/c.json"; a=$GID; eq "$RC" 0 "[$T] a charter of 3 s"
  sleep 4; has "$(glist)" "$a  expired  charter, signed " "[$T] …past its expiry: expired"
  has "$(glist)" "  grant $a expired at " "[$T] …naming when"
  cspec "$W/c.json"; charter "$W/c.json"; b=$GID; eq "$RC" 0 "[$T] the expired one is not in force: a new charter for P8 is signed"
  eq "$(bt "$W" grant revoke "$b")" 0 "[$T] grant revoke: rc 0"
  eq "$(out)" "grant $b revoked: the charter for P8 ended" "[$T] …one line says so"
  has "$(glist)" "$b  revoked  charter, signed " "[$T] …listed revoked"
  # grant revoke --focus: each charter in force for the focus signed from this project, none other
  charter "$W/c.json"; a=$GID; cspec "$W/c9.json" 's["focus"] = "P9"'; charter "$W/c9.json"; c=$GID
  W2=$(fresh); git_ init -q -b main "$W2"; W2=$(cd "$W2" && pwd -P); charter "$W/c.json" "$W2"; b=$GID
  eq "$(bt "$W" grant revoke --focus P8)" 0 "[$T] grant revoke --focus P8 from W: rc 0"
  eq "$(out)" "grant $a revoked: the charter for P8 ended" "[$T] …it revokes W's charter for P8, one line"
  has "$(glist)" "$a  revoked  charter" "[$T] …listed revoked"
  has "$(glist)" "$b  in force  charter" "[$T] …P8's charter from another project stays in force"
  has "$(glist)" "$c  in force  charter" "[$T] …and P9's from W"
  eq "$(bt "$W" grant revoke --focus P8)/$(out)" "0/no charter in force for P8 from $W" "[$T] again: rc 0, nothing to revoke"
  eq "$(bt "$W" grant revoke --focus 8)" 64 "[$T] grant revoke --focus with a malformed focus: rc 64"
  eq "$(bt "$W" grant revoke --focus P8 extra)" 64 "[$T] …or a word after it: rc 64"
  # a grants/ file nested past what json.dumps encodes (the depth depends on the Python): damaged at every depth, never a crash
  eq "$(reader 'import json, os
gid = "0123456789abcdef"; p = os.path.join(baton.grants_dir(), gid + ".json"); bad = []
rec = json.dumps({"v": 1, "kind": "charter", "id": gid, "expires": "2030-01-01T00:00:00Z", "focus": "P8", "repos": [], "kinds": [], "max_stops": []})
for n in range(800, 1200):
    open(p, "w").write(rec[:-1] + ", \"x\": " + "[" * n + "]" * n + "}")   # an input, not a break
    try:
        bad += [] if baton.load_grant(gid, kind="charter")[1] == "damaged" else [n]
    except RecursionError:
        bad.append(n)
os.unlink(p)
print(bad)')" "[]" "[$T] a grants/ file nested 800 to 1199 deep: read damaged at each depth, never a crash (so --focus and the brain's close go on)"
  # the focus closed in a real brain: its close revokes the charter
  setup; registry "$BROOT"; export XDG_STATE_HOME="$ST"; cd "$W" || return 1
  day=$(python3 -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=30))')
  owner_ok add --kind goal --text "ship the story process" --owner-quote q --where chat --done "merged" --not-doing "x" --review "$day" --scope project
  eq "$RC" 0 "[$T] instrument: a goal G1 is pinned in the real brain"
  br op add --kind focus --text "the story process" --owner-quote "ký cũng dài hơn" --where chat --goal G1 --done-when "every story merged"
  eq "$RC" 0 "[$T] instrument: a focus P1 with its done when"
  cspec "$W/c.json" 's["focus"] = "P1"'; eq "$(ask "$W/c.json")" ask "[$T] the dialog reads P1 through the real brain"
  has "$(reason)" "charter for focus P1 the story process (goal G1):" "[$T] …its words on the card"
  csign "$W/c.json"; a=$GID; eq "$RC" 0 "[$T] …signed"
  # the session's recorded project is W (as the brain's SessionStart writes it); from another project the focus is that one's
  bpy 's.record_session("'"$SID"'", "'"$W"'", s.state_dir("'"$W"'"))' >/dev/null; W3=$(fresh); git_ init -q -b main "$W3"
  eq "$( (cd "$W3" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$SID" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton
print(baton.focus_item("P1")[1])' "$S/scripts") 2>&1)" "P1 is not an open focus of this brain (brain show: brain: no brain state for this project yet)" \
     "[$T] from another project in a session recorded on W: the focus is read in the project the charter binds, not W"
  tok="ghp_$(python3 -c 'print("a1B2c3D4e5" * 4)' | cut -c1-36)"
  br op close P1 --reason "$tok"; eq "$RC" 1 "[$T] a close the sensitive filter refuses: rc 1"
  has "$(glist)" "$a  in force  charter" "[$T] …nothing written, and the charter is not revoked"
  br op close P1 --reason "the story landed"; eq "$RC" 0 "[$T] brain op close P1: rc 0"
  has "$OUT" "closed P1" "[$T] …the focus is closed"
  has "$OUT" "grant $a revoked: the charter for P1 ended" "[$T] …and its charter revoked, said in the same output"
  has "$(glist)" "$a  revoked  charter" "[$T] …listed revoked"
  br op add --kind focus --text "a second focus" --owner-quote q2 --where chat --goal G1 --done-when "it shipped"
  br op close P2 --reason "dropped"; eq "$RC" 0 "[$T] closing a focus with no charter: rc 0"
  hasnt "$OUT" "revoked" "[$T] …nothing revoked"
  # a supersede ends the focus too: its charter is revoked, and the owner signs again for the successor
  br op add --kind focus --text "a third focus" --owner-quote q3 --where chat --goal G1 --done-when "it landed"
  cspec "$W/c.json" 's["focus"] = "P3"'; charter "$W/c.json"; a=$GID; eq "$RC" 0 "[$T] instrument: a charter for P3"
  br op supersede P3 --text "a third" --reason "shorter"; eq "$RC" 1 "[$T] a supersede its own shrink check refuses: rc 1"
  has "$(glist)" "$a  in force  charter" "[$T] …nothing written, and the charter is not revoked"
  # an older vibemaestro-sdlc beside the brain, whose baton.py knows only `grant revoke <id>`: the focus does not end
  osd="$TMP/oldsdlc"; mkdir -p "$osd/scripts" "$TMP/oldcfg/plugins"
  printf 'import sys\nsys.stderr.write("usage: baton.py grant revoke <id>  (the id log --grants shows)\\n")\nsys.exit(64)\n' > "$osd/scripts/baton.py"
  printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s"}]}}' "$osd" > "$TMP/oldcfg/plugins/installed_plugins.json"
  CLAUDE_CONFIG_DIR="$TMP/oldcfg" br op close P3 --reason "the story landed"; eq "$RC" 1 "[$T] brain op close P3 beside an older sdlc: rc 1"
  has "$OUT" "this vibemaestro-sdlc predates \`grant revoke --focus\`, update it" "[$T] …naming the update"
  has "$(glist)" "$a  in force  charter" "[$T] …the focus not closed, its charter in force"
  printf 'import sys\nsys.stderr.write("usage: baton.py grant revoke --focus <P>\\n")\nsys.exit(64)\n' > "$osd/scripts/baton.py"
  CLAUDE_CONFIG_DIR="$TMP/oldcfg" br op close P3 --reason "the story landed"; eq "$RC" 1 "[$T] a baton that refuses --focus another way (rc 64): rc 1"
  hasnt "$OUT" "predates" "[$T] …no update hint: only an older baton's usage gets one"
  br op supersede P3 --text "a third focus, said again" --reason "the owner's new words"; eq "$RC" 0 "[$T] brain op supersede P3: rc 0"
  has "$OUT" "superseded P3 with P4" "[$T] …P4 succeeds it"
  has "$OUT" "grant $a revoked: the charter for P3 ended" "[$T] …and P3's charter is revoked, said in the same output"
  has "$(glist)" "$a  revoked  charter" "[$T] …listed revoked"
  br op supersede P4 --text "a third focus, said a third time" --reason "again"; eq "$RC" 0 "[$T] superseding a focus with no charter: rc 0"
  hasnt "$OUT" "revoked" "[$T] …nothing revoked"
  cd "$TMP" || return 1; export XDG_STATE_HOME="$HOME/.local/state"
}

fam_floor() {  # [charter-floor-refused] owner-acts or a SIGN_AGAIN_STOPS word in max_stops: never inside a charter
  local T=charter-floor-refused w
  setup
  for w in owner-acts security-boundary irreversible-delete no-way-back history-rewrite; do
    cspec "$W/d.json" 's["max_stops"] = ["secrets", "'"$w"'"]'
    eq "$(ask "$W/d.json")/$(asked_n)" "deny/0" "[$T] max_stops holds $w: the dialog is denied, no record"
    has "$(reason)" "max_stops: $w " "[$T] …naming $w"
  done
  has "$(reason)" "max_stops: history-rewrite signs again at every run: never inside a charter" "[$T] …a SIGN_AGAIN_STOPS word: why"
  cspec "$W/d.json" 's["max_stops"] = ["owner-acts"]'; ask "$W/d.json" >/dev/null
  has "$(reason)" "max_stops: owner-acts means the owner does the act: never inside an envelope that removes the owner's dialog" "[$T] owner-acts: why"
  cspec "$W/c.json"; ask "$W/c.json" >/dev/null; cspec "$W/c.json" 's["max_stops"] = ["owner-acts"]'   # rewritten after the dialog: an input
  csign "$W/c.json"; eq "$RC/$(grants_n)" "65/0" "[$T] owner-acts written in after the dialog: sign rc 65, nothing signed"
  has "$(out)" "max_stops: owner-acts means the owner does the act" "[$T] …naming it"
  cspec "$W/c.json"; ask "$W/c.json" >/dev/null; cspec "$W/c.json" 's["max_stops"] = ["no-way-back"]'
  csign "$W/c.json"; eq "$RC/$(grants_n)" "65/0" "[$T] no-way-back written in after the dialog: sign rc 65, nothing signed"
  has "$(out)" "max_stops: no-way-back signs again at every run" "[$T] …naming it"
  # the floor read again from the record: owner-acts written into a signed one, its digest and signed line forged
  cspec "$W/c.json"; charter "$W/c.json"; eq "$RC" 0 "[$T] instrument: a charter signed"
  python3 - "$(gfile)" <<'PY' > "$TMP/forged.sha"   # the record rewritten, its digest computed again: an input, not a break
import hashlib, json, sys
g = json.load(open(sys.argv[1]))
g["max_stops"].append("owner-acts")
body = {k: v for k, v in g.items() if k not in ("body_sha256", "signature")}
g["body_sha256"] = g["signature"]["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
open(sys.argv[1], "w").write(json.dumps(g))
print(g["body_sha256"])
PY
  printf '2026-11-09T00:00:00Z\tgrant\t-\t-\t-\t-\t-\towner\t-\tsigned\t-\t%s %s\t-\n' "$GID" "$(cat "$TMP/forged.sha")" >> "$(bdir)/log.tsv"
  has "$(glist)" "$GID  damaged  (grant $GID is damaged" "[$T] …read as damaged, never in force"
  eq "$(bt "$W" grant revoke "$GID")/$(out)" "0/grant $GID revoked: the charter for P8 ended" "[$T] …grant revoke of that damaged charter: rc 0, said as a charter's"
}

fam_done() {  # [charter-no-done-when] the focus: live in the brain, with its done when (AC11)
  local T=charter-no-done-when r
  setup
  for r in 'del i["P8"]["done"]|P8 has no `done when`: a charter needs the owner'"'"'s words for when the focus is done (brain op supersede P8 --done-when …)' \
           'i["P8"]["done"] = "  "|P8 has no `done when`' \
           'i["P8"]["status"] = "closed"|P8 is not an open focus of this brain (it is a focus item, closed)' \
           'del i["P8"]|P8 is not an open focus of this brain (brain show: brain: P8 is not an item of this brain)' \
           'i["P8"] = i["N1"]|P8 is not an open focus of this brain (it is a now item, live)'; do
    items "${r%%|*}"; cspec "$W/d.json"
    eq "$(ask "$W/d.json")/$(asked_n)" "deny/0" "[$T] ${r%%|*}: the dialog is denied, no record"
    has "$(reason)" "${r#*|}" "[$T] …named: ${r#*|}"
  done
  items; cspec "$W/d.json" 's["focus"] = "8"'; eq "$(ask "$W/d.json")" deny "[$T] focus 8: denied"
  has "$(reason)" "focus is a focus of the brain, like P8" "[$T] …named"
  registry; cspec "$W/d.json"; eq "$(ask "$W/d.json")" deny "[$T] no brain beside the sdlc copy: denied"
  has "$(reason)" "no brain answers here (vibemaestro-brain is not installed beside this sdlc copy): a charter reads its focus there" "[$T] …named"
  registry "$FB"; items; cspec "$W/c.json"; eq "$(ask "$W/c.json")" ask "[$T] control: P8 live with its done when: asked"
  items 'del i["P8"]["done"]'
  csign "$W/c.json"; eq "$RC/$(grants_n)" "65/0" "[$T] its done when gone between the dialog and the click: sign rc 65, nothing signed"
  has "$(out)" 'sign refused: the charter spec '"$W"'/c.json: P8 has no `done when`' "[$T] …naming the missing done when"
  items; ask "$W/c.json" >/dev/null; items 'i["P8"]["status"] = "closed"'
  csign "$W/c.json"; eq "$RC/$(grants_n)" "65/0" "[$T] the focus closed between the dialog and the click: sign rc 65"
  has "$(out)" "P8 is not an open focus of this brain" "[$T] …named"
}

for f in fam_sign fam_card fam_second fam_ended fam_floor fam_done; do
  echo "-- $f"; f0=$FAIL; "$f"
  t=$(declare -f "$f" | sed -n 's/.*local T=\([a-z-]*\).*/\1/p' | head -n 1)
  [ "$FAIL" = "$f0" ] && echo "[$t] ok" || echo "[$t] FAIL"
done

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
