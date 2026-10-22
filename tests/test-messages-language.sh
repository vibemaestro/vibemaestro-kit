#!/bin/bash
# =============================================================================
# The messages of the sdlc scripts follow the repo's `language`: en prints English, no key prints today's bytes
# =============================================================================
# Run: bash tests/test-messages-language.sh            (the suite)
#      bash tests/test-messages-language.sh --record   (rewrite tests/fixtures/messages-vi/ from the plugin as it is: only to
#                                                       record the bytes of a commit before a change, never to make a run green)
#
# Families:
#   [vi]      a repo with no `language` key: every printing path of tests/fixtures/messages_drive.sh prints exactly the bytes
#             recorded from kit main b8d2683 (tests/fixtures/messages-vi/), and no case is missing or new
#   [en]      `"language": "en"`: the same paths end with the same exit code as the recorded ones and print no Vietnamese
#             letter outside the user's own words a message quotes (<case>.data of the driver); positive control: the vi run
#             of the same plugin prints them in most cases
#   [table]   scripts/messages.py: every key has a `vi` and an `en` text with the same `%` placeholders, no `en` text holds a
#             Vietnamese letter, every key is used by a script, and `language()` reads the file leniently (an invalid config,
#             an unknown language, no file: vi)
#   [measure] tests/fixtures/messages_measure.py over sdlc scripts/ and gates/ and brain scripts/: no string that is not a
#             docstring holds a Vietnamese letter outside the `vi` side of a table or the parsing patterns it lists (positive
#             control: a planted print is reported)
#
# Every family runs on a copy of the real plugin; then each planted break must turn its family red. Real git on throw-away
# repositories, a fake gh, the network shims of netguard.sh, no model, no network.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/messages_drive.sh
. "$HERE/fixtures/messages_drive.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
BRAIN="$SRC_ROOT/plugins/vibemaestro-brain"
GOLD="$HERE/fixtures/messages-vi"
LANGPY="$HERE/fixtures/language/lang.py"
MEASURE="$HERE/fixtures/messages_measure.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

if [ "${1:-}" = --record ]; then
  PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"; O=$(fresh)
  drive "$PL0" vi "$O"
  rm -rf "$GOLD"; mkdir -p "$GOLD"; cp "$O"/*.txt "$GOLD/"
  echo "recorded $(ls "$GOLD" | wc -l | tr -d ' ') cases into tests/fixtures/messages-vi/"
  exit 0
fi

viet() { cenv python3 -B "$LANGPY" viet "$@"; }
# unquote <output> <data> — the output without the words of <data> (input a message quotes) that hold a non-ASCII letter
unquote() {
  python3 - "$1" "$2" <<'PY'
import os, sys
out, data = sys.argv[1:3]
t = open(out, encoding="utf-8").read()
words = open(data, encoding="utf-8").read().split() if os.path.exists(data) else []
for w in sorted({w.strip(".,:;'\"()[]") for w in words if any(ord(c) > 127 for c in w)}, key=len, reverse=True):
    t = t.replace(w, "<input>")
sys.stdout.write(t)
PY
}

# ── [vi] ─────────────────────────────────────────────────────────────────────────────────────────
fam_vi() {
  local P=$1 O f n=0 bad_=0
  O=$(fresh); drive "$P" vi "$O"
  eq "$(cd "$O" && ls ./*.txt | sort | tr '\n' ' ')" "$(cd "$GOLD" && ls ./*.txt | sort | tr '\n' ' ')" "[vi] the cases driven are the recorded ones"
  for f in "$GOLD"/*.txt; do
    n=$((n + 1))
    cmp -s "$f" "$O/$(basename "$f")" || { bad_=$((bad_ + 1)); bad "[vi] $(basename "$f" .txt): not the recorded bytes: $(diff "$f" "$O/$(basename "$f")" | head -4 | tr '\n' ' ' | cut -c1-300)"; }
  done
  [ "$bad_" = 0 ] && ok "[vi] no language key: all $n cases print the bytes recorded from b8d2683"
}

# ── [en] ─────────────────────────────────────────────────────────────────────────────────────────
fam_en() {
  local P=$1 O V f c hits=0 rcs=0 n=0 vihits
  O=$(fresh); drive "$P" en "$O"
  for f in "$GOLD"/*.txt; do
    c=$(basename "$f" .txt); n=$((n + 1))
    [ -f "$O/$c.txt" ] || { bad "[en] $c: not driven"; continue; }
    [ "$(tail -n 1 "$O/$c.txt")" = "$(tail -n 1 "$f")" ] || { rcs=$((rcs + 1)); bad "[en] $c: ends $(tail -n 1 "$O/$c.txt"), the recorded run $(tail -n 1 "$f")"; }
    unquote "$O/$c.txt" "$O/$c.data" > "$O/$c.own"
    viet "$O/$c.own" >/dev/null || { hits=$((hits + 1)); bad "[en] $c prints Vietnamese: $(grep -m1 -n '[^ -~]' "$O/$c.own" | cut -c1-200)"; }
  done
  [ "$rcs" = 0 ] && ok "[en] all $n cases end with the exit code of the recorded run (the same paths were reached)"
  [ "$hits" = 0 ] && ok "[en] \"language\": \"en\": none of the $n cases prints a Vietnamese letter"
  V=$(fresh); drive "$P" vi "$V"
  vihits=$(cd "$V" && viet ./*.txt | awk '$1 > 0' | wc -l | tr -d ' ')
  [ "$vihits" -ge 50 ] && ok "[en] positive control: the vi run of the same plugin prints Vietnamese in $vihits cases" \
    || bad "[en] positive control: the vi run prints Vietnamese in only $vihits cases: the instrument does not see them"
}

# ── [table] ──────────────────────────────────────────────────────────────────────────────────────
fam_table() {
  local P=$1 out
  out=$(cenv python3 -B - "$P" "$BRAIN" <<'PY'
import json, os, re, sys, tempfile
plugin, brain = sys.argv[1:3]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import messages as M
VI = re.compile(r"[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]", re.I)
PH = re.compile(r"%(?:\([^)]*\))?[-#0 +]*\d*(?:\.\d+)?[sdrifx%]")
def say(ok, what):
    print(("ok\t" if ok else "FAIL\t") + what)
bad = [k for k, v in M.TABLE.items() if set(v) != {"vi", "en"} or not all(isinstance(v[l], str) and v[l] for l in ("vi", "en"))]
say(not bad, "[table] every key has a non-empty vi and en text (%d keys)%s" % (len(M.TABLE), ": " + ", ".join(bad[:5]) if bad else ""))
bad = [k for k, v in M.TABLE.items() if PH.findall(v.get("vi", "")) != PH.findall(v.get("en", ""))]
say(not bad, "[table] vi and en hold the same %% placeholders in the same order%s" % (": " + ", ".join(bad[:5]) if bad else ""))
bad = [k for k, v in M.TABLE.items() if VI.search(v.get("en", ""))]
say(not bad, "[table] no en text holds a Vietnamese letter%s" % (": " + ", ".join(bad[:5]) if bad else ""))
src = ""
for top in (os.path.join(plugin, "scripts"), os.path.join(plugin, "gates"), os.path.join(brain, "scripts")):
    for root, _subs, files in os.walk(top):
        for fn in sorted(files):
            if fn != "messages.py" and fn.endswith((".py", ".sh")):
                src += open(os.path.join(root, fn), encoding="utf-8").read()
# the reverse: every key a script names is in the table, with as many arguments as its placeholders (text() never raises, so a
# wrong key or count would print the key instead of failing)
import ast
unknown, counts = [], []
for top in (os.path.join(plugin, "scripts"), os.path.join(plugin, "gates"), os.path.join(brain, "scripts")):
    for root, _subs, files in os.walk(top):
        for fn in sorted(files):
            p = os.path.join(root, fn)
            if fn == "messages.py" or not fn.endswith((".py", ".sh")):
                continue
            text = open(p, encoding="utf-8").read()
            if fn.endswith(".sh"):
                for k in re.findall(r"\bsay (?:--root \S+ )?([a-z]+\.[a-z_.]+)", text):
                    k in M.TABLE or unknown.append("%s:%s" % (fn, k))
                continue
            for node in ast.walk(ast.parse(text)):
                if not isinstance(node, ast.Call) or not node.args or not isinstance(node.args[0], ast.Constant):
                    continue
                f = node.func
                name = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""
                key = node.args[0].value
                if name == "M":
                    n = len(node.args) - 1
                elif name == "text" and isinstance(f, ast.Attribute) and getattr(f.value, "id", "") == "messages":
                    n = len(node.args) - 2
                else:
                    continue
                if key not in M.TABLE:
                    unknown.append("%s:%d:%s" % (fn, node.lineno, key))
                elif not any(isinstance(a, ast.Starred) for a in node.args) and n != len(PH.findall(M.TABLE[key]["vi"])):
                    counts.append("%s:%d:%s" % (fn, node.lineno, key))
say(not unknown, "[table] every key a script names is in the table%s" % (": " + ", ".join(unknown[:5]) if unknown else ""))
say(not counts, "[table] every call passes as many arguments as its key has placeholders%s" % (": " + ", ".join(counts[:5]) if counts else ""))
dead = [k for k in M.TABLE if not re.search(r"(?<![\w.])" + re.escape(k) + r"(?![\w.])", src)
        and not (k.startswith("cs.sign.") and '"cs.sign." + sid' in src)]
say(not dead, "[table] every key is used by a script%s" % (": " + ", ".join(dead[:5]) if dead else ""))
d = tempfile.mkdtemp()
def lang(text):
    os.makedirs(os.path.join(d, ".vibemaestro"), exist_ok=True)
    p = os.path.join(d, ".vibemaestro", "sdlc.json")
    if text is None:
        os.path.exists(p) and os.remove(p)
    else:
        open(p, "w").write(text)
    return M.language(d)
say(lang(None) == "vi", "[table] language(): no config file reads vi")
say(lang('{"schema": 1}') == "vi", "[table] language(): a config without the key reads vi")
say(lang('{"schema": 1, "language": "en"}') == "en", "[table] language(): \"language\": \"en\" reads en")
say(lang('{"schema": 1, "language": "en", "bogus": {') == "vi", "[table] language(): a file that does not parse reads vi")
say(lang('{"schema": 1, "language": "en", "commits": {"max_per_pr": "x"}}') == "en", "[table] language(): an otherwise invalid config still reads its language")
say(lang('{"schema": 1, "language": "fr"}') == "vi", "[table] language(): an unknown language reads vi")
say(M.text("kb.date", "fr") == M.TABLE["kb.date"]["vi"], "[table] text(): an unknown language falls back to vi")
say(M.text("no.such.key", "en", 1, "x") == "no.such.key 1 x", "[table] text(): a key the table lacks (a gate newer than its vendored table) prints the key and its arguments, never raises")
PY
)
  while IFS= read -r line; do
    case "$line" in ok$'\t'*) ok "${line#ok$'\t'}";; FAIL$'\t'*) bad "${line#FAIL$'\t'}";; *) bad "[table] unexpected: ${line:0:200}";; esac
  done <<<"$out"
}

# ── [measure] ────────────────────────────────────────────────────────────────────────────────────
fam_measure() {
  local P=$1 out rc d
  out=$(cenv python3 -B "$MEASURE" "$P" "$BRAIN" 2>&1); rc=$?
  eq "$rc" 0 "[measure] no unclassified Vietnamese string in sdlc scripts/, gates/ or brain scripts/ ($(printf '%s\n' "$out" | tail -n 1))"
  [ "$rc" = 0 ] || printf '%s\n' "$out" | head -8 | sed 's/^/       /'
  d=$(fresh); cp -r "$P" "$d/p"; printf '\ndef _planted():\n    print("Tóm tắt")\n' >> "$d/p/scripts/kb_index.py"
  out=$(cenv python3 -B "$MEASURE" "$d/p" "$BRAIN" 2>&1); rc=$?
  eq "$rc" 1 "[measure] positive control: a planted print(\"Tóm tắt\") is reported"
  has "$out" "kb_index.py" "[measure] …naming its file"
}

FAMILIES="fam_vi fam_en fam_table fam_measure"
echo "== the real plugin =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a plugin with one break =="
BRK() {  # BRK <label> <family> <needle> <file under the plugin> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK vi-byte fam_vi '[vi] kb-date' scripts/messages.py '"vi": "--date phải là YYYY-MM-DD"' '"vi": "--date phải là YYYY-MM-DD "'
BRK en-viet fam_en '[en] kb-date prints Vietnamese' scripts/messages.py '"en": "--date must be YYYY-MM-DD"' '"en": "--date phải là YYYY-MM-DD"'
BRK en-table fam_table '[table] no en text holds a Vietnamese letter' scripts/messages.py '"en": "--date must be YYYY-MM-DD"' '"en": "--date phải là YYYY-MM-DD"'
BRK bypass fam_measure '[measure] no unclassified' scripts/kb.py 'return die(M("kb.date"), 64)' 'return die("--date phải là YYYY-MM-DD", 64)'
BRK key-unknown fam_table '[table] every key a script names' scripts/kb.py 'return die(M("kb.date"), 64)' 'return die(M("kb.dat"), 64)'
BRK arg-count fam_table '[table] every call passes as many arguments' scripts/kb.py 'M("kb.slug", slug)' 'M("kb.slug", slug, slug)'
BRK lang-strict fam_table '[table] language(): an otherwise invalid' scripts/messages.py '    lang = data.get("language") if isinstance(data, dict) else None' '    lang = data.get("language") if isinstance(data, dict) and len(data) <= 2 else None'

summary
